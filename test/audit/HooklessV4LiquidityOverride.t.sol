// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3PoolState} from "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolState.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBSwapPoolLib} from "../../src/libraries/JBSwapPoolLib.sol";

contract HooklessV4OverrideHarness {
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

contract HooklessV4OverridePoolManager {
    using PoolIdLibrary for PoolKey;

    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));
    uint256 private constant LIQUIDITY_OFFSET = 3;

    mapping(bytes32 => bytes32) internal _slots;

    uint256 public unlockCount;
    address public lastHooks;
    uint256 public lastMinAmountOut;
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

    function unlock(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key,,,, uint256 minAmountOut,) =
            abi.decode(data, (PoolKey, bool, int256, uint160, uint256, address));
        unlockCount++;
        lastHooks = address(key.hooks);
        lastMinAmountOut = minAmountOut;
        return abi.encode(nextAmountOut);
    }
}

contract HooklessV4LiquidityOverrideTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant TOKEN_A = address(0xA0);
    address internal constant TOKEN_B = address(0xB0);
    address internal constant V3_FACTORY = address(0xF3);
    address internal constant V3_POOL = address(0xC3);
    address internal constant WETH = address(0xE7);
    address internal constant HOOK = address(0xD0);

    uint256 internal constant AMOUNT_IN = 1000e18;
    uint128 internal constant V3_LIQUIDITY = 1_000_000e18;
    uint128 internal constant V4_LIQUIDITY = V3_LIQUIDITY + 1;
    int24 internal constant TOXIC_SPOT_TICK = -23_028; // ~= 0.1 quoteToken per baseToken.

    HooklessV4OverrideHarness internal harness;
    HooklessV4OverridePoolManager internal poolManager;

    function setUp() external {
        vm.warp(1000);

        harness = new HooklessV4OverrideHarness();
        poolManager = new HooklessV4OverridePoolManager();

        vm.mockCall(
            V3_FACTORY,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_A, TOKEN_B, uint24(500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            V3_FACTORY,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_B, TOKEN_A, uint24(500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            V3_FACTORY,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_A, TOKEN_B, uint24(3000)),
            abi.encode(V3_POOL)
        );
        vm.mockCall(
            V3_FACTORY,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_B, TOKEN_A, uint24(3000)),
            abi.encode(V3_POOL)
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
        vm.mockCall(V3_POOL, abi.encodeWithSelector(IUniswapV3PoolState.liquidity.selector), abi.encode(V3_LIQUIDITY));
        vm.mockCall(
            V3_POOL,
            abi.encodeWithSelector(IUniswapV3PoolState.slot0.selector),
            abi.encode(uint160(1 << 96), int24(0), uint16(0), uint16(2), uint16(2), uint8(0), true)
        );
        vm.mockCall(
            V3_POOL,
            abi.encodeWithSelector(IUniswapV3PoolState.observations.selector, uint256(1)),
            abi.encode(uint32(block.timestamp - 600), int56(0), uint160(0), true)
        );
    }

    function test_hooklessV4SpotPoolCannotOverrideLiveV3TwapOnOneWeiLiquidityEdge() external {
        PoolKey memory toxicKey = PoolKey({
            currency0: Currency.wrap(TOKEN_A),
            currency1: Currency.wrap(TOKEN_B),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolManager.setPool(toxicKey, TOXIC_SPOT_TICK, V4_LIQUIDITY);

        JBSwapPoolLib.SwapConfig memory config = JBSwapPoolLib.SwapConfig({
            v3Factory: IUniswapV3Factory(V3_FACTORY),
            poolManager: IPoolManager(address(poolManager)),
            univ4Hook: HOOK,
            weth: WETH
        });

        (bool isV4, IUniswapV3Pool v3Pool, PoolKey memory chosenKey) = harness.discoverPool(config, TOKEN_A, TOKEN_B);

        assertFalse(isV4, "live V3 TWAP should beat hookless V4 spot even on a small liquidity edge");
        assertEq(address(v3Pool), V3_POOL, "discovery should keep the V3 TWAP route");
        assertEq(address(chosenKey.hooks), address(0), "no V4 key should be selected");
        assertEq(poolManager.unlockCount(), 0, "discovery must not execute through V4");
    }
}
