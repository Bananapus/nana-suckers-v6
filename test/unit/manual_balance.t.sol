// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../../src/JBSucker.sol";
import {JBAddToBalanceMode} from "../../src/enums/JBAddToBalanceMode.sol";
import {JBClaim} from "../../src/structs/JBClaim.sol";
import {JBLeaf} from "../../src/structs/JBLeaf.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBOutboxTree} from "../../src/structs/JBOutboxTree.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @notice Test sucker with exposed helpers for manual balance testing.
contract ManualBalanceSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;

    bool nextCheckShouldPass;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        JBAddToBalanceMode addToBalanceMode,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, addToBalanceMode, forwarder)
    {}

    function _sendRootOverAMB(
        uint256,
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBMessageRoot memory
    )
        internal
        override
    {}

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == _toAddress(peer());
    }

    function peerChainId() external view virtual override returns (uint256) {
        return block.chainid;
    }

    function _validateBranchRoot(
        bytes32 expectedRoot,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        uint256 index,
        bytes32[_TREE_DEPTH] calldata leaves
    )
        internal
        virtual
        override
    {
        if (!nextCheckShouldPass) {
            super._validateBranchRoot(expectedRoot, projectTokenCount, terminalTokenAmount, beneficiary, index, leaves);
        }
        nextCheckShouldPass = false;
    }

    function test_setNextMerkleCheckToBe(bool _pass) external {
        nextCheckShouldPass = _pass;
    }

    function test_setOutboxBalance(address token, uint256 amount) external {
        _outboxOf[token].balance = amount;
    }

    function test_insertIntoTree(
        uint256 projectTokenCount,
        address token,
        uint256 terminalTokenAmount,
        bytes32 beneficiary
    )
        external
    {
        _insertIntoTree(projectTokenCount, token, terminalTokenAmount, beneficiary);
    }

    function test_getOutboxBalance(address token) external view returns (uint256) {
        return _outboxOf[token].balance;
    }

    function test_getOutboxCount(address token) external view returns (uint256) {
        return _outboxOf[token].tree.count;
    }

    function test_getOutboxNonce(address token) external view returns (uint64) {
        return _outboxOf[token].nonce;
    }

    function test_getOutboxRoot(address token) external view returns (bytes32) {
        return _outboxOf[token].tree.root();
    }

    function test_setInboxRoot(address token, uint64 nonce, bytes32 root) external {
        _inboxOf[token] = JBInboxTreeRoot({nonce: nonce, root: root});
    }

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

    function test_setNumberOfClaimsSent(address token, uint256 count) external {
        _outboxOf[token].numberOfClaimsSent = count;
    }

    function test_setDeprecatedAfter(uint256 timestamp) external {
        deprecatedAfter = timestamp;
    }
}

/// @title ManualBalanceTest
/// @notice Tests `addOutstandingAmountToBalance()` / `amountToAddToBalanceOf()` lifecycle for MANUAL mode suckers.
contract ManualBalanceTest is Test {
    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);
    address constant TERMINAL = address(1200);

    uint256 constant PROJECT_ID = 1;
    address constant TOKEN = address(0x000000000000000000000000000000000000EEEe); // NATIVE_TOKEN
    address constant ERC20_TOKEN = address(0x1234567890AbcdEF1234567890aBcdef12345678);

    ManualBalanceSucker manualSucker;
    ManualBalanceSucker onClaimSucker;

    function setUp() public {
        vm.warp(100 days);

        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");
        vm.label(TOKENS, "MOCK_TOKENS");
        vm.label(CONTROLLER, "MOCK_CONTROLLER");
        vm.label(PROJECT, "MOCK_PROJECT");
        vm.label(TERMINAL, "MOCK_TERMINAL");

        manualSucker = _createSucker(JBAddToBalanceMode.MANUAL, "manual_salt");
        onClaimSucker = _createSucker(JBAddToBalanceMode.ON_CLAIM, "onclaim_salt");

        // Common mocks.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, TOKEN)), abi.encode(TERMINAL)
        );
    }

    function _createSucker(JBAddToBalanceMode mode, bytes32 salt) internal returns (ManualBalanceSucker) {
        ManualBalanceSucker singleton = new ManualBalanceSucker(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), mode, FORWARDER
        );

        ManualBalanceSucker clone =
            ManualBalanceSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        clone.initialize(PROJECT_ID);
        return clone;
    }

    function _enableTokenMapping(ManualBalanceSucker sucker, address token) internal {
        sucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken")))),
                minBridgeAmount: 0
            })
        );
    }

    function _mockMint(address beneficiary, uint256 amount) internal {
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, amount, beneficiary, "", false)),
            abi.encode(amount)
        );
    }

    function _mockTerminalAddToBalance(uint256 amount) internal {
        vm.mockCall(
            TERMINAL,
            amount,
            abi.encodeCall(IJBTerminal.addToBalanceOf, (PROJECT_ID, TOKEN, amount, false, "", "")),
            abi.encode()
        );
    }

    // =========================================================================
    // Test: Full balance added when no outbox pending
    // =========================================================================

    function test_addOutstandingAmount_addsFullBalance() public {
        vm.deal(address(manualSucker), 10 ether);

        _mockTerminalAddToBalance(10 ether);

        uint256 addable = manualSucker.amountToAddToBalanceOf(TOKEN);
        assertEq(addable, 10 ether, "Full balance should be addable");

        // Call should succeed without revert.
        manualSucker.addOutstandingAmountToBalance(TOKEN);
        // Note: mock terminal doesn't actually receive ETH, so we verify the call succeeded
        // (it would revert with JBSucker_InsufficientBalance if amount > addable).
    }

    // =========================================================================
    // Test: Pending outbox reduces addable amount
    // =========================================================================

    function test_addOutstandingAmount_withPendingOutbox() public {
        vm.deal(address(manualSucker), 20 ether);
        manualSucker.test_setOutboxBalance(TOKEN, 15 ether);

        uint256 addable = manualSucker.amountToAddToBalanceOf(TOKEN);
        assertEq(addable, 5 ether, "Only 5 ETH should be addable (20 - 15)");

        _mockTerminalAddToBalance(5 ether);

        // Call should succeed — only 5 ether is addable.
        manualSucker.addOutstandingAmountToBalance(TOKEN);
        // outbox.balance remains unchanged at 15 ether.
        assertEq(manualSucker.test_getOutboxBalance(TOKEN), 15 ether, "Outbox balance should be unchanged");
    }

    // =========================================================================
    // Test: After toRemote clears outbox.balance, full balance becomes addable
    // =========================================================================

    function test_addOutstandingAmount_afterToRemoteClearsBalance() public {
        vm.deal(address(manualSucker), 10 ether);
        _enableTokenMapping(manualSucker, TOKEN);

        // Insert a leaf (increases outbox.balance by 5 ETH).
        manualSucker.test_insertIntoTree(1 ether, TOKEN, 5 ether, bytes32(uint256(uint160(address(this)))));
        assertEq(manualSucker.test_getOutboxBalance(TOKEN), 5 ether);
        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 5 ether, "5 ETH addable before toRemote");

        // toRemote zeros outbox.balance.
        manualSucker.toRemote(TOKEN);
        assertEq(manualSucker.test_getOutboxBalance(TOKEN), 0, "outbox.balance should be 0 after toRemote");

        // Now full balance is addable (toRemote doesn't actually bridge in test since _sendRootOverAMB is no-op).
        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 10 ether, "Full balance addable after toRemote");
    }

    // =========================================================================
    // Test: Claims in MANUAL mode don't auto-add; ETH stays until manual flush
    // =========================================================================

    function test_addOutstandingAmount_afterClaimsInManualMode() public {
        vm.deal(address(manualSucker), 10 ether);

        // Set up an inbox root so we can claim.
        address beneficiary = address(0xAAA);
        manualSucker.test_setOutboxBalance(TOKEN, 5 ether);

        // Set inbox with matching data.
        manualSucker.test_insertIntoTree(1 ether, TOKEN, 5 ether, bytes32(uint256(uint160(beneficiary))));
        bytes32 root = manualSucker.test_getOutboxRoot(TOKEN);
        manualSucker.test_setInboxRoot(TOKEN, 1, root);

        _mockMint(beneficiary, 1 ether);

        // Claim (bypass merkle).
        manualSucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(beneficiary))),
                projectTokenCount: 1 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });
        manualSucker.claim(claimData);

        // In MANUAL mode, _handleClaim does NOT call _addToBalance.
        // Sucker balance should still be 10 ETH (no ETH was sent to terminal).
        assertEq(address(manualSucker).balance, 10 ether, "ETH should stay in sucker in MANUAL mode");
        // But outbox balance was not changed by claim (claim uses inbox, not outbox).
        // The 5 ether addable amount is now: balance(10) - outbox.balance(10, since insertIntoTree added 5 to existing
        // 5).
        uint256 addable = manualSucker.amountToAddToBalanceOf(TOKEN);
        assertEq(addable, 0, "Outbox consumed all balance");
    }

    // =========================================================================
    // Test: Each _insertIntoTree increases outbox.balance, reducing addable
    // =========================================================================

    function test_addOutstandingAmount_interactionWithOutboxPrepare() public {
        vm.deal(address(manualSucker), 20 ether);

        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 20 ether, "Initially all addable");

        manualSucker.test_insertIntoTree(1 ether, TOKEN, 3 ether, bytes32(uint256(uint160(address(this)))));
        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 17 ether, "17 after first insert");

        manualSucker.test_insertIntoTree(1 ether, TOKEN, 7 ether, bytes32(uint256(uint160(address(this)))));
        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 10 ether, "10 after second insert");

        manualSucker.test_insertIntoTree(1 ether, TOKEN, 10 ether, bytes32(uint256(uint160(address(this)))));
        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 0, "0 after third insert consumes all");
    }

    // =========================================================================
    // Test: Emergency exit decrements outbox.balance, increasing addable amount
    // =========================================================================

    function test_addOutstandingAmount_interactionWithEmergencyExit() public {
        vm.deal(address(manualSucker), 10 ether);

        // Insert leaf and deprecate so emergency exit works.
        address beneficiary = address(0xBBB);
        manualSucker.test_insertIntoTree(1 ether, TOKEN, 5 ether, bytes32(uint256(uint160(beneficiary))));
        assertEq(manualSucker.test_getOutboxBalance(TOKEN), 5 ether);
        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 5 ether);

        // Deprecate the sucker.
        uint256 deprecateAt = block.timestamp + 14 days;
        manualSucker.setDeprecation(uint40(deprecateAt));
        vm.warp(deprecateAt);

        _mockMint(beneficiary, 1 ether);

        // Emergency exit — this decrements outbox.balance by terminalTokenAmount.
        manualSucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(beneficiary))),
                projectTokenCount: 1 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });
        manualSucker.exitThroughEmergencyHatch(claimData);

        // outbox.balance should be decremented by 5 ETH.
        assertEq(manualSucker.test_getOutboxBalance(TOKEN), 0, "outbox.balance should be 0 after emergency exit");
        // In MANUAL mode, _handleClaim doesn't send ETH to terminal, so sucker still has 10 ETH.
        // Wait — _handleClaim in MANUAL mode does NOT call _addToBalance, but emergency exit does call _handleClaim.
        // So balance stays at 10 ETH and addable is now 10 ETH.
        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 10 ether, "Full balance addable after emergency exit");
    }

    // =========================================================================
    // Test: ON_CLAIM sucker reverts with JBSucker_ManualNotAllowed
    // =========================================================================

    function test_addOutstandingAmount_ON_CLAIM_reverts() public {
        vm.deal(address(onClaimSucker), 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_ManualNotAllowed.selector, JBAddToBalanceMode.ON_CLAIM)
        );
        onClaimSucker.addOutstandingAmountToBalance(TOKEN);
    }

    // =========================================================================
    // Test: 0 addable amount doesn't revert
    // =========================================================================

    function test_addOutstandingAmount_zeroAmount() public {
        // Sucker has 0 ETH, 0 outbox.
        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 0);

        // Mock terminal to accept 0 amount.
        _mockTerminalAddToBalance(0);

        // Should not revert (adds 0).
        manualSucker.addOutstandingAmountToBalance(TOKEN);
    }

    // =========================================================================
    // Test: Flushing ETH doesn't affect ERC20 addable amount
    // =========================================================================

    function test_addOutstandingAmount_multipleTokens_independent() public {
        vm.deal(address(manualSucker), 10 ether);

        // Set up ERC20 balance on sucker.
        vm.mockCall(ERC20_TOKEN, abi.encodeCall(IERC20.balanceOf, (address(manualSucker))), abi.encode(50 ether));

        // Insert into ETH outbox only.
        manualSucker.test_setOutboxBalance(TOKEN, 3 ether);

        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 7 ether, "ETH: 10 - 3 = 7");
        assertEq(manualSucker.amountToAddToBalanceOf(ERC20_TOKEN), 50 ether, "ERC20: 50 - 0 = 50");

        // Insert into ERC20 outbox.
        manualSucker.test_setOutboxBalance(ERC20_TOKEN, 20 ether);

        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 7 ether, "ETH unchanged");
        assertEq(manualSucker.amountToAddToBalanceOf(ERC20_TOKEN), 30 ether, "ERC20: 50 - 20 = 30");
    }

    // =========================================================================
    // Test: Direct ETH transfer inflates amountToAddToBalanceOf
    // =========================================================================

    function test_balanceInflation_directETHTransfer() public {
        manualSucker.test_setOutboxBalance(TOKEN, 5 ether);
        vm.deal(address(manualSucker), 5 ether);

        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 0, "No addable before inflation");

        // Direct ETH transfer inflates the view.
        vm.deal(address(manualSucker), 15 ether);

        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), 10 ether, "10 ETH inflated into addable");
    }

    // =========================================================================
    // Test: Direct ERC20 transfer inflates view
    // =========================================================================

    function test_balanceInflation_directERC20Transfer() public {
        manualSucker.test_setOutboxBalance(ERC20_TOKEN, 10 ether);

        // Mock initial ERC20 balance matching outbox.
        vm.mockCall(ERC20_TOKEN, abi.encodeCall(IERC20.balanceOf, (address(manualSucker))), abi.encode(10 ether));
        assertEq(manualSucker.amountToAddToBalanceOf(ERC20_TOKEN), 0, "No addable initially");

        // Simulate direct ERC20 transfer by increasing mock balance.
        vm.mockCall(ERC20_TOKEN, abi.encodeCall(IERC20.balanceOf, (address(manualSucker))), abi.encode(25 ether));
        assertEq(manualSucker.amountToAddToBalanceOf(ERC20_TOKEN), 15 ether, "15 ERC20 inflated");
    }

    // =========================================================================
    // Test: When outbox.balance > actual balance, view reverts (underflow)
    // =========================================================================

    function test_amountToAddToBalanceOf_underflows() public {
        // Set outbox balance higher than actual balance.
        manualSucker.test_setOutboxBalance(TOKEN, 10 ether);
        vm.deal(address(manualSucker), 5 ether);

        // Subtraction underflows in amountToAddToBalanceOf.
        vm.expectRevert();
        manualSucker.amountToAddToBalanceOf(TOKEN);
    }

    // =========================================================================
    // Fuzz: Random bridge/outbox amounts, assert addable amount is correct
    // =========================================================================

    function testFuzz_addOutstandingAmount_timing(uint128 balance, uint128 outboxBalance) public {
        // Ensure balance >= outboxBalance to avoid underflow.
        vm.assume(balance >= outboxBalance);

        vm.deal(address(manualSucker), uint256(balance));
        manualSucker.test_setOutboxBalance(TOKEN, uint256(outboxBalance));

        uint256 expected = uint256(balance) - uint256(outboxBalance);
        assertEq(manualSucker.amountToAddToBalanceOf(TOKEN), expected, "Addable should be balance - outbox");
    }
}
