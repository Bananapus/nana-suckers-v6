// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v5/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v5/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v5/src/interfaces/IJBTokens.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v5/src/interfaces/IJBCashOutTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v5/src/interfaces/IJBTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v5/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../../src/JBSucker.sol";
import "../../src/extensions/JBAllowanceSucker.sol";
import {IJBSuckerDeployer} from "../../src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerDeployerFeeless} from "../../src/interfaces/IJBSuckerDeployerFeeless.sol";

/// @notice Concrete test implementation of JBAllowanceSucker.
contract TestAllowanceSucker is JBAllowanceSucker {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        JBAddToBalanceMode addToBalanceMode,
        address forwarder
    ) JBSucker(directory, permissions, tokens, addToBalanceMode, forwarder) {}

    function _sendRootOverAMB(uint256, uint256, address, uint256, JBRemoteToken memory, JBMessageRoot memory)
        internal
        override
    {}

    function _isRemotePeer(address) internal pure override returns (bool) {
        return true;
    }

    function peerChainId() external pure override returns (uint256) {
        return 1;
    }

    /// @notice Expose _pullBackingAssets for direct testing.
    function exposed_pullBackingAssets(
        IERC20 projectToken,
        uint256 count,
        address token,
        uint256 minTokensReclaimed
    ) external returns (uint256) {
        return _pullBackingAssets(projectToken, count, token, minTokensReclaimed);
    }
}

/// @notice Tests for M-15: defense-in-depth isSucker check in JBAllowanceSucker.
contract AllowanceSuckerTest is Test {
    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant TERMINAL = address(1200);
    address constant PROJECT_TOKEN = address(1300);
    address constant DEPLOYER = address(1400);

    uint256 constant PROJECT_ID = 1;
    address constant TOKEN = address(0xEeeE);

    TestAllowanceSucker sucker;

    function setUp() public {
        // Deploy singleton and clone.
        TestAllowanceSucker singleton = new TestAllowanceSucker(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), JBAddToBalanceMode.MANUAL, address(0)
        );

        // Clone, initializing as DEPLOYER so deployer = DEPLOYER.
        sucker = TestAllowanceSucker(payable(LibClone.cloneDeterministic(address(singleton), "m15_test")));
        vm.prank(DEPLOYER);
        sucker.initialize(PROJECT_ID);

        // Mock directory.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, TOKEN)), abi.encode(TERMINAL));

        // Mock project token total supply.
        vm.mockCall(PROJECT_TOKEN, abi.encodeCall(IERC20.totalSupply, ()), abi.encode(1000 ether));

        // Mock controller burn.
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.burnTokensOf, (address(sucker), PROJECT_ID, 100 ether, "")),
            abi.encode(100 ether)
        );

        // Mock terminal accounting context.
        JBAccountingContext memory ctx = JBAccountingContext({token: TOKEN, decimals: 18, currency: 1});
        JBAccountingContext[] memory ctxArr = new JBAccountingContext[](1);
        ctxArr[0] = ctx;
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(IJBTerminal.accountingContextForTokenOf, (PROJECT_ID, TOKEN)),
            abi.encode(ctx)
        );

        // Mock surplus.
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.currentSurplusOf.selector), abi.encode(500 ether));
    }

    /// @notice When deployer.isSucker returns false, _pullBackingAssets should revert.
    function test_pullBackingAssets_notRegistered_reverts() public {
        // Mock deployer.isSucker to return false.
        vm.mockCall(DEPLOYER, abi.encodeCall(IJBSuckerDeployer.isSucker, (address(sucker))), abi.encode(false));

        vm.expectRevert(JBAllowanceSucker.JBAllowanceSucker_NotRegisteredSucker.selector);
        sucker.exposed_pullBackingAssets(IERC20(PROJECT_TOKEN), 100 ether, TOKEN, 0);
    }

    /// @notice When deployer.isSucker returns true, _pullBackingAssets should NOT revert at the check.
    /// We verify this by checking that the call proceeds past isSucker and reaches useAllowanceFeeless.
    function test_pullBackingAssets_registered_passesCheck() public {
        // Mock deployer.isSucker to return true.
        vm.mockCall(DEPLOYER, abi.encodeCall(IJBSuckerDeployer.isSucker, (address(sucker))), abi.encode(true));

        // Mock useAllowanceFeeless to return 50 ether.
        vm.mockCall(
            DEPLOYER, abi.encodeWithSelector(IJBSuckerDeployerFeeless.useAllowanceFeeless.selector), abi.encode(50 ether)
        );

        // The function will revert at the final balance assertion (since we can't easily mock
        // sequential balance calls), but the important thing is it does NOT revert with
        // JBAllowanceSucker_NotRegisteredSucker — proving it passed the isSucker check.
        // We verify this by checking that it calls useAllowanceFeeless (past the guard).
        vm.expectCall(
            DEPLOYER, abi.encodeWithSelector(IJBSuckerDeployerFeeless.useAllowanceFeeless.selector)
        );

        // Allow the final assert to fail — we only care that it got past isSucker.
        try sucker.exposed_pullBackingAssets(IERC20(PROJECT_TOKEN), 100 ether, TOKEN, 0) {} catch {}
    }
}
