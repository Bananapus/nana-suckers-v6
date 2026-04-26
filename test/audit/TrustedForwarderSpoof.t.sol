// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBArbitrumSucker} from "../../src/JBArbitrumSucker.sol";
import {JBLayer} from "../../src/enums/JBLayer.sol";
import {IArbGatewayRouter} from "../../src/interfaces/IArbGatewayRouter.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";
import {JBArbitrumSuckerDeployer} from "../../src/deployers/JBArbitrumSuckerDeployer.sol";
import {JBSucker} from "../../src/JBSucker.sol";

/// @notice Regression test: a trusted forwarder must NOT be able to spoof `fromRemote()`.
/// @dev Before the fix, `fromRemote()` used `_msgSender()`, which let a trusted forwarder
/// append a spoofed bridge-messenger address via the ERC-2771 calldata suffix.
/// After the fix, `fromRemote()` uses `msg.sender` directly, so the forwarder's own address
/// is checked against `_isRemotePeer` and the call reverts with `JBSucker_NotPeer`.
contract TrustedForwarderSpoofTest is Test {
    address internal constant DIRECTORY = address(0x1000);
    address internal constant PERMISSIONS = address(0x2000);
    address internal constant TOKENS = address(0x3000);
    address internal constant REGISTRY = address(0x4000);
    address internal constant CONTROLLER = address(0x5000);
    address internal constant FORWARDER = address(0x6000);
    address internal constant TOKEN = address(0x7000);

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant FORGED_TOKEN_COUNT = 123 ether;

    JBArbitrumSucker internal sucker;

    function setUp() external {
        // Mock DIRECTORY.PROJECTS() so the JBSucker constructor can initialize the PROJECTS immutable.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(address(0)));

        JBArbitrumSuckerDeployer deployer = new JBArbitrumSuckerDeployer({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            configurator: address(this),
            trustedForwarder: FORWARDER
        });

        deployer.setChainSpecificConstants({
            layer: JBLayer.L2, inbox: IInbox(address(0)), gatewayRouter: IArbGatewayRouter(address(0xBEEF))
        });

        JBArbitrumSucker singleton = new JBArbitrumSucker({
            deployer: deployer,
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(REGISTRY),
            trustedForwarder: FORWARDER
        });

        sucker = JBArbitrumSucker(payable(LibClone.cloneDeterministic(address(singleton), bytes32("codex-forwarder"))));
        sucker.initialize(PROJECT_ID);

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, FORGED_TOKEN_COUNT, address(this), "", false)),
            abi.encode(FORGED_TOKEN_COUNT)
        );
    }

    /// @notice Verify that a trusted forwarder cannot forge a `fromRemote()` root via ERC-2771.
    /// @dev The forwarder appends the aliased peer address to the calldata, but `fromRemote()`
    /// now checks `msg.sender` (the forwarder itself), which is not a valid remote peer.
    function test_trustedForwarderCannotForgeRootAfterFix() external {
        bytes32 beneficiary = bytes32(uint256(uint160(address(this))));
        bytes32[32] memory proof;

        bytes32 forgedRoot =
            MerkleLib.branchRoot(keccak256(abi.encode(FORGED_TOKEN_COUNT, uint256(0), beneficiary)), proof, 0);

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: forgedRoot}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            sourceTimestamp: 1
        });

        // Build the spoofed ERC-2771 calldata: real `fromRemote` encoding + 20-byte suffix
        // that _msgSender() would have decoded as the aliased peer address.
        address spoofedRemoteMessenger = AddressAliasHelper.applyL1ToL2Alias(address(sucker));
        bytes memory forwardedCalldata = bytes.concat(
            abi.encodeWithSignature(
                "fromRemote((uint8,bytes32,uint256,(uint64,bytes32),uint256,uint256,uint8,uint256,uint256,uint256))",
                root
            ),
            bytes20(spoofedRemoteMessenger)
        );

        // The call should revert because msg.sender is FORWARDER, not the aliased peer.
        vm.prank(FORWARDER);
        (bool ok, bytes memory returnData) = address(sucker).call(forwardedCalldata);
        assertFalse(ok, "forged fromRemote via trusted forwarder must revert");
        assertEq(bytes4(returnData), JBSucker.JBSucker_NotPeer.selector, "revert reason must be JBSucker_NotPeer");
    }
}
