// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

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

contract CodexNemesisMockTerminal {
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

contract CodexNemesisSwapHarness is JBSwapCCIPSucker {
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

    function test_addToBalance(address token, uint256 amount, uint256 projectId, uint256 leafIndex) external {
        _currentClaimLeafIndex = leafIndex + 1;
        _addToBalance(token, amount, projectId);
    }
}

contract CodexNemesisSwapQueueOrderTest is Test {
    address constant MOCK_DEPLOYER = address(0xDE);
    address constant MOCK_DIRECTORY = address(0xD1);
    address constant MOCK_TOKENS = address(0xD2);
    address constant MOCK_PERMISSIONS = address(0xD3);
    address constant MOCK_ROUTER = address(0xD4);
    address constant MOCK_PROJECTS = address(0xD5);

    uint256 constant PROJECT_ID = 1;
    uint256 constant REMOTE_CHAIN_ID = 4217;
    uint64 constant REMOTE_CHAIN_SELECTOR = 7_281_642_695_469_137_430;

    ERC20Mock usdc;
    ERC20Mock weth;
    CodexNemesisMockTerminal terminal;
    CodexNemesisSwapHarness sucker;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        terminal = new CodexNemesisMockTerminal();

        vm.etch(MOCK_ROUTER, hex"01");

        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(REMOTE_CHAIN_ID));
        vm.mockCall(
            MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(REMOTE_CHAIN_SELECTOR)
        );
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

        CodexNemesisSwapHarness singleton = new CodexNemesisSwapHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
        sucker = CodexNemesisSwapHarness(payable(LibClone.cloneDeterministic(address(singleton), bytes32("nemesis"))));
        sucker.initialize(PROJECT_ID);
    }

    /// @notice FIX VERIFIED: out-of-order claims now get correct rates.
    /// Previously, a batch 2 claimant claiming first would drain batch 1's favorable rate.
    /// With nonce-indexed rates, each claim looks up its correct batch by leaf index.
    function test_outOfOrderClaims_getCorrectRates() public {
        // Batch 1 (nonce 1): favorable rate 1.0 (100 leaf -> 100 local), range [0,1).
        sucker.test_setConversionRate(address(usdc), 1, 100, 100, 0, 1);
        // Batch 2 (nonce 2): unfavorable rate 0.5 (100 leaf -> 50 local), range [1,2).
        sucker.test_setConversionRate(address(usdc), 2, 100, 50, 1, 2);
        usdc.mint(address(sucker), 150);

        // Batch 2 claimant claims FIRST (leaf index 1) — gets rate 0.5, NOT 1.0.
        uint256 beforeFirst = usdc.balanceOf(address(sucker));
        sucker.test_addToBalance(address(usdc), 100, PROJECT_ID, 1);
        uint256 firstClaimed = beforeFirst - usdc.balanceOf(address(sucker));
        assertEq(firstClaimed, 50, "batch 2 claim should use rate 0.5 even when claimed first");

        // Batch 1 claimant claims SECOND (leaf index 0) — gets rate 1.0, NOT 0.5.
        uint256 beforeSecond = usdc.balanceOf(address(sucker));
        sucker.test_addToBalance(address(usdc), 100, PROJECT_ID, 0);
        uint256 secondClaimed = beforeSecond - usdc.balanceOf(address(sucker));
        assertEq(secondClaimed, 100, "batch 1 claim should use rate 1.0 even when claimed second");
    }

    /// @notice FIX VERIFIED: out-of-order root arrival doesn't affect rate application.
    /// With nonce-indexed rates, the order roots arrive in doesn't matter — each is keyed by nonce.
    function test_outOfOrderRootArrival_correctRates() public {
        // Root 2 arrives BEFORE root 1. With per-nonce ranges, this is fine.
        // Nonce 2: rate 0.5, range [1,2).
        sucker.test_setConversionRate(address(usdc), 2, 100, 50, 1, 2);
        // Nonce 1 arrives late: rate 1.0, range [0,1).
        sucker.test_setConversionRate(address(usdc), 1, 100, 100, 0, 1);
        usdc.mint(address(sucker), 150);

        // Claim leaf 0 (batch 1) — should get rate 1.0.
        uint256 beforeFirst = usdc.balanceOf(address(sucker));
        sucker.test_addToBalance(address(usdc), 100, PROJECT_ID, 0);
        uint256 firstClaimed = beforeFirst - usdc.balanceOf(address(sucker));
        assertEq(firstClaimed, 100, "leaf 0 should use nonce 1's rate 1.0");

        // Claim leaf 1 (batch 2) — should get rate 0.5.
        uint256 beforeSecond = usdc.balanceOf(address(sucker));
        sucker.test_addToBalance(address(usdc), 100, PROJECT_ID, 1);
        uint256 secondClaimed = beforeSecond - usdc.balanceOf(address(sucker));
        assertEq(secondClaimed, 50, "leaf 1 should use nonce 2's rate 0.5");
    }

    /// @notice FIX VERIFIED: missing nonce only blocks claims for leaves NOT in any received range.
    /// With per-nonce [start, end) ranges, each nonce is self-describing. Leaves in a received
    /// nonce's range can be claimed even if earlier nonces haven't arrived yet.
    function test_missingNonce_onlyBlocksUnreceivedRange() public {
        // Only nonce 2 received (nonce 1 missing). Nonce 2 covers range [1, 2).
        sucker.test_setConversionRate(address(usdc), 2, 100, 50, 1, 2);
        usdc.mint(address(sucker), 50);

        // Leaf 0 is NOT in any received range — reverts.
        vm.expectRevert(abi.encodeWithSelector(JBSwapCCIPSucker.JBSwapCCIPSucker_BatchNotReceived.selector, uint64(0)));
        sucker.test_addToBalance(address(usdc), 100, PROJECT_ID, 0);

        // Leaf 1 IS in nonce 2's range [1, 2) — succeeds with nonce 2's rate.
        uint256 balBefore = usdc.balanceOf(address(sucker));
        sucker.test_addToBalance(address(usdc), 100, PROJECT_ID, 1);
        uint256 claimed = balBefore - usdc.balanceOf(address(sucker));
        assertEq(claimed, 50, "leaf 1 should use nonce 2's rate 0.5");
    }
}
