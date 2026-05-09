// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";

contract BuildETHAggregateConversionDirectionTest is Test {
    address internal constant DIRECTORY = address(0xA11CE);
    address internal constant PRICES = address(0xB0B);
    address internal constant STORE = address(0xC0DE);
    address internal constant TERMINAL = address(0xD00D);
    address internal constant USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant USDC_BALANCE = 5000e6;
    uint256 internal constant USD_PER_ETH = 2000e6;

    function setUp() external {
        vm.etch(DIRECTORY, hex"00");
        vm.etch(PRICES, hex"00");
        vm.etch(STORE, hex"00");
        vm.etch(TERMINAL, hex"00");
    }

    function test_nonEthTerminalBalanceIsConvertedWithInvertedPriceDirection() external {
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(TERMINAL);

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: USDC, decimals: 6, currency: JBCurrencyIds.USD});

        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)),
            abi.encode(terminals)
        );
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)),
            abi.encode(IERC165(address(0)))
        );
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(
                IJBTerminal.currentSurplusOf,
                (PROJECT_ID, new address[](0), uint256(18), uint256(JBCurrencyIds.ETH))
            ),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(IJBTerminal.accountingContextsOf, (PROJECT_ID)),
            abi.encode(contexts)
        );
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(IJBMultiTerminal.STORE, ()),
            abi.encode(IJBTerminalStore(STORE))
        );
        vm.mockCall(
            STORE,
            abi.encodeCall(IJBTerminalStore.balanceOf, (TERMINAL, PROJECT_ID, USDC)),
            abi.encode(USDC_BALANCE)
        );

        // Core semantics: pricePerUnitOf(USD, ETH, 6) returns the USD price of one ETH at source decimals.
        vm.mockCall(
            PRICES,
            abi.encodeCall(
                IJBPrices.pricePerUnitOf,
                (PROJECT_ID, uint256(JBCurrencyIds.USD), uint256(JBCurrencyIds.ETH), uint256(6))
            ),
            abi.encode(USD_PER_ETH)
        );

        JBMessageRoot memory message = JBSuckerLib.buildSnapshotMessage({
            directory: IJBDirectory(DIRECTORY),
            prices: IJBPrices(PRICES),
            projectId: PROJECT_ID,
            remoteToken: bytes32(uint256(1)),
            amount: 0,
            nonce: 1,
            root: bytes32(uint256(2)),
            messageVersion: 1,
            sourceTimestamp: 1
        });

        assertEq(message.sourceBalance, 2.5 ether);
    }
}
