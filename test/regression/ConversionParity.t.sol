// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";

/// @notice Harness to expose `convertPeerValue`.
contract ParityHarness {
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

/// @notice Cross-component conversion parity test.
/// @dev Asserts that `JBSuckerLib.convertPeerValue` and the `JBTerminalStore` conversion pattern
///      produce equivalent results for the same economic conversion. A divergence would mean
///      cross-chain accounting (suckers) and local accounting (terminal store) disagree on value,
///      which was the root cause of the conversion-direction bug.
///
///      The two components use slightly different decimal strategies:
///      - JBTerminalStore: `mulDiv(amount, 10^18, price_at_18_decimals)` then adjustDecimals
///      - JBSuckerLib: `mulDiv(amount, 10^targetDecimals, price_at_sourceDecimals)`
///
///      For same-precision conversions, results must be identical.
///      For cross-precision conversions, results may differ by rounding but must be within 1 wei
///      per decimal difference.
///
///      References TEST_IMPROVEMENT_PLAN.md Section 4.
contract ConversionParityTest is Test {
    address internal constant PRICES = address(0xA00);
    uint256 internal constant PROJECT_ID = 1;

    uint32 internal constant CURRENCY_A = 1;
    uint32 internal constant CURRENCY_B = 2;

    uint256 internal constant MAX_FIDELITY = 18; // JBTerminalStore._MAX_FIXED_POINT_FIDELITY

    ParityHarness internal harness;

    function setUp() external {
        harness = new ParityHarness();
        vm.etch(PRICES, hex"00");
    }

    /// @notice Replicate JBTerminalStore's conversion pattern: mulDiv(amount, 10^18, price@18dec)
    ///         then adjust decimals from 18 to targetDecimals.
    function _terminalStoreConvert(
        uint256 amount,
        uint8 srcDecimals,
        uint8 dstDecimals,
        uint256 priceAt18Dec
    )
        internal
        pure
        returns (uint256)
    {
        // Step 1: Adjust source amount from srcDecimals to MAX_FIDELITY (18)
        uint256 normalizedAmount =
            JBFixedPointNumber.adjustDecimals({value: amount, decimals: srcDecimals, targetDecimals: MAX_FIDELITY});

        // Step 2: Convert at 18 decimal fidelity (terminal store pattern)
        uint256 convertedAt18 = mulDiv(normalizedAmount, 10 ** MAX_FIDELITY, priceAt18Dec);

        // Step 3: Adjust from 18 to target decimals
        return
            JBFixedPointNumber.adjustDecimals({
                value: convertedAt18, decimals: MAX_FIDELITY, targetDecimals: dstDecimals
            });
    }

    /// @notice USDC (6) → ETH (18) at price 2000
    function test_parity_6to18_USDC_ETH() external {
        uint256 amount = 1000e6; // 1000 USDC
        uint8 srcDec = 6;
        uint8 dstDec = 18;

        // Price at source decimals (for sucker lib)
        uint256 priceAtSrc = 2000e6; // 2000 USDC per ETH at 6 dec
        // Price at 18 decimals (for terminal store)
        uint256 priceAt18 = 2000e18; // same price, 18 dec

        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, CURRENCY_A, CURRENCY_B, srcDec)),
            abi.encode(priceAtSrc)
        );

        JBDenominatedAmount memory source = JBDenominatedAmount({value: amount, currency: CURRENCY_A, decimals: srcDec});

        uint256 suckerResult = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, dstDec, uint256(CURRENCY_B));
        uint256 storeResult = _terminalStoreConvert(amount, srcDec, dstDec, priceAt18);

        // Both should produce 0.5 ETH = 5e17
        assertEq(suckerResult, 5e17, "sucker: 1000 USDC -> 0.5 ETH");
        assertEq(storeResult, 5e17, "store: 1000 USDC -> 0.5 ETH");
        assertEq(suckerResult, storeResult, "parity: USDC->ETH must match");
    }

    /// @notice ETH (18) → USDC (6) at price 2000
    function test_parity_18to6_ETH_USDC() external {
        uint256 amount = 1e18; // 1 ETH
        uint8 srcDec = 18;
        uint8 dstDec = 6;

        uint256 priceAtSrc = 5e14; // 0.0005 ETH per USDC at 18 dec
        uint256 priceAt18 = 5e14; // same (already at 18 dec)

        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, CURRENCY_A, CURRENCY_B, srcDec)),
            abi.encode(priceAtSrc)
        );

        JBDenominatedAmount memory source = JBDenominatedAmount({value: amount, currency: CURRENCY_A, decimals: srcDec});

        uint256 suckerResult = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, dstDec, uint256(CURRENCY_B));
        uint256 storeResult = _terminalStoreConvert(amount, srcDec, dstDec, priceAt18);

        // Both should produce 2000 USDC = 2000e6
        assertEq(suckerResult, 2000e6, "sucker: 1 ETH -> 2000 USDC");
        assertEq(storeResult, 2000e6, "store: 1 ETH -> 2000 USDC");
        assertEq(suckerResult, storeResult, "parity: ETH->USDC must match");
    }

    /// @notice WBTC (8) → ETH (18) at 1 BTC = 20 ETH
    function test_parity_8to18_WBTC_ETH() external {
        uint256 amount = 1e8; // 1 WBTC
        uint8 srcDec = 8;
        uint8 dstDec = 18;

        uint256 priceAtSrc = 5e6; // 0.05 BTC per ETH at 8 dec
        uint256 priceAt18 = 5e16; // 0.05 at 18 dec

        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, CURRENCY_A, CURRENCY_B, srcDec)),
            abi.encode(priceAtSrc)
        );

        JBDenominatedAmount memory source = JBDenominatedAmount({value: amount, currency: CURRENCY_A, decimals: srcDec});

        uint256 suckerResult = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, dstDec, uint256(CURRENCY_B));
        uint256 storeResult = _terminalStoreConvert(amount, srcDec, dstDec, priceAt18);

        // Both should produce 20 ETH = 20e18
        assertEq(suckerResult, 20e18, "sucker: 1 WBTC -> 20 ETH");
        assertEq(storeResult, 20e18, "store: 1 WBTC -> 20 ETH");
        assertEq(suckerResult, storeResult, "parity: WBTC->ETH must match");
    }

    /// @notice DAI (18) → USDC (6) at 1:1
    function test_parity_18to6_DAI_USDC() external {
        uint256 amount = 500e18; // 500 DAI
        uint8 srcDec = 18;
        uint8 dstDec = 6;

        uint256 priceAtSrc = 1e18; // 1:1 at 18 dec
        uint256 priceAt18 = 1e18;

        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, CURRENCY_A, CURRENCY_B, srcDec)),
            abi.encode(priceAtSrc)
        );

        JBDenominatedAmount memory source = JBDenominatedAmount({value: amount, currency: CURRENCY_A, decimals: srcDec});

        uint256 suckerResult = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, dstDec, uint256(CURRENCY_B));
        uint256 storeResult = _terminalStoreConvert(amount, srcDec, dstDec, priceAt18);

        // Both should produce 500 USDC = 500e6
        assertEq(suckerResult, 500e6, "sucker: 500 DAI -> 500 USDC");
        assertEq(storeResult, 500e6, "store: 500 DAI -> 500 USDC");
        assertEq(suckerResult, storeResult, "parity: DAI->USDC must match");
    }
}
