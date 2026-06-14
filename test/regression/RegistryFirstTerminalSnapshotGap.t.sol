// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBChainAccounting} from "../../src/structs/JBChainAccounting.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @notice A terminal that holds no accounting contexts (it forwards funds elsewhere), used as the first terminal so
/// it contributes nothing to the snapshot.
contract ZeroSurplusForwardingTerminal {
    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract SnapshotGapHarness is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    // The struct's dynamic context array can't be copied to storage without the IR pipeline, so capture it encoded.
    bytes private _lastSentMessage;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
    {}

    function _sendRootOverAMB(
        uint256,
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBMessageRoot memory message
    )
        internal
        override
    {
        _lastSentMessage = abi.encode(message);
    }

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == _toAddress(peer());
    }

    function peerChainId() public view override returns (uint256) {
        return block.chainid;
    }

    function test_getLastSentMessage() external view returns (JBMessageRoot memory) {
        return abi.decode(_lastSentMessage, (JBMessageRoot));
    }

    function test_insertIntoTree(
        uint256 projectTokenCount,
        address token,
        uint256 terminalTokenAmount,
        bytes32 beneficiary
    )
        external
    {
        _insertIntoTree(projectTokenCount, token, terminalTokenAmount, beneficiary, bytes32(0));
    }

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }
}

contract RegistryFirstTerminalSnapshotGapTest is Test {
    address internal constant DIRECTORY = address(600);
    address internal constant PERMISSIONS = address(800);
    address internal constant TOKENS = address(700);
    address internal constant PROJECTS = address(1000);
    address internal constant CONTROLLER = address(1100);
    address internal constant REAL_TERMINAL = address(1200);
    address internal constant STORE = address(1300);
    address internal constant FORWARDER = address(1500);

    uint256 internal constant PROJECT_ID = 1;
    uint8 internal constant ETH_DECIMALS = 18;
    address internal constant TOKEN = address(0x000000000000000000000000000000000000EEEe);

    /// @dev An accounting context's currency is token-keyed.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 internal constant NATIVE_CURRENCY = uint32(uint160(TOKEN));

    SnapshotGapHarness internal sucker;
    ZeroSurplusForwardingTerminal internal forwardingTerminal;

    function setUp() public {
        vm.warp(100 days);

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(IJBProjects(PROJECTS)));

        sucker = _createSucker();
        forwardingTerminal = new ZeroSurplusForwardingTerminal();

        vm.mockCall(PROJECTS, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.etch(CONTROLLER, hex"00");
        vm.mockCall(
            CONTROLLER, abi.encodeCall(IERC165.supportsInterface, (type(IJBController).interfaceId)), abi.encode(true)
        );
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(1000 ether))
        );

        vm.mockCall(address(1), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
        // Mock registry.peerChainAccountsOf() so the gossip gather in _sendRoot() returns an empty peer set.
        vm.mockCall(
            address(1),
            abi.encodeWithSelector(IJBSuckerRegistry.peerChainAccountsOf.selector),
            abi.encode(new JBChainAccounting[](0))
        );
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(IJBTerminal(address(0)))
        );
    }

    function test_forwardingTerminalFirstDoesNotDropLaterTreasurySnapshot() public {
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );

        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        // Forwarding terminal first (no accounting contexts), real treasury terminal second.
        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(address(forwardingTerminal));
        terminals[1] = IJBTerminal(REAL_TERMINAL);
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));

        vm.etch(REAL_TERMINAL, hex"00");
        vm.etch(STORE, hex"00");

        // Real terminal: one native accounting context with raw per-token surplus and balance.
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: TOKEN, decimals: 18, currency: NATIVE_CURRENCY});
        vm.mockCall(REAL_TERMINAL, abi.encodeCall(IJBTerminal.accountingContextsOf, (PROJECT_ID)), abi.encode(contexts));

        address[] memory oneToken = new address[](1);
        oneToken[0] = TOKEN;
        vm.mockCall(
            REAL_TERMINAL,
            abi.encodeCall(IJBTerminal.currentSurplusOf, (PROJECT_ID, oneToken, ETH_DECIMALS, NATIVE_CURRENCY)),
            abi.encode(uint256(40 ether))
        );
        vm.mockCall(REAL_TERMINAL, abi.encodeCall(IJBMultiTerminal.STORE, ()), abi.encode(STORE));
        vm.mockCall(
            STORE,
            abi.encodeCall(IJBTerminalStore.balanceOf, (REAL_TERMINAL, PROJECT_ID, TOKEN)),
            abi.encode(uint256(70 ether))
        );

        sucker.toRemote(TOKEN);

        JBMessageRoot memory message = sucker.test_getLastSentMessage();

        // The sender's own chain leads the gossip bundle; with no registry-gathered peers it is the only record.
        assertEq(message.accounts.length, 1, "only the local chain's record is bundled");
        assertEq(message.accounts[0].chainId, block.chainid, "local record carries the source chain id");
        assertEq(message.accounts[0].totalSupply, 1000 ether, "control: snapshot still records controller supply");
        assertEq(message.accounts[0].contexts.length, 1, "only the treasury terminal contributes a context");
        assertEq(
            message.accounts[0].contexts[0].token,
            bytes32(uint256(uint160(TOKEN))),
            "later terminal's token is snapshotted"
        );
        assertEq(message.accounts[0].contexts[0].surplus, 40 ether, "later terminal surplus is still snapshotted");
        assertEq(message.accounts[0].contexts[0].balance, 70 ether, "later terminal balance is still snapshotted");
    }

    function _createSucker() internal returns (SnapshotGapHarness) {
        SnapshotGapHarness singleton =
            new SnapshotGapHarness(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER);

        SnapshotGapHarness clone =
        // forge-lint: disable-next-line(unsafe-typecast)
        SnapshotGapHarness(payable(address(LibClone.cloneDeterministic(address(singleton), keccak256(bytes("gap"))))));
        clone.initialize(PROJECT_ID);
        return clone;
    }
}
