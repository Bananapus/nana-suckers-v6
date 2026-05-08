// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";

/// @notice Harness to expose the library's `convertPeerValue` for direct unit testing.
contract DecimalHarness {
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

/// @notice Decimal-parametric fuzz and explicit tests for `JBSuckerLib.convertPeerValue`.
/// @dev Systematically sweeps decimal combinations to catch any hardcoded `1e18` or decimal assumption.
///      References TEST_IMPROVEMENT_PLAN.md Section 5.
contract DecimalParametricTest is Test {
    address internal constant PRICES = address(0xA00);
    uint256 internal constant PROJECT_ID = 1;

    uint32 internal constant CURRENCY_A = 1;
    uint32 internal constant CURRENCY_B = 2;

    DecimalHarness internal harness;

    function setUp() external {
        harness = new DecimalHarness();
        vm.etch(PRICES, hex"00");
    }

    // ─── Fuzz Tests
    // ───────────────────────────────────────────────────────

    /// @notice Fuzz: for any decimal pair and reasonable price, the conversion should match
    ///         the expected formula: result = amount * 10^dstDecimals / price
    function testFuzz_convertPeerValue_decimalSweep(
        uint8 srcDecimals,
        uint8 dstDecimals,
        uint128 amount,
        uint128 price
    )
        external
    {
        srcDecimals = uint8(bound(srcDecimals, 2, 24));
        dstDecimals = uint8(bound(dstDecimals, 2, 24));
        amount = uint128(bound(amount, 1, type(uint128).max));
        price = uint128(bound(price, 1, type(uint128).max));

        // Mock the price oracle
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, CURRENCY_A, CURRENCY_B, srcDecimals)),
            abi.encode(uint256(price))
        );

        JBDenominatedAmount memory source =
            JBDenominatedAmount({value: uint256(amount), currency: CURRENCY_A, decimals: srcDecimals});

        uint256 result =
            harness.convert(IJBPrices(PRICES), PROJECT_ID, source, uint256(dstDecimals), uint256(CURRENCY_B));

        // Expected: mulDiv(amount, 10^dstDecimals, price)
        uint256 expected = mulDiv(uint256(amount), 10 ** uint256(dstDecimals), uint256(price));

        assertEq(result, expected, "conversion must match expected formula");
    }

    /// @notice Fuzz: same-currency conversion only adjusts decimals (no price oracle needed).
    function testFuzz_sameCurrency_adjustsDecimals(uint8 srcDecimals, uint8 dstDecimals, uint128 amount) external view {
        srcDecimals = uint8(bound(srcDecimals, 0, 24));
        dstDecimals = uint8(bound(dstDecimals, 0, 24));
        amount = uint128(bound(amount, 0, type(uint128).max));

        JBDenominatedAmount memory source =
            JBDenominatedAmount({value: uint256(amount), currency: CURRENCY_A, decimals: srcDecimals});

        uint256 result =
            harness.convert(IJBPrices(PRICES), PROJECT_ID, source, uint256(dstDecimals), uint256(CURRENCY_A));

        // Same currency: adjust decimals only
        uint256 expected;
        if (dstDecimals >= srcDecimals) {
            expected = uint256(amount) * 10 ** (uint256(dstDecimals) - uint256(srcDecimals));
        } else {
            expected = uint256(amount) / 10 ** (uint256(srcDecimals) - uint256(dstDecimals));
        }

        assertEq(result, expected, "same-currency conversion must only adjust decimals");
    }

    /// @notice Fuzz: zero amount always returns zero regardless of parameters.
    function testFuzz_zeroAmount_alwaysZero(
        uint8 srcDecimals,
        uint8 dstDecimals,
        uint128 /* price */
    )
        external
        view
    {
        srcDecimals = uint8(bound(srcDecimals, 2, 24));
        dstDecimals = uint8(bound(dstDecimals, 2, 24));

        JBDenominatedAmount memory source = JBDenominatedAmount({value: 0, currency: CURRENCY_A, decimals: srcDecimals});

        uint256 result =
            harness.convert(IJBPrices(PRICES), PROJECT_ID, source, uint256(dstDecimals), uint256(CURRENCY_B));

        assertEq(result, 0, "zero input must always yield zero output");
    }

    // ─── Explicit Decimal Pair Tests (from TEST_IMPROVEMENT_PLAN.md §5) ──

    /// @notice (6, 18) — USDC→ETH — the AM scenario
    function test_explicit_6to18_USDC_ETH() external {
        uint256 price = 2000e6; // 2000 USDC per ETH at 6 decimals
        vm.mockCall(
            PRICES, abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, CURRENCY_A, CURRENCY_B, 6)), abi.encode(price)
        );

        JBDenominatedAmount memory source = JBDenominatedAmount({value: 1000e6, currency: CURRENCY_A, decimals: 6});
        uint256 result = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 18, uint256(CURRENCY_B));

        // 1000e6 * 10^18 / 2000e6 = 5e17 (0.5 ETH)
        assertEq(result, 5e17, "(6,18) USDC->ETH: 1000 USDC at 2000 should be 0.5 ETH");
    }

    /// @notice (18, 6) — ETH→USDC — inverse of AM
    function test_explicit_18to6_ETH_USDC() external {
        uint256 price = 5e14; // 0.0005 ETH per USDC at 18 decimals
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, CURRENCY_A, CURRENCY_B, 18)),
            abi.encode(price)
        );

        JBDenominatedAmount memory source = JBDenominatedAmount({value: 1e18, currency: CURRENCY_A, decimals: 18});
        uint256 result = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 6, uint256(CURRENCY_B));

        // 1e18 * 10^6 / 5e14 = 2000e6
        assertEq(result, 2000e6, "(18,6) ETH->USDC: 1 ETH at 0.0005 should be 2000 USDC");
    }

    /// @notice (8, 18) — WBTC→ETH
    function test_explicit_8to18_WBTC_ETH() external {
        uint256 price = 5e6; // 0.05 BTC per ETH at 8 decimals
        vm.mockCall(
            PRICES, abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, CURRENCY_A, CURRENCY_B, 8)), abi.encode(price)
        );

        JBDenominatedAmount memory source = JBDenominatedAmount({value: 1e8, currency: CURRENCY_A, decimals: 8});
        uint256 result = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 18, uint256(CURRENCY_B));

        // 1e8 * 10^18 / 5e6 = 20e18 (20 ETH)
        assertEq(result, 20e18, "(8,18) WBTC->ETH: 1 WBTC at 0.05 should be 20 ETH");
    }

    /// @notice (6, 6) — USDC→USDT (same decimals, different tokens)
    function test_explicit_6to6_USDC_USDT() external {
        uint256 price = 1e6; // 1:1 peg at 6 decimals
        vm.mockCall(
            PRICES, abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, CURRENCY_A, CURRENCY_B, 6)), abi.encode(price)
        );

        JBDenominatedAmount memory source = JBDenominatedAmount({value: 500e6, currency: CURRENCY_A, decimals: 6});
        uint256 result = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 6, uint256(CURRENCY_B));

        // 500e6 * 10^6 / 1e6 = 500e6
        assertEq(result, 500e6, "(6,6) USDC->USDT: 500 USDC at 1:1 should be 500 USDT");
    }

    /// @notice (18, 18) — ETH→DAI (the "always works" sanity check)
    function test_explicit_18to18_ETH_DAI() external {
        uint256 price = 1e18; // 1:1 at 18 decimals
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, CURRENCY_A, CURRENCY_B, 18)),
            abi.encode(price)
        );

        JBDenominatedAmount memory source = JBDenominatedAmount({value: 10e18, currency: CURRENCY_A, decimals: 18});
        uint256 result = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 18, uint256(CURRENCY_B));

        // 10e18 * 10^18 / 1e18 = 10e18
        assertEq(result, 10e18, "(18,18) ETH->DAI: 10 ETH at 1:1 should be 10 DAI");
    }
}
