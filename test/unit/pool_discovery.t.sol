// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3PoolState} from "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolState.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {JBSwapPoolLib} from "../../src/libraries/JBSwapPoolLib.sol";

/// @notice Mock V4 PoolManager that stores slot data for pool state queries via extsload.
contract MockPoolManager {
    using PoolIdLibrary for PoolKey;

    /// @dev Storage slot for pools mapping (matches StateLibrary.POOLS_SLOT).
    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));
    /// @dev Offset for liquidity within Pool.State (matches StateLibrary.LIQUIDITY_OFFSET).
    uint256 private constant LIQUIDITY_OFFSET = 3;

    /// @dev Arbitrary storage mapping: slot => value.
    mapping(bytes32 => bytes32) private _slots;

    /// @notice Configure a pool's slot0 (sqrtPriceX96, tick, protocolFee, lpFee) and liquidity.
    /// @param key The pool key to configure.
    /// @param sqrtPriceX96 The sqrt price (non-zero means initialized).
    /// @param liquidity The in-range liquidity.
    function setPool(PoolKey memory key, uint160 sqrtPriceX96, uint128 liquidity) external {
        PoolId id = key.toId();
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(id), POOLS_SLOT));

        // Pack slot0: sqrtPriceX96 in bottom 160 bits, tick=0 in next 24, fees=0 in upper.
        _slots[stateSlot] = bytes32(uint256(sqrtPriceX96));

        // Pack liquidity at offset 3.
        bytes32 liquiditySlot = bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET);
        _slots[liquiditySlot] = bytes32(uint256(liquidity));
    }

    /// @notice Implements IExtsload.extsload for StateLibrary compatibility.
    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    /// @notice Multi-slot extsload (not used in pool discovery but required by interface).
    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        for (uint256 i; i < nSlots; i++) {
            values[i] = _slots[bytes32(uint256(startSlot) + i)];
        }
    }

    /// @notice Array extsload (not used in pool discovery but required by interface).
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; i++) {
            values[i] = _slots[slots[i]];
        }
    }
}

/// @notice Harness contract that exposes JBSwapPoolLib.discoverPool for unit testing.
contract PoolDiscoveryHarness {
    function discoverPool(
        JBSwapPoolLib.SwapConfig memory config,
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        returns (bool isV4, IUniswapV3Pool v3Pool, PoolKey memory v4Key)
    {
        return JBSwapPoolLib.discoverPool(config, normalizedTokenIn, normalizedTokenOut);
    }
}

/// @title JBSwapPoolLib_PoolDiscoveryTest
/// @notice Unit tests for the M-1 audit fix: V3/V4 pool preference logic in _discoverPool.
/// @dev The fix removed the V3 preference guard that blocked hookless V4 pools from being selected
/// even when they had deeper liquidity than any V3 pool.
contract JBSwapPoolLib_PoolDiscoveryTest is Test {
    using PoolIdLibrary for PoolKey;

    // Test addresses.
    address constant TOKEN_A = address(0xA);
    address constant TOKEN_B = address(0xB);
    address constant WETH = address(0xC);
    address constant HOOK_ADDR = address(0xD);

    // Mock contracts.
    address v3Factory;
    MockPoolManager poolManager;
    PoolDiscoveryHarness harness;

    // Precomputed V3 pool addresses (one per fee tier).
    address v3Pool3000;
    address v3Pool500;
    address v3Pool10000;
    address v3Pool100;

    function setUp() public {
        v3Factory = makeAddr("v3Factory");
        poolManager = new MockPoolManager();
        harness = new PoolDiscoveryHarness();

        // Create V3 pool addresses.
        v3Pool3000 = makeAddr("v3Pool3000");
        v3Pool500 = makeAddr("v3Pool500");
        v3Pool10000 = makeAddr("v3Pool10000");
        v3Pool100 = makeAddr("v3Pool100");

        // Default: all V3 factory getPool calls return address(0) (no pool).
        vm.mockCall(v3Factory, abi.encodeWithSelector(IUniswapV3Factory.getPool.selector), abi.encode(address(0)));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Configure a V3 pool at a specific fee tier with given liquidity.
    function _setupV3Pool(address pool, uint24 fee, uint128 liquidity) internal {
        // Mock the factory to return this pool for the given fee tier.
        vm.mockCall(
            v3Factory,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_A, TOKEN_B, fee),
            abi.encode(pool)
        );
        // Also mock the reverse token ordering (factory is commutative).
        vm.mockCall(
            v3Factory,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, TOKEN_B, TOKEN_A, fee),
            abi.encode(pool)
        );
        // Mock the pool's liquidity.
        vm.mockCall(pool, abi.encodeWithSelector(IUniswapV3PoolState.liquidity.selector), abi.encode(liquidity));
    }

    /// @dev Configure a V4 pool (hookless) with given liquidity.
    function _setupV4HooklessPool(uint24 fee, int24 tickSpacing, uint128 liquidity) internal {
        // Sort tokens for V4 convention (no WETH conversion needed here since neither is WETH).
        (address sorted0, address sorted1) = TOKEN_A < TOKEN_B ? (TOKEN_A, TOKEN_B) : (TOKEN_B, TOKEN_A);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        // Set a non-zero sqrtPriceX96 to indicate the pool is initialized, and set liquidity.
        poolManager.setPool(key, 1 << 96, liquidity); // sqrtPriceX96 = 2^96 (price = 1)
    }

    /// @dev Configure a V4 pool with a hook and given liquidity.
    function _setupV4HookedPool(address hook, uint24 fee, int24 tickSpacing, uint128 liquidity) internal {
        (address sorted0, address sorted1) = TOKEN_A < TOKEN_B ? (TOKEN_A, TOKEN_B) : (TOKEN_B, TOKEN_A);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });

        poolManager.setPool(key, 1 << 96, liquidity);
    }

    /// @dev Build a SwapConfig pointing at our mocks.
    function _config() internal view returns (JBSwapPoolLib.SwapConfig memory) {
        return JBSwapPoolLib.SwapConfig({
            v3Factory: IUniswapV3Factory(v3Factory),
            poolManager: IPoolManager(address(poolManager)),
            univ4Hook: HOOK_ADDR,
            weth: WETH
        });
    }

    // =========================================================================
    // Test 1: V3 dust liquidity, V4 deep liquidity => V4 selected
    // (This was the broken case before the M-1 fix)
    // =========================================================================

    /// @notice When V3 has dust liquidity (1 wei) and hookless V4 has deep liquidity,
    /// V4 should be selected. Before the fix, V3 would win because hookless V4 was blocked.
    function test_poolDiscovery_v4HooklessBeatsV3Dust() public {
        // V3 has dust liquidity at 0.3% fee tier.
        _setupV3Pool(v3Pool3000, 3000, 1);

        // Hookless V4 has deep liquidity at 0.3% fee tier (fee=3000, tickSpacing=60).
        _setupV4HooklessPool(3000, 60, 1_000_000e18);

        (bool isV4, IUniswapV3Pool v3Pool,) = harness.discoverPool(_config(), TOKEN_A, TOKEN_B);

        assertTrue(isV4, "V4 hookless pool with deep liquidity should be selected over V3 dust");
        assertEq(address(v3Pool), address(0), "V3 pool should be cleared when V4 wins");
    }

    // =========================================================================
    // Test 2: V3 deeper liquidity than V4 => V3 still selected
    // =========================================================================

    /// @notice When V3 has deeper liquidity than V4, V3 should still be selected.
    function test_poolDiscovery_v3DeeperThanV4() public {
        // V3 has deep liquidity.
        _setupV3Pool(v3Pool3000, 3000, 1_000_000e18);

        // Hookless V4 has less liquidity.
        _setupV4HooklessPool(3000, 60, 500_000e18);

        (bool isV4, IUniswapV3Pool v3Pool,) = harness.discoverPool(_config(), TOKEN_A, TOKEN_B);

        assertFalse(isV4, "V3 should be selected when it has deeper liquidity");
        assertEq(address(v3Pool), v3Pool3000, "Best V3 pool should be returned");
    }

    // =========================================================================
    // Test 3: Equal liquidity => V3 wins (tie-break behavior)
    // =========================================================================

    /// @notice When V3 and V4 have equal liquidity, V3 wins because V4 requires
    /// strictly greater liquidity (> not >=).
    function test_poolDiscovery_equalLiquidity_v3Wins() public {
        uint128 sameLiquidity = 500_000e18;

        // V3 and V4 both at same liquidity.
        _setupV3Pool(v3Pool3000, 3000, sameLiquidity);
        _setupV4HooklessPool(3000, 60, sameLiquidity);

        (bool isV4, IUniswapV3Pool v3Pool,) = harness.discoverPool(_config(), TOKEN_A, TOKEN_B);

        assertFalse(isV4, "V3 should win on equal liquidity (V4 needs strictly more)");
        assertEq(address(v3Pool), v3Pool3000, "V3 pool should be returned on tie");
    }

    // =========================================================================
    // Test 4: V3 zero liquidity, V4 has liquidity => V4 selected
    // (Was already working before the fix, regression check)
    // =========================================================================

    /// @notice When V3 has zero liquidity and V4 has liquidity, V4 is selected.
    function test_poolDiscovery_v3ZeroLiquidity_v4Selected() public {
        // V3 pool exists but has zero liquidity.
        _setupV3Pool(v3Pool3000, 3000, 0);

        // V4 hookless has some liquidity.
        _setupV4HooklessPool(3000, 60, 100e18);

        (bool isV4,,) = harness.discoverPool(_config(), TOKEN_A, TOKEN_B);

        assertTrue(isV4, "V4 should be selected when V3 has zero liquidity");
    }

    // =========================================================================
    // Test 5: Hookless V4 with more liquidity than V3 (the broken case)
    // =========================================================================

    /// @notice Edge case: hookless V4 pool with strictly more liquidity than V3 should
    /// be selected. This was the exact scenario broken before the M-1 fix — the old
    /// code required V4 to have a hook OR V3 to have zero liquidity.
    function test_poolDiscovery_hooklessV4MoreLiquidityThanV3() public {
        // V3 has moderate liquidity.
        _setupV3Pool(v3Pool500, 500, 100_000e18);

        // Hookless V4 at 0.05% tier has more liquidity.
        _setupV4HooklessPool(500, 10, 200_000e18);

        (bool isV4, IUniswapV3Pool v3Pool,) = harness.discoverPool(_config(), TOKEN_A, TOKEN_B);

        assertTrue(isV4, "Hookless V4 with more liquidity must beat V3 (M-1 fix)");
        assertEq(address(v3Pool), address(0), "V3 pool should be zeroed when V4 wins");
    }

    // =========================================================================
    // Additional coverage: hooked V4 pool with more liquidity
    // =========================================================================

    /// @notice A hooked V4 pool with more liquidity than V3 should also be selected
    /// (this already worked before the fix, but verify it still works).
    function test_poolDiscovery_hookedV4BeatsV3() public {
        // V3 has some liquidity.
        _setupV3Pool(v3Pool3000, 3000, 50_000e18);

        // Hooked V4 has much more liquidity.
        _setupV4HookedPool(HOOK_ADDR, 3000, 60, 500_000e18);

        (bool isV4,,) = harness.discoverPool(_config(), TOKEN_A, TOKEN_B);

        assertTrue(isV4, "Hooked V4 with more liquidity should beat V3");
    }

    // =========================================================================
    // No V4 pool manager configured => V3 always wins
    // =========================================================================

    /// @notice When no V4 pool manager is configured, V3 is always selected.
    function test_poolDiscovery_noPoolManager_v3Only() public {
        _setupV3Pool(v3Pool3000, 3000, 100e18);

        JBSwapPoolLib.SwapConfig memory config = JBSwapPoolLib.SwapConfig({
            v3Factory: IUniswapV3Factory(v3Factory),
            poolManager: IPoolManager(address(0)), // No V4.
            univ4Hook: HOOK_ADDR,
            weth: WETH
        });

        (bool isV4, IUniswapV3Pool v3Pool,) = harness.discoverPool(config, TOKEN_A, TOKEN_B);

        assertFalse(isV4, "Without pool manager, V3 should always be selected");
        assertEq(address(v3Pool), v3Pool3000, "V3 pool should be returned");
    }

    // =========================================================================
    // No pools at all => reverts with NoPool in executeSwap (but discoverPool returns zeros)
    // =========================================================================

    /// @notice When neither V3 nor V4 has any pools, discoverPool returns zeros.
    function test_poolDiscovery_noPools_returnsZeros() public {
        // No pools configured (default setUp has all V3 returning address(0)).
        (bool isV4, IUniswapV3Pool v3Pool,) = harness.discoverPool(_config(), TOKEN_A, TOKEN_B);

        assertFalse(isV4, "Should not select V4 when no pools exist");
        assertEq(address(v3Pool), address(0), "No V3 pool should be found");
    }

    // =========================================================================
    // Multi-tier: V4 wins on a different tier than V3's best
    // =========================================================================

    /// @notice V3 best pool is on 0.3% tier, but hookless V4 on 0.05% tier has more liquidity.
    function test_poolDiscovery_v4WinsOnDifferentTier() public {
        // V3 at 0.3% has moderate liquidity.
        _setupV3Pool(v3Pool3000, 3000, 100_000e18);

        // Hookless V4 at 0.05% tier (fee=500, tickSpacing=10) has more.
        _setupV4HooklessPool(500, 10, 200_000e18);

        (bool isV4,,) = harness.discoverPool(_config(), TOKEN_A, TOKEN_B);

        assertTrue(isV4, "V4 should win even on a different fee tier");
    }

    // =========================================================================
    // V4 barely beats V3 (boundary: V4 has 1 more liquidity)
    // =========================================================================

    /// @notice V4 with exactly 1 more unit of liquidity than V3 should win.
    function test_poolDiscovery_v4BeatsV3ByOne() public {
        uint128 v3Liq = 1_000_000;

        _setupV3Pool(v3Pool3000, 3000, v3Liq);
        _setupV4HooklessPool(3000, 60, v3Liq + 1);

        (bool isV4,,) = harness.discoverPool(_config(), TOKEN_A, TOKEN_B);

        assertTrue(isV4, "V4 should win with strictly more liquidity (by 1 wei)");
    }
}
