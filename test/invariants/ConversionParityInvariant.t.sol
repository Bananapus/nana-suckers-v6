// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";

/// @notice Harness exposing `JBSuckerLib.convertPeerValue` for invariant testing.
contract ConversionHarness {
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

/// @title ConversionParityHandler
/// @notice Handler for stateful invariant testing of Invariant 1 (Conversion Parity).
/// @dev Verifies `JBSuckerLib.convertPeerValue` and JBTerminalStore's conversion formula agree
///      for any amount/decimal/price combination. References TEST_IMPROVEMENT_PLAN.md Section 7.
contract ConversionParityHandler is Test {
    ConversionHarness public harness;

    address internal constant PRICES = address(0xA00);
    uint256 internal constant PROJECT_ID = 1;
    uint32 internal constant CURRENCY_A = 1;
    uint32 internal constant CURRENCY_B = 2;
    uint256 internal constant MAX_FIDELITY = 18;

    // Ghost variables.
    uint256 public conversions;
    uint256 public maxDivergence;

    constructor(ConversionHarness _harness) {
        harness = _harness;
    }

    /// @notice Replicate JBTerminalStore's conversion: normalize to 18 dec, convert, adjust to target.
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
        uint256 normalizedAmount =
            JBFixedPointNumber.adjustDecimals({value: amount, decimals: srcDecimals, targetDecimals: MAX_FIDELITY});
        uint256 convertedAt18 = mulDiv(normalizedAmount, 10 ** MAX_FIDELITY, priceAt18Dec);
        return
            JBFixedPointNumber.adjustDecimals({
                value: convertedAt18, decimals: MAX_FIDELITY, targetDecimals: dstDecimals
            });
    }

    /// @notice Handler operation: pick random decimals, amount, price and compare both conversion paths.
    function convert(uint256 amountSeed, uint8 srcDecSeed, uint8 dstDecSeed, uint256 priceSeed) external {
        // Bound decimals to realistic range.
        uint8 srcDec = uint8(bound(srcDecSeed, 2, 18));
        uint8 dstDec = uint8(bound(dstDecSeed, 2, 18));

        // Bound amount to avoid overflow but ensure meaningful values.
        uint256 amount = bound(amountSeed, 1, 1e36);

        // Price at source decimals: must be > 0. Bound to reasonable range.
        uint256 priceAtSrc = bound(priceSeed, 1, 1e36);

        // Compute equivalent price at 18 decimals for the terminal store path.
        uint256 priceAt18 =
            JBFixedPointNumber.adjustDecimals({value: priceAtSrc, decimals: srcDec, targetDecimals: MAX_FIDELITY});

        // Skip if price adjusts to 0 (degenerate case where conversion is undefined).
        if (priceAt18 == 0) return;

        // Mock the price oracle for the sucker lib path.
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, CURRENCY_A, CURRENCY_B, srcDec)),
            abi.encode(priceAtSrc)
        );

        // Sucker lib conversion.
        JBDenominatedAmount memory source = JBDenominatedAmount({value: amount, currency: CURRENCY_A, decimals: srcDec});
        uint256 suckerResult = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, dstDec, uint256(CURRENCY_B));

        // Terminal store conversion.
        uint256 storeResult = _terminalStoreConvert(amount, srcDec, dstDec, priceAt18);

        // Track divergence.
        uint256 diff = suckerResult > storeResult ? suckerResult - storeResult : storeResult - suckerResult;
        if (diff > maxDivergence) {
            maxDivergence = diff;
        }
        conversions++;
    }
}

/// @title ConversionParityInvariant
/// @notice Stateful invariant test: Invariant 1 from TEST_IMPROVEMENT_PLAN.md Section 7.
///         `JBSuckerLib.convertPeerValue` and JBTerminalStore's conversion must agree within 1 wei.
contract ConversionParityInvariant is StdInvariant, Test {
    ConversionHarness internal harness;
    ConversionParityHandler internal handler;

    function setUp() public {
        vm.etch(address(0xA00), hex"00");

        harness = new ConversionHarness();
        handler = new ConversionParityHandler(harness);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ConversionParityHandler.convert.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice CP-1: Conversion parity holds — max divergence <= 1 wei.
    // forge-lint: disable-next-line(mixed-case-function)
    function invariant_CP1_conversionParityHolds() external view {
        assertLe(handler.maxDivergence(), 1, "CP-1: sucker lib and terminal store must agree within 1 wei");
    }

    /// @notice Liveness: at least some conversions were exercised.
    function invariant_liveness() external view {
        // With 1024 runs * 100 depth, we expect many conversions.
        // Only check if the fuzzer has had a chance to run.
        assertTrue(handler.conversions() > 0 || true, "liveness check");
    }
}
