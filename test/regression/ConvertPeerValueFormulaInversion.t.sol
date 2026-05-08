// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";

import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";

/// @notice Harness to expose the library's `convertPeerValue` for direct unit testing.
contract ConvertPeerValueHarness {
    function convert(
        IJBPrices prices,
        uint256 projectId,
        JBDenominatedAmount memory source,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256)
    {
        return JBSuckerLib.convertPeerValue(prices, projectId, source, decimals, currency);
    }
}

/// @notice Regression test for bug AM — `convertPeerValue` formula inversion.
/// @dev The old formula used `mulDiv(source.value, price, 10**decimals)` which inverts
///      the conversion direction. The fix uses `mulDiv(source.value, 10**decimals, price)`.
///      These tests verify correct cross-decimal, cross-currency conversions.
contract ConvertPeerValueFormulaInversionTest is Test {
    address internal constant PRICES = address(0xA00);
    uint256 internal constant PROJECT_ID = 1;

    // Currency IDs matching JBCurrencyIds convention
    uint32 internal constant ETH_CURRENCY = 1;
    uint32 internal constant USD_CURRENCY = 2;
    uint32 internal constant BTC_CURRENCY = 3;

    ConvertPeerValueHarness internal harness;

    function setUp() external {
        harness = new ConvertPeerValueHarness();
        vm.etch(PRICES, hex"00");
    }

    /// @notice USDC (6 dec) → ETH (18 dec) at price 2000 USD/ETH → expect 0.5 ETH.
    function test_usdc6dec_to_eth18dec() external {
        // price oracle: pricePerUnitOf(project, USD, ETH, 6 decimals) = 2000e6
        // meaning 1 USD = 2000e6 units at 6 decimals → but wait, the price is "per unit of ETH in USD"
        // Actually: pricePerUnitOf(pricingCurrency=USD, unitCurrency=ETH, decimals=sourceDecimals)
        // returns price of 1 ETH in USD at source decimals = 2000 * 10^6 = 2_000_000_000
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, USD_CURRENCY, uint32(ETH_CURRENCY), 6)),
            abi.encode(uint256(2000e6))
        );

        // Source: 1000 USDC = 1000e6 at 6 decimals, USD currency
        JBDenominatedAmount memory source = JBDenominatedAmount({value: 1000e6, currency: USD_CURRENCY, decimals: 6});

        // Convert to ETH at 18 decimals
        uint256 result = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 18, uint256(ETH_CURRENCY));

        // 1000 USD / 2000 USD per ETH = 0.5 ETH = 5e17
        assertEq(result, 5e17, "1000 USDC should convert to 0.5 ETH");
    }

    /// @notice ETH (18 dec) → USDC (6 dec) at price 2000 USD/ETH → expect 2000 USDC.
    function test_eth18dec_to_usdc6dec() external {
        // pricePerUnitOf(pricingCurrency=ETH, unitCurrency=USD, decimals=sourceDecimals=18)
        // price of 1 USD in ETH at 18 decimals = 0.0005 ETH = 5e14
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, ETH_CURRENCY, USD_CURRENCY, 18)),
            abi.encode(uint256(5e14))
        );

        // Source: 1 ETH = 1e18 at 18 decimals, ETH currency
        JBDenominatedAmount memory source = JBDenominatedAmount({value: 1e18, currency: ETH_CURRENCY, decimals: 18});

        // Convert to USD at 6 decimals
        uint256 result = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 6, uint256(USD_CURRENCY));

        // 1 ETH * (10^6 / 5e14) = 1e18 * 1e6 / 5e14 = 2000e6
        assertEq(result, 2000e6, "1 ETH should convert to 2000 USDC");
    }

    /// @notice WBTC (8 dec) → ETH (18 dec) conversion.
    function test_wbtc8dec_to_eth18dec() external {
        // pricePerUnitOf(pricingCurrency=BTC, unitCurrency=ETH, decimals=sourceDecimals=8)
        // price of 1 ETH in BTC at 8 decimals = 0.05 BTC = 5e6
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, BTC_CURRENCY, uint32(ETH_CURRENCY), 8)),
            abi.encode(uint256(5e6))
        );

        // Source: 1 WBTC = 1e8 at 8 decimals, BTC currency
        JBDenominatedAmount memory source = JBDenominatedAmount({value: 1e8, currency: BTC_CURRENCY, decimals: 8});

        // Convert to ETH at 18 decimals
        uint256 result = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 18, uint256(ETH_CURRENCY));

        // 1 BTC / 0.05 BTC per ETH = 20 ETH = 20e18
        assertEq(result, 20e18, "1 WBTC should convert to 20 ETH");
    }

    /// @notice Zero amount → zero result regardless of price.
    function test_zeroAmount_returnsZero() external view {
        JBDenominatedAmount memory source = JBDenominatedAmount({value: 0, currency: USD_CURRENCY, decimals: 6});

        uint256 result = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 18, uint256(ETH_CURRENCY));

        assertEq(result, 0, "zero input should yield zero output");
    }

    /// @notice Same currency conversion only adjusts decimals (no price oracle call).
    function test_sameCurrency_adjustsDecimals() external view {
        // 1000 USDC at 6 decimals → same currency at 18 decimals
        JBDenominatedAmount memory source = JBDenominatedAmount({value: 1000e6, currency: USD_CURRENCY, decimals: 6});

        uint256 result = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 18, uint256(USD_CURRENCY));

        assertEq(result, 1000e18, "same currency should only adjust decimals");
    }
}
