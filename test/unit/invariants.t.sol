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
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../../src/JBSucker.sol";

import {JBClaim} from "../../src/structs/JBClaim.sol";
import {JBLeaf} from "../../src/structs/JBLeaf.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBOutboxTree} from "../../src/structs/JBOutboxTree.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @notice Test sucker with exposed helpers for invariant testing.
contract InvariantSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    bool nextCheckShouldPass;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
    {}

    function _sendRootOverAMB(
        uint256,
        uint256,
        address token,
        uint256 amount,
        JBRemoteToken memory,
        JBMessageRoot memory
    )
        internal
        override
    {
        // Simulate the bridge actually consuming the ETH (native token only).
        if (token == JBConstants.NATIVE_TOKEN && amount > 0) {
            (bool success,) = payable(address(0xdead)).call{value: amount}("");
            require(success, "bridge sim: ETH transfer failed");
        }
    }

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

    function test_getNumberOfClaimsSent(address token) external view returns (uint256) {
        return _outboxOf[token].numberOfClaimsSent;
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

    function test_getDeprecatedAfter() external view returns (uint256) {
        return deprecatedAfter;
    }

    function test_isExecuted(address token, uint256 index) external view returns (bool) {
        return _executedFor[token].get(index);
    }

    function test_isEmergencyExecuted(address terminalToken, uint256 index) external view returns (bool) {
        address emergencyExitAddress = address(bytes20(keccak256(abi.encode(terminalToken))));
        return _executedFor[emergencyExitAddress].get(index);
    }
}

/// @title SuckerHandler
/// @notice Handler contract for Foundry invariant testing. Performs bounded actions on the sucker.
contract SuckerHandler is Test {
    InvariantSucker public sucker;
    address constant TOKEN = address(0x000000000000000000000000000000000000EEEe);
    address constant CONTROLLER = address(900);
    uint256 constant PROJECT_ID = 1;

    // Ghost variables for invariant tracking.
    uint256 public totalInserted;
    uint256 public totalEmergencyExited;
    uint256 public outboxBalanceCleared;
    uint64 public lastNonce;
    uint256 public lastTreeCount;

    // Track claimed and emergency-exited indices.
    uint256[] public claimedIndices;
    uint256[] public emergencyExitedIndices;

    // Track leaf data for claims and emergency exits.
    struct LeafData {
        uint256 projectTokenCount;
        uint256 terminalTokenAmount;
        bytes32 beneficiary;
    }

    LeafData[] public leaves;

    constructor(InvariantSucker _sucker) {
        sucker = _sucker;
    }

    function insertIntoTree(uint256 amount, uint256 tokens, address beneficiary) external {
        // Bound to avoid uint128 overflow in sucker.
        amount = bound(amount, 1, 100 ether);
        tokens = bound(tokens, 1, 100 ether);
        if (beneficiary == address(0)) beneficiary = address(0xBEEF);

        // Send ETH to the sucker to cover the outbox balance increase.
        (bool ok,) = payable(address(sucker)).call{value: amount}("");
        require(ok, "ETH transfer to sucker failed");

        sucker.test_insertIntoTree(tokens, TOKEN, amount, bytes32(uint256(uint160(beneficiary))));

        totalInserted += amount;
        leaves.push(
            LeafData({
                projectTokenCount: tokens,
                terminalTokenAmount: amount,
                beneficiary: bytes32(uint256(uint160(beneficiary)))
            })
        );
    }

    /// @notice Send root via toRemote. Skips if outbox is empty.
    function sendRoot() external {
        uint256 outboxBalance = sucker.test_getOutboxBalance(TOKEN);
        if (outboxBalance == 0) return;

        // toRemote clears the outbox balance and _sendRootOverAMB sends the ETH to 0xdead.
        sucker.toRemote(TOKEN);

        outboxBalanceCleared += outboxBalance;
        lastNonce = sucker.test_getOutboxNonce(TOKEN);
        lastTreeCount = sucker.test_getOutboxCount(TOKEN);
    }

    /// @notice Claim a leaf. Bypasses merkle validation. Skips if already claimed or no leaves.
    function claimLeaf(uint256 indexSeed) external {
        uint256 count = leaves.length;
        if (count == 0) return;

        uint256 index = indexSeed % count;

        // Skip if already claimed.
        if (sucker.test_isExecuted(TOKEN, index)) return;

        // Set inbox root so claim can proceed.
        bytes32 root = sucker.test_getOutboxRoot(TOKEN);
        uint64 currentNonce = sucker.test_getOutboxNonce(TOKEN);
        sucker.test_setInboxRoot(TOKEN, currentNonce > 0 ? currentNonce : 1, root);

        LeafData memory leaf = leaves[index];
        _mockMint(address(uint160(uint256(leaf.beneficiary))), leaf.projectTokenCount);

        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: index,
                beneficiary: leaf.beneficiary,
                projectTokenCount: leaf.projectTokenCount,
                terminalTokenAmount: leaf.terminalTokenAmount
            }),
            proof: proof
        });

        sucker.claim(claimData);
        claimedIndices.push(index);
    }

    /// @notice Emergency exit a leaf. Skips if leaf is already sent (covered by numberOfClaimsSent).
    function emergencyExit(uint256 indexSeed) external {
        uint256 count = leaves.length;
        if (count == 0) return;

        uint256 index = indexSeed % count;

        // Skip if this index was already sent via toRemote.
        uint256 claimsSent = sucker.test_getNumberOfClaimsSent(TOKEN);
        if (index < claimsSent) return;

        // Skip if already emergency-exited.
        if (sucker.test_isEmergencyExecuted(TOKEN, index)) return;

        // Ensure sucker is deprecated for emergency exit.
        if (sucker.test_getDeprecatedAfter() == 0 || block.timestamp < sucker.test_getDeprecatedAfter()) {
            sucker.test_setDeprecatedAfter(block.timestamp);
        }

        LeafData memory leaf = leaves[index];
        _mockMint(address(uint160(uint256(leaf.beneficiary))), leaf.projectTokenCount);

        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: index,
                beneficiary: leaf.beneficiary,
                projectTokenCount: leaf.projectTokenCount,
                terminalTokenAmount: leaf.terminalTokenAmount
            }),
            proof: proof
        });

        sucker.exitThroughEmergencyHatch(claimData);

        totalEmergencyExited += leaf.terminalTokenAmount;
        emergencyExitedIndices.push(index);
    }

    /// @notice Send ETH directly to the sucker (inflates balance).
    function directTransfer(uint256 amount) external {
        amount = bound(amount, 0, 10 ether);
        if (amount > 0) {
            (bool ok,) = payable(address(sucker)).call{value: amount}("");
            require(ok, "ETH transfer to sucker failed");
        }
    }

    function _mockMint(address beneficiary, uint256 amount) internal {
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, amount, beneficiary, "", false)),
            abi.encode(amount)
        );
    }

    function getClaimedIndicesLength() external view returns (uint256) {
        return claimedIndices.length;
    }

    function getEmergencyExitedIndicesLength() external view returns (uint256) {
        return emergencyExitedIndices.length;
    }

    function getLeavesLength() external view returns (uint256) {
        return leaves.length;
    }
}

/// @title SuckerInvariantsTest
/// @notice Foundry invariant tests for JBSucker. Uses handler contract for bounded actions.
contract SuckerInvariantsTest is Test {
    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);
    address constant TERMINAL = address(1200);

    uint256 constant PROJECT_ID = 1;
    address constant TOKEN = address(0x000000000000000000000000000000000000EEEe);

    InvariantSucker sucker;
    SuckerHandler handler;

    function setUp() public {
        vm.warp(100 days);

        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");
        vm.label(TOKENS, "MOCK_TOKENS");
        vm.label(CONTROLLER, "MOCK_CONTROLLER");
        vm.label(PROJECT, "MOCK_PROJECT");
        vm.label(TERMINAL, "MOCK_TERMINAL");

        InvariantSucker singleton =
            new InvariantSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER);
        sucker = InvariantSucker(payable(address(LibClone.cloneDeterministic(address(singleton), "invariant_salt"))));
        sucker.initialize(PROJECT_ID);

        // Set up token mapping.
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );

        // Common mocks.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, TOKEN)), abi.encode(TERMINAL)
        );
        // Mock terminal.pay so the toRemote fee payment try-catch doesn't revert on ABI decode of empty return data.
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(0)));

        // Create handler and target it for invariant testing.
        handler = new SuckerHandler(sucker);
        vm.deal(address(handler), 100_000 ether);

        targetContract(address(handler));
    }

    // =========================================================================
    // Invariant: outbox.balance <= address(sucker).balance
    // =========================================================================

    function invariant_outboxBalanceLteContractBalance() public view {
        uint256 outboxBalance = sucker.test_getOutboxBalance(TOKEN);
        uint256 contractBalance = address(sucker).balance;
        assertLe(outboxBalance, contractBalance, "outbox.balance must be <= contract balance");
    }

    // =========================================================================
    // Invariant: numberOfClaimsSent <= tree.count
    // =========================================================================

    function invariant_numberOfClaimsSentLteTreeCount() public view {
        uint256 claimsSent = sucker.test_getNumberOfClaimsSent(TOKEN);
        uint256 treeCount = sucker.test_getOutboxCount(TOKEN);
        assertLe(claimsSent, treeCount, "numberOfClaimsSent must be <= tree.count");
    }

    // =========================================================================
    // Invariant: All claimed indices are marked executed in bitmap
    // =========================================================================

    function invariant_eachLeafClaimedOnce() public view {
        uint256 len = handler.getClaimedIndicesLength();
        for (uint256 i; i < len; i++) {
            uint256 idx = handler.claimedIndices(i);
            assertTrue(sucker.test_isExecuted(TOKEN, idx), "Claimed index should be marked executed");
        }
    }

    // =========================================================================
    // Invariant: Emergency-exited indices >= numberOfClaimsSent
    // =========================================================================

    function invariant_emergencyExitOnlyForUnsentLeaves() public view {
        uint256 claimsSent = sucker.test_getNumberOfClaimsSent(TOKEN);
        uint256 len = handler.getEmergencyExitedIndicesLength();
        for (uint256 i; i < len; i++) {
            uint256 idx = handler.emergencyExitedIndices(i);
            assertGe(idx, claimsSent, "Emergency exit should only work for unsent leaves");
        }
    }

    // =========================================================================
    // Invariant: amountToAddToBalance never underflows
    // (address(sucker).balance >= outbox.balance)
    // =========================================================================

    function invariant_amountToAddNeverUnderflows() public view {
        uint256 contractBalance = address(sucker).balance;
        uint256 outboxBalance = sucker.test_getOutboxBalance(TOKEN);
        assertGe(contractBalance, outboxBalance, "Contract balance must be >= outbox balance");
    }

    // =========================================================================
    // Invariant: Nonce monotonically increases
    // =========================================================================

    function invariant_nonceMonotonicallyIncreases() public view {
        uint64 currentNonce = sucker.test_getOutboxNonce(TOKEN);
        assertGe(currentNonce, handler.lastNonce(), "Nonce must monotonically increase");
    }

    // =========================================================================
    // Invariant: Tree count monotonically increases
    // =========================================================================

    function invariant_treeCountMonotonicallyIncreases() public view {
        uint256 currentCount = sucker.test_getOutboxCount(TOKEN);
        assertGe(currentCount, handler.lastTreeCount(), "Tree count must monotonically increase");
    }

    // =========================================================================
    // Invariant: outbox.balance == totalInserted - totalEmergencyExited - outboxBalanceCleared
    // =========================================================================

    function invariant_outboxBalanceAccountedCorrectly() public view {
        uint256 outboxBalance = sucker.test_getOutboxBalance(TOKEN);
        uint256 expected = handler.totalInserted() - handler.totalEmergencyExited() - handler.outboxBalanceCleared();
        assertEq(
            outboxBalance,
            expected,
            "outbox.balance must equal totalInserted - totalEmergencyExited - outboxBalanceCleared"
        );
    }
}
