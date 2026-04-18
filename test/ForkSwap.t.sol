// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {JBSwapCCIPSucker} from "../src/JBSwapCCIPSucker.sol";
import {JBSwapCCIPSuckerDeployer} from "../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";
import {JBSwapPoolLib} from "../src/libraries/JBSwapPoolLib.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Harness exposing internal swap functions for fork testing against real Uniswap V3 pools.
contract ForkSwapHarness is JBSwapCCIPSucker {
    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBSwapCCIPSucker(deployer, directory, tokens, permissions, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    /// @notice Expose pool discovery for testing (delegates to JBSwapPoolLib).
    function exposed_discoverPool(
        address normalizedIn,
        address normalizedOut
    )
        external
        view
        returns (bool isV4, IUniswapV3Pool v3Pool, PoolKey memory v4Key)
    {
        return JBSwapPoolLib.discoverPool(
            JBSwapPoolLib.SwapConfig({
                v3Factory: V3_FACTORY, poolManager: POOL_MANAGER, univ4Hook: UNIV4_HOOK, weth: address(WETH)
            }),
            normalizedIn,
            normalizedOut
        );
    }

    /// @notice Expose swap execution for testing.
    function exposed_executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amount
    )
        external
        returns (uint256 amountOut)
    {
        return _executeSwap(tokenIn, tokenOut, amount);
    }

    /// @notice Expose normalization for testing.
    function exposed_normalize(address token) external view returns (address) {
        return token == JBConstants.NATIVE_TOKEN ? address(WETH) : token;
    }

    /// @notice Read a conversion rate for a given nonce.
    function exposed_conversionRateOf(
        address token,
        uint64 nonce
    )
        external
        view
        returns (uint256 leafTotal, uint256 localTotal)
    {
        ConversionRate storage rate = _conversionRateOf[token][nonce];
        return (rate.leafTotal, rate.localTotal);
    }

    /// @notice Read batch start for a given nonce.
    function exposed_batchStartOf(address token, uint64 nonce) external view returns (uint256) {
        return _batchStartOf[token][nonce];
    }

    /// @notice Read batch end for a given nonce.
    function exposed_batchEndOf(address token, uint64 nonce) external view returns (uint256) {
        return _batchEndOf[token][nonce];
    }

    /// @notice Read highest received nonce for a token.
    function exposed_highestReceivedNonce(address token) external view returns (uint64) {
        return _highestReceivedNonce[token];
    }
}

/// @title ForkSwapTest
/// @notice Fork test for JBSwapCCIPSucker swap logic against real Uniswap V3 pools on Ethereum mainnet.
/// @dev Verifies pool discovery, ETH/USDC swaps, large swaps, and end-to-end ccipReceive flow
/// using production Uniswap contracts. Requires `RPC_ETHEREUM_MAINNET` env var.
contract ForkSwapTest is Test {
    // ── Ethereum mainnet addresses
    // ──────────────────────────────────
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant MAINNET_CCIP_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;

    // ── CCIP / Tempo constants
    // ──────────────────────────────────────
    uint64 constant TEMPO_CHAIN_SELECTOR = 7_281_642_695_469_137_430;

    // ── Mock addresses for deployer/directory (not swap-relevant) ───
    address constant MOCK_DEPLOYER = address(0xDE);
    address constant MOCK_DIRECTORY = address(0xD1);
    address constant MOCK_TOKENS = address(0xD2);
    address constant MOCK_PERMISSIONS = address(0xD3);
    address constant MOCK_PROJECTS = address(0xD5);

    ForkSwapHarness sucker;

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);

        vm.etch(MOCK_DEPLOYER, hex"01");

        // Mock deployer: CCIP config (not relevant to swap tests but needed by constructor).
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(uint256(4217)));
        vm.mockCall(
            MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(TEMPO_CHAIN_SELECTOR)
        );
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(MAINNET_CCIP_ROUTER));

        // Mock deployer: swap config — real V3 factory and WETH, real USDC as bridge token.
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("bridgeToken()"), abi.encode(USDC));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("poolManager()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("v3Factory()"), abi.encode(V3_FACTORY));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("univ4Hook()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("weth()"), abi.encode(MAINNET_WETH));

        // Mock directory (needed by JBSucker base constructor).
        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(MOCK_PROJECTS));
        vm.mockCall(MOCK_PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));

        // Deploy singleton and clone.
        ForkSwapHarness singleton = new ForkSwapHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
        sucker = ForkSwapHarness(payable(LibClone.cloneDeterministic(address(singleton), bytes32("forkswap"))));
        sucker.initialize(1);
    }

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @notice Constructor wires real V3 factory and WETH from deployer.
    function test_immutables() public view {
        assertEq(address(sucker.V3_FACTORY()), V3_FACTORY, "V3_FACTORY should be real mainnet factory");
        assertEq(address(sucker.WETH()), MAINNET_WETH, "WETH should be real mainnet WETH");
        assertEq(address(sucker.BRIDGE_TOKEN()), USDC, "BRIDGE_TOKEN should be real mainnet USDC");
        assertEq(address(sucker.POOL_MANAGER()), address(0), "POOL_MANAGER should be 0 (V4 not configured)");
    }

    // =========================================================================
    // Pool discovery
    // =========================================================================

    /// @notice V3 pool discovery finds the USDC/WETH pool on mainnet.
    function test_discoverPool_wethUsdc() public view {
        (bool isV4, IUniswapV3Pool v3Pool,) = sucker.exposed_discoverPool(MAINNET_WETH, USDC);

        assertFalse(isV4, "Should find V3 pool (V4 not configured)");
        assertTrue(address(v3Pool) != address(0), "V3 pool should exist for WETH/USDC");
        assertGt(v3Pool.liquidity(), 0, "Pool should have liquidity");
    }

    /// @notice Pool discovery picks the highest-liquidity fee tier.
    function test_discoverPool_highestLiquidity() public view {
        (bool isV4, IUniswapV3Pool bestPool,) = sucker.exposed_discoverPool(MAINNET_WETH, USDC);

        assertFalse(isV4);

        // The 0.05% (500) fee tier is typically the most liquid for WETH/USDC.
        // Verify our discovered pool has more liquidity than the 1% tier.
        address pool1pct = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            V3_FACTORY,
                            keccak256(
                                abi.encode(
                                    MAINNET_WETH < USDC ? MAINNET_WETH : USDC,
                                    MAINNET_WETH < USDC ? USDC : MAINNET_WETH,
                                    uint24(10_000)
                                )
                            ),
                            bytes32(0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54)
                        )
                    )
                )
            )
        );

        // If the 1% pool exists, our best pool should have >= its liquidity.
        if (pool1pct.code.length > 0) {
            uint128 pool1pctLiq = IUniswapV3Pool(pool1pct).liquidity();
            assertGe(bestPool.liquidity(), pool1pctLiq, "Best pool should have >= 1% tier liquidity");
        }
    }

    // =========================================================================
    // ETH -> USDC swap
    // =========================================================================

    /// @notice Swap 1 ETH -> USDC via real V3 pool. Verifies meaningful output.
    function test_swapEthToUsdc() public {
        uint256 ethAmount = 1 ether;

        // Fund sucker with ETH (needed for WETH wrapping in V3 callback).
        vm.deal(address(sucker), ethAmount);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(sucker));

        uint256 usdcOut = sucker.exposed_executeSwap(JBConstants.NATIVE_TOKEN, USDC, ethAmount);

        // Should receive a meaningful amount of USDC.
        assertGt(usdcOut, 0, "Should receive USDC");
        // Conservative bound: ETH is worth > $500 (holds from 2020 onwards).
        assertGt(usdcOut, 500e6, "USDC output should be reasonable (>$500 for 1 ETH)");

        // Balance accounting.
        assertEq(
            IERC20(USDC).balanceOf(address(sucker)) - usdcBefore, usdcOut, "USDC balance should increase by amountOut"
        );
        assertEq(address(sucker).balance, 0, "All ETH should be consumed");
    }

    /// @notice Swap a small amount of ETH -> USDC to check slippage on small trades.
    function test_swapSmallEthToUsdc() public {
        uint256 ethAmount = 0.01 ether;

        vm.deal(address(sucker), ethAmount);

        uint256 usdcOut = sucker.exposed_executeSwap(JBConstants.NATIVE_TOKEN, USDC, ethAmount);

        assertGt(usdcOut, 0, "Should receive USDC for small trade");
        // 0.01 ETH > $5 at any reasonable ETH price.
        assertGt(usdcOut, 5e6, "Small trade should still produce meaningful output");
    }

    // =========================================================================
    // USDC -> ETH swap
    // =========================================================================

    /// @notice Swap 1000 USDC -> ETH via real V3 pool. Verifies meaningful output.
    function test_swapUsdcToEth() public {
        uint256 usdcAmount = 1000e6; // 1000 USDC

        // Fund sucker with USDC.
        deal(USDC, address(sucker), usdcAmount);

        uint256 ethBefore = address(sucker).balance;

        uint256 ethOut = sucker.exposed_executeSwap(USDC, JBConstants.NATIVE_TOKEN, usdcAmount);

        // Should receive a meaningful amount of ETH.
        assertGt(ethOut, 0, "Should receive ETH");
        // Conservative bound: 1000 USDC > 0.01 ETH (assumes ETH < $100k).
        assertGt(ethOut, 0.01 ether, "ETH output should be reasonable (>0.01 ETH for $1000)");

        // Balance accounting.
        assertEq(address(sucker).balance - ethBefore, ethOut, "ETH balance should increase by amountOut");
        assertEq(IERC20(USDC).balanceOf(address(sucker)), 0, "All USDC should be consumed");
    }

    // =========================================================================
    // Large swap (liquidity stress)
    // =========================================================================

    /// @notice Swap 100 ETH -> USDC. Verifies large swaps execute without revert
    /// and that sigmoid slippage protection produces reasonable output.
    function test_swapLargeEthToUsdc() public {
        uint256 ethAmount = 100 ether;

        vm.deal(address(sucker), ethAmount);

        uint256 usdcOut = sucker.exposed_executeSwap(JBConstants.NATIVE_TOKEN, USDC, ethAmount);

        assertGt(usdcOut, 0, "Large swap should produce output");
        // 100 ETH should yield at least $50k USDC (ETH > $500).
        assertGt(usdcOut, 50_000e6, "Large swap output should be meaningful");

        // Price impact: output per ETH should be less than the 1 ETH swap price
        // (can't easily compare without state reset, just verify it completed).
        assertEq(address(sucker).balance, 0, "All ETH should be consumed");
    }

    /// @notice Swap 100,000 USDC -> ETH. Large reverse direction.
    function test_swapLargeUsdcToEth() public {
        uint256 usdcAmount = 100_000e6; // 100k USDC

        deal(USDC, address(sucker), usdcAmount);

        uint256 ethOut = sucker.exposed_executeSwap(USDC, JBConstants.NATIVE_TOKEN, usdcAmount);

        assertGt(ethOut, 0, "Large reverse swap should produce output");
        // $100k > 1 ETH at any reasonable price.
        assertGt(ethOut, 1 ether, "Large reverse swap output should be meaningful");
        assertEq(IERC20(USDC).balanceOf(address(sucker)), 0, "All USDC should be consumed");
    }

    // =========================================================================
    // End-to-end: ccipReceive -> swap -> scaling totals
    // =========================================================================

    /// @notice Full ccipReceive flow: receive USDC via CCIP, swap to ETH, update scaling totals.
    /// This is the Tempo -> Ethereum direction where the remote chain sends USDC and the
    /// local chain needs ETH.
    function test_ccipReceive_e2e_swapUsdcToEth() public {
        uint256 usdcAmount = 1000e6;

        // Fund sucker with USDC (simulates CCIP OffRamp token delivery before ccipReceive call).
        deal(USDC, address(sucker), usdcAmount);

        // Build a ROOT message: the remote (Tempo) sends USDC, local token is NATIVE_TOKEN (ETH).
        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: usdcAmount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xdead))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 18,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        Client.EVMTokenAmount[] memory destTokenAmounts = new Client.EVMTokenAmount[](1);
        destTokenAmounts[0] = Client.EVMTokenAmount({token: USDC, amount: usdcAmount});

        Client.Any2EVMMessage memory ccipMsg = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: TEMPO_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)), // peer() == address(this)
            data: abi.encode(uint8(0), abi.encode(root, uint256(0), uint256(1))), // type 0 = ROOT, range [0,1)
            destTokenAmounts: destTokenAmounts
        });

        uint256 ethBefore = address(sucker).balance;

        // Prank as the real mainnet CCIP router.
        vm.prank(MAINNET_CCIP_ROUTER);
        sucker.ccipReceive(ccipMsg);

        // Verify: swap happened — sucker now holds ETH from USDC->ETH swap.
        uint256 ethReceived = address(sucker).balance - ethBefore;
        assertGt(ethReceived, 0, "Sucker should hold ETH from USDC->ETH swap");
        assertGt(ethReceived, 0.01 ether, "ETH amount should be reasonable for 1000 USDC");

        // Verify: USDC was consumed by the swap.
        assertEq(IERC20(USDC).balanceOf(address(sucker)), 0, "All USDC should be swapped");

        // Verify: conversion rate stored for nonce 1 with correct values.
        assertEq(sucker.exposed_highestReceivedNonce(JBConstants.NATIVE_TOKEN), 1, "highest nonce should be 1");
        (uint256 leafEntry, uint256 localEntry) = sucker.exposed_conversionRateOf(JBConstants.NATIVE_TOKEN, 1);
        assertEq(leafEntry, usdcAmount, "leafTotal should equal root.amount (source denomination)");
        assertEq(localEntry, ethReceived, "localTotal should equal ETH received from swap");
    }

    /// @notice ccipReceive with no swap needed (localToken == BRIDGE_TOKEN).
    /// This tests the Tempo-side scenario where the local token IS USDC.
    function test_ccipReceive_e2e_noSwapNeeded() public {
        uint256 usdcAmount = 500e6;

        // Fund sucker with USDC.
        deal(USDC, address(sucker), usdcAmount);

        // Root token is USDC (== BRIDGE_TOKEN), so no swap is needed.
        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(USDC))),
            amount: usdcAmount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xbeef))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 18,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        Client.EVMTokenAmount[] memory destTokenAmounts = new Client.EVMTokenAmount[](1);
        destTokenAmounts[0] = Client.EVMTokenAmount({token: USDC, amount: usdcAmount});

        Client.Any2EVMMessage memory ccipMsg = Client.Any2EVMMessage({
            messageId: bytes32(uint256(2)),
            sourceChainSelector: TEMPO_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)),
            data: abi.encode(uint8(0), abi.encode(root, uint256(0), uint256(1))), // range [0,1)
            destTokenAmounts: destTokenAmounts
        });

        vm.prank(MAINNET_CCIP_ROUTER);
        sucker.ccipReceive(ccipMsg);

        // No swap — conversion rate stored for nonce 1 with 1:1 ratio.
        assertEq(sucker.exposed_highestReceivedNonce(USDC), 1, "highest nonce should be 1");
        (uint256 leafEntry, uint256 localEntry) = sucker.exposed_conversionRateOf(USDC, 1);
        assertEq(leafEntry, usdcAmount, "leafTotal should equal root.amount");
        assertEq(localEntry, usdcAmount, "localTotal should equal delivered amount (no swap, 1:1)");
    }

    // =========================================================================
    // Normalization guard
    // =========================================================================

    /// @notice NATIVE_TOKEN -> WETH is a no-op (same token after normalization).
    function test_swapNativeToWeth_noop() public {
        uint256 ethAmount = 1 ether;
        vm.deal(address(sucker), ethAmount);

        uint256 amountOut = sucker.exposed_executeSwap(JBConstants.NATIVE_TOKEN, MAINNET_WETH, ethAmount);

        // No actual swap occurs -- normalization guard returns the input amount directly.
        assertEq(amountOut, ethAmount, "Should be 1:1 (normalized tokens are the same)");
    }

    /// @notice NATIVE_TOKEN normalizes to real WETH, USDC stays unchanged.
    function test_normalize_mainnet() public view {
        assertEq(sucker.exposed_normalize(JBConstants.NATIVE_TOKEN), MAINNET_WETH, "NATIVE_TOKEN -> WETH");
        assertEq(sucker.exposed_normalize(USDC), USDC, "USDC -> USDC");
    }
}
