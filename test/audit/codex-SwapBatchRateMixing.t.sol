// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSwapCCIPSucker} from "../../src/JBSwapCCIPSucker.sol";
import {JBSwapCCIPSuckerDeployer} from "../../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract CodexMockTerminal {
    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

contract CodexSwapBatchHarness is JBSwapCCIPSucker {
    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBSwapCCIPSucker(deployer, directory, tokens, permissions, 1, IJBSuckerRegistry(address(1)), address(0))
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
        _conversionRateOf[token][nonce] = ConversionRate({leafTotal: leafTotal, localTotal: localTotal});
        _batchStartOf[token][nonce] = batchStart;
        _batchEndOf[token][nonce] = batchEnd;
        if (nonce > _highestReceivedNonce[token]) {
            _highestReceivedNonce[token] = nonce;
        }
    }

    function exposed_addToBalance(address token, uint256 amount, uint256 projectId, uint256 leafIndex) external {
        _currentClaimLeafIndex = leafIndex + 1;
        _addToBalance(token, amount, projectId);
    }
}

contract CodexSwapBatchRateMixingTest is Test {
    address internal constant MOCK_DEPLOYER = address(0xDE);
    address internal constant MOCK_DIRECTORY = address(0xD1);
    address internal constant MOCK_TOKENS = address(0xD2);
    address internal constant MOCK_PERMISSIONS = address(0xD3);
    address internal constant MOCK_ROUTER = address(0xD4);
    address internal constant MOCK_PROJECTS = address(0xD5);

    uint256 internal constant PROJECT_ID = 1;

    ERC20Mock internal usdc;
    ERC20Mock internal weth;
    CodexMockTerminal internal terminal;
    CodexSwapBatchHarness internal sucker;

    function setUp() external {
        usdc = new ERC20Mock("USDC", "USDC", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        terminal = new CodexMockTerminal();

        vm.etch(MOCK_ROUTER, hex"01");

        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(uint256(4217)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(uint64(7)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(MOCK_ROUTER));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("bridgeToken()"), abi.encode(address(usdc)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("poolManager()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("v3Factory()"), abi.encode(address(0x1234)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("univ4Hook()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("weth()"), abi.encode(address(weth)));

        vm.mockCall(MOCK_ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(weth)));
        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(MOCK_PROJECTS));
        vm.mockCall(MOCK_PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));
        vm.mockCall(
            MOCK_DIRECTORY,
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(address(terminal))
        );

        CodexSwapBatchHarness singleton = new CodexSwapBatchHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );

        sucker =
            CodexSwapBatchHarness(payable(LibClone.cloneDeterministic(address(singleton), bytes32("codex-swap-mix"))));
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
