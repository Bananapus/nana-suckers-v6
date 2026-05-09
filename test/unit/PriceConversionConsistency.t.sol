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

import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";

/// @notice Verifies that buildSnapshotMessage and convertPeerValue produce consistent ETH values,
/// and that the ETH result never exceeds the actual token value.
contract PriceConversionConsistencyTest is Test {
    address internal constant DIRECTORY = address(0xA11CE);
    address internal constant PRICES = address(0xB0B);
    address internal constant STORE = address(0xC0DE);
    address internal constant TERMINAL = address(0xD00D);
    address internal constant USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    uint256 internal constant PROJECT_ID = 1;

    function setUp() external {
        vm.etch(DIRECTORY, hex"00");
        vm.etch(PRICES, hex"00");
        vm.etch(STORE, hex"00");
        vm.etch(TERMINAL, hex"00");
    }

    /// @notice buildSnapshotMessage and convertPeerValue produce identical ETH values for the same inputs.
    function test_buildAndConvertProduceIdenticalETHValues() external {
        uint256 balance = 5000e6;
        uint256 priceAtSourceDecimals = 2000e6; // 2000 USDC per 1 ETH at 6 decimals

        // Set up terminal with USDC accounting context (6 decimals, USD currency).
        _mockSingleERC20Terminal(USDC, 6, JBCurrencyIds.USD, balance, priceAtSourceDecimals);

        // Get ETH value via buildSnapshotMessage.
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

        // Get ETH value via convertPeerValue.
        JBDenominatedAmount memory source =
            JBDenominatedAmount({value: balance, currency: uint32(JBCurrencyIds.USD), decimals: 6});
        uint256 converted = JBSuckerLib.convertPeerValue({
            prices: IJBPrices(PRICES),
            projectId: PROJECT_ID,
            source: source,
            decimals: 18,
            currency: JBCurrencyIds.ETH
        });

        assertEq(message.sourceBalance, converted, "buildSnapshotMessage and convertPeerValue must agree");
        assertEq(message.sourceBalance, 2.5 ether, "5000 USDC at 2000 USD/ETH = 2.5 ETH");
    }

    /// @notice Fuzz across decimal values (6, 8, 18) verifying ETH result is sane.
    function test_fuzzDecimalValues() external {
        uint8[3] memory decimalValues = [6, 8, 18];

        for (uint256 i = 0; i < decimalValues.length; i++) {
            uint8 dec = decimalValues[i];
            uint256 balance = 5000 * 10 ** dec;
            uint256 price = 2000 * 10 ** dec; // 2000 tokens per ETH at source decimals

            _mockSingleERC20Terminal(USDC, dec, JBCurrencyIds.USD, balance, price);

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

            // 5000 tokens / 2000 tokens-per-ETH = 2.5 ETH regardless of decimals.
            assertEq(message.sourceBalance, 2.5 ether, string.concat("decimals=", vm.toString(dec)));
        }
    }

    function _mockSingleERC20Terminal(
        address token,
        uint8 dec,
        uint256 currency,
        uint256 balance,
        uint256 price
    )
        internal
    {
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(TERMINAL);

        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: token, decimals: dec, currency: uint32(currency)});

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(IERC165(address(0)))
        );
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(IJBTerminal.currentSurplusOf, (PROJECT_ID, new address[](0), uint256(18), uint256(JBCurrencyIds.ETH))),
            abi.encode(uint256(0))
        );
        vm.mockCall(TERMINAL, abi.encodeCall(IJBTerminal.accountingContextsOf, (PROJECT_ID)), abi.encode(contexts));
        vm.mockCall(TERMINAL, abi.encodeCall(IJBMultiTerminal.STORE, ()), abi.encode(IJBTerminalStore(STORE)));
        vm.mockCall(STORE, abi.encodeCall(IJBTerminalStore.balanceOf, (TERMINAL, PROJECT_ID, token)), abi.encode(balance));
        vm.mockCall(STORE, abi.encodeCall(IJBTerminalStore.PRICES, ()), abi.encode(PRICES));

        vm.mockCall(
            PRICES,
            abi.encodeCall(
                IJBPrices.pricePerUnitOf,
                (PROJECT_ID, uint256(currency), uint256(JBCurrencyIds.ETH), uint256(dec))
            ),
            abi.encode(price)
        );
    }
}
