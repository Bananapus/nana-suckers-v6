// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {JBSwapPoolLib} from "../../src/libraries/JBSwapPoolLib.sol";

contract PartialFillToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract PartialFillFactory {
    mapping(bytes32 key => address pool) internal _poolOf;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        _poolOf[keccak256(abi.encode(tokenA, tokenB, fee))] = pool;
        _poolOf[keccak256(abi.encode(tokenB, tokenA, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _poolOf[keccak256(abi.encode(tokenA, tokenB, fee))];
    }
}

contract PartialFillPool {
    uint24 public immutable fee;
    uint128 public immutable liquidity;
    address public immutable token0;
    address public immutable token1;

    uint256 public immutable consumedAmount;
    uint256 public immutable outputAmount;

    constructor(address tokenA, address tokenB, uint24 fee_, uint128 liquidity_, uint256 consumed_, uint256 output_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = fee_;
        liquidity = liquidity_;
        consumedAmount = consumed_;
        outputAmount = output_;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(1 << 96), 0, 0, 2, 2, 0, true);
    }

    function observations(uint256) external view returns (uint32, int56, uint160, bool) {
        return (uint32(block.timestamp) - 601, 0, 0, true);
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory, uint160[] memory) {
        int56[] memory tickCumulatives = new int56[](2);
        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](2);

        uint32 window = secondsAgos[0];
        uint160 delta = uint160((uint192(window) * type(uint160).max) / (uint192(uint256(liquidity)) << 32));
        secondsPerLiquidityCumulativeX128s[1] = delta;

        return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256,
        uint160,
        bytes calldata data
    )
        external
        returns (int256 amount0, int256 amount1)
    {
        if (zeroForOne) {
            IUniswapV3SwapCallback(msg.sender)
                .uniswapV3SwapCallback({
                // forge-lint: disable-next-line(unsafe-typecast)
                amount0Delta: int256(consumedAmount),
                // forge-lint: disable-next-line(unsafe-typecast)
                amount1Delta: -int256(outputAmount),
                data: data
            });
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            PartialFillToken(token1).transfer(recipient, outputAmount);
            // forge-lint: disable-next-line(unsafe-typecast)
            return (int256(consumedAmount), -int256(outputAmount));
        }

        IUniswapV3SwapCallback(msg.sender)
            .uniswapV3SwapCallback({
            // forge-lint: disable-next-line(unsafe-typecast)
            amount0Delta: -int256(outputAmount),
            // forge-lint: disable-next-line(unsafe-typecast)
            amount1Delta: int256(consumedAmount),
            data: data
        });
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        PartialFillToken(token0).transfer(recipient, outputAmount);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (-int256(outputAmount), int256(consumedAmount));
    }
}

contract V4PartialFillPoolManager {
    int128 internal constant CONSUMED_AMOUNT = 500 ether;
    int128 internal constant OUTPUT_AMOUNT = 990 ether;

    function swap(PoolKey calldata, SwapParams calldata params, bytes calldata) external pure returns (BalanceDelta) {
        return params.zeroForOne
            ? toBalanceDelta(-CONSUMED_AMOUNT, OUTPUT_AMOUNT)
            : toBalanceDelta(OUTPUT_AMOUNT, -CONSUMED_AMOUNT);
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256 paid) {
        return msg.value;
    }

    function take(Currency, address, uint256) external {}
}

contract PartialFillHarness is IUniswapV3SwapCallback {
    IUniswapV3Factory internal immutable _factory;

    constructor(IUniswapV3Factory factory_) {
        _factory = factory_;
    }

    function executeSwap(
        JBSwapPoolLib.SwapConfig memory config,
        address tokenIn,
        address tokenOut,
        uint256 amount
    )
        external
        returns (uint256)
    {
        return JBSwapPoolLib.executeSwap({
            config: config, tokenIn: tokenIn, tokenOut: tokenOut, amount: amount, minAmountOut: 0
        });
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        JBSwapPoolLib.executeV3SwapCallback({
            v3Factory: _factory, amount0Delta: amount0Delta, amount1Delta: amount1Delta, data: data
        });
    }

    function executeV4UnlockCallback(IPoolManager poolManager, bytes calldata data) external returns (bytes memory) {
        return JBSwapPoolLib.executeV4UnlockCallback({poolManager: poolManager, data: data});
    }

    receive() external payable {}
}

contract SwapPartialFillRemainderTest is Test {
    uint24 internal constant FEE = 3000;
    uint128 internal constant LIQUIDITY = 1_000_000_000 ether;
    uint256 internal constant AMOUNT_IN = 1000 ether;
    uint256 internal constant CONSUMED = 500 ether;
    uint256 internal constant AMOUNT_OUT = 990 ether;

    /// @notice V3 partial fills now revert. The pool's sqrtPriceLimit can stop a swap before all
    /// input is consumed, leaving the caller with a remainder that the sucker's accounting cannot
    /// reconcile (the bridge amount has already been recorded as fully swapped). Reverting forces
    /// the operator to retry with a size that the pool can fully absorb.
    function test_v3PartialFillReverts() external {
        vm.warp(10_000);

        PartialFillToken tokenIn = new PartialFillToken("Input", "IN");
        PartialFillToken tokenOut = new PartialFillToken("Output", "OUT");
        PartialFillFactory factory = new PartialFillFactory();
        PartialFillHarness harness = new PartialFillHarness(IUniswapV3Factory(address(factory)));

        PartialFillPool pool = new PartialFillPool({
            tokenA: address(tokenIn),
            tokenB: address(tokenOut),
            fee_: FEE,
            liquidity_: LIQUIDITY,
            consumed_: CONSUMED,
            output_: AMOUNT_OUT
        });
        factory.setPool({tokenA: address(tokenIn), tokenB: address(tokenOut), fee: FEE, pool: address(pool)});

        tokenIn.mint(address(harness), AMOUNT_IN);
        tokenOut.mint(address(pool), AMOUNT_OUT);

        JBSwapPoolLib.SwapConfig memory config = JBSwapPoolLib.SwapConfig({
            v3Factory: IUniswapV3Factory(address(factory)),
            poolManager: IPoolManager(address(0)),
            univ4Hook: address(0),
            wrappedNativeToken: address(0xBEEF)
        });

        vm.expectRevert(abi.encodeWithSelector(JBSwapPoolLib.JBSwapPoolLib_PartialFill.selector, CONSUMED, AMOUNT_IN));
        harness.executeSwap({config: config, tokenIn: address(tokenIn), tokenOut: address(tokenOut), amount: AMOUNT_IN});
    }

    function test_v4PartialFillReverts() external {
        PartialFillToken tokenA = new PartialFillToken("Input", "IN");
        PartialFillToken tokenB = new PartialFillToken("Output", "OUT");
        PartialFillToken token0 = address(tokenA) < address(tokenB) ? tokenA : tokenB;
        PartialFillToken token1 = address(tokenA) < address(tokenB) ? tokenB : tokenA;
        PartialFillHarness harness = new PartialFillHarness(IUniswapV3Factory(address(0)));
        V4PartialFillPoolManager poolManager = new V4PartialFillPoolManager();

        token0.mint(address(harness), AMOUNT_IN);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory data = abi.encode(key, true, -int256(AMOUNT_IN), uint160(1 << 96), AMOUNT_OUT - 1, address(0));

        vm.expectRevert(abi.encodeWithSelector(JBSwapPoolLib.JBSwapPoolLib_PartialFill.selector, CONSUMED, AMOUNT_IN));
        harness.executeV4UnlockCallback({poolManager: IPoolManager(address(poolManager)), data: data});
    }
}
