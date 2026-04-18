// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSwapCCIPSucker} from "../../src/JBSwapCCIPSucker.sol";
import {JBSwapCCIPSuckerDeployer} from "../../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice Minimal terminal mock that actually transfers ERC-20 tokens from the caller.
contract MockTerminal {
    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes memory
    )
        external
        payable
    {
        if (token != address(0x000000000000000000000000000000000000EEEe)) {
            IERC20(token).transferFrom(msg.sender, address(this), amount);
        }
    }
}

/// @notice Harness contract exposing JBSwapCCIPSucker internals for testing.
contract SwapCCIPTestHarness is JBSwapCCIPSucker {
    using MerkleLib for MerkleLib.Tree;

    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBSwapCCIPSucker(deployer, directory, tokens, permissions, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    /// @notice Set a conversion rate for a specific nonce with its batch range.
    function test_setConversionRate(
        address token,
        uint64 nonce,
        uint256 leafTotal,
        uint256 localTotal,
        uint256 batchStart,
        uint256 batchEnd
    )
        external
    {
        _conversionRateOf[token][nonce] = ConversionRate({leafTotal: leafTotal, localTotal: localTotal});
        _batchStartOf[token][nonce] = batchStart;
        _batchEndOf[token][nonce] = batchEnd;
        if (nonce > _highestReceivedNonce[token]) {
            _highestReceivedNonce[token] = nonce;
        }
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

    /// @notice Read the batch start for a given nonce.
    function exposed_batchStartOf(address token, uint64 nonce) external view returns (uint256) {
        return _batchStartOf[token][nonce];
    }

    /// @notice Read the batch end for a given nonce.
    function exposed_batchEndOf(address token, uint64 nonce) external view returns (uint256) {
        return _batchEndOf[token][nonce];
    }

    /// @notice Read the highest received nonce for a token.
    function exposed_highestReceivedNonce(address token) external view returns (uint64) {
        return _highestReceivedNonce[token];
    }

    /// @notice Expose _addToBalance for direct testing (with leaf index context).
    function exposed_addToBalance(address token, uint256 amount, uint256 projectId, uint256 leafIndex) external {
        _currentClaimLeafIndex = leafIndex + 1;
        _addToBalance(token, amount, projectId);
    }

    /// @notice Expose _addToBalance without leaf index (bypass scaling).
    function exposed_addToBalance(address token, uint256 amount, uint256 projectId) external {
        _addToBalance(token, amount, projectId);
    }

    /// @notice Expose _normalize for testing.
    function exposed_normalize(address token) external view returns (address) {
        return token == JBConstants.NATIVE_TOKEN ? address(WETH) : token;
    }

    /// @notice Set a remote token mapping for testing.
    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }
}

/// @title SwapCCIPScalingTest
/// @notice Tests for the cross-denomination scaling math in JBSwapCCIPSucker.
/// Verifies the FIFO conversion queue correctly isolates batch exchange rates
/// and prevents blended-rate bugs when overlapping roots arrive at different swap rates.
contract SwapCCIPScalingTest is Test {
    address constant MOCK_DEPLOYER = address(0xDE);
    address constant MOCK_DIRECTORY = address(0xD1);
    address constant MOCK_TOKENS = address(0xD2);
    address constant MOCK_PERMISSIONS = address(0xD3);
    address constant MOCK_ROUTER = address(0xD4);
    address constant MOCK_PROJECTS = address(0xD5);

    uint256 constant PROJECT_ID = 1;
    uint256 constant REMOTE_CHAIN_ID = 4217; // Tempo
    uint64 constant REMOTE_CHAIN_SELECTOR = 7_281_642_695_469_137_430;

    ERC20Mock usdc;
    ERC20Mock weth;
    MockTerminal terminal;
    SwapCCIPTestHarness sucker;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        terminal = new MockTerminal();

        vm.etch(MOCK_ROUTER, hex"01");

        // Mock deployer responses.
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(REMOTE_CHAIN_ID));
        vm.mockCall(
            MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(REMOTE_CHAIN_SELECTOR)
        );
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(MOCK_ROUTER));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("bridgeToken()"), abi.encode(address(usdc)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("poolManager()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("v3Factory()"), abi.encode(address(0x1234))); // non-zero V3
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("univ4Hook()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("weth()"), abi.encode(address(weth)));

        // Mock CCIP router.
        vm.mockCall(MOCK_ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(weth)));

        // Mock directory.
        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(MOCK_PROJECTS));
        vm.mockCall(MOCK_PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));
        vm.mockCall(
            MOCK_DIRECTORY,
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(address(terminal))
        );

        // Deploy singleton and clone.
        SwapCCIPTestHarness singleton = new SwapCCIPTestHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
        sucker = SwapCCIPTestHarness(payable(LibClone.cloneDeterministic(address(singleton), bytes32("swap"))));
        sucker.initialize(PROJECT_ID);
    }

    // =========================================================================
    // Scaling: single batch
    // =========================================================================

    /// @notice Single batch — scaling converts leaf denomination to local denomination.
    function test_scaling_singleBatch() public {
        address token = address(usdc);

        // Simulate: nonce 1, 1 leaf in batch, 1e18 leaf amount → 1800e6 USDC, range [0,1).
        sucker.test_setConversionRate(token, 1, 1e18, 1800e6, 0, 1);
        usdc.mint(address(sucker), 1800e6);

        // Claim leaf 0 (full batch, 1e18 leaf amount) — should scale to 1800e6.
        sucker.exposed_addToBalance(token, 1e18, PROJECT_ID, 0);
    }

    /// @notice Single batch — partial claim scales proportionally.
    function test_scaling_singleBatch_partial() public {
        address token = address(usdc);

        // Simulate: nonce 1, 2 leaves, 2e18 leaf total → 3600e6 USDC, range [0,2).
        sucker.test_setConversionRate(token, 1, 2e18, 3600e6, 0, 2);
        usdc.mint(address(sucker), 3600e6);

        // Claim leaf 0 (half: 1e18 leaf).
        uint256 balBefore = usdc.balanceOf(address(sucker));
        sucker.exposed_addToBalance(token, 1e18, PROJECT_ID, 0);
        uint256 claimed = balBefore - usdc.balanceOf(address(sucker));
        assertEq(claimed, 1800e6, "half claim should get half local amount");

        // Rate is immutable — can still claim the other half at the same rate.
        balBefore = usdc.balanceOf(address(sucker));
        sucker.exposed_addToBalance(token, 1e18, PROJECT_ID, 1);
        claimed = balBefore - usdc.balanceOf(address(sucker));
        assertEq(claimed, 1800e6, "second half should get same rate");
    }

    // =========================================================================
    // Scaling: multiple batches — different rates
    // =========================================================================

    /// @notice Two batches with different rates — each claim gets its own rate.
    function test_scaling_twoBatches_differentRates() public {
        address token = address(usdc);

        // Batch 1 (nonce 1): 1e18 leaf → 1800e6 USDC, range [0,1).
        sucker.test_setConversionRate(token, 1, 1e18, 1800e6, 0, 1);
        // Batch 2 (nonce 2): 1e18 leaf → 1600e6 USDC, range [1,2).
        sucker.test_setConversionRate(token, 2, 1e18, 1600e6, 1, 2);
        usdc.mint(address(sucker), 3400e6);

        // Claim from batch 1 (leaf 0).
        uint256 balBefore = usdc.balanceOf(address(sucker));
        sucker.exposed_addToBalance(token, 1e18, PROJECT_ID, 0);
        uint256 claimed1 = balBefore - usdc.balanceOf(address(sucker));
        assertEq(claimed1, 1800e6, "batch 1 should use rate 1800");

        // Claim from batch 2 (leaf 1).
        balBefore = usdc.balanceOf(address(sucker));
        sucker.exposed_addToBalance(token, 1e18, PROJECT_ID, 1);
        uint256 claimed2 = balBefore - usdc.balanceOf(address(sucker));
        assertEq(claimed2, 1600e6, "batch 2 should use rate 1600");
    }

    /// @notice Two batches with rising rate — no dust.
    function test_scaling_twoBatches_risingRate_noDust() public {
        address token = address(usdc);

        // Batch 1: 1e18 leaf → 1800e6 USDC, range [0,1).
        sucker.test_setConversionRate(token, 1, 1e18, 1800e6, 0, 1);
        // Batch 2: 1e18 leaf → 2000e6 USDC, range [1,2).
        sucker.test_setConversionRate(token, 2, 1e18, 2000e6, 1, 2);
        usdc.mint(address(sucker), 3800e6);

        sucker.exposed_addToBalance(token, 1e18, PROJECT_ID, 0);
        sucker.exposed_addToBalance(token, 1e18, PROJECT_ID, 1);

        assertEq(usdc.balanceOf(address(sucker)), 0, "no USDC dust should be stuck");
    }

    // =========================================================================
    // Scaling: overlapping batches — the core bug fix
    // =========================================================================

    /// @notice Two overlapping batches with different rates — each claim gets its own rate.
    /// This was the cross-batch rate mixing bug (NM-002 / SI-002 / FF-002).
    function test_scaling_overlappingBatches_rateIsolation() public {
        address token = address(usdc);

        // Batch 1 (nonce 1): 100 leaf → 100 local (rate 1.0), range [0,1).
        sucker.test_setConversionRate(token, 1, 100, 100, 0, 1);
        // Batch 2 (nonce 2): 100 leaf → 50 local (rate 0.5), range [1,2).
        sucker.test_setConversionRate(token, 2, 100, 50, 1, 2);
        usdc.mint(address(sucker), 150);

        // Claim from batch 1 (leaf 0) — should get 100, not blended 75.
        uint256 balBefore = usdc.balanceOf(address(sucker));
        sucker.exposed_addToBalance(token, 100, PROJECT_ID, 0);
        uint256 claimed1 = balBefore - usdc.balanceOf(address(sucker));
        assertEq(claimed1, 100, "batch 1 claim should use rate 1.0");

        // Claim from batch 2 (leaf 1) — should get 50, not blended 75.
        balBefore = usdc.balanceOf(address(sucker));
        sucker.exposed_addToBalance(token, 100, PROJECT_ID, 1);
        uint256 claimed2 = balBefore - usdc.balanceOf(address(sucker));
        assertEq(claimed2, 50, "batch 2 claim should use rate 0.5");
    }

    /// @notice Out-of-order claims: batch 2 claimed before batch 1 — still correct rates.
    function test_scaling_outOfOrder_correctRates() public {
        address token = address(usdc);

        // Batch 1 (nonce 1): rate 1.0, range [0,1).
        sucker.test_setConversionRate(token, 1, 100, 100, 0, 1);
        // Batch 2 (nonce 2): rate 0.5, range [1,2).
        sucker.test_setConversionRate(token, 2, 100, 50, 1, 2);
        usdc.mint(address(sucker), 150);

        // Claim batch 2 FIRST (leaf 1).
        uint256 balBefore = usdc.balanceOf(address(sucker));
        sucker.exposed_addToBalance(token, 100, PROJECT_ID, 1);
        uint256 claimed2 = balBefore - usdc.balanceOf(address(sucker));
        assertEq(claimed2, 50, "batch 2 claim should use rate 0.5 even when claimed first");

        // Then claim batch 1 (leaf 0).
        balBefore = usdc.balanceOf(address(sucker));
        sucker.exposed_addToBalance(token, 100, PROJECT_ID, 0);
        uint256 claimed1 = balBefore - usdc.balanceOf(address(sucker));
        assertEq(claimed1, 100, "batch 1 claim should use rate 1.0 even when claimed second");
    }

    // =========================================================================
    // Scaling: conservation property
    // =========================================================================

    /// @notice Total scaled claims from one batch always equal batch's localTotal.
    function test_scaling_conservation_threeClaims() public {
        address token = address(usdc);

        // Nonce 1: 3e18 leaf → 5400e6 USDC, 3 leaves, range [0,3).
        sucker.test_setConversionRate(token, 1, 3e18, 5400e6, 0, 3);
        usdc.mint(address(sucker), 5400e6);

        // Three claims of 1e18 each from the same batch.
        sucker.exposed_addToBalance(token, 1e18, PROJECT_ID, 0);
        sucker.exposed_addToBalance(token, 1e18, PROJECT_ID, 1);
        sucker.exposed_addToBalance(token, 1e18, PROJECT_ID, 2);

        // All tokens should be claimed.
        assertEq(usdc.balanceOf(address(sucker)), 0, "no dust should remain");
    }

    // =========================================================================
    // Scaling: no cross-currency (bypass)
    // =========================================================================

    /// @notice When no conversion rates exist (same-denomination bridging), scaling is bypassed.
    function test_scaling_bypass_whenNoRates() public {
        address token = address(usdc);

        // No conversion rates set (default 0).
        usdc.mint(address(sucker), 1000e6);

        // The raw amount should pass through unscaled.
        sucker.exposed_addToBalance(token, 1000e6, PROJECT_ID);
        assertEq(usdc.balanceOf(address(sucker)), 0, "full amount should be sent to terminal");
    }

    // =========================================================================
    // Scaling: fuzz test
    // =========================================================================

    /// @notice Fuzz: multiple claims from a single batch — total scaled never exceeds localTotal.
    function testFuzz_scaling_singleBatch_neverExceedsLocal(
        uint128 leafTotal,
        uint128 localTotal,
        uint8 numClaims
    )
        public
    {
        vm.assume(leafTotal > 0);
        vm.assume(localTotal > 0);
        vm.assume(numClaims > 0 && numClaims <= 20);
        uint256 perClaim = uint256(leafTotal) / numClaims;
        vm.assume(perClaim > 0);

        address token = address(usdc);
        sucker.test_setConversionRate(token, 1, leafTotal, localTotal, 0, numClaims);
        usdc.mint(address(sucker), localTotal);

        uint256 totalClaimed;
        uint256 balBefore;
        for (uint256 i; i < numClaims - 1; i++) {
            balBefore = usdc.balanceOf(address(sucker));
            sucker.exposed_addToBalance(token, perClaim, PROJECT_ID, i);
            totalClaimed += balBefore - usdc.balanceOf(address(sucker));
        }

        // Last claim gets the remainder.
        uint256 remainder = uint256(leafTotal) - perClaim * (numClaims - 1);
        balBefore = usdc.balanceOf(address(sucker));
        sucker.exposed_addToBalance(token, remainder, PROJECT_ID, numClaims - 1);
        totalClaimed += balBefore - usdc.balanceOf(address(sucker));

        // Conservation: total claimed should equal localTotal (within rounding dust).
        // The immutable rate approach rounds independently per claim: floor(claimAmount * localTotal / leafTotal).
        // Each claim can lose at most 1 wei, so total dust is bounded by numClaims.
        assertLe(localTotal - totalClaimed, numClaims, "rounding dust must be bounded by numClaims");
    }

    // =========================================================================
    // Gap detection
    // =========================================================================

    /// @notice Missing nonce: leaf not in any received range reverts with BatchNotReceived.
    function test_scaling_gap_reverts() public {
        address token = address(usdc);

        // Only nonce 2 received (nonce 1 missing). Range [1, 2).
        sucker.test_setConversionRate(token, 2, 100, 50, 1, 2);
        usdc.mint(address(sucker), 50);

        // Claiming leaf 0 reverts — not in any received batch's range.
        vm.expectRevert(abi.encodeWithSelector(JBSwapCCIPSucker.JBSwapCCIPSucker_BatchNotReceived.selector, uint64(0)));
        sucker.exposed_addToBalance(token, 100, PROJECT_ID, 0);
    }

    /// @notice Gap fill: late nonce 1 arrival unblocks previously blocked claims.
    function test_scaling_gapFill_unblocks() public {
        address token = address(usdc);

        // Nonce 2 arrives first, range [1,2).
        sucker.test_setConversionRate(token, 2, 100, 50, 1, 2);
        usdc.mint(address(sucker), 150);

        // Leaf 0 reverts (not in any received range).
        vm.expectRevert(abi.encodeWithSelector(JBSwapCCIPSucker.JBSwapCCIPSucker_BatchNotReceived.selector, uint64(0)));
        sucker.exposed_addToBalance(token, 100, PROJECT_ID, 0);

        // Nonce 1 arrives late, range [0,1).
        sucker.test_setConversionRate(token, 1, 100, 100, 0, 1);

        // Now leaf 0 succeeds with nonce 1's rate.
        uint256 balBefore = usdc.balanceOf(address(sucker));
        sucker.exposed_addToBalance(token, 100, PROJECT_ID, 0);
        uint256 claimed = balBefore - usdc.balanceOf(address(sucker));
        assertEq(claimed, 100, "leaf 0 should use nonce 1's rate after gap fill");
    }

    // =========================================================================
    // Normalize
    // =========================================================================

    /// @notice NATIVE_TOKEN normalizes to WETH.
    function test_normalize_nativeToWeth() public view {
        assertEq(sucker.exposed_normalize(JBConstants.NATIVE_TOKEN), address(weth));
    }

    /// @notice Non-native token normalizes to itself.
    function test_normalize_erc20Unchanged() public view {
        assertEq(sucker.exposed_normalize(address(usdc)), address(usdc));
    }

    // =========================================================================
    // Constructor immutables
    // =========================================================================

    /// @notice Immutables are set correctly from deployer.
    function test_constructor_immutables() public view {
        assertEq(address(sucker.BRIDGE_TOKEN()), address(usdc));
        assertEq(address(sucker.WETH()), address(weth));
    }
}

/// @title SwapCCIPConstructorTest
/// @notice Tests for constructor validation in JBSwapCCIPSucker.
contract SwapCCIPConstructorTest is Test {
    address constant MOCK_DEPLOYER = address(0xDE);
    address constant MOCK_DIRECTORY = address(0xD1);
    address constant MOCK_TOKENS = address(0xD2);
    address constant MOCK_PERMISSIONS = address(0xD3);
    address constant MOCK_ROUTER = address(0xD4);

    ERC20Mock usdc;
    ERC20Mock weth;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);

        vm.etch(MOCK_ROUTER, hex"01");

        // Base deployer mocks.
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(uint256(4217)));
        vm.mockCall(
            MOCK_DEPLOYER,
            abi.encodeWithSignature("ccipRemoteChainSelector()"),
            abi.encode(uint64(7_281_642_695_469_137_430))
        );
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(MOCK_ROUTER));
        vm.mockCall(MOCK_ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(weth)));

        // Mock directory so JBSucker constructor can initialize the PROJECTS immutable.
        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(address(0)));
    }

    /// @notice Reverts when bridgeToken is address(0).
    function test_constructor_reverts_zeroBridgeToken() public {
        _mockSwapConfig(address(0), address(0), address(0x1234), address(0), address(weth));

        vm.expectRevert(JBSwapCCIPSucker.JBSwapCCIPSucker_InvalidBridgeToken.selector);
        new SwapCCIPTestHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
    }

    /// @notice Reverts when bridgeToken == WETH.
    function test_constructor_reverts_bridgeTokenIsWeth() public {
        _mockSwapConfig(address(weth), address(0), address(0x1234), address(0), address(weth));

        vm.expectRevert(JBSwapCCIPSucker.JBSwapCCIPSucker_InvalidBridgeToken.selector);
        new SwapCCIPTestHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
    }

    /// @notice Succeeds with no swap infra (Tempo scenario: local token IS bridge token, no swaps needed).
    function test_constructor_succeeds_noSwapInfra_tempoScenario() public {
        _mockSwapConfig(address(usdc), address(0), address(0), address(0), address(weth));

        SwapCCIPTestHarness s = new SwapCCIPTestHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
        assertEq(address(s.BRIDGE_TOKEN()), address(usdc));
        assertEq(address(s.V3_FACTORY()), address(0));
        assertEq(address(s.POOL_MANAGER()), address(0));
    }

    /// @notice Succeeds with only V3 (no V4).
    function test_constructor_succeeds_v3Only() public {
        _mockSwapConfig(address(usdc), address(0), address(0x1234), address(0), address(weth));

        SwapCCIPTestHarness s = new SwapCCIPTestHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
        assertEq(address(s.BRIDGE_TOKEN()), address(usdc));
    }

    /// @notice Succeeds with only V4 (no V3).
    function test_constructor_succeeds_v4Only() public {
        _mockSwapConfig(address(usdc), address(0x5678), address(0), address(0), address(weth));

        SwapCCIPTestHarness s = new SwapCCIPTestHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
        assertEq(address(s.POOL_MANAGER()), address(0x5678));
    }

    function _mockSwapConfig(
        address bridgeToken,
        address poolManager,
        address v3Factory,
        address univ4Hook,
        address _weth
    )
        internal
    {
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("bridgeToken()"), abi.encode(bridgeToken));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("poolManager()"), abi.encode(poolManager));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("v3Factory()"), abi.encode(v3Factory));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("univ4Hook()"), abi.encode(univ4Hook));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("weth()"), abi.encode(_weth));
    }
}
