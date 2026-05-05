// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
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
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

contract ZeroSurplusForwardingTerminal {
    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract SnapshotGapHarness is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    JBMessageRoot private _lastSentMessage;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        address prices,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, prices, tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
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
        _lastSentMessage = message;
    }

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == _toAddress(peer());
    }

    function peerChainId() external view override returns (uint256) {
        return block.chainid;
    }

    function test_getLastSentMessage() external view returns (JBMessageRoot memory) {
        return _lastSentMessage;
    }

    function test_insertIntoTree(
        uint256 projectTokenCount,
        address token,
        uint256 terminalTokenAmount,
        bytes32 beneficiary
    )
        external
    {
        _insertIntoTree(projectTokenCount, token, terminalTokenAmount, beneficiary);
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
    address internal constant PRICES = address(1400);
    address internal constant FORWARDER = address(1500);

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant ETH_CURRENCY = 1;
    uint8 internal constant ETH_DECIMALS = 18;
    address internal constant TOKEN = address(0x000000000000000000000000000000000000EEEe);

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
        vm.mockCall(CONTROLLER, abi.encodeCall(IJBController.PRICES, ()), abi.encode(PRICES));
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(1000 ether))
        );

        vm.mockCall(address(1), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(IJBTerminal(address(0)))
        );
    }

    function test_forwardingTerminalFirstDoesNotZeroLaterTreasurySnapshot() public {
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

        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(address(forwardingTerminal));
        terminals[1] = IJBTerminal(REAL_TERMINAL);
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));

        uint32 nativeTokenCurrency = uint32(uint160(TOKEN));
        vm.mockCall(
            REAL_TERMINAL,
            abi.encodeCall(
                IJBTerminal.currentSurplusOf, (PROJECT_ID, new address[](0), ETH_DECIMALS, uint32(ETH_CURRENCY))
            ),
            abi.encode(uint256(40 ether))
        );
        vm.mockCall(REAL_TERMINAL, abi.encodeCall(IJBMultiTerminal.STORE, ()), abi.encode(STORE));
        vm.etch(PRICES, hex"00");

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: TOKEN, decimals: 18, currency: nativeTokenCurrency});
        vm.mockCall(REAL_TERMINAL, abi.encodeCall(IJBTerminal.accountingContextsOf, (PROJECT_ID)), abi.encode(contexts));
        vm.mockCall(
            STORE,
            abi.encodeCall(IJBTerminalStore.balanceOf, (REAL_TERMINAL, PROJECT_ID, TOKEN)),
            abi.encode(uint256(70 ether))
        );
        vm.mockCall(
            PRICES,
            abi.encodeCall(
                IJBPrices.pricePerUnitOf, (PROJECT_ID, nativeTokenCurrency, uint32(ETH_CURRENCY), ETH_DECIMALS)
            ),
            abi.encode(uint256(1 ether))
        );

        sucker.toRemote(TOKEN);

        JBMessageRoot memory message = sucker.test_getLastSentMessage();

        assertEq(message.sourceTotalSupply, 1000 ether, "control: snapshot still records controller supply");
        assertEq(message.sourceSurplus, 40 ether, "later terminal surplus is still snapshotted");
        assertEq(message.sourceBalance, 70 ether, "later terminal balance is still snapshotted");
    }

    function _createSucker() internal returns (SnapshotGapHarness) {
        SnapshotGapHarness singleton = new SnapshotGapHarness(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), PRICES, IJBTokens(TOKENS), FORWARDER
        );

        SnapshotGapHarness clone =
            SnapshotGapHarness(payable(address(LibClone.cloneDeterministic(address(singleton), bytes32("gap")))));
        clone.initialize(PROJECT_ID);
        return clone;
    }
}
