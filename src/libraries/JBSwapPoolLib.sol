// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap V3 imports.
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

// Uniswap V4 imports.
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Local imports.
import {IGeomeanOracle} from "../interfaces/IGeomeanOracle.sol";
import {IWrappedNativeToken} from "../interfaces/IWrappedNativeToken.sol";
import {JBSwapLib} from "./JBSwapLib.sol";

/// @notice Library with Uniswap pool discovery, TWAP quoting, and swap execution logic extracted from
/// JBSwapCCIPSucker to reduce child contract sizes.
/// @dev These are `external` library functions, deployed as a separate contract and called via DELEGATECALL.
/// Swap callbacks (`uniswapV3SwapCallback`, `unlockCallback`) remain on the calling contract.
library JBSwapPoolLib {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    // -------------------- errors -------------------- //

    error JBSwapPoolLib_NoPool();
    error JBSwapPoolLib_NoLiquidity();
    error JBSwapPoolLib_InsufficientTwapHistory();
    error JBSwapPoolLib_AmountOverflow(uint256 amount);
    error JBSwapPoolLib_SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error JBSwapPoolLib_CallerNotPool(address caller);

    // -------------------- constants -------------------- //

    uint256 private constant _DEFAULT_TWAP_WINDOW = 600;
    uint256 private constant _MIN_TWAP_WINDOW = 120;
    uint32 private constant _V4_TWAP_WINDOW = 120;
    uint256 private constant _SLIPPAGE_DENOMINATOR = 10_000;

    // -------------------- structs -------------------- //

    /// @notice Configuration context for swap execution, packed into a struct to avoid stack-too-deep.
    struct SwapConfig {
        IUniswapV3Factory v3Factory;
        IPoolManager poolManager;
        address univ4Hook;
        address weth;
    }

    // -------------------- external state-changing -------------------- //

    /// @notice Execute a full swap: discover the best V3/V4 pool, quote via TWAP, execute the swap.
    /// @dev Runs via DELEGATECALL so the calling contract's balance and callbacks are used.
    /// @param config The swap configuration (factory, pool manager, hook, WETH addresses).
    /// @param tokenIn The input token (raw address, may be NATIVE_TOKEN sentinel).
    /// @param tokenOut The output token (raw address).
    /// @param amount The amount of input tokens to swap.
    /// @return amountOut The amount of output tokens received.
    function executeSwap(
        SwapConfig memory config,
        address tokenIn,
        address tokenOut,
        uint256 amount
    )
        external
        returns (uint256 amountOut)
    {
        address normalizedIn = _normalize(tokenIn, config.weth);
        address normalizedOut = _normalize(tokenOut, config.weth);

        // No swap needed if tokens are the same after normalization (e.g., NATIVE_TOKEN and WETH).
        if (normalizedIn == normalizedOut) return amount;

        // Discover the most liquid pool across V3 and V4.
        (bool isV4, IUniswapV3Pool v3Pool, PoolKey memory v4Key) =
            _discoverPool(config, normalizedIn, normalizedOut);

        if (!isV4 && address(v3Pool) == address(0)) revert JBSwapPoolLib_NoPool();

        if (isV4) {
            amountOut = _quoteAndSwapV4(config, v4Key, normalizedIn, normalizedOut, amount);
        } else {
            amountOut = _quoteAndSwapV3(v3Pool, normalizedIn, normalizedOut, amount, tokenIn);
            // V3 outputs WETH for native pairs — unwrap to raw ETH.
            if (tokenOut == JBConstants.NATIVE_TOKEN) {
                IWrappedNativeToken(config.weth).withdraw(amountOut);
            }
        }
    }

    /// @notice Externally accessible pool discovery for testing and off-chain queries.
    /// @param config The swap configuration (factory, pool manager, etc.).
    /// @param normalizedTokenIn The normalized input token address (WETH, not NATIVE_TOKEN).
    /// @param normalizedTokenOut The normalized output token address.
    /// @return isV4 Whether the best pool is a V4 pool.
    /// @return v3Pool The best V3 pool (or address(0) if V4 is better).
    /// @return v4Key The best V4 pool key (if V4 is better).
    function discoverPool(
        SwapConfig memory config,
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        returns (bool isV4, IUniswapV3Pool v3Pool, PoolKey memory v4Key)
    {
        return _discoverPool(config, normalizedTokenIn, normalizedTokenOut);
    }

    // -------------------- internal: pool discovery -------------------- //

    /// @notice Find the highest liquidity pool across all V3 fee tiers and V4 pool configurations.
    function _discoverPool(
        SwapConfig memory config,
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        internal
        view
        returns (bool isV4, IUniswapV3Pool v3Pool, PoolKey memory v4Key)
    {
        uint128 bestLiquidity;
        (v3Pool, bestLiquidity) = _discoverV3Pool(config.v3Factory, normalizedTokenIn, normalizedTokenOut);

        if (address(config.poolManager) != address(0)) {
            (PoolKey memory v4Candidate, uint128 v4Liquidity) =
                _discoverV4Pool(config, normalizedTokenIn, normalizedTokenOut);
            if (v4Liquidity > bestLiquidity) {
                if (address(v4Candidate.hooks) != address(0) || bestLiquidity == 0) {
                    isV4 = true;
                    v3Pool = IUniswapV3Pool(address(0));
                    v4Key = v4Candidate;
                }
            }
        }
    }

    /// @notice Search V3 pools across 4 fee tiers for the highest liquidity.
    function _discoverV3Pool(
        IUniswapV3Factory v3Factory,
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        internal
        view
        returns (IUniswapV3Pool bestPool, uint128 bestLiquidity)
    {
        if (address(v3Factory) == address(0)) return (bestPool, bestLiquidity);

        for (uint256 i; i < 4;) {
            // slither-disable-next-line calls-loop
            address poolAddr =
                v3Factory.getPool({tokenA: normalizedTokenIn, tokenB: normalizedTokenOut, fee: _feeTier(i)});

            if (poolAddr != address(0)) {
                // slither-disable-next-line calls-loop
                uint128 poolLiquidity = IUniswapV3Pool(poolAddr).liquidity();
                if (poolLiquidity > bestLiquidity) {
                    bestLiquidity = poolLiquidity;
                    bestPool = IUniswapV3Pool(poolAddr);
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Search V4 pools across 4 fee tiers and 2 hook configs for the highest liquidity.
    function _discoverV4Pool(
        SwapConfig memory config,
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        internal
        view
        returns (PoolKey memory bestKey, uint128 bestLiquidity)
    {
        // Convert to V4 convention: WETH -> address(0) for native ETH.
        address sorted0;
        address sorted1;
        {
            address v4In = normalizedTokenIn == config.weth ? address(0) : normalizedTokenIn;
            address v4Out = normalizedTokenOut == config.weth ? address(0) : normalizedTokenOut;
            (sorted0, sorted1) = v4In < v4Out ? (v4In, v4Out) : (v4Out, v4In);
        }

        for (uint256 i; i < 4;) {
            for (uint256 j; j < 2;) {
                address hookAddr = j == 0 ? address(0) : config.univ4Hook;
                if (j != 0 && hookAddr == address(0)) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }

                (PoolKey memory key, uint128 liq) =
                    _probeV4Pool(config.poolManager, sorted0, sorted1, hookAddr, i);
                if (liq > bestLiquidity) {
                    bestLiquidity = liq;
                    bestKey = key;
                }

                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Probe a single V4 pool configuration for liquidity.
    function _probeV4Pool(
        IPoolManager poolManager,
        address sorted0,
        address sorted1,
        address hookAddr,
        uint256 tierIndex
    )
        internal
        view
        returns (PoolKey memory key, uint128 poolLiquidity)
    {
        (uint24 fee, int24 tickSpacing) = _v4FeeAndTickSpacing(tierIndex);
        key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddr)
        });

        PoolId id = key.toId();

        // Check if pool is initialized (sqrtPriceX96 != 0).
        // slither-disable-next-line unused-return,calls-loop
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        // slither-disable-next-line incorrect-equality
        if (sqrtPriceX96 == 0) return (key, 0);

        // slither-disable-next-line calls-loop
        poolLiquidity = poolManager.getLiquidity(id);
    }

    // -------------------- internal: combined quote+swap -------------------- //

    /// @notice Quote via V4 TWAP/spot and execute swap. Separate function for stack isolation.
    function _quoteAndSwapV4(
        SwapConfig memory config,
        PoolKey memory key,
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint256 amount
    )
        internal
        returns (uint256 amountOut)
    {
        uint256 minOut = _getV4Quote(config, key, normalizedTokenIn, normalizedTokenOut, amount);
        amountOut = _executeV4Swap(config, key, normalizedTokenIn, amount, minOut);
    }

    /// @notice Quote via V3 TWAP and execute swap. Separate function for stack isolation.
    function _quoteAndSwapV3(
        IUniswapV3Pool pool,
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint256 amount,
        address originalTokenIn
    )
        internal
        returns (uint256 amountOut)
    {
        uint256 minOut = _getV3TwapQuote(pool, normalizedTokenIn, normalizedTokenOut, amount);
        amountOut = _executeV3Swap(pool, normalizedTokenIn, normalizedTokenOut, amount, minOut, originalTokenIn);
    }

    // -------------------- internal: quoting -------------------- //

    /// @notice Get a TWAP-based quote with dynamic slippage for a V3 pool.
    function _getV3TwapQuote(
        IUniswapV3Pool pool,
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint256 amount
    )
        internal
        view
        returns (uint256 minAmountOut)
    {
        uint256 feeBps = uint256(pool.fee()) / 100;

        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(address(pool));
        if (oldestObservation == 0) revert JBSwapPoolLib_InsufficientTwapHistory();

        uint256 twapWindow = _DEFAULT_TWAP_WINDOW;
        if (oldestObservation < twapWindow) twapWindow = oldestObservation;
        if (twapWindow < _MIN_TWAP_WINDOW) revert JBSwapPoolLib_InsufficientTwapHistory();

        (int24 arithmeticMeanTick, uint128 liquidity) =
            OracleLibrary.consult({pool: address(pool), secondsAgo: uint32(twapWindow)});

        if (liquidity == 0) revert JBSwapPoolLib_NoLiquidity();

        minAmountOut = _quoteWithSlippage({
            amount: amount,
            liquidity: liquidity,
            tokenIn: normalizedTokenIn,
            tokenOut: normalizedTokenOut,
            tick: arithmeticMeanTick,
            poolFeeBps: feeBps
        });
    }

    /// @notice Get a V4 quote with dynamic slippage. Prefers hook TWAP, falls back to spot tick.
    function _getV4Quote(
        SwapConfig memory config,
        PoolKey memory key,
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint256 amount
    )
        internal
        view
        returns (uint256 minAmountOut)
    {
        uint256 feeBps = uint256(key.fee) / 100;
        int24 tick;
        uint128 liquidity;

        {
            PoolId id = key.toId();
            bool usedTwap;

            if (address(key.hooks) != address(0)) {
                uint32[] memory secondsAgos = new uint32[](2);
                secondsAgos[0] = _V4_TWAP_WINDOW;
                secondsAgos[1] = 0;

                // slither-disable-next-line unused-return
                try IGeomeanOracle(address(key.hooks)).observe(key, secondsAgos) returns (
                    int56[] memory tickCumulatives, uint160[] memory
                ) {
                    tick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(_V4_TWAP_WINDOW)));
                    usedTwap = true;
                } catch {}
            }

            if (!usedTwap) {
                // slither-disable-next-line unused-return
                (, tick,,) = config.poolManager.getSlot0(id);
            }

            liquidity = config.poolManager.getLiquidity(id);
        }

        if (liquidity == 0) revert JBSwapPoolLib_NoLiquidity();

        // V4 uses address(0) for native ETH — compute quoting addresses inline to save stack slots.
        minAmountOut = _quoteWithSlippage({
            amount: amount,
            liquidity: liquidity,
            tokenIn: normalizedTokenIn == config.weth ? address(0) : normalizedTokenIn,
            tokenOut: normalizedTokenOut == config.weth ? address(0) : normalizedTokenOut,
            tick: tick,
            poolFeeBps: feeBps
        });
    }

    /// @notice Compute the minimum acceptable output using sigmoid slippage at the given tick.
    function _quoteWithSlippage(
        uint256 amount,
        uint128 liquidity,
        address tokenIn,
        address tokenOut,
        int24 tick,
        uint256 poolFeeBps
    )
        internal
        pure
        returns (uint256 minAmountOut)
    {
        uint256 slippageTolerance = _getSlippageTolerance({
            amountIn: amount,
            liquidity: liquidity,
            tokenOut: tokenOut,
            tokenIn: tokenIn,
            arithmeticMeanTick: tick,
            poolFeeBps: poolFeeBps
        });

        if (slippageTolerance >= _SLIPPAGE_DENOMINATOR) return 0;
        if (amount > type(uint128).max) revert JBSwapPoolLib_AmountOverflow(amount);

        minAmountOut = OracleLibrary.getQuoteAtTick({
            tick: tick,
            baseAmount: uint128(amount),
            baseToken: tokenIn,
            quoteToken: tokenOut
        });

        minAmountOut -= (minAmountOut * slippageTolerance) / _SLIPPAGE_DENOMINATOR;
    }

    /// @notice Compute the sigmoid slippage tolerance for a given swap.
    function _getSlippageTolerance(
        uint256 amountIn,
        uint128 liquidity,
        address tokenOut,
        address tokenIn,
        int24 arithmeticMeanTick,
        uint256 poolFeeBps
    )
        internal
        pure
        returns (uint256)
    {
        (address token0,) = tokenOut < tokenIn ? (tokenOut, tokenIn) : (tokenIn, tokenOut);
        bool zeroForOne = tokenIn == token0;

        uint160 sqrtP = TickMath.getSqrtPriceAtTick(arithmeticMeanTick);
        if (sqrtP == 0) return _SLIPPAGE_DENOMINATOR;

        uint256 impact =
            JBSwapLib.calculateImpact({amountIn: amountIn, liquidity: liquidity, sqrtP: sqrtP, zeroForOne: zeroForOne});

        return JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps});
    }

    // -------------------- internal: swap execution -------------------- //

    /// @notice Execute a swap through a V3 pool.
    function _executeV3Swap(
        IUniswapV3Pool pool,
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint256 amount,
        uint256 minAmountOut,
        address originalTokenIn
    )
        internal
        returns (uint256 amountOut)
    {
        bool zeroForOne = normalizedTokenIn < normalizedTokenOut;

        (int256 amount0, int256 amount1) = pool.swap({
            recipient: address(this),
            zeroForOne: zeroForOne,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: JBSwapLib.sqrtPriceLimitFromAmounts({
                amountIn: amount,
                minimumAmountOut: minAmountOut,
                zeroForOne: zeroForOne
            }),
            data: abi.encode(originalTokenIn, normalizedTokenIn, normalizedTokenOut)
        });

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        if (amountOut < minAmountOut) revert JBSwapPoolLib_SlippageExceeded(amountOut, minAmountOut);
    }

    /// @notice Execute a swap through a V4 pool via `PoolManager.unlock()`.
    function _executeV4Swap(
        SwapConfig memory config,
        PoolKey memory key,
        address normalizedTokenIn,
        uint256 amount,
        uint256 minAmountOut
    )
        internal
        returns (uint256 amountOut)
    {
        address v4In = normalizedTokenIn == config.weth ? address(0) : normalizedTokenIn;
        bool zeroForOne = Currency.unwrap(key.currency0) == v4In;

        uint160 sqrtPriceLimitX96 = JBSwapLib.sqrtPriceLimitFromAmounts({
            amountIn: amount,
            minimumAmountOut: minAmountOut,
            zeroForOne: zeroForOne
        });

        int256 exactInputAmount = -int256(amount);

        bytes memory result =
            config.poolManager.unlock(abi.encode(key, zeroForOne, exactInputAmount, sqrtPriceLimitX96, minAmountOut));

        amountOut = abi.decode(result, (uint256));
    }

    // -------------------- internal: helpers -------------------- //

    function _normalize(address token, address weth) internal pure returns (address) {
        return token == JBConstants.NATIVE_TOKEN ? weth : token;
    }

    function _feeTier(uint256 index) internal pure returns (uint24 fee) {
        if (index == 0) return 3000;
        if (index == 1) return 500;
        if (index == 2) return 10_000;
        return 100;
    }

    function _v4FeeAndTickSpacing(uint256 index) internal pure returns (uint24 fee, int24 tickSpacing) {
        if (index == 0) return (3000, 60);
        if (index == 1) return (500, 10);
        if (index == 2) return (10_000, 200);
        return (100, 1);
    }

    // -------------------- external: callback helpers -------------------- //

    /// @notice Execute the body of a V4 unlock callback. Called via DELEGATECALL from the sucker's
    /// `unlockCallback` so the V4 swap logic lives in library bytecode instead of the sucker's.
    /// @dev DELEGATECALL preserves msg.sender, address(this), and the sucker's token balances.
    /// @param poolManager The Uniswap V4 PoolManager.
    /// @param data The encoded swap parameters from PoolManager.unlock().
    /// @return Encoded output amount.
    function executeV4UnlockCallback(IPoolManager poolManager, bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, uint256 minAmountOut) =
            abi.decode(data, (PoolKey, bool, int256, uint160, uint256));

        // Execute the swap.
        BalanceDelta delta = poolManager.swap({
            key: key,
            params: SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            hookData: ""
        });

        // V4 sign convention: negative = we owe (input), positive = we're owed (output).
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        uint256 amountIn;
        uint256 amountOut;

        if (zeroForOne) {
            amountIn = uint256(uint128(-delta0));
            amountOut = uint256(uint128(delta1));
        } else {
            amountIn = uint256(uint128(-delta1));
            amountOut = uint256(uint128(delta0));
        }

        if (amountOut < minAmountOut) revert JBSwapPoolLib_SlippageExceeded(amountOut, minAmountOut);

        // Settle input (pay what we owe to the PoolManager).
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        if (Currency.unwrap(inputCurrency) == address(0)) {
            // slither-disable-next-line unused-return
            poolManager.settle{value: amountIn}();
        } else {
            poolManager.sync(inputCurrency);
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer({to: address(poolManager), value: amountIn});
            // slither-disable-next-line unused-return
            poolManager.settle();
        }

        // Take output (receive what the PoolManager owes us).
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        poolManager.take({currency: outputCurrency, to: address(this), amount: amountOut});

        return abi.encode(amountOut);
    }

    /// @notice Execute the body of a V3 swap callback. Called via DELEGATECALL from the sucker's
    /// `uniswapV3SwapCallback` so the V3 callback logic lives in library bytecode.
    /// @dev DELEGATECALL preserves msg.sender (the V3 pool), allowing pool verification.
    /// @param v3Factory The Uniswap V3 factory for pool verification.
    /// @param amount0Delta The amount of token0 being used for the swap.
    /// @param amount1Delta The amount of token1 being used for the swap.
    /// @param data Encoded (originalTokenIn, normalizedTokenIn, normalizedTokenOut).
    function executeV3SwapCallback(
        IUniswapV3Factory v3Factory,
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    )
        external
    {
        (address originalTokenIn, address normalizedIn, address normalizedOut) =
            abi.decode(data, (address, address, address));

        // Verify caller is a legitimate V3 pool via the factory.
        // slither-disable-next-line calls-loop
        uint24 fee = IUniswapV3Pool(msg.sender).fee();
        address expectedPool = v3Factory.getPool({tokenA: normalizedIn, tokenB: normalizedOut, fee: fee});
        if (msg.sender != expectedPool) revert JBSwapPoolLib_CallerNotPool(msg.sender);

        // The positive delta is what we owe to the pool.
        uint256 amountToSend = amount0Delta < 0 ? uint256(amount1Delta) : uint256(amount0Delta);

        // If input is native ETH, wrap to WETH for V3.
        // When originalTokenIn == NATIVE_TOKEN, normalizedIn is already the WETH address.
        if (originalTokenIn == JBConstants.NATIVE_TOKEN) {
            IWrappedNativeToken(normalizedIn).deposit{value: amountToSend}();
        }

        IERC20(normalizedIn).safeTransfer({to: msg.sender, value: amountToSend});
    }
}
