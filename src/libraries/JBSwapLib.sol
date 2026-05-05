// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

/// @notice Shared library for slippage tolerance and price limit calculations.
/// @dev Uses continuous sigmoid formula for smooth slippage tolerance across all swap sizes.
library JBSwapLib {
    /// @notice The denominator used for slippage tolerance basis points.
    uint256 internal constant SLIPPAGE_DENOMINATOR = 10_000;

    /// @notice The maximum slippage ceiling (88%).
    uint256 internal constant MAX_SLIPPAGE = 8800;

    /// @notice The precision multiplier for impact calculations.
    /// @dev Using 1e18 instead of 1e5 gives 13 extra orders of magnitude,
    ///      preventing small-swap-in-deep-pool impacts from rounding to zero.
    uint256 internal constant IMPACT_PRECISION = 1e18;

    /// @notice The K parameter for the sigmoid curve, scaled to match IMPACT_PRECISION.
    /// @dev K_new = 5000 * 1e18 / 1e5 = 5e16
    uint256 internal constant SIGMOID_K = 5e16;

    //*********************************************************************//
    // -------------------- Slippage Tolerance -------------------------- //
    //*********************************************************************//

    /// @notice Compute a continuous sigmoid slippage tolerance based on swap impact and pool fee.
    /// @dev tolerance = minSlippage + (maxSlippage - minSlippage) * impact / (impact + K)
    /// @param impact The estimated price impact from calculateImpact (scaled by IMPACT_PRECISION).
    /// @param poolFeeBps The pool fee in basis points (e.g., 30 for 0.3%).
    /// @return tolerance The slippage tolerance in basis points of SLIPPAGE_DENOMINATOR.
    function getSlippageTolerance(uint256 impact, uint256 poolFeeBps) internal pure returns (uint256) {
        if (poolFeeBps >= MAX_SLIPPAGE) return MAX_SLIPPAGE;

        uint256 minSlippage = poolFeeBps + 100;
        if (minSlippage < 200) minSlippage = 200;
        if (minSlippage >= MAX_SLIPPAGE) return MAX_SLIPPAGE;

        if (impact == 0) return minSlippage;

        if (impact > type(uint256).max - SIGMOID_K) return MAX_SLIPPAGE;

        uint256 range = MAX_SLIPPAGE - minSlippage;
        uint256 tolerance = minSlippage + mulDiv({x: range, y: impact, denominator: impact + SIGMOID_K});

        return tolerance;
    }

    //*********************************************************************//
    // -------------------- Impact Calculation -------------------------- //
    //*********************************************************************//

    /// @notice Estimate the price impact of a swap, scaled by IMPACT_PRECISION.
    /// @param amountIn The amount of tokens to swap in.
    /// @param liquidity The pool's in-range liquidity.
    /// @param sqrtP The sqrt price in Q96 format.
    /// @param zeroForOne Whether the swap is token0 -> token1.
    /// @return impact The estimated price impact scaled by IMPACT_PRECISION.
    function calculateImpact(
        uint256 amountIn,
        uint128 liquidity,
        uint160 sqrtP,
        bool zeroForOne
    )
        internal
        pure
        returns (uint256 impact)
    {
        if (liquidity == 0 || sqrtP == 0) return 0;

        uint256 base = mulDiv({x: amountIn, y: IMPACT_PRECISION, denominator: uint256(liquidity)});

        impact = zeroForOne
            ? mulDiv({x: base, y: uint256(sqrtP), denominator: uint256(1) << 96})
            : mulDiv({x: base, y: uint256(1) << 96, denominator: uint256(sqrtP)});
    }

    //*********************************************************************//
    // -------------------- Price Limit -------------------------------- //
    //*********************************************************************//

    /// @notice Compute a sqrtPriceLimitX96 from input/output amounts so the swap stops
    ///         if the execution price would be worse than the minimum acceptable rate.
    /// @param amountIn The amount of tokens to swap in.
    /// @param minimumAmountOut The minimum acceptable output.
    /// @param zeroForOne True when selling token0 for token1 (price decreases).
    /// @return sqrtPriceLimit The V3-compatible sqrtPriceLimitX96.
    function sqrtPriceLimitFromAmounts(
        uint256 amountIn,
        uint256 minimumAmountOut,
        bool zeroForOne
    )
        internal
        pure
        returns (uint160 sqrtPriceLimit)
    {
        if (minimumAmountOut == 0 || amountIn == 0) {
            return zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        }

        uint256 num;
        uint256 den;
        if (zeroForOne) {
            num = minimumAmountOut;
            den = amountIn;
        } else {
            num = amountIn;
            den = minimumAmountOut;
        }

        uint256 sqrtResult;

        if (num / den >= (uint256(1) << 128)) {
            return zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        } else if (num / den >= (uint256(1) << 64)) {
            uint256 ratioX128 = mulDiv({x: num, y: uint256(1) << 128, denominator: den});
            sqrtResult = Math.sqrt(ratioX128) * (uint256(1) << 32);
        } else {
            uint256 ratioX192 = mulDiv({x: num, y: uint256(1) << 192, denominator: den});
            sqrtResult = Math.sqrt(ratioX192);
        }

        if (zeroForOne) {
            if (sqrtResult <= uint256(TickMath.MIN_SQRT_RATIO)) {
                return TickMath.MIN_SQRT_RATIO + 1;
            }
            if (sqrtResult >= uint256(TickMath.MAX_SQRT_RATIO)) {
                return TickMath.MAX_SQRT_RATIO - 1;
            }
            // The bounds above clamp `sqrtResult` into the uint160 Uniswap sqrt-price domain.
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint160(sqrtResult);
        } else {
            if (sqrtResult >= uint256(TickMath.MAX_SQRT_RATIO)) {
                return TickMath.MAX_SQRT_RATIO - 1;
            }
            if (sqrtResult <= uint256(TickMath.MIN_SQRT_RATIO)) {
                return TickMath.MIN_SQRT_RATIO + 1;
            }
            // The bounds above clamp `sqrtResult` into the uint160 Uniswap sqrt-price domain.
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint160(sqrtResult);
        }
    }
}
