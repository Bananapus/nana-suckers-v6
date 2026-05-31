// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSwapCCIPSucker} from "../../src/JBSwapCCIPSucker.sol";
import {JBSwapCCIPSuckerDeployer} from "../../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {JBConversionRate} from "../../src/structs/JBConversionRate.sol";

contract RegressionMockTerminal {
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
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

contract RegressionSwapBatchHarness is JBSwapCCIPSucker {
    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBSwapCCIPSucker(
            deployer,
            directory,
            permissions,
            IJBPrices(address(1)),
            tokens,
            1,
            IJBSuckerRegistry(address(1)),
            address(0)
        )
    {}

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
        _conversionRateOf[token][nonce] = JBConversionRate({leafTotal: leafTotal, localTotal: localTotal});
        _batchStartOf[token][nonce] = batchStart;
        _batchEndOf[token][nonce] = batchEnd;
        // Mirror the bookkeeping `ccipReceive` performs on real deliveries so
        // `_findNonceForLeafIndex` can walk only populated nonces.
        uint64 priorCount = _populatedNonceCount[token];
        _populatedNonceByIndex[token][priorCount] = nonce;
        _populatedNonceCount[token] = priorCount + 1;
    }

    function exposed_addToBalance(address token, uint256 amount, uint256 projectId, uint256 leafIndex) external {
        _currentClaimLeafIndex = leafIndex + 1;
        _addToBalance(token, amount, projectId);
    }
}

contract RegressionSwapBatchRateMixingTest is Test {
    address internal constant MOCK_DEPLOYER = address(0xDE);
    address internal constant MOCK_DIRECTORY = address(0xD1);
    address internal constant MOCK_TOKENS = address(0xD2);
    address internal constant MOCK_PERMISSIONS = address(0xD3);
    address internal constant MOCK_ROUTER = address(0xD4);
    address internal constant MOCK_PROJECTS = address(0xD5);

    uint256 internal constant PROJECT_ID = 1;

    ERC20Mock internal usdc;
    ERC20Mock internal weth;
    RegressionMockTerminal internal terminal;
    RegressionSwapBatchHarness internal sucker;

    function setUp() external {
        usdc = new ERC20Mock("USDC", "USDC", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        terminal = new RegressionMockTerminal();

        vm.etch(MOCK_ROUTER, hex"01");

        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(uint256(4217)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(uint64(7)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(MOCK_ROUTER));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("bridgeToken()"), abi.encode(address(usdc)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("poolManager()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("v3Factory()"), abi.encode(address(0x1234)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("univ4Hook()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("wrappedNativeToken()"), abi.encode(address(weth)));

        vm.mockCall(MOCK_ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(weth)));
        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(MOCK_PROJECTS));
        vm.mockCall(MOCK_PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));
        vm.mockCall(
            MOCK_DIRECTORY,
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(address(terminal))
        );

        RegressionSwapBatchHarness singleton = new RegressionSwapBatchHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );

        sucker =
        // forge-lint: disable-next-line(unsafe-typecast)
        RegressionSwapBatchHarness(
            payable(LibClone.cloneDeterministic(address(singleton), keccak256(bytes("regression-swap-mix"))))
        );
        sucker.initialize(PROJECT_ID);
    }

    function test_overlappingRoots_fixedByNonceIndexedRates() external {
        // Batch 1 (nonce 1): rate 1.0 (100e18 leaf -> 100e6 local), range [0,1).
        // Batch 2 (nonce 2): rate 0.5 (100e18 leaf -> 50e6 local), range [1,2).
        sucker.test_setConversionRate(address(usdc), 1, 100e18, 100e6, 0, 1);
        sucker.test_setConversionRate(address(usdc), 2, 100e18, 50e6, 1, 2);
        usdc.mint(address(sucker), 150e6);

        // Claim from batch 1 (leaf 0) — should get 100e6 (rate 1.0), not 75e6 (blended).
        uint256 terminalBalanceBefore = usdc.balanceOf(address(terminal));
        sucker.exposed_addToBalance(address(usdc), 100e18, PROJECT_ID, 0);
        uint256 paid1 = usdc.balanceOf(address(terminal)) - terminalBalanceBefore;
        assertEq(paid1, 100e6, "batch 1 should use its own rate 1.0");

        // Claim from batch 2 (leaf 1) — should get 50e6 (rate 0.5), not 75e6.
        terminalBalanceBefore = usdc.balanceOf(address(terminal));
        sucker.exposed_addToBalance(address(usdc), 100e18, PROJECT_ID, 1);
        uint256 paid2 = usdc.balanceOf(address(terminal)) - terminalBalanceBefore;
        assertEq(paid2, 50e6, "batch 2 should use its own rate 0.5");
    }
}

contract RegressionSwapNonceScanGasTest is Test {
    address internal constant MOCK_DEPLOYER = address(0xDE);
    address internal constant MOCK_DIRECTORY = address(0xD1);
    address internal constant MOCK_TOKENS = address(0xD2);
    address internal constant MOCK_PERMISSIONS = address(0xD3);
    address internal constant MOCK_ROUTER = address(0xD4);
    address internal constant MOCK_PROJECTS = address(0xD5);

    uint256 internal constant PROJECT_ID = 1;
    uint64 internal constant BATCH_COUNT = 2500;

    ERC20Mock internal usdc;
    ERC20Mock internal weth;
    RegressionMockTerminal internal terminal;
    RegressionSwapBatchHarness internal sucker;

    function setUp() external {
        usdc = new ERC20Mock("USDC", "USDC", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        terminal = new RegressionMockTerminal();

        vm.etch(MOCK_ROUTER, hex"01");

        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(uint256(4217)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(uint64(7)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(MOCK_ROUTER));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("bridgeToken()"), abi.encode(address(usdc)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("poolManager()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("v3Factory()"), abi.encode(address(0x1234)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("univ4Hook()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("wrappedNativeToken()"), abi.encode(address(weth)));

        vm.mockCall(MOCK_ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(weth)));
        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(MOCK_PROJECTS));
        vm.mockCall(MOCK_PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));
        vm.mockCall(
            MOCK_DIRECTORY,
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(address(terminal))
        );

        RegressionSwapBatchHarness singleton = new RegressionSwapBatchHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );

        sucker =
        // forge-lint: disable-next-line(unsafe-typecast)
        RegressionSwapBatchHarness(
            payable(LibClone.cloneDeterministic(address(singleton), keccak256(bytes("regression-swap-scan-gas"))))
        );
        sucker.initialize(PROJECT_ID);

        sucker.test_setConversionRate(address(usdc), 1, 1, 1, 0, 1);
        for (uint64 nonce = 2; nonce <= BATCH_COUNT; nonce++) {
            uint256 leafIndex = uint256(nonce) - 1;
            sucker.test_setConversionRate(address(usdc), nonce, 0, 0, leafIndex, leafIndex + 1);
        }
        usdc.mint(address(sucker), 1);
    }

    /// @notice Sparse high nonce values alone must not make old claims expensive.
    /// @dev The populated-nonce index is insertion ordered. The oldest leaf resolves from the first populated
    /// range even when later nonces have very large values, so this test proves lookup cost is tied to received
    /// batches, not the largest nonce. Worst-case lookup is still O(populated batch count) when the matching range is
    /// near the end of the populated list.
    function test_oldLeafClaimStaysCheapUnderSparseNonceInflation() external {
        uint256 oldestGasBefore = gasleft();
        sucker.exposed_addToBalance(address(usdc), 1, PROJECT_ID, 0);
        uint256 oldestGasUsed = oldestGasBefore - gasleft();

        // Allow generous headroom for surrounding bookkeeping while still proving sparse nonce inflation alone does
        // not force a scan over empty nonce slots.
        assertLt(
            oldestGasUsed, 1_000_000, "populated-nonce lookup keeps old-leaf claim gas bounded under sparse nonces"
        );
    }
}

contract RegressionSwapSparseEmptyMidpointTest is Test {
    address internal constant MOCK_DEPLOYER = address(0xDE);
    address internal constant MOCK_DIRECTORY = address(0xD1);
    address internal constant MOCK_TOKENS = address(0xD2);
    address internal constant MOCK_PERMISSIONS = address(0xD3);
    address internal constant MOCK_ROUTER = address(0xD4);
    address internal constant MOCK_PROJECTS = address(0xD5);

    uint256 internal constant PROJECT_ID = 1;
    uint64 internal constant SPAN = 2500;

    ERC20Mock internal usdc;
    ERC20Mock internal weth;
    RegressionMockTerminal internal terminal;
    RegressionSwapBatchHarness internal sucker;

    function setUp() external {
        usdc = new ERC20Mock("USDC", "USDC", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        terminal = new RegressionMockTerminal();

        vm.etch(MOCK_ROUTER, hex"01");

        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(uint256(4217)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(uint64(7)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(MOCK_ROUTER));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("bridgeToken()"), abi.encode(address(usdc)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("poolManager()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("v3Factory()"), abi.encode(address(0x1234)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("univ4Hook()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("wrappedNativeToken()"), abi.encode(address(weth)));

        vm.mockCall(MOCK_ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(weth)));
        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(MOCK_PROJECTS));
        vm.mockCall(MOCK_PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));
        vm.mockCall(
            MOCK_DIRECTORY,
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(address(terminal))
        );

        RegressionSwapBatchHarness singleton = new RegressionSwapBatchHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );

        sucker =
        // forge-lint: disable-next-line(unsafe-typecast)
        RegressionSwapBatchHarness(
            payable(LibClone.cloneDeterministic(address(singleton), keccak256(bytes("regression-swap-sparse-mid"))))
        );
        sucker.initialize(PROJECT_ID);

        // Populate only nonces {1, SPAN}. Lookup must walk this compact populated list instead of
        // assuming nonces arrived contiguously.
        sucker.test_setConversionRate({
            token: address(usdc), nonce: 1, leafTotal: 1, localTotal: 1, batchStart: 0, batchEnd: 1
        });
        sucker.test_setConversionRate({
            token: address(usdc), nonce: SPAN, leafTotal: 1, localTotal: 1, batchStart: SPAN - 1, batchEnd: SPAN
        });
        usdc.mint(address(sucker), 1);
    }

    /// @notice When only the boundary nonces are populated and the leaf lives in the LAST one, the
    /// pre-fix linear-window scan walked every empty slot in `[1, SPAN]` (O(N) SLOADs). The fix
    /// walks `_populatedNonceByIndex` directly, so the work is O(K) SLOADs where K = number of
    /// received batches (2 here) — well below the linear bound.
    function test_lastPopulatedLeafStaysCheapWithEmptyMidpoints() external {
        uint256 gasBefore = gasleft();
        sucker.exposed_addToBalance(address(usdc), 1, PROJECT_ID, uint256(SPAN) - 1);
        uint256 gasUsed = gasBefore - gasleft();

        // Pre-fix worst case was ~5M+ gas (2500 cold SLOADs at ~2.1k each); the populated-walk
        // fallback uses ~2 SLOADs per populated nonce, so even with surrounding bookkeeping the
        // total stays under 250k. The strict bound surfaces regressions if the fallback gets
        // re-broadened.
        assertLt(gasUsed, 250_000, "populated-nonce fallback keeps last-leaf claim O(K) under sparse pattern");
    }
}
