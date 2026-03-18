// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../src/JBSucker.sol";

import {JBSuckerState} from "../src/enums/JBSuckerState.sol";
import {JBClaim} from "../src/structs/JBClaim.sol";
import {JBLeaf} from "../src/structs/JBLeaf.sol";
import {JBInboxTreeRoot} from "../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";
import {JBOutboxTree} from "../src/structs/JBOutboxTree.sol";
import {JBRemoteToken} from "../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../src/structs/JBTokenMapping.sol";
import {MerkleLib} from "../src/utils/MerkleLib.sol";

/// @notice A test sucker that exposes internals for audit gap testing.
contract AuditGapSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    bool nextCheckShouldPass;
    bool public sendRootOverAMBCalled;
    uint256 public lastAMBAmount;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, forwarder)
    {}

    function _sendRootOverAMB(
        uint256,
        uint256,
        address,
        uint256 amount,
        JBRemoteToken memory,
        JBMessageRoot memory
    )
        internal
        override
    {
        sendRootOverAMBCalled = true;
        lastAMBAmount = amount;
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

    // ========================= Test helpers =========================

    function test_setNextMerkleCheckToBe(bool _pass) external {
        nextCheckShouldPass = _pass;
    }

    function test_setOutboxBalance(address token, uint256 amount) external {
        _outboxOf[token].balance = amount;
    }

    function test_setInboxRoot(address token, uint64 nonce, bytes32 root) external {
        _inboxOf[token] = JBInboxTreeRoot({nonce: nonce, root: root});
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

    function test_getOutboxRoot(address token) external view returns (bytes32) {
        return _outboxOf[token].tree.root();
    }

    function test_getOutboxCount(address token) external view returns (uint256) {
        return _outboxOf[token].tree.count;
    }

    function test_getOutboxNonce(address token) external view returns (uint64) {
        return _outboxOf[token].nonce;
    }

    function test_getOutboxBalance(address token) external view returns (uint256) {
        return _outboxOf[token].balance;
    }

    function test_getInboxRoot(address token) external view returns (bytes32) {
        return _inboxOf[token].root;
    }

    function test_getInboxNonce(address token) external view returns (uint64) {
        return _inboxOf[token].nonce;
    }

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

    function test_setNumberOfClaimsSent(address token, uint256 count) external {
        _outboxOf[token].numberOfClaimsSent = count;
    }

    function test_getNumberOfClaimsSent(address token) external view returns (uint256) {
        return _outboxOf[token].numberOfClaimsSent;
    }

    function test_isExecuted(address token, uint256 index) external view returns (bool) {
        return _executedFor[token].get(index);
    }

    function test_isEmergencyExecuted(address terminalToken, uint256 index) external view returns (bool) {
        address emergencyExitAddress = address(bytes20(keccak256(abi.encode(terminalToken))));
        return _executedFor[emergencyExitAddress].get(index);
    }

    function test_setDeprecatedAfter(uint256 timestamp) external {
        deprecatedAfter = timestamp;
    }

    function test_resetSendRootOverAMBCalled() external {
        sendRootOverAMBCalled = false;
    }
}

/// @title TestAuditGaps
/// @notice Tests for audit gaps: (1) concurrent sucker prepare/claim operations happening
///         simultaneously across multiple tokens and beneficiaries, and (2) cross-chain
///         atomic delivery via the merkle tree proof system for atomicity guarantees.
contract TestAuditGaps is Test {
    using MerkleLib for MerkleLib.Tree;

    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);
    address constant TERMINAL = address(1200);

    uint256 constant PROJECT_ID = 1;
    address constant TOKEN = address(0x000000000000000000000000000000000000EEEe);

    AuditGapSucker sucker;

    function setUp() public {
        vm.warp(100 days);

        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");
        vm.label(TOKENS, "MOCK_TOKENS");
        vm.label(CONTROLLER, "MOCK_CONTROLLER");
        vm.label(PROJECT, "MOCK_PROJECT");

        sucker = _createTestSucker(PROJECT_ID, "audit_gap_salt");

        // Common mocks.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, TOKEN)), abi.encode(TERMINAL)
        );
        // Mock terminal.addToBalanceOf to accept any call (including payable for native token).
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());
    }

    function _createTestSucker(uint256 projectId, bytes32 salt) internal returns (AuditGapSucker) {
        AuditGapSucker singleton =
            new AuditGapSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER);

        AuditGapSucker clone = AuditGapSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        clone.initialize(projectId);
        return clone;
    }

    function _mockMint(address beneficiary, uint256 amount) internal {
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, amount, beneficiary, "", false)),
            abi.encode(amount)
        );
    }

    function _enableTokenMapping(address token) internal {
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

    // =========================================================================
    // GAP 1: Concurrent sucker operations
    // Tests for multiple prepare/claim operations happening simultaneously
    // across different tokens, beneficiaries, and indices.
    // =========================================================================

    /// @notice Multiple users prepare leaves for the same token in the same batch;
    ///         each gets a unique outbox index and the outbox balance accumulates correctly.
    function test_concurrentPrepare_multipleUsersForSameToken() public {
        address tokenA = TOKEN;
        _enableTokenMapping(tokenA);

        // Simulate 5 users each inserting a leaf into the outbox tree for the same token.
        address[5] memory users = [address(0xA1), address(0xA2), address(0xA3), address(0xA4), address(0xA5)];

        uint256 runningBalance;
        for (uint256 i; i < users.length; i++) {
            uint256 projectTokenCount = (i + 1) * 1 ether;
            uint256 terminalTokenAmount = (i + 1) * 0.5 ether;
            bytes32 beneficiary = bytes32(uint256(uint160(users[i])));

            sucker.test_insertIntoTree(projectTokenCount, tokenA, terminalTokenAmount, beneficiary);
            runningBalance += terminalTokenAmount;
        }

        // Verify all 5 leaves were inserted with correct count and balance.
        assertEq(sucker.test_getOutboxCount(tokenA), 5, "Outbox should have 5 leaves");
        assertEq(sucker.test_getOutboxBalance(tokenA), runningBalance, "Outbox balance should equal sum of all amounts");

        // Verify root is non-zero (tree is populated).
        assertTrue(sucker.test_getOutboxRoot(tokenA) != bytes32(0), "Outbox root should be non-zero");
    }

    /// @notice Concurrent prepare operations for DIFFERENT tokens produce independent outbox trees.
    function test_concurrentPrepare_differentTokensAreIndependent() public {
        address tokenA = TOKEN;
        address tokenB = makeAddr("tokenB");

        // Insert 3 leaves for token A and 2 for token B.
        sucker.test_insertIntoTree(1 ether, tokenA, 0.5 ether, bytes32(uint256(uint160(address(0xA1)))));
        sucker.test_insertIntoTree(2 ether, tokenB, 1 ether, bytes32(uint256(uint160(address(0xB1)))));
        sucker.test_insertIntoTree(3 ether, tokenA, 1.5 ether, bytes32(uint256(uint160(address(0xA2)))));
        sucker.test_insertIntoTree(4 ether, tokenB, 2 ether, bytes32(uint256(uint160(address(0xB2)))));
        sucker.test_insertIntoTree(5 ether, tokenA, 2.5 ether, bytes32(uint256(uint160(address(0xA3)))));

        // Token A: 3 leaves, balance = 0.5 + 1.5 + 2.5 = 4.5 ether
        assertEq(sucker.test_getOutboxCount(tokenA), 3, "Token A should have 3 leaves");
        assertEq(sucker.test_getOutboxBalance(tokenA), 4.5 ether, "Token A balance should be 4.5 ether");

        // Token B: 2 leaves, balance = 1 + 2 = 3 ether
        assertEq(sucker.test_getOutboxCount(tokenB), 2, "Token B should have 2 leaves");
        assertEq(sucker.test_getOutboxBalance(tokenB), 3 ether, "Token B balance should be 3 ether");

        // Roots should be different (different trees).
        assertTrue(
            sucker.test_getOutboxRoot(tokenA) != sucker.test_getOutboxRoot(tokenB),
            "Token A and B should have different outbox roots"
        );
    }

    /// @notice Multiple claims from different beneficiaries on the same token's inbox.
    ///         Each claim succeeds independently, and double-claim for any index is rejected.
    function test_concurrentClaim_multipleBeneficiariesSameToken() public {
        address[3] memory beneficiaries = [address(0xC1), address(0xC2), address(0xC3)];
        uint256[3] memory amounts = [uint256(1 ether), 2 ether, 3 ether];

        // Insert 3 leaves into the outbox tree.
        for (uint256 i; i < 3; i++) {
            sucker.test_insertIntoTree(amounts[i], TOKEN, amounts[i], bytes32(uint256(uint160(beneficiaries[i]))));
        }

        // Set the inbox root to the outbox root (simulating full round-trip).
        bytes32 root = sucker.test_getOutboxRoot(TOKEN);
        sucker.test_setInboxRoot(TOKEN, 1, root);
        sucker.test_setOutboxBalance(TOKEN, 100 ether);
        // Fund sucker: outbox balance + total claim amounts (1+2+3 = 6 ether).
        vm.deal(address(sucker), 106 ether);

        // Claim for each beneficiary (bypass merkle).
        for (uint256 i; i < 3; i++) {
            _mockMint(beneficiaries[i], amounts[i]);
            sucker.test_setNextMerkleCheckToBe(true);

            bytes32[32] memory proof;
            JBClaim memory claimData = JBClaim({
                token: TOKEN,
                leaf: JBLeaf({
                    index: i,
                    beneficiary: bytes32(uint256(uint160(beneficiaries[i]))),
                    projectTokenCount: amounts[i],
                    terminalTokenAmount: amounts[i]
                }),
                proof: proof
            });

            sucker.claim(claimData);

            // Verify index is marked as executed.
            assertTrue(sucker.test_isExecuted(TOKEN, i), "Index should be marked executed after claim");
        }

        // Attempting to re-claim any of them should revert.
        for (uint256 i; i < 3; i++) {
            bytes32[32] memory proof;
            JBClaim memory claimData = JBClaim({
                token: TOKEN,
                leaf: JBLeaf({
                    index: i,
                    beneficiary: bytes32(uint256(uint160(beneficiaries[i]))),
                    projectTokenCount: amounts[i],
                    terminalTokenAmount: amounts[i]
                }),
                proof: proof
            });

            vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, TOKEN, i));
            sucker.claim(claimData);
        }
    }

    /// @notice Claims for one token's inbox do NOT mark indices as executed for another token's inbox.
    function test_concurrentClaim_crossTokenExecutionIsolation() public {
        address tokenA = TOKEN;
        address tokenB = makeAddr("tokenB");

        // Insert a leaf at index 0 for token A.
        sucker.test_insertIntoTree(5 ether, tokenA, 2 ether, bytes32(uint256(uint160(address(0xD1)))));
        bytes32 rootA = sucker.test_getOutboxRoot(tokenA);
        sucker.test_setInboxRoot(tokenA, 1, rootA);

        // Insert a leaf at index 0 for token B with terminalTokenAmount=0 to avoid _addToBalance
        // ERC20 mocking complexity. This test is about execution slot isolation, not balance handling.
        sucker.test_insertIntoTree(7 ether, tokenB, 0, bytes32(uint256(uint160(address(0xD2)))));
        bytes32 rootB = sucker.test_getOutboxRoot(tokenB);
        sucker.test_setInboxRoot(tokenB, 1, rootB);

        sucker.test_setOutboxBalance(tokenA, 100 ether);

        // Fund sucker for token A (native): outbox balance + claim amount.
        vm.deal(address(sucker), 102 ether);

        // Claim index 0 on token A.
        _mockMint(address(0xD1), 5 ether);
        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proofA;
        sucker.claim(
            JBClaim({
                token: tokenA,
                leaf: JBLeaf({
                    index: 0,
                    beneficiary: bytes32(uint256(uint160(address(0xD1)))),
                    projectTokenCount: 5 ether,
                    terminalTokenAmount: 2 ether
                }),
                proof: proofA
            })
        );

        // Index 0 on token A is executed.
        assertTrue(sucker.test_isExecuted(tokenA, 0), "Token A index 0 should be executed");

        // Index 0 on token B should NOT be executed (different mapping key).
        assertFalse(sucker.test_isExecuted(tokenB, 0), "Token B index 0 should NOT be executed");

        // Claim index 0 on token B should succeed.
        _mockMint(address(0xD2), 7 ether);
        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proofB;
        sucker.claim(
            JBClaim({
                token: tokenB,
                leaf: JBLeaf({
                    index: 0,
                    beneficiary: bytes32(uint256(uint160(address(0xD2)))),
                    projectTokenCount: 7 ether,
                    terminalTokenAmount: 0
                }),
                proof: proofB
            })
        );

        // Both are now executed.
        assertTrue(sucker.test_isExecuted(tokenA, 0), "Token A index 0 still executed");
        assertTrue(sucker.test_isExecuted(tokenB, 0), "Token B index 0 now executed");
    }

    /// @notice Concurrent prepare and toRemote: preparing new leaves while a toRemote batch
    ///         is being sent. The new leaves added after toRemote are tracked by numberOfClaimsSent.
    function test_concurrentPrepareAndToRemote_newLeavesAfterSendTrackedCorrectly() public {
        _enableTokenMapping(TOKEN);

        // Insert 2 leaves.
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xE1)))));
        sucker.test_insertIntoTree(2 ether, TOKEN, 2 ether, bytes32(uint256(uint160(address(0xE2)))));

        assertEq(sucker.test_getOutboxCount(TOKEN), 2, "Should have 2 leaves before toRemote");

        // Send the root (simulates toRemote).
        vm.deal(address(sucker), 3 ether);
        sucker.test_resetSendRootOverAMBCalled();
        sucker.toRemote(TOKEN);

        // After toRemote, numberOfClaimsSent == 2 (indices 0 and 1 were sent).
        assertEq(sucker.test_getNumberOfClaimsSent(TOKEN), 2, "numberOfClaimsSent should be 2 after first send");
        assertEq(sucker.test_getOutboxNonce(TOKEN), 1, "Nonce should be 1 after first send");
        assertTrue(sucker.sendRootOverAMBCalled(), "AMB should have been called");

        // Now add 2 more leaves (simulating concurrent prepare after toRemote).
        sucker.test_insertIntoTree(3 ether, TOKEN, 3 ether, bytes32(uint256(uint160(address(0xE3)))));
        sucker.test_insertIntoTree(4 ether, TOKEN, 4 ether, bytes32(uint256(uint160(address(0xE4)))));

        assertEq(sucker.test_getOutboxCount(TOKEN), 4, "Should have 4 leaves total");

        // The new leaves (indices 2 and 3) are NOT yet covered by numberOfClaimsSent.
        // If emergency exit were needed, only indices 2 and 3 could exit.
        assertEq(sucker.test_getNumberOfClaimsSent(TOKEN), 2, "numberOfClaimsSent should still be 2 before second send");

        // Send the second root.
        vm.deal(address(sucker), 7 ether); // 3 + 4 for new leaves
        sucker.test_resetSendRootOverAMBCalled();
        sucker.toRemote(TOKEN);

        // Now all 4 indices are covered.
        assertEq(sucker.test_getNumberOfClaimsSent(TOKEN), 4, "numberOfClaimsSent should be 4 after second send");
        assertEq(sucker.test_getOutboxNonce(TOKEN), 2, "Nonce should be 2 after second send");
    }

    /// @notice Multiple fromRemote calls with increasing nonces: each updates the inbox.
    function test_concurrentFromRemote_multipleRootUpdatesInSequence() public {
        bytes32[3] memory roots = [bytes32(uint256(0xAAA)), bytes32(uint256(0xBBB)), bytes32(uint256(0xCCC))];

        for (uint64 i = 1; i <= 3; i++) {
            JBMessageRoot memory msgRoot = JBMessageRoot({
                version: 1,
                token: bytes32(uint256(uint160(TOKEN))),
                amount: i * 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: i, root: roots[i - 1]})
            });

            vm.prank(address(sucker)); // peer = self for clones
            sucker.fromRemote(msgRoot);

            assertEq(sucker.test_getInboxNonce(TOKEN), i, "Nonce should match after sequential delivery");
            assertEq(sucker.test_getInboxRoot(TOKEN), roots[i - 1], "Root should match after sequential delivery");
        }
    }

    /// @notice Out-of-order fromRemote: nonce 3 arrives before nonce 2. Only nonce 3 is accepted;
    ///         subsequent nonce 2 is silently ignored.
    function test_concurrentFromRemote_outOfOrderDelivery() public {
        // Deliver nonce 3 first.
        JBMessageRoot memory root3 = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 3 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 3, root: bytes32(uint256(0xDDD))})
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root3);

        assertEq(sucker.test_getInboxNonce(TOKEN), 3, "Nonce should be 3 after out-of-order delivery");
        assertEq(sucker.test_getInboxRoot(TOKEN), bytes32(uint256(0xDDD)), "Root should be from nonce 3");

        // Now deliver nonce 2 (late) — should be silently ignored.
        JBMessageRoot memory root2 = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 2 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 2, root: bytes32(uint256(0xEEE))})
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root2);

        // State unchanged (nonce 2 < current nonce 3).
        assertEq(sucker.test_getInboxNonce(TOKEN), 3, "Nonce should still be 3 after stale delivery");
        assertEq(sucker.test_getInboxRoot(TOKEN), bytes32(uint256(0xDDD)), "Root should still be from nonce 3");
    }

    /// @notice Claims from different indices can be interleaved (non-sequential order).
    function test_concurrentClaim_nonSequentialIndexOrder() public {
        // Insert 4 leaves.
        address[4] memory beneficiaries = [address(0xF1), address(0xF2), address(0xF3), address(0xF4)];
        for (uint256 i; i < 4; i++) {
            sucker.test_insertIntoTree(
                (i + 1) * 1 ether, TOKEN, (i + 1) * 0.5 ether, bytes32(uint256(uint160(beneficiaries[i])))
            );
        }

        bytes32 root = sucker.test_getOutboxRoot(TOKEN);
        sucker.test_setInboxRoot(TOKEN, 1, root);
        sucker.test_setOutboxBalance(TOKEN, 100 ether);
        // Fund sucker: outbox balance + total claim amounts (0.5+1+1.5+2 = 5 ether).
        vm.deal(address(sucker), 105 ether);

        // Claim in order: 2, 0, 3, 1 (non-sequential).
        uint256[4] memory claimOrder = [uint256(2), 0, 3, 1];

        for (uint256 j; j < 4; j++) {
            uint256 idx = claimOrder[j];
            uint256 projTok = (idx + 1) * 1 ether;
            uint256 termTok = (idx + 1) * 0.5 ether;
            address ben = beneficiaries[idx];

            _mockMint(ben, projTok);
            sucker.test_setNextMerkleCheckToBe(true);

            bytes32[32] memory proof;
            sucker.claim(
                JBClaim({
                    token: TOKEN,
                    leaf: JBLeaf({
                        index: idx,
                        beneficiary: bytes32(uint256(uint160(ben))),
                        projectTokenCount: projTok,
                        terminalTokenAmount: termTok
                    }),
                    proof: proof
                })
            );
        }

        // All 4 indices should be executed.
        for (uint256 i; i < 4; i++) {
            assertTrue(sucker.test_isExecuted(TOKEN, i), "All indices should be executed");
        }
    }

    // =========================================================================
    // GAP 2: Cross-chain atomic delivery (merkle tree proof system)
    // Tests for the merkle tree guaranteeing atomicity: append-only, root
    // progression, proof validity across root updates, and inbox/outbox
    // consistency.
    // =========================================================================

    /// @notice Merkle tree is append-only: adding a new leaf changes the root but
    ///         the old leaves are still part of the new tree.
    function test_merkleTree_appendOnlyRootProgression() public {
        // Insert leaf 0.
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0x100)))));
        bytes32 root1 = sucker.test_getOutboxRoot(TOKEN);

        // Insert leaf 1.
        sucker.test_insertIntoTree(2 ether, TOKEN, 2 ether, bytes32(uint256(uint160(address(0x200)))));
        bytes32 root2 = sucker.test_getOutboxRoot(TOKEN);

        // Insert leaf 2.
        sucker.test_insertIntoTree(3 ether, TOKEN, 3 ether, bytes32(uint256(uint160(address(0x300)))));
        bytes32 root3 = sucker.test_getOutboxRoot(TOKEN);

        // Each root should be different (tree progresses with each insertion).
        assertTrue(root1 != root2, "root1 != root2");
        assertTrue(root2 != root3, "root2 != root3");
        assertTrue(root1 != root3, "root1 != root3");

        // All 3 leaves exist in the tree.
        assertEq(sucker.test_getOutboxCount(TOKEN), 3, "Tree count should be 3");
    }

    /// @notice After inbox root is updated to a newer nonce, claims against the new root
    ///         succeed while the old root's proofs (which do not match) are rejected.
    function test_merkleTree_inboxRootUpdateInvalidatesOldProofs() public {
        // Set up a valid inbox root.
        sucker.test_insertIntoTree(5 ether, TOKEN, 5 ether, bytes32(uint256(uint160(address(0x111)))));
        bytes32 rootOld = sucker.test_getOutboxRoot(TOKEN);
        sucker.test_setInboxRoot(TOKEN, 1, rootOld);

        // Overwrite with a completely different root (simulating new nonce delivery).
        bytes32 rootNew = bytes32(uint256(0xFACADE));
        sucker.test_setInboxRoot(TOKEN, 2, rootNew);

        // A claim against the old root's data with empty proof will fail because
        // branchRoot computation won't match rootNew.
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(0x111)))),
                projectTokenCount: 5 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });

        vm.expectRevert(); // InvalidProof — proof computed against old root won't match rootNew
        sucker.claim(claimData);
    }

    /// @notice Verifying that the same leaf hash produces the same tree root regardless of
    ///         when it is computed. Tests deterministic hashing.
    function test_merkleTree_deterministicHashing() public {
        address tokenA = makeAddr("tokenDeterministic1");
        address tokenB = makeAddr("tokenDeterministic2");

        // Insert the exact same leaf into two independent trees.
        sucker.test_insertIntoTree(42 ether, tokenA, 21 ether, bytes32(uint256(uint160(address(0x999)))));
        sucker.test_insertIntoTree(42 ether, tokenB, 21 ether, bytes32(uint256(uint160(address(0x999)))));

        // Both trees have 1 leaf with the same hash, so roots should be identical.
        bytes32 rootA = sucker.test_getOutboxRoot(tokenA);
        bytes32 rootB = sucker.test_getOutboxRoot(tokenB);

        assertEq(rootA, rootB, "Same leaf data should produce same root in independent trees");
    }

    /// @notice Outbox root for an empty tree returns a well-defined constant (Z_32).
    function test_merkleTree_emptyTreeRoot() public {
        address unusedToken = makeAddr("unusedToken");

        // No insertions — the tree is empty.
        bytes32 emptyRoot = sucker.test_getOutboxRoot(unusedToken);

        // The MerkleLib returns Z_32 for empty trees (see MerkleLib.root: count==0 → return Z_32).
        // Z_32 is the fixed hash for a completely empty depth-32 tree.
        bytes32 Z_32 = hex"27ae5ba08d7291c96c8cbddcc148bf48a6d68c7974b94356f53754ef6171d757";
        assertEq(emptyRoot, Z_32, "Empty tree root should be Z_32");
    }

    /// @notice Inbox nonce monotonicity: fromRemote only accepts strictly increasing nonces.
    ///         Same-nonce and lower-nonce deliveries are silently rejected.
    function test_merkleTree_inboxNonceMonotonicity() public {
        // Deliver nonce 1.
        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: bytes32(uint256(uint160(TOKEN))),
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0x111))})
            })
        );
        assertEq(sucker.test_getInboxNonce(TOKEN), 1);

        // Try same nonce 1 again — rejected.
        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: bytes32(uint256(uint160(TOKEN))),
                amount: 2 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0x222))})
            })
        );
        assertEq(sucker.test_getInboxNonce(TOKEN), 1, "Same nonce should not update");
        assertEq(sucker.test_getInboxRoot(TOKEN), bytes32(uint256(0x111)), "Same nonce should not update root");

        // Deliver nonce 5 (gap) — accepted.
        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: bytes32(uint256(uint160(TOKEN))),
                amount: 5 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 5, root: bytes32(uint256(0x555))})
            })
        );
        assertEq(sucker.test_getInboxNonce(TOKEN), 5, "Higher nonce should update");
        assertEq(sucker.test_getInboxRoot(TOKEN), bytes32(uint256(0x555)), "Higher nonce should update root");

        // Try nonce 3 (lower than current 5) — rejected.
        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: bytes32(uint256(uint160(TOKEN))),
                amount: 3 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 3, root: bytes32(uint256(0x333))})
            })
        );
        assertEq(sucker.test_getInboxNonce(TOKEN), 5, "Lower nonce should not update");
        assertEq(sucker.test_getInboxRoot(TOKEN), bytes32(uint256(0x555)), "Lower nonce should not update root");
    }

    /// @notice The outbox nonce increments with each toRemote call and the outbox balance
    ///         is cleared after sending.
    function test_merkleTree_outboxNonceIncrementsAndBalanceClears() public {
        _enableTokenMapping(TOKEN);

        // Insert and send batch 1.
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0x10)))));
        vm.deal(address(sucker), 1 ether);
        sucker.toRemote(TOKEN);

        assertEq(sucker.test_getOutboxNonce(TOKEN), 1, "Nonce should be 1 after first send");
        assertEq(sucker.test_getOutboxBalance(TOKEN), 0, "Balance should be 0 after send");

        // Insert and send batch 2.
        sucker.test_insertIntoTree(2 ether, TOKEN, 2 ether, bytes32(uint256(uint160(address(0x20)))));
        vm.deal(address(sucker), 2 ether);
        sucker.toRemote(TOKEN);

        assertEq(sucker.test_getOutboxNonce(TOKEN), 2, "Nonce should be 2 after second send");
        assertEq(sucker.test_getOutboxBalance(TOKEN), 0, "Balance should be 0 after second send");

        // Insert and send batch 3.
        sucker.test_insertIntoTree(3 ether, TOKEN, 3 ether, bytes32(uint256(uint160(address(0x30)))));
        vm.deal(address(sucker), 3 ether);
        sucker.toRemote(TOKEN);

        assertEq(sucker.test_getOutboxNonce(TOKEN), 3, "Nonce should be 3 after third send");
        assertEq(sucker.test_getOutboxBalance(TOKEN), 0, "Balance should be 0 after third send");
    }

    /// @notice Multiple tokens can have independent inbox nonces and roots.
    function test_merkleTree_multiTokenInboxIndependence() public {
        address tokenA = TOKEN;
        address tokenB = makeAddr("inboxIndepB");

        // Deliver different roots/nonces for token A and token B.
        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: bytes32(uint256(uint160(tokenA))),
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 3, root: bytes32(uint256(0xAAA))})
            })
        );

        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: bytes32(uint256(uint160(tokenB))),
                amount: 2 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 7, root: bytes32(uint256(0xBBB))})
            })
        );

        // Verify they are independent.
        assertEq(sucker.test_getInboxNonce(tokenA), 3, "Token A nonce should be 3");
        assertEq(sucker.test_getInboxRoot(tokenA), bytes32(uint256(0xAAA)), "Token A root");
        assertEq(sucker.test_getInboxNonce(tokenB), 7, "Token B nonce should be 7");
        assertEq(sucker.test_getInboxRoot(tokenB), bytes32(uint256(0xBBB)), "Token B root");

        // Update token A to nonce 10 — should not affect token B.
        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: bytes32(uint256(uint160(tokenA))),
                amount: 10 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 10, root: bytes32(uint256(0xCCC))})
            })
        );

        assertEq(sucker.test_getInboxNonce(tokenA), 10, "Token A nonce updated to 10");
        assertEq(sucker.test_getInboxRoot(tokenA), bytes32(uint256(0xCCC)), "Token A root updated");
        assertEq(sucker.test_getInboxNonce(tokenB), 7, "Token B nonce unchanged");
        assertEq(sucker.test_getInboxRoot(tokenB), bytes32(uint256(0xBBB)), "Token B root unchanged");
    }

    /// @notice Emergency exit cannot double-spend: a leaf claimed via emergency exit
    ///         cannot be claimed again via emergency exit (same emergency slot).
    function test_merkleTree_emergencyExitAtomicity() public {
        // Insert 2 leaves.
        sucker.test_insertIntoTree(5 ether, TOKEN, 5 ether, bytes32(uint256(uint160(address(this)))));
        sucker.test_insertIntoTree(7 ether, TOKEN, 7 ether, bytes32(uint256(uint160(address(this)))));

        sucker.test_setOutboxBalance(TOKEN, 100 ether);
        vm.deal(address(sucker), 100 ether);

        // Enable emergency hatch (no claims sent yet, so numberOfClaimsSent == 0).
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: false,
                emergencyHatch: true,
                minGas: 0,
                addr: bytes32(uint256(uint160(makeAddr("remote")))),
                minBridgeAmount: 0
            })
        );

        // Emergency exit index 0.
        _mockMint(address(this), 5 ether);
        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        sucker.exitThroughEmergencyHatch(
            JBClaim({
                token: TOKEN,
                leaf: JBLeaf({
                    index: 0,
                    beneficiary: bytes32(uint256(uint160(address(this)))),
                    projectTokenCount: 5 ether,
                    terminalTokenAmount: 5 ether
                }),
                proof: proof
            })
        );

        assertTrue(sucker.test_isEmergencyExecuted(TOKEN, 0), "Index 0 should be emergency-executed");
        assertFalse(sucker.test_isEmergencyExecuted(TOKEN, 1), "Index 1 should NOT be emergency-executed yet");

        // Try index 0 again — revert.
        sucker.test_setNextMerkleCheckToBe(true);
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, TOKEN, 0));
        sucker.exitThroughEmergencyHatch(
            JBClaim({
                token: TOKEN,
                leaf: JBLeaf({
                    index: 0,
                    beneficiary: bytes32(uint256(uint160(address(this)))),
                    projectTokenCount: 5 ether,
                    terminalTokenAmount: 5 ether
                }),
                proof: proof
            })
        );

        // Index 1 should still work.
        _mockMint(address(this), 7 ether);
        sucker.test_setNextMerkleCheckToBe(true);
        sucker.exitThroughEmergencyHatch(
            JBClaim({
                token: TOKEN,
                leaf: JBLeaf({
                    index: 1,
                    beneficiary: bytes32(uint256(uint160(address(this)))),
                    projectTokenCount: 7 ether,
                    terminalTokenAmount: 7 ether
                }),
                proof: proof
            })
        );

        assertTrue(sucker.test_isEmergencyExecuted(TOKEN, 1), "Index 1 should now be emergency-executed");
    }

    /// @notice Message version mismatch: fromRemote rejects messages with wrong version.
    function test_merkleTree_messageVersionValidation() public {
        JBMessageRoot memory root = JBMessageRoot({
            version: 99, // wrong version
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0x123))})
        });

        vm.prank(address(sucker));
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_InvalidMessageVersion.selector, 99, 1));
        sucker.fromRemote(root);

        // Inbox should be unchanged.
        assertEq(sucker.test_getInboxNonce(TOKEN), 0, "Nonce should remain 0 after version rejection");
    }

    /// @notice Outbox tree tracks balance correctly across multiple insertions and a send cycle.
    function test_merkleTree_outboxBalanceAccuracyAcrossCycles() public {
        _enableTokenMapping(TOKEN);

        // Cycle 1: insert 3 leaves with varying amounts.
        sucker.test_insertIntoTree(10 ether, TOKEN, 5 ether, bytes32(uint256(uint160(address(0x100)))));
        sucker.test_insertIntoTree(20 ether, TOKEN, 8 ether, bytes32(uint256(uint160(address(0x200)))));
        sucker.test_insertIntoTree(30 ether, TOKEN, 12 ether, bytes32(uint256(uint160(address(0x300)))));

        assertEq(sucker.test_getOutboxBalance(TOKEN), 25 ether, "Balance should be 5+8+12 = 25 ether");

        // Send cycle 1.
        vm.deal(address(sucker), 25 ether);
        sucker.toRemote(TOKEN);
        assertEq(sucker.test_getOutboxBalance(TOKEN), 0, "Balance cleared after send");

        // Cycle 2: insert more leaves.
        sucker.test_insertIntoTree(40 ether, TOKEN, 15 ether, bytes32(uint256(uint160(address(0x400)))));
        sucker.test_insertIntoTree(50 ether, TOKEN, 20 ether, bytes32(uint256(uint160(address(0x500)))));

        assertEq(sucker.test_getOutboxBalance(TOKEN), 35 ether, "Balance should be 15+20 = 35 ether");
        assertEq(sucker.test_getOutboxCount(TOKEN), 5, "Total count should be 5 across both cycles");

        // Send cycle 2.
        vm.deal(address(sucker), 35 ether);
        sucker.toRemote(TOKEN);
        assertEq(sucker.test_getOutboxBalance(TOKEN), 0, "Balance cleared after second send");
        assertEq(sucker.test_getOutboxNonce(TOKEN), 2, "Nonce should be 2 after two sends");
        assertEq(sucker.test_getNumberOfClaimsSent(TOKEN), 5, "All 5 claims should be marked as sent");
    }

    /// @notice Claim and emergency exit slots are completely independent,
    ///         preventing cross-contamination between inbox claims and outbox emergency exits.
    function test_merkleTree_claimAndEmergencyExitSlotIndependence() public {
        // Insert a leaf at index 0.
        sucker.test_insertIntoTree(10 ether, TOKEN, 10 ether, bytes32(uint256(uint160(address(this)))));

        // Set the inbox root to match the outbox root (simulating a round-trip).
        bytes32 root = sucker.test_getOutboxRoot(TOKEN);
        sucker.test_setInboxRoot(TOKEN, 1, root);
        sucker.test_setOutboxBalance(TOKEN, 100 ether);
        // Fund sucker: outbox balance + claim amount.
        vm.deal(address(sucker), 110 ether);

        // Claim via inbox (regular claim) at index 0.
        _mockMint(address(this), 10 ether);
        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        sucker.claim(
            JBClaim({
                token: TOKEN,
                leaf: JBLeaf({
                    index: 0,
                    beneficiary: bytes32(uint256(uint160(address(this)))),
                    projectTokenCount: 10 ether,
                    terminalTokenAmount: 10 ether
                }),
                proof: proof
            })
        );

        // Index 0 is executed in the inbox (claim) slot.
        assertTrue(sucker.test_isExecuted(TOKEN, 0), "Claim slot should be marked");

        // Index 0 is NOT executed in the emergency exit slot.
        assertFalse(sucker.test_isEmergencyExecuted(TOKEN, 0), "Emergency slot should NOT be marked by claim");
    }

    /// @notice Each leaf insertion into the outbox tree changes the root deterministically;
    ///         the count field accurately tracks the number of insertions.
    function test_merkleTree_rootProgressionWithManyInsertions() public {
        bytes32 prevRoot = sucker.test_getOutboxRoot(TOKEN);

        uint256 numInsertions = 20;
        bytes32[] memory roots = new bytes32[](numInsertions);

        for (uint256 i; i < numInsertions; i++) {
            sucker.test_insertIntoTree((i + 1) * 1 ether, TOKEN, (i + 1) * 0.5 ether, bytes32(uint256(1000 + i)));

            bytes32 newRoot = sucker.test_getOutboxRoot(TOKEN);
            assertTrue(newRoot != prevRoot, "Root should change with each insertion");

            // Ensure no duplicate root in previous insertions.
            for (uint256 j; j < i; j++) {
                assertTrue(newRoot != roots[j], "Each root should be unique");
            }

            roots[i] = newRoot;
            prevRoot = newRoot;
        }

        assertEq(sucker.test_getOutboxCount(TOKEN), numInsertions, "Count should match number of insertions");
    }

    /// @notice toRemote on empty tree (no prepare calls) does nothing: no revert, no nonce increment.
    function test_merkleTree_emptyTreeToRemoteNoOp() public {
        _enableTokenMapping(TOKEN);
        sucker.test_resetSendRootOverAMBCalled();

        // Outbox is empty.
        assertEq(sucker.test_getOutboxCount(TOKEN), 0, "Tree should be empty");

        // toRemote should succeed but not send anything.
        sucker.toRemote(TOKEN);

        assertFalse(sucker.sendRootOverAMBCalled(), "AMB should NOT be called on empty tree");
        assertEq(sucker.test_getOutboxNonce(TOKEN), 0, "Nonce should remain 0");
        assertEq(sucker.test_getOutboxBalance(TOKEN), 0, "Balance should remain 0");
    }

    receive() external payable {}
}
