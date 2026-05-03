// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// External packages (alphabetized).
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3PoolState} from "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolState.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Local: libraries (alphabetized).
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

// Local: interfaces (alphabetized).
import {IGeomeanOracle} from "../interfaces/IGeomeanOracle.sol";
import {IWrappedNativeToken} from "../interfaces/IWrappedNativeToken.sol";

// Local: libraries (alphabetized).
import {JBSwapLib} from "./JBSwapLib.sol";

/// @notice Library with Uniswap pool discovery, TWAP quoting, and swap execution logic extracted from
/// JBSwapCCIPSucker to reduce child contract sizes.
/// @dev These are `external` library functions, deployed as a separate contract and called via DELEGATECALL.
/// Swap callbacks (`uniswapV3SwapCallback`, `unlockCallback`) remain on the calling contract.
library JBSwapPoolLib {
    // A library for converting pool keys to pool IDs.
    using PoolIdLibrary for PoolKey;
    // A library for reading pool state from the pool manager.
    using StateLibrary for IPoolManager;
    // A library for extracting individual amounts from balance deltas.
    using BalanceDeltaLibrary for BalanceDelta;
    // A library for safe ERC-20 transfers.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBSwapPoolLib_AmountOverflow(uint256 amount);
    error JBSwapPoolLib_CallerNotPool(address caller);
    error JBSwapPoolLib_InsufficientTwapHistory();
    error JBSwapPoolLib_NoLiquidity();
    error JBSwapPoolLib_NoPool();
    error JBSwapPoolLib_SlippageExceeded(uint256 amountOut, uint256 minAmountOut);

    //*********************************************************************//
    // ------------------------ private constants ------------------------ //
    //*********************************************************************//

    /// @dev The default TWAP observation window in seconds (10 minutes).
    uint256 private constant _DEFAULT_TWAP_WINDOW = 600;

    /// @dev The minimum acceptable TWAP observation window in seconds (2 minutes).
    uint256 private constant _MIN_TWAP_WINDOW = 120;

    /// @dev The TWAP observation window used for V4 geomean oracle queries in seconds (2 minutes).
    uint32 private constant _V4_TWAP_WINDOW = 120;

    /// @dev The denominator for slippage tolerance calculations (basis points).
    uint256 private constant _SLIPPAGE_DENOMINATOR = 10_000;

    //*********************************************************************//
    // ------------------------------ structs ---------------------------- //
    //*********************************************************************//

    /// @notice Configuration context for swap execution, packed into a struct to avoid stack-too-deep.
    /// @custom:member v3Factory The Uniswap V3 factory used for pool discovery.
    /// @custom:member poolManager The Uniswap V4 pool manager used for V4 pool queries and swaps.
    /// @custom:member univ4Hook The address of the Uniswap V4 hook contract to search for hooked pools.
    /// @custom:member weth The address of the wrapped native token (WETH) on this chain.
    struct SwapConfig {
        IUniswapV3Factory v3Factory;
        IPoolManager poolManager;
        address univ4Hook;
        address weth;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Execute a full swap: discover the best V3/V4 pool, quote via TWAP, execute the swap.
    /// @dev Runs via DELEGATECALL so the calling contract's balance and callbacks are used.
    /// @param config The swap configuration (factory, pool manager, hook, WETH addresses).
    /// @param tokenIn The input token (raw address, may be NATIVE_TOKEN sentinel).
    /// @param tokenOut The output token (raw address).
    /// @param amount The amount of input tokens to swap.
    /// @param minAmountOut Caller-provided minimum output. When non-zero, TWAP quoting is skipped and this value
    /// is used directly as the slippage floor. When zero, the existing TWAP-based quoting logic applies.
    /// @return amountOut The amount of output tokens received.
    function executeSwap(
        SwapConfig memory config,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 minAmountOut
    )
        external
        returns (uint256 amountOut)
    {
        // Normalize NATIVE_TOKEN sentinel to WETH for pool lookups.
        address normalizedIn = _normalize({token: tokenIn, weth: config.weth});
        address normalizedOut = _normalize({token: tokenOut, weth: config.weth});

        // No swap needed if tokens are the same after normalization (e.g., NATIVE_TOKEN and WETH).
        if (normalizedIn == normalizedOut) return amount;

        // Discover the most liquid pool across V3 and V4.
        (bool isV4, IUniswapV3Pool v3Pool, PoolKey memory v4Key) =
            _discoverPool({config: config, normalizedTokenIn: normalizedIn, normalizedTokenOut: normalizedOut});

        // Revert if no pool was found on either protocol.
        if (!isV4 && address(v3Pool) == address(0)) revert JBSwapPoolLib_NoPool();

        if (isV4) {
            if (minAmountOut > 0) {
                // Caller-provided quote — skip TWAP, execute directly.
                amountOut = _executeV4Swap({
                    config: config,
                    key: v4Key,
                    normalizedTokenIn: normalizedIn,
                    amount: amount,
                    minAmountOut: minAmountOut
                });
            } else {
                // Quote via V4 TWAP/spot and execute swap through PoolManager.
                amountOut = _quoteAndSwapV4({
                    config: config,
                    key: v4Key,
                    normalizedTokenIn: normalizedIn,
                    normalizedTokenOut: normalizedOut,
                    amount: amount
                });
            }
        } else {
            if (minAmountOut > 0) {
                // Caller-provided quote — skip TWAP, execute directly.
                amountOut = _executeV3Swap({
                    pool: v3Pool,
                    normalizedTokenIn: normalizedIn,
                    normalizedTokenOut: normalizedOut,
                    amount: amount,
                    minAmountOut: minAmountOut,
                    originalTokenIn: tokenIn
                });
            } else {
                // Quote via V3 TWAP and execute swap through the V3 pool.
                amountOut = _quoteAndSwapV3({
                    pool: v3Pool,
                    normalizedTokenIn: normalizedIn,
                    normalizedTokenOut: normalizedOut,
                    amount: amount,
                    originalTokenIn: tokenIn
                });
            }
            // V3 outputs WETH for native pairs — unwrap to raw ETH.
            if (tokenOut == JBConstants.NATIVE_TOKEN) {
                IWrappedNativeToken(config.weth).withdraw(amountOut);
            }
        }

        // V4 outputs native ETH for WETH-paired pools. If the caller requested WETH (not NATIVE_TOKEN),
        // wrap the received ETH so the caller gets the token they expect.
        if (isV4 && tokenOut != JBConstants.NATIVE_TOKEN && normalizedOut == config.weth) {
            IWrappedNativeToken(config.weth).deposit{value: amountOut}();
        }
    }

    /// @notice Execute the body of a V4 unlock callback. Called via DELEGATECALL from the sucker's
    /// `unlockCallback` so the V4 swap logic lives in library bytecode instead of the sucker's.
    /// @dev DELEGATECALL preserves msg.sender, address(this), and the sucker's token balances.
    /// @param poolManager The Uniswap V4 PoolManager.
    /// @param data The encoded swap parameters from PoolManager.unlock().
    /// @return Encoded output amount.
    function executeV4UnlockCallback(IPoolManager poolManager, bytes calldata data) external returns (bytes memory) {
        // Decode the swap parameters packed during _executeV4Swap.
        (
            PoolKey memory key,
            bool zeroForOne,
            int256 amountSpecified,
            uint160 sqrtPriceLimitX96,
            uint256 minAmountOut,
            address weth
        ) = abi.decode(data, (PoolKey, bool, int256, uint160, uint256, address));

        uint256 amountIn;
        uint256 amountOut;

        {
            // Execute the swap through the V4 PoolManager.
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

            // Extract input and output amounts based on swap direction.
            if (zeroForOne) {
                amountIn = uint256(uint128(-delta0));
                amountOut = uint256(uint128(delta1));
            } else {
                amountIn = uint256(uint128(-delta1));
                amountOut = uint256(uint128(delta0));
            }

            // Enforce the minimum output from the TWAP quote.
            if (amountOut < minAmountOut) {
                revert JBSwapPoolLib_SlippageExceeded({amountOut: amountOut, minAmountOut: minAmountOut});
            }
        }

        // Settle input (pay what we owe to the PoolManager).
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        if (Currency.unwrap(inputCurrency) == address(0)) {
            // Native ETH: unwrap WETH if needed, then settle by sending ETH value directly.
            if (weth != address(0)) IWrappedNativeToken(weth).withdraw(amountIn);
            // slither-disable-next-line unused-return,arbitrary-send-eth
            poolManager.settle{value: amountIn}();
        } else {
            // ERC-20: sync the currency balance, transfer tokens, then settle.
            poolManager.sync(inputCurrency);
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer({to: address(poolManager), value: amountIn});
            // slither-disable-next-line unused-return
            poolManager.settle();
        }

        // Take output (receive what the PoolManager owes us).
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        poolManager.take({currency: outputCurrency, to: address(this), amount: amountOut});

        // Return the output amount to the caller.
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
        // Decode the callback data packed during _executeV3Swap.
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

        // Transfer the owed tokens to the V3 pool.
        IERC20(normalizedIn).safeTransfer({to: msg.sender, value: amountToSend});
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

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
        return
            _discoverPool({
                config: config, normalizedTokenIn: normalizedTokenIn, normalizedTokenOut: normalizedTokenOut
            });
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Find the highest liquidity pool across all V3 fee tiers and V4 pool configurations.
    /// @param config The swap configuration (factory, pool manager, hook, WETH addresses).
    /// @param normalizedTokenIn The normalized input token address (WETH, not NATIVE_TOKEN).
    /// @param normalizedTokenOut The normalized output token address.
    /// @return isV4 Whether the best pool is a V4 pool.
    /// @return v3Pool The best V3 pool (or address(0) if V4 is better).
    /// @return v4Key The best V4 pool key (if V4 is better).
    function _discoverPool(
        SwapConfig memory config,
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        internal
        view
        returns (bool isV4, IUniswapV3Pool v3Pool, PoolKey memory v4Key)
    {
        // Track the best TWAP-ready liquidity found across both protocols.
        uint128 bestLiquidity;

        // Search V3 pools across all fee tiers. Only pools with the full TWAP window are eligible.
        (v3Pool, bestLiquidity) = _discoverV3Pool({
            v3Factory: config.v3Factory, normalizedTokenIn: normalizedTokenIn, normalizedTokenOut: normalizedTokenOut
        });

        // If a V4 pool manager is configured, also search V4 pools.
        if (address(config.poolManager) != address(0)) {
            (PoolKey memory v4Candidate, uint128 v4Liquidity, bool v4UsesTwap) = _discoverV4Pool({
                config: config, normalizedTokenIn: normalizedTokenIn, normalizedTokenOut: normalizedTokenOut
            });

            // Select V4 if no TWAP-ready V3 exists, or if a TWAP-ready V4 beats the V3 route.
            // Hookless V4 spot pools remain a last-resort fallback and cannot outrank V3 TWAP.
            if (v4Liquidity != 0 && (bestLiquidity == 0 || (v4UsesTwap && v4Liquidity > bestLiquidity))) {
                isV4 = true;
                v3Pool = IUniswapV3Pool(address(0));
                v4Key = v4Candidate;
            }
        }
    }

    /// @notice Search V3 pools across 4 fee tiers for the highest liquidity.
    /// @param v3Factory The Uniswap V3 factory to query for pools.
    /// @param normalizedTokenIn The normalized input token address.
    /// @param normalizedTokenOut The normalized output token address.
    /// @return bestPool The V3 pool with the highest liquidity.
    /// @return bestLiquidity The liquidity of the best pool found.
    function _discoverV3Pool(
        IUniswapV3Factory v3Factory,
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        internal
        view
        returns (IUniswapV3Pool bestPool, uint128 bestLiquidity)
    {
        // Return early if no V3 factory is configured.
        if (address(v3Factory) == address(0)) return (bestPool, bestLiquidity);

        // Iterate over all 4 standard fee tiers.
        for (uint256 i; i < 4;) {
            // slither-disable-next-line calls-loop
            address poolAddr =
                v3Factory.getPool({tokenA: normalizedTokenIn, tokenB: normalizedTokenOut, fee: _feeTier(i)});

            if (poolAddr != address(0)) {
                // Skip young V3 pools instead of falling back to spot. No-quote programmatic swaps rely on the TWAP
                // floor, so a pool must already cover the full observation window before it can route funds.
                if (!_v3PoolHasFullTwapHistory(IUniswapV3Pool(poolAddr))) {
                    unchecked {
                        ++i;
                    }
                    continue;
                }

                // Query the pool's current in-range liquidity.
                // slither-disable-next-line calls-loop
                uint128 poolLiquidity = IUniswapV3Pool(poolAddr).liquidity();

                // Track the pool with the highest liquidity.
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

    /// @notice Search V4 pools across 4 fee tiers and 2 hook configs for the best eligible liquidity.
    /// @dev TWAP-capable hooked pools are preferred over hookless spot pools. Broken hooked pools are skipped.
    /// @param config The swap configuration (pool manager, hook, WETH addresses).
    /// @param normalizedTokenIn The normalized input token address.
    /// @param normalizedTokenOut The normalized output token address.
    /// @return bestKey The selected V4 pool key.
    /// @return bestLiquidity The liquidity of the best V4 pool found.
    /// @return bestUsesTwap Whether the selected V4 pool has a working TWAP hook.
    function _discoverV4Pool(
        SwapConfig memory config,
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        internal
        view
        returns (PoolKey memory bestKey, uint128 bestLiquidity, bool bestUsesTwap)
    {
        PoolKey memory bestSpotKey;
        uint128 bestSpotLiquidity;

        // Convert to V4 convention: WETH -> address(0) for native ETH.
        address sorted0;
        address sorted1;
        {
            // V4 uses address(0) for native ETH, so convert WETH addresses.
            address v4In = normalizedTokenIn == config.weth ? address(0) : normalizedTokenIn;
            address v4Out = normalizedTokenOut == config.weth ? address(0) : normalizedTokenOut;

            // Sort tokens to match the V4 currency ordering convention.
            (sorted0, sorted1) = v4In < v4Out ? (v4In, v4Out) : (v4Out, v4In);
        }

        // Iterate over all 4 standard fee tiers.
        for (uint256 i; i < 4;) {
            // For each fee tier, probe both hookless and hooked pools.
            for (uint256 j; j < 2;) {
                // Use no hook for j==0, configured hook for j==1.
                address hookAddr = j == 0 ? address(0) : config.univ4Hook;

                // Skip the hooked probe if no hook address is configured.
                if (j != 0 && hookAddr == address(0)) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }

                // Probe this specific pool configuration for liquidity.
                (PoolKey memory key, uint128 liq) = _probeV4Pool({
                    poolManager: config.poolManager,
                    sorted0: sorted0,
                    sorted1: sorted1,
                    hookAddr: hookAddr,
                    tierIndex: i
                });

                if (liq != 0) {
                    if (hookAddr == address(0)) {
                        if (liq > bestSpotLiquidity) {
                            bestSpotLiquidity = liq;
                            bestSpotKey = key;
                        }
                    } else if (_v4PoolHasTwap(key)) {
                        if (liq > bestLiquidity) {
                            bestLiquidity = liq;
                            bestKey = key;
                            bestUsesTwap = true;
                        }
                    }
                }

                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }

        if (bestLiquidity == 0) {
            bestKey = bestSpotKey;
            bestLiquidity = bestSpotLiquidity;
        }
    }

    /// @notice Probe a single V4 pool configuration for liquidity.
    /// @param poolManager The Uniswap V4 pool manager to query.
    /// @param sorted0 The lower-address token in the pair (sorted).
    /// @param sorted1 The higher-address token in the pair (sorted).
    /// @param hookAddr The hook address to use for this pool configuration.
    /// @param tierIndex The fee tier index (0-3) to probe.
    /// @return key The constructed pool key for this configuration.
    /// @return poolLiquidity The current in-range liquidity of the pool, or 0 if uninitialized.
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
        // Look up fee and tick spacing for this tier index.
        (uint24 fee, int24 tickSpacing) = _v4FeeAndTickSpacing(tierIndex);

        // Construct the pool key from the sorted tokens and tier parameters.
        key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddr)
        });

        // Derive the pool ID from the key.
        PoolId id = key.toId();

        // Check if pool is initialized (sqrtPriceX96 != 0).
        // slither-disable-next-line unused-return,calls-loop
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        // slither-disable-next-line incorrect-equality
        if (sqrtPriceX96 == 0) return (key, 0);

        // Query the pool's current in-range liquidity.
        // slither-disable-next-line calls-loop
        poolLiquidity = poolManager.getLiquidity(id);
    }

    /// @notice Get a TWAP-based quote with dynamic slippage for a V3 pool.
    /// @param pool The V3 pool to get the TWAP quote from.
    /// @param normalizedTokenIn The normalized input token address.
    /// @param normalizedTokenOut The normalized output token address.
    /// @param amount The amount of input tokens to quote.
    /// @return minAmountOut The minimum acceptable output amount after slippage.
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
        // Convert the pool fee from hundredths-of-a-bip to basis points.
        uint256 feeBps = uint256(pool.fee()) / 100;

        // Get the oldest observation available in the pool's oracle.
        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(address(pool));

        // Revert if the pool has no TWAP history at all.
        if (oldestObservation == 0) revert JBSwapPoolLib_InsufficientTwapHistory();

        // Revert if the available history cannot serve the full default TWAP window.
        if (oldestObservation < _DEFAULT_TWAP_WINDOW) revert JBSwapPoolLib_InsufficientTwapHistory();

        // Consult the V3 oracle for the arithmetic mean tick and harmonic mean liquidity.
        (int24 arithmeticMeanTick, uint128 liquidity) =
            OracleLibrary.consult({pool: address(pool), secondsAgo: uint32(_DEFAULT_TWAP_WINDOW)});

        // Revert if the pool has no in-range liquidity.
        if (liquidity == 0) revert JBSwapPoolLib_NoLiquidity();

        // Compute the minimum output with sigmoid-based dynamic slippage.
        minAmountOut = _quoteWithSlippage({
            amount: amount,
            liquidity: liquidity,
            tokenIn: normalizedTokenIn,
            tokenOut: normalizedTokenOut,
            tick: arithmeticMeanTick,
            poolFeeBps: feeBps
        });
    }

    /// @notice Get a V4 quote with dynamic slippage. Hooked pools must serve TWAP; hookless pools use spot fallback.
    /// @param config The swap configuration (pool manager, WETH addresses).
    /// @param key The V4 pool key to quote against.
    /// @param normalizedTokenIn The normalized input token address.
    /// @param normalizedTokenOut The normalized output token address.
    /// @param amount The amount of input tokens to quote.
    /// @return minAmountOut The minimum acceptable output amount after slippage.
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
        // Convert the pool fee from hundredths-of-a-bip to basis points.
        uint256 feeBps = uint256(key.fee) / 100;
        int24 tick;
        uint128 liquidity;

        {
            // Derive the pool ID from the key.
            PoolId id = key.toId();
            // If the pool has a hook, require a TWAP from the geomean oracle.
            if (address(key.hooks) != address(0)) {
                // Build the observation window: [_V4_TWAP_WINDOW seconds ago, now].
                uint32[] memory secondsAgos = new uint32[](2);
                secondsAgos[0] = _V4_TWAP_WINDOW;
                secondsAgos[1] = 0;

                // Read the TWAP from the hook's geomean oracle.
                (int56[] memory tickCumulatives,) =
                    IGeomeanOracle(address(key.hooks)).observe({key: key, secondsAgos: secondsAgos});
                if (tickCumulatives.length < 2) revert JBSwapPoolLib_InsufficientTwapHistory();

                // Compute the arithmetic mean tick from the cumulative tick difference.
                tick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(_V4_TWAP_WINDOW)));
            } else {
                // Hookless V4 spot pools are only selected when no TWAP-capable route exists.
                // slither-disable-next-line unused-return
                (, tick,,) = config.poolManager.getSlot0(id);
            }

            // Query the pool's current in-range liquidity.
            liquidity = config.poolManager.getLiquidity(id);
        }

        // Revert if the pool has no in-range liquidity.
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

    /// @notice Checks whether a V3 pool can serve the full default TWAP window.
    /// @dev Reads the observation ring directly so discovery can skip young pools without reverting. The oldest
    /// initialized observation must be at least `_DEFAULT_TWAP_WINDOW` seconds old.
    /// @param pool The V3 pool to inspect.
    /// @return True if the pool has enough initialized history for a default-window TWAP.
    function _v3PoolHasFullTwapHistory(IUniswapV3Pool pool) internal view returns (bool) {
        // slot0 gives the current observation cursor and total initialized/available observation slots.
        (bool slot0Ok, uint16 observationIndex, uint16 observationCardinality) = _v3ObservationStateOf(pool);
        if (!slot0Ok || observationCardinality == 0) return false;

        // In a full ring, the next slot after the cursor is the oldest observation.
        uint256 oldestIndex = (uint256(observationIndex) + 1) % uint256(observationCardinality);
        (bool observationOk, uint32 observationTimestamp, bool initialized) =
            _v3ObservationOf({pool: pool, index: oldestIndex});
        if (!observationOk) return false;

        // If the ring has not wrapped yet, slot 0 is the oldest initialized observation.
        if (!initialized) {
            (observationOk, observationTimestamp, initialized) = _v3ObservationOf({pool: pool, index: 0});
            if (!observationOk || !initialized) return false;
        }

        return _observationIsOldEnough({observationTimestamp: observationTimestamp, window: _DEFAULT_TWAP_WINDOW});
    }

    /// @notice Reads the observation cursor and cardinality from a V3 pool's slot0.
    function _v3ObservationStateOf(IUniswapV3Pool pool)
        internal
        view
        returns (bool ok, uint16 observationIndex, uint16 observationCardinality)
    {
        (bool success, bytes memory data) =
            address(pool).staticcall(abi.encodeWithSelector(IUniswapV3PoolState.slot0.selector));
        if (!success || data.length < 224) return (false, 0, 0);

        (,, observationIndex, observationCardinality,,,) =
            abi.decode(data, (uint160, int24, uint16, uint16, uint16, uint8, bool));
        ok = true;
    }

    /// @notice Reads one V3 observation.
    function _v3ObservationOf(
        IUniswapV3Pool pool,
        uint256 index
    )
        internal
        view
        returns (bool ok, uint32 observationTimestamp, bool initialized)
    {
        (bool success, bytes memory data) =
            address(pool).staticcall(abi.encodeWithSelector(IUniswapV3PoolState.observations.selector, index));
        if (!success || data.length < 128) return (false, 0, false);

        (observationTimestamp,,, initialized) = abi.decode(data, (uint32, int56, uint160, bool));
        ok = true;
    }

    /// @notice Returns true when a timestamp is at least `window` seconds old.
    function _observationIsOldEnough(uint32 observationTimestamp, uint256 window) internal view returns (bool) {
        if (observationTimestamp >= block.timestamp) return false;
        return block.timestamp - observationTimestamp >= window;
    }

    /// @notice Checks whether a V4 hooked pool can serve the required TWAP window.
    function _v4PoolHasTwap(PoolKey memory key) internal view returns (bool) {
        if (address(key.hooks) == address(0)) return false;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = _V4_TWAP_WINDOW;
        secondsAgos[1] = 0;

        try IGeomeanOracle(address(key.hooks)).observe({key: key, secondsAgos: secondsAgos}) returns (
            int56[] memory tickCumulatives, uint160[] memory
        ) {
            return tickCumulatives.length >= 2;
        } catch {
            return false;
        }
    }

    /// @notice Compute the minimum acceptable output using sigmoid slippage at the given tick.
    /// @param amount The amount of input tokens.
    /// @param liquidity The pool's in-range liquidity.
    /// @param tokenIn The input token address (for quoting).
    /// @param tokenOut The output token address (for quoting).
    /// @param tick The arithmetic mean tick from the TWAP or current spot.
    /// @param poolFeeBps The pool's fee in basis points.
    /// @return minAmountOut The minimum acceptable output amount after slippage.
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
        // Compute the dynamic slippage tolerance based on price impact.
        uint256 slippageTolerance = _getSlippageTolerance({
            amountIn: amount,
            liquidity: liquidity,
            tokenOut: tokenOut,
            tokenIn: tokenIn,
            arithmeticMeanTick: tick,
            poolFeeBps: poolFeeBps
        });

        // If the slippage tolerance is 100% or more, accept any output.
        if (slippageTolerance >= _SLIPPAGE_DENOMINATOR) return 0;

        // Revert if amount exceeds uint128 (required by OracleLibrary.getQuoteAtTick).
        if (amount > type(uint128).max) revert JBSwapPoolLib_AmountOverflow(amount);

        // Get the expected output at the TWAP tick.
        minAmountOut = OracleLibrary.getQuoteAtTick({
            tick: tick, baseAmount: uint128(amount), baseToken: tokenIn, quoteToken: tokenOut
        });

        // Reduce by the slippage tolerance to get the minimum acceptable output.
        minAmountOut -= (minAmountOut * slippageTolerance) / _SLIPPAGE_DENOMINATOR;
    }

    /// @notice Compute the sigmoid slippage tolerance for a given swap.
    /// @param amountIn The amount of input tokens.
    /// @param liquidity The pool's in-range liquidity.
    /// @param tokenOut The output token address.
    /// @param tokenIn The input token address.
    /// @param arithmeticMeanTick The arithmetic mean tick from the TWAP.
    /// @param poolFeeBps The pool's fee in basis points.
    /// @return The slippage tolerance in basis points (out of _SLIPPAGE_DENOMINATOR).
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
        // Sort the tokens to determine swap direction.
        (address token0,) = tokenOut < tokenIn ? (tokenOut, tokenIn) : (tokenIn, tokenOut);
        bool zeroForOne = tokenIn == token0;

        // Get the sqrt price at the mean tick for impact calculation.
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(arithmeticMeanTick);

        // If sqrtP is zero, return maximum slippage (accept any output).
        if (sqrtP == 0) return _SLIPPAGE_DENOMINATOR;

        // Calculate the price impact of the swap.
        uint256 impact =
            JBSwapLib.calculateImpact({amountIn: amountIn, liquidity: liquidity, sqrtP: sqrtP, zeroForOne: zeroForOne});

        // Map the impact to a sigmoid slippage tolerance.
        return JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps});
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Quote via V4 TWAP/spot and execute swap. Separate function for stack isolation.
    /// @param config The swap configuration (pool manager, WETH addresses).
    /// @param key The V4 pool key to swap through.
    /// @param normalizedTokenIn The normalized input token address.
    /// @param normalizedTokenOut The normalized output token address.
    /// @param amount The amount of input tokens to swap.
    /// @return amountOut The amount of output tokens received.
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
        // Get the TWAP-based minimum output for slippage protection.
        uint256 minOut = _getV4Quote({
            config: config,
            key: key,
            normalizedTokenIn: normalizedTokenIn,
            normalizedTokenOut: normalizedTokenOut,
            amount: amount
        });

        // Execute the swap through the V4 PoolManager.
        amountOut = _executeV4Swap({
            config: config, key: key, normalizedTokenIn: normalizedTokenIn, amount: amount, minAmountOut: minOut
        });
    }

    /// @notice Quote via V3 TWAP and execute swap. Separate function for stack isolation.
    /// @param pool The V3 pool to swap through.
    /// @param normalizedTokenIn The normalized input token address.
    /// @param normalizedTokenOut The normalized output token address.
    /// @param amount The amount of input tokens to swap.
    /// @param originalTokenIn The original (pre-normalization) input token address.
    /// @return amountOut The amount of output tokens received.
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
        // Get the TWAP-based minimum output for slippage protection.
        uint256 minOut = _getV3TwapQuote({
            pool: pool, normalizedTokenIn: normalizedTokenIn, normalizedTokenOut: normalizedTokenOut, amount: amount
        });

        // Execute the swap through the V3 pool.
        amountOut = _executeV3Swap({
            pool: pool,
            normalizedTokenIn: normalizedTokenIn,
            normalizedTokenOut: normalizedTokenOut,
            amount: amount,
            minAmountOut: minOut,
            originalTokenIn: originalTokenIn
        });
    }

    /// @notice Execute a swap through a V3 pool.
    /// @param pool The V3 pool to execute the swap on.
    /// @param normalizedTokenIn The normalized input token address.
    /// @param normalizedTokenOut The normalized output token address.
    /// @param amount The amount of input tokens to swap.
    /// @param minAmountOut The minimum acceptable output amount.
    /// @param originalTokenIn The original (pre-normalization) input token address.
    /// @return amountOut The amount of output tokens received.
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
        // Determine swap direction based on token ordering.
        bool zeroForOne = normalizedTokenIn < normalizedTokenOut;

        // Execute the V3 swap with a price limit derived from the expected amounts.
        (int256 amount0, int256 amount1) = pool.swap({
            recipient: address(this),
            zeroForOne: zeroForOne,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: JBSwapLib.sqrtPriceLimitFromAmounts({
                amountIn: amount, minimumAmountOut: minAmountOut, zeroForOne: zeroForOne
            }),
            data: abi.encode(originalTokenIn, normalizedTokenIn, normalizedTokenOut)
        });

        // Extract the output amount from the signed delta (negative = tokens received).
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));

        // Enforce the minimum output from the TWAP quote.
        if (amountOut < minAmountOut) {
            revert JBSwapPoolLib_SlippageExceeded({amountOut: amountOut, minAmountOut: minAmountOut});
        }
    }

    /// @notice Execute a swap through a V4 pool via `PoolManager.unlock()`.
    /// @param config The swap configuration (pool manager, WETH addresses).
    /// @param key The V4 pool key to swap through.
    /// @param normalizedTokenIn The normalized input token address.
    /// @param amount The amount of input tokens to swap.
    /// @param minAmountOut The minimum acceptable output amount.
    /// @return amountOut The amount of output tokens received.
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
        // Convert WETH to address(0) for V4's native ETH convention.
        address v4In = normalizedTokenIn == config.weth ? address(0) : normalizedTokenIn;

        // Determine swap direction based on currency ordering in the pool key.
        bool zeroForOne = Currency.unwrap(key.currency0) == v4In;

        // Build the encoded unlock data in a scoped block to avoid stack-too-deep.
        bytes memory unlockData;
        {
            // Compute the sqrt price limit from the expected amounts.
            uint160 sqrtPriceLimitX96 = JBSwapLib.sqrtPriceLimitFromAmounts({
                amountIn: amount, minimumAmountOut: minAmountOut, zeroForOne: zeroForOne
            });

            // V4 uses negative amounts for exact-input swaps.
            int256 exactInputAmount = -int256(amount);

            unlockData = abi.encode(key, zeroForOne, exactInputAmount, sqrtPriceLimitX96, minAmountOut, config.weth);
        }

        // Unlock the PoolManager and encode the swap parameters for the callback.
        bytes memory result = config.poolManager.unlock(unlockData);

        // Decode the output amount returned by the unlock callback.
        amountOut = abi.decode(result, (uint256));
    }

    /// @notice Normalize a token address, converting the NATIVE_TOKEN sentinel to WETH.
    /// @param token The token address to normalize.
    /// @param weth The WETH address on this chain.
    /// @return The normalized token address.
    function _normalize(address token, address weth) internal pure returns (address) {
        return token == JBConstants.NATIVE_TOKEN ? weth : token;
    }

    /// @notice Get the Uniswap V3 fee tier for a given index.
    /// @param index The fee tier index (0 = 0.3%, 1 = 0.05%, 2 = 1%, 3 = 0.01%).
    /// @return fee The fee tier in hundredths of a basis point.
    function _feeTier(uint256 index) internal pure returns (uint24 fee) {
        if (index == 0) return 3000;
        if (index == 1) return 500;
        if (index == 2) return 10_000;
        return 100;
    }

    /// @notice Get the Uniswap V4 fee and tick spacing for a given tier index.
    /// @param index The fee tier index (0 = 0.3%/60, 1 = 0.05%/10, 2 = 1%/200, 3 = 0.01%/1).
    /// @return fee The fee in hundredths of a basis point.
    /// @return tickSpacing The tick spacing for this fee tier.
    function _v4FeeAndTickSpacing(uint256 index) internal pure returns (uint24 fee, int24 tickSpacing) {
        if (index == 0) return (3000, 60);
        if (index == 1) return (500, 10);
        if (index == 2) return (10_000, 200);
        return (100, 1);
    }
}
