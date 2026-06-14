// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {SuckerForkHelpers} from "../helpers/SuckerForkHelpers.sol";
import {JBSucker} from "../../src/JBSucker.sol";
import {JBOptimismSucker} from "../../src/JBOptimismSucker.sol";
import {JBOptimismSuckerDeployer} from "../../src/deployers/JBOptimismSuckerDeployer.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {IOPMessenger} from "../../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../../src/interfaces/IOPStandardBridge.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBChainAccounting} from "../../src/structs/JBChainAccounting.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

/// @notice Receive-side fork coverage for the OP Stack sucker. Existing `ForkOPStack.t.sol` exercises the
/// **send-side**: pay -> bridge a root + funds to the canonical OP messenger. That path proves the bridge accepted
/// our outbound call. This file pins the inverse: the L2 sucker's `fromRemote` correctly authenticates against
/// the **real** L2 `CrossDomainMessenger` (`0x4200000000000000000000000000000000000007`) — accepting messages
/// from the messenger with the correct `xDomainMessageSender`, and rejecting impostors.
///
/// All assertions run against the canonical L2 messenger bytecode on a real Optimism fork. The
/// `xDomainMessageSender` return value is the only thing we mock (it's normally set by the messenger itself during
/// the relay; we set it via `vm.mockCall` so we can drive the test deterministically without an actual L1->L2 relay).
contract OPStackReceiveSideFork is SuckerForkHelpers {
    // L2 OP predeploy — canonical across every OP Stack chain.
    IOPMessenger constant L2_MESSENGER = IOPMessenger(0x4200000000000000000000000000000000000007);
    IOPStandardBridge constant L2_BRIDGE = IOPStandardBridge(0x4200000000000000000000000000000000000010);

    JBOptimismSuckerDeployer suckerDeployer;
    JBOptimismSucker sucker;
    address peerAddress; // The L1 sucker peer (same address as L2 sucker thanks to CREATE2).

    function setUp() public override {
        _initMetadata();

        // Fork Optimism mainnet.
        vm.createSelectFork("optimism");
        vm.rollFork(block.number - 5);
        super.setUp();
        vm.stopPrank();

        // Deploy the sucker on the L2 fork using the canonical L2 messenger + bridge.
        vm.startPrank(address(0x1112222));
        suckerDeployer =
            new JBOptimismSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        vm.stopPrank();

        suckerDeployer.setChainSpecificConstants(L2_MESSENGER, L2_BRIDGE);

        vm.startPrank(address(0x1112222));
        JBOptimismSucker singleton = new JBOptimismSucker({
            deployer: suckerDeployer,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        suckerDeployer.configureSingleton(singleton);
        // Bind a known peer address that's deterministically the L1 sucker (same address via CREATE2).
        peerAddress = makeAddr("L1Peer");
        sucker = JBOptimismSucker(
            payable(address(suckerDeployer.createForSender(1, "l2-recv-salt", bytes32(uint256(uint160(peerAddress))))))
        );

        vm.label(address(sucker), "suckerL2");
        vm.label(address(L2_MESSENGER), "L2_MESSENGER");

        _launchProject();

        // Registry fee call falls through cleanly when there's no registry.
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
        // Registry gossip set is empty when there's no registry (project's only sucker is the one under test).
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IJBSuckerRegistry.peerChainAccountsOf.selector),
            abi.encode(new JBChainAccounting[](0))
        );
    }

    function _buildRoot(uint64 nonce, bytes32 root) internal pure returns (JBMessageRoot memory) {
        return JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: root}),
            accounts: new JBChainAccounting[](0)
        });
    }

    /// @notice Real L2 messenger calling `fromRemote` with the matching `xDomainMessageSender` (the L1 peer) is
    /// accepted, and the inbox root is updated.
    function testFork_fromRemote_acceptedFromRealMessenger() public {
        // Mock xDomainMessageSender so the real messenger appears to be relaying from the peer.
        vm.mockCall(
            address(L2_MESSENGER),
            abi.encodeWithSelector(IOPMessenger.xDomainMessageSender.selector),
            abi.encode(peerAddress)
        );

        JBMessageRoot memory root = _buildRoot(1, bytes32(uint256(0xBEEF)));
        vm.prank(address(L2_MESSENGER));
        sucker.fromRemote(root);

        JBInboxTreeRoot memory inbox = sucker.inboxOf(JBConstants.NATIVE_TOKEN);
        assertEq(inbox.nonce, 1, "inbox nonce updated by accepted relay");
        assertEq(inbox.root, bytes32(uint256(0xBEEF)), "inbox root updated by accepted relay");
    }

    /// @notice Non-messenger caller — even if they're at a contract address with code — is rejected by
    /// `_isRemotePeer` because `msg.sender != L2_MESSENGER`.
    function testFork_fromRemote_rejectedFromNonMessengerCaller() public {
        address impostor = makeAddr("impostor");

        // Even if the impostor faked an xDomainMessageSender, msg.sender check fires first.
        vm.mockCall(
            address(L2_MESSENGER),
            abi.encodeWithSelector(IOPMessenger.xDomainMessageSender.selector),
            abi.encode(peerAddress)
        );

        JBMessageRoot memory root = _buildRoot(1, bytes32(uint256(0xDEAD)));
        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_NotPeer.selector, bytes32(uint256(uint160(impostor)))));
        sucker.fromRemote(root);
    }

    /// @notice Real L2 messenger calling, but `xDomainMessageSender` reports an address other than the peer.
    /// The sucker must reject because `_toBytes32(xDomainMessageSender) != peer()`.
    function testFork_fromRemote_rejectedWhenXDomainSenderIsNotPeer() public {
        address wrongRemote = makeAddr("wrongRemote");

        vm.mockCall(
            address(L2_MESSENGER),
            abi.encodeWithSelector(IOPMessenger.xDomainMessageSender.selector),
            abi.encode(wrongRemote)
        );

        JBMessageRoot memory root = _buildRoot(1, bytes32(uint256(0xC0FFEE)));
        vm.prank(address(L2_MESSENGER));
        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_NotPeer.selector, bytes32(uint256(uint160(address(L2_MESSENGER)))))
        );
        sucker.fromRemote(root);
    }

    /// @notice Stale nonce delivery: a second relay with a smaller nonce does not overwrite the inbox root.
    function testFork_fromRemote_staleNonceDoesNotOverwrite() public {
        vm.mockCall(
            address(L2_MESSENGER),
            abi.encodeWithSelector(IOPMessenger.xDomainMessageSender.selector),
            abi.encode(peerAddress)
        );

        // First delivery, nonce 5.
        vm.prank(address(L2_MESSENGER));
        sucker.fromRemote(_buildRoot(5, bytes32(uint256(0xAAAA))));

        // Second delivery, nonce 3 — stale, must not overwrite.
        vm.prank(address(L2_MESSENGER));
        sucker.fromRemote(_buildRoot(3, bytes32(uint256(0xBBBB))));

        JBInboxTreeRoot memory inbox = sucker.inboxOf(JBConstants.NATIVE_TOKEN);
        assertEq(inbox.nonce, 5, "stale nonce did not overwrite");
        assertEq(inbox.root, bytes32(uint256(0xAAAA)), "stale root did not overwrite");
    }

    /// @notice Higher-nonce delivery does overwrite (monotonic acceptance).
    function testFork_fromRemote_higherNonceOverwrites() public {
        vm.mockCall(
            address(L2_MESSENGER),
            abi.encodeWithSelector(IOPMessenger.xDomainMessageSender.selector),
            abi.encode(peerAddress)
        );

        vm.prank(address(L2_MESSENGER));
        sucker.fromRemote(_buildRoot(1, bytes32(uint256(0x1111))));

        vm.prank(address(L2_MESSENGER));
        sucker.fromRemote(_buildRoot(2, bytes32(uint256(0x2222))));

        JBInboxTreeRoot memory inbox = sucker.inboxOf(JBConstants.NATIVE_TOKEN);
        assertEq(inbox.nonce, 2, "newer nonce updates");
        assertEq(inbox.root, bytes32(uint256(0x2222)), "newer root updates");
    }
}
