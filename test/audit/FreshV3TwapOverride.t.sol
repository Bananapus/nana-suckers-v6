// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBSwapPoolLib} from "../../src/libraries/JBSwapPoolLib.sol";

contract FreshV3TwapHarness {
    function discoverPool(
        JBSwapPoolLib.SwapConfig memory config,
        address tokenIn,
        address tokenOut
    )
        external
        view
        returns (bool isV4, IUniswapV3Pool v3Pool, PoolKey memory v4Key)
    {
        return JBSwapPoolLib.discoverPool(config, tokenIn, tokenOut);
    }

    function executeSwap(
        JBSwapPoolLib.SwapConfig memory config,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 minAmountOut
    )
        external
        returns (uint256 amountOut)
    {
        return JBSwapPoolLib.executeSwap(config, tokenIn, tokenOut, amount, minAmountOut);
    }

    receive() external payable {}
}

contract ToxicFreshV3Pool {
    int24 public immutable twapTick;
    uint24 public fee;
    uint128 public liquidity;
    uint32 public oldestObservationAge;
    uint256 public nextAmountOut;

    constructor(uint24 _fee, uint128 _liquidity, uint32 _oldestObservationAge, int24 _twapTick) {
        fee = _fee;
        liquidity = _liquidity;
        oldestObservationAge = _oldestObservationAge;
        twapTick = _twapTick;
    }

    function setLiquidity(uint128 newLiquidity) external {
        liquidity = newLiquidity;
    }

    function setNextAmountOut(uint256 amountOut) external {
        nextAmountOut = amountOut;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(1 << 96), 0, 0, 1, 1, 0, true);
    }

    function observations(uint256) external view returns (uint32, int56, uint160, bool) {
        return (uint32(block.timestamp) - oldestObservationAge, 0, 0, true);
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory, uint160[] memory) {
        int56[] memory tickCumulatives = new int56[](2);
        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](2);

        uint32 window = secondsAgos[0];

        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(twapTick) * int56(uint56(window));

        uint160 delta = uint160((uint192(window) * type(uint160).max) / (uint192(uint256(liquidity)) << 32));
        secondsPerLiquidityCumulativeX128s[0] = 0;
        secondsPerLiquidityCumulativeX128s[1] = delta;

        return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
    }

    function swap(
        address,
        bool zeroForOne,
        int256 amountSpecified,
        uint160,
        bytes calldata
    )
        external
        view
        returns (int256 amount0, int256 amount1)
    {
        if (zeroForOne) {
            amount0 = amountSpecified;
            amount1 = -int256(nextAmountOut);
        } else {
            amount0 = -int256(nextAmountOut);
            amount1 = amountSpecified;
        }
    }
}

contract FreshV3TwapPoolManager {
    using PoolIdLibrary for PoolKey;

    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));
    uint256 private constant LIQUIDITY_OFFSET = 3;

    mapping(bytes32 => bytes32) internal _slots;

    uint256 public unlockCount;
    uint256 public nextAmountOut;

    function setPool(PoolKey memory key, int24 tick, uint128 liquidity) external {
        PoolId id = key.toId();
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(id), POOLS_SLOT));

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 packed = uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160);

        _slots[stateSlot] = bytes32(packed);
        _slots[bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET)] = bytes32(uint256(liquidity));
    }

    function setNextAmountOut(uint256 amountOut) external {
        nextAmountOut = amountOut;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        for (uint256 i; i < nSlots; i++) {
            values[i] = _slots[bytes32(uint256(startSlot) + i)];
        }
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; i++) {
            values[i] = _slots[slots[i]];
        }
    }

    function unlock(bytes calldata) external returns (bytes memory) {
        unlockCount++;
        return abi.encode(nextAmountOut);
    }
}

contract FreshV3TwapOverrideTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant TOKEN_A = address(0xA0);
    address internal constant TOKEN_B = address(0xB0);
    address internal constant V3_FACTORY = address(0xF3);
    address internal constant WETH = address(0xE7);

    uint256 internal constant AMOUNT_IN = 1000e18;
    uint128 internal constant V4_LIQUIDITY = 1_000_000e18;
    uint128 internal constant TOXIC_V3_LIQUIDITY = V4_LIQUIDITY + 1;
    uint32 internal constant MIN_HISTORY = 120;
    int24 internal constant TOXIC_TWAP_TICK = -230_280;
    uint256 internal constant V4_AMOUNT_OUT = 995e18;

    FreshV3TwapHarness internal harness;
    FreshV3TwapPoolManager internal poolManager;
    ToxicFreshV3Pool internal toxicV3Pool;

    function setUp() external {
        vm.warp(1000);

        harness = new FreshV3TwapHarness();
        poolManager = new FreshV3TwapPoolManager();
        toxicV3Pool = new ToxicFreshV3Pool(500, TOXIC_V3_LIQUIDITY, MIN_HISTORY, TOXIC_TWAP_TICK);

        vm.mockCall(
            V3_FACTORY,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_A, TOKEN_B, uint24(500)),
            abi.encode(address(toxicV3Pool))
        );
        vm.mockCall(
            V3_FACTORY,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_B, TOKEN_A, uint24(500)),
            abi.encode(address(toxicV3Pool))
        );
        vm.mockCall(
            V3_FACTORY,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_A, TOKEN_B, uint24(3000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            V3_FACTORY,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_B, TOKEN_A, uint24(3000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            V3_FACTORY,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_A, TOKEN_B, uint24(10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            V3_FACTORY,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_B, TOKEN_A, uint24(10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            V3_FACTORY,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_A, TOKEN_B, uint24(100)),
            abi.encode(address(0))
        );
        vm.mockCall(
            V3_FACTORY,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_B, TOKEN_A, uint24(100)),
            abi.encode(address(0))
        );
    }

    function test_freshV3PoolWithMinimumHistoryCannotOverrideHealthyRouteWithAttackerDefinedTwap() external {
        PoolKey memory healthyV4Key = PoolKey({
            currency0: Currency.wrap(TOKEN_A),
            currency1: Currency.wrap(TOKEN_B),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolManager.setPool(healthyV4Key, 0, V4_LIQUIDITY);
        poolManager.setNextAmountOut(V4_AMOUNT_OUT);

        JBSwapPoolLib.SwapConfig memory config = JBSwapPoolLib.SwapConfig({
            v3Factory: IUniswapV3Factory(V3_FACTORY),
            poolManager: IPoolManager(address(poolManager)),
            univ4Hook: address(0),
            weth: WETH
        });

        (bool isV4, IUniswapV3Pool chosenV3Pool, PoolKey memory chosenV4Key) =
            harness.discoverPool(config, TOKEN_A, TOKEN_B);

        assertTrue(isV4, "healthy V4 fallback should win while V3 lacks the full TWAP window");
        assertEq(address(chosenV3Pool), address(0), "fresh V3 pool should be discarded");
        assertEq(address(chosenV4Key.hooks), address(0), "the configured V4 fallback should be selected");

        uint256 v4AmountOut = harness.executeSwap(config, TOKEN_A, TOKEN_B, AMOUNT_IN, 0);

        assertEq(v4AmountOut, V4_AMOUNT_OUT, "healthy route should execute instead of the toxic fresh V3 TWAP");
        assertEq(poolManager.unlockCount(), 1, "V4 should execute while fresh V3 is disqualified");
    }
}
