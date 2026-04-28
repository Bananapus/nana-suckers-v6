// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {PeerChainStateSucker} from "../unit/peer_chain_state.t.sol";

contract CodexNemesisSameTimestampSnapshotTest is Test {
    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);
    address constant TERMINAL = address(1200);
    address constant TERMINAL_2 = address(1201);
    address constant STORE = address(1300);
    address constant PRICES = address(1400);
    uint256 constant PROJECT_ID = 1;
    address constant TOKEN_A = address(0xA11CE);
    address constant TOKEN_B = address(0xB0B);
    /// @dev After the fix, the snapshot currency is the token-derived currency (61166), not JBCurrencyIds.ETH (1).
    uint256 constant NATIVE_TOKEN_CURRENCY =
        uint256(uint32(uint160(address(0x000000000000000000000000000000000000EEEe))));
    uint8 constant ETH_DECIMALS = 18;
    address constant NATIVE_TOKEN = address(0x000000000000000000000000000000000000EEEe);

    PeerChainStateSucker sucker;

    function setUp() public {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        PeerChainStateSucker singleton = new PeerChainStateSucker(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER
        );
        sucker = PeerChainStateSucker(payable(address(LibClone.clone(address(singleton)))));
        sucker.initialize(PROJECT_ID);

        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER, abi.encodeCall(IERC165.supportsInterface, (type(IJBController).interfaceId)), abi.encode(true)
        );
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, TOKEN_A)), abi.encode(TERMINAL)
        );
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, NATIVE_TOKEN)),
            abi.encode(address(0))
        );
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());
        vm.mockCall(address(1), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(new IJBTerminal[](0)));
    }

    function test_sameTimestampNewerTokenRootDoesNotRefreshPeerWideSnapshot() public {
        JBMessageRoot memory first = _root({
            token: TOKEN_A, nonce: 1, sourceTimestamp: 100, totalSupply: 100 ether, surplus: 10 ether, balance: 20 ether
        });

        JBMessageRoot memory second = _root({
            token: TOKEN_B,
            nonce: 1,
            sourceTimestamp: 100,
            totalSupply: 1000 ether,
            surplus: 100 ether,
            balance: 200 ether
        });

        vm.prank(address(sucker));
        sucker.fromRemote(first);

        vm.prank(address(sucker));
        sucker.fromRemote(second);

        assertEq(sucker.inboxOf(TOKEN_B).nonce, 1, "token-local root is accepted");
        assertEq(
            sucker.peerChainTotalSupply(),
            100 ether,
            "peer-wide supply remains stale when the newer snapshot has the same timestamp"
        );

        JBDenominatedAmount memory surplus = sucker.peerChainSurplusOf(ETH_DECIMALS, NATIVE_TOKEN_CURRENCY);
        assertEq(surplus.value, 10 ether, "peer-wide surplus also remains stale");
    }

    /// @notice After the currency mismatch fix, native ETH balance is correctly included in the snapshot.
    /// The fix changes _NATIVE_TOKEN_CURRENCY from JBCurrencyIds.ETH (1) to uint32(uint160(NATIVE_TOKEN)) (61166),
    /// so native token accounting contexts are correctly identified and their balance is included.
    function test_snapshotBuilderCorrectlyIncludesNativeBalance() public {
        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(TERMINAL);
        terminals[1] = IJBTerminal(TERMINAL_2);

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(
                IJBTerminal.currentSurplusOf,
                (PROJECT_ID, new address[](0), uint256(ETH_DECIMALS), NATIVE_TOKEN_CURRENCY)
            ),
            abi.encode(11 ether)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] =
            JBAccountingContext({token: NATIVE_TOKEN, decimals: ETH_DECIMALS, currency: uint32(NATIVE_TOKEN_CURRENCY)});

        vm.mockCall(TERMINAL, abi.encodeCall(IJBTerminal.accountingContextsOf, (PROJECT_ID)), abi.encode(contexts));
        vm.mockCall(TERMINAL, abi.encodeCall(IJBMultiTerminal.STORE, ()), abi.encode(STORE));
        vm.mockCall(STORE, abi.encodeCall(IJBTerminalStore.PRICES, ()), abi.encode(PRICES));
        vm.etch(PRICES, hex"00");
        vm.mockCall(
            STORE, abi.encodeCall(IJBTerminalStore.balanceOf, (TERMINAL, PROJECT_ID, NATIVE_TOKEN)), abi.encode(5 ether)
        );
        vm.mockCall(
            TERMINAL_2,
            abi.encodeCall(IJBTerminal.accountingContextsOf, (PROJECT_ID)),
            abi.encode(new JBAccountingContext[](0))
        );

        sucker.test_setRemoteToken(
            TOKEN_A, JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 300_000, addr: bytes32(uint256(1))})
        );
        sucker.test_insertIntoTree({
            projectTokenCount: 1,
            token: TOKEN_A,
            terminalTokenAmount: 0,
            beneficiary: bytes32(uint256(uint160(address(this))))
        });

        sucker.toRemote(TOKEN_A);

        JBMessageRoot memory sent = sucker.test_getLastSentMessage();
        assertEq(sent.sourceSurplus, 11 ether, "only terminal[0] surplus is snapshotted");
        // After the fix, native balance IS correctly included (was 0 before).
        assertEq(sent.sourceBalance, 5 ether, "native balance is now correctly included after currency fix");
    }

    function _root(
        address token,
        uint64 nonce,
        uint256 sourceTimestamp,
        uint256 totalSupply,
        uint256 surplus,
        uint256 balance
    )
        internal
        pure
        returns (JBMessageRoot memory)
    {
        return JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(token))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: bytes32(uint256(nonce))}),
            sourceTotalSupply: totalSupply,
            sourceCurrency: NATIVE_TOKEN_CURRENCY,
            sourceDecimals: ETH_DECIMALS,
            sourceSurplus: surplus,
            sourceBalance: balance,
            sourceTimestamp: sourceTimestamp
        });
    }
}
