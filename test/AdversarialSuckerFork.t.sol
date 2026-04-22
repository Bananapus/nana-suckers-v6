// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CCIPSuckerClaimForkTestBase, LeafData} from "./ForkClaimMainnet.t.sol";
import {JBSucker} from "../src/JBSucker.sol";
import {JBClaim} from "../src/structs/JBClaim.sol";
import {JBLeaf} from "../src/structs/JBLeaf.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

/// @notice Adversarial fork tests for the CCIP sucker: multi-root, stale-proof, and double-send scenarios.
/// @dev Extends `CCIPSuckerClaimForkTestBase` (Ethereum -> Arbitrum) and exercises edge cases around
/// the append-only outbox merkle tree, sequential root delivery, and inbox nonce gating.
///
/// The outbox merkle tree is **append-only**: `prepare()` inserts leaves and `toRemote()` reads the
/// current cumulative root without clearing the tree. This means nonce=2's root is the root of the
/// tree containing ALL leaves (including those from nonce=1). Proofs must always be computed against
/// the LATEST delivered root on the inbox side.
contract AdversarialSuckerForkTest is CCIPSuckerClaimForkTestBase {
    // ── Chain-specific overrides (Ethereum -> Arbitrum, same as EthArbClaimForkTest)
    // ──────────────────────────────────────────────────────────────────────────────

    function _l1RpcUrl() internal pure override returns (string memory) {
        return "ethereum";
    }

    function _l2RpcUrl() internal pure override returns (string memory) {
        return "arbitrum";
    }

    function _l1ChainId() internal pure override returns (uint256) {
        return 1;
    }

    function _l2ChainId() internal pure override returns (uint256) {
        return 42_161;
    }

    function _l1ForkBlock() internal pure override returns (uint256) {
        return 21_700_000;
    }

    function _l2ForkBlock() internal pure override returns (uint256) {
        return 300_000_000;
    }

    // ════════════════════════════════════════════════════════════════════════
    // Test 1: Claim with stale root after newer root delivered
    // ════════════════════════════════════════════════════════════════════════
    //
    // Scenario:
    //   - User A prepares (leaf 0, tree count = 1)
    //   - toRemote sends root with nonce=1 (root of 1-leaf tree)
    //   - Deliver nonce=1 to L2 inbox
    //   - User B prepares (leaf 1, tree count = 2)
    //   - toRemote sends root with nonce=2 (root of 2-leaf tree)
    //   - Deliver nonce=2 to L2 inbox (overwrites inbox root)
    //   - Attempt to claim User A's leaf using the STALE proof from nonce=1's tree
    //
    // Expected: The stale proof FAILS because the inbox root is now nonce=2's root (2-leaf tree),
    // and the zero proof (valid for a single-leaf tree) does not match. The outbox tree is
    // append-only, so nonce=2's root is the cumulative root of both leaves -- a different value
    // from nonce=1's root.
    //
    // After the stale proof fails, we verify User A CAN claim with a proof computed against
    // the 2-leaf tree (using leafB.hashed as the sibling at proof[0]).
    //
    // ════════════════════════════════════════════════════════════════════════

    function test_adversarial_claimAgainstStaleRootAfterNewerRoot() external {
        address userA = makeAddr("userA");
        address userB = makeAddr("userB");
        uint256 amountToSend = 0.05 ether;

        // ── L1: User A pays and prepares ──
        vm.selectFork(l1Fork);
        address token = _terminalToken();
        _mapTerminalToken();

        LeafData memory leafA = _mapPayAndPrepare(userA, amountToSend);
        assertEq(leafA.index, 0, "User A should be at index 0");

        // toRemote: sends nonce=1 root (1-leaf tree).
        (bytes32 root1, uint64 nonce1) = _sendToRemote();
        assertEq(nonce1, 1, "First toRemote should produce nonce 1");
        assertEq(root1, leafA.root, "Root 1 should match leaf A's root from InsertToOutboxTree");

        // ── Deliver nonce=1 to L2 ──
        vm.selectFork(l2Fork);
        token = _terminalToken();
        _deliverToL2(root1, nonce1, leafA.terminalTokenAmount);
        assertEq(suckerL1.inboxOf(token).root, root1, "Inbox should hold root from nonce=1");

        // ── L1: User B pays and prepares (tree now has 2 leaves) ──
        vm.selectFork(l1Fork);
        LeafData memory leafB = _mapPayAndPrepare(userB, amountToSend);
        assertEq(leafB.index, 1, "User B should be at index 1");

        // toRemote: sends nonce=2 root (2-leaf tree, cumulative).
        (bytes32 root2, uint64 nonce2) = _sendToRemote();
        assertEq(nonce2, 2, "Second toRemote should produce nonce 2");
        assertTrue(root2 != root1, "Root 2 (2-leaf) should differ from root 1 (1-leaf)");

        // ── Deliver nonce=2 to L2 (overwrites inbox root) ──
        // IMPORTANT: _deliverToL2 uses vm.deal which SETS the balance (not adds).
        // Since we need to claim BOTH leaves after nonce=2 delivery, we must provide
        // the cumulative amount so the sucker can fund both claims.
        vm.selectFork(l2Fork);
        token = _terminalToken();
        _deliverToL2(root2, nonce2, leafA.terminalTokenAmount + leafB.terminalTokenAmount);
        assertEq(suckerL1.inboxOf(token).root, root2, "Inbox should now hold root from nonce=2");

        // ── Attempt to claim User A's leaf with STALE proof (from nonce=1's 1-leaf tree) ──
        // The zero proof is correct for a 1-leaf tree but NOT for a 2-leaf tree.
        vm.expectPartialRevert(JBSucker.JBSucker_InvalidProof.selector);
        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leafA.index,
                    beneficiary: leafA.beneficiary,
                    projectTokenCount: leafA.projectTokenCount,
                    terminalTokenAmount: leafA.terminalTokenAmount
                }),
                proof: _zeroProof() // Stale proof: valid for root1 but NOT root2.
            })
        );

        // ── User A CAN claim with the correct proof against the 2-leaf tree ──
        // In a 2-leaf tree, the sibling of leaf A (index 0) is leaf B's hash at proof[0].
        bytes32[32] memory correctProofA = _zeroProof();
        correctProofA[0] = leafB.hashed;

        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leafA.index,
                    beneficiary: leafA.beneficiary,
                    projectTokenCount: leafA.projectTokenCount,
                    terminalTokenAmount: leafA.terminalTokenAmount
                }),
                proof: correctProofA
            })
        );
        assertEq(
            jbTokens().totalBalanceOf(userA, 1),
            leafA.projectTokenCount,
            "User A should receive tokens after claiming with correct 2-leaf proof"
        );

        // ── User B claims normally against the 2-leaf tree ──
        bytes32[32] memory correctProofB = _zeroProof();
        correctProofB[0] = leafA.hashed;

        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leafB.index,
                    beneficiary: leafB.beneficiary,
                    projectTokenCount: leafB.projectTokenCount,
                    terminalTokenAmount: leafB.terminalTokenAmount
                }),
                proof: correctProofB
            })
        );
        assertEq(
            jbTokens().totalBalanceOf(userB, 1),
            leafB.projectTokenCount,
            "User B should receive tokens after claiming with correct 2-leaf proof"
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // Test 2: Multiple sequential roots before any claims
    // ════════════════════════════════════════════════════════════════════════
    //
    // Scenario:
    //   - User A prepares (leaf 0)
    //   - toRemote (nonce=1, root of 1-leaf tree)
    //   - User B prepares (leaf 1)
    //   - toRemote (nonce=2, root of 2-leaf tree)
    //   - Deliver nonce=1 to L2 (inbox root = root1)
    //   - Deliver nonce=2 to L2 (inbox root = root2, overwrites root1)
    //   - Attempt to claim User A with nonce=1 proof (zero proof) -> should FAIL
    //   - Claim User A with nonce=2 proof (leafB sibling) -> should SUCCEED
    //   - Claim User B with nonce=2 proof (leafA sibling) -> should SUCCEED
    //
    // Key insight: Even though nonce=1 was delivered first, nonce=2 overwrites the inbox root.
    // All claims must use proofs against nonce=2's root. The append-only tree ensures leaf A
    // is still in nonce=2's tree, just with a different proof path.
    //
    // ════════════════════════════════════════════════════════════════════════

    function test_adversarial_multipleRootsBeforeClaims() external {
        address userA = makeAddr("userA");
        address userB = makeAddr("userB");
        uint256 amountToSend = 0.05 ether;

        // ── L1: User A prepares ──
        vm.selectFork(l1Fork);
        address token = _terminalToken();
        _mapTerminalToken();

        LeafData memory leafA = _mapPayAndPrepare(userA, amountToSend);

        // toRemote nonce=1 (1-leaf tree).
        (bytes32 root1, uint64 nonce1) = _sendToRemote();

        // ── L1: User B prepares ──
        LeafData memory leafB = _mapPayAndPrepare(userB, amountToSend);

        // toRemote nonce=2 (2-leaf tree).
        (bytes32 root2, uint64 nonce2) = _sendToRemote();

        // ── Deliver both roots to L2 in order ──
        vm.selectFork(l2Fork);
        token = _terminalToken();

        // Deliver nonce=1 first.
        _deliverToL2(root1, nonce1, leafA.terminalTokenAmount);
        assertEq(suckerL1.inboxOf(token).root, root1, "Inbox should initially hold root1");

        // Deliver nonce=2 (overwrites). Use cumulative amount since both claims happen after this.
        _deliverToL2(root2, nonce2, leafA.terminalTokenAmount + leafB.terminalTokenAmount);
        assertEq(suckerL1.inboxOf(token).root, root2, "Inbox should now hold root2 after nonce=2 delivery");

        // ── Attempt to claim User A with nonce=1's proof (zero proof) ──
        // This MUST fail because inbox root is now root2 (2-leaf tree).
        vm.expectPartialRevert(JBSucker.JBSucker_InvalidProof.selector);
        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leafA.index,
                    beneficiary: leafA.beneficiary,
                    projectTokenCount: leafA.projectTokenCount,
                    terminalTokenAmount: leafA.terminalTokenAmount
                }),
                proof: _zeroProof()
            })
        );

        // ── Claim User A with correct proof against the 2-leaf tree ──
        bytes32[32] memory proofA = _zeroProof();
        proofA[0] = leafB.hashed;

        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leafA.index,
                    beneficiary: leafA.beneficiary,
                    projectTokenCount: leafA.projectTokenCount,
                    terminalTokenAmount: leafA.terminalTokenAmount
                }),
                proof: proofA
            })
        );
        assertEq(
            jbTokens().totalBalanceOf(userA, 1),
            leafA.projectTokenCount,
            "User A claim should succeed with nonce=2 proof"
        );

        // ── Claim User B (only exists in nonce=2's tree) ──
        bytes32[32] memory proofB = _zeroProof();
        proofB[0] = leafA.hashed;

        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leafB.index,
                    beneficiary: leafB.beneficiary,
                    projectTokenCount: leafB.projectTokenCount,
                    terminalTokenAmount: leafB.terminalTokenAmount
                }),
                proof: proofB
            })
        );
        assertEq(
            jbTokens().totalBalanceOf(userB, 1),
            leafB.projectTokenCount,
            "User B claim should succeed with nonce=2 proof"
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // Test 3: Double toRemote (empty outbox)
    // ════════════════════════════════════════════════════════════════════════
    //
    // Scenario:
    //   - User prepares
    //   - toRemote succeeds (outbox cleared: balance=0, numberOfClaimsSent=tree.count)
    //   - toRemote again immediately — outbox is empty
    //   - Expected: reverts with JBSucker_NothingToSend
    //
    // The guard is: `outbox.balance == 0 && outbox.tree.count == outbox.numberOfClaimsSent`
    // After the first toRemote, balance is cleared and numberOfClaimsSent is set to tree.count,
    // so the second call hits this guard and reverts.
    //
    // ════════════════════════════════════════════════════════════════════════

    function test_adversarial_doubleToRemote() external {
        address user = makeAddr("user");

        // ── L1: User pays and prepares ──
        vm.selectFork(l1Fork);
        _mapTerminalToken();
        _mapPayAndPrepare(user, 0.05 ether);

        // First toRemote: should succeed.
        _sendToRemote();

        // Second toRemote: outbox is empty, should revert.
        address token = _terminalToken();
        address rootSender = makeAddr("doubleRootSender");
        uint256 ccipFeeAmount = 1 ether;
        vm.deal(rootSender, ccipFeeAmount);

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_NothingToSend.selector));
        vm.prank(rootSender);
        suckerL1.toRemote{value: ccipFeeAmount}(token);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Test 4: Prepare after toRemote starts new batch
    // ════════════════════════════════════════════════════════════════════════
    //
    // Scenario:
    //   - User A prepares (leaf 0)
    //   - toRemote sends root (nonce=1, 1-leaf tree)
    //   - User B prepares (leaf 1 in the SAME append-only tree -- new "batch")
    //   - toRemote sends root (nonce=2, 2-leaf tree)
    //   - Deliver nonce=1 to L2, then deliver nonce=2 to L2
    //   - Claim User A's leaf from first batch -> verify success
    //   - Claim User B's leaf from second batch -> verify success
    //
    // Key: Even though User B's leaf was in a "new batch" (prepared after User A's toRemote),
    // the outbox tree is cumulative. Nonce=2's root contains BOTH leaves. After nonce=2 delivery
    // overwrites the inbox root, claims for both User A and User B must use proofs against the
    // 2-leaf tree root.
    //
    // BUT: if we want to claim User A from nonce=1's root, we must do it BEFORE nonce=2
    // overwrites it. This test demonstrates both orderings:
    //   (a) Deliver nonce=1, claim User A against root1 (1-leaf proof)
    //   (b) Deliver nonce=2, claim User B against root2 (2-leaf proof)
    //
    // ════════════════════════════════════════════════════════════════════════

    function test_adversarial_prepareAfterToRemote_newBatch() external {
        address userA = makeAddr("userA");
        address userB = makeAddr("userB");
        uint256 amountToSend = 0.05 ether;

        // ── L1: User A prepares ──
        vm.selectFork(l1Fork);
        address token = _terminalToken();
        _mapTerminalToken();

        LeafData memory leafA = _mapPayAndPrepare(userA, amountToSend);
        assertEq(leafA.index, 0, "User A should be at index 0");

        // toRemote nonce=1 (1-leaf tree root).
        (bytes32 root1, uint64 nonce1) = _sendToRemote();

        // ── L1: User B prepares after toRemote (new "batch", same tree) ──
        LeafData memory leafB = _mapPayAndPrepare(userB, amountToSend);
        assertEq(leafB.index, 1, "User B should be at index 1");

        // toRemote nonce=2 (2-leaf tree root).
        (bytes32 root2, uint64 nonce2) = _sendToRemote();

        // ── Deliver nonce=1 to L2 and claim User A immediately ──
        vm.selectFork(l2Fork);
        token = _terminalToken();

        _deliverToL2(root1, nonce1, leafA.terminalTokenAmount);
        assertEq(suckerL1.inboxOf(token).root, root1, "Inbox should hold root1");

        // Claim User A against root1 (single-leaf tree, zero proof).
        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leafA.index,
                    beneficiary: leafA.beneficiary,
                    projectTokenCount: leafA.projectTokenCount,
                    terminalTokenAmount: leafA.terminalTokenAmount
                }),
                proof: _zeroProof()
            })
        );
        assertEq(
            jbTokens().totalBalanceOf(userA, 1),
            leafA.projectTokenCount,
            "User A should receive tokens from nonce=1 claim"
        );

        // ── Deliver nonce=2 to L2 (overwrites inbox root) ──
        _deliverToL2(root2, nonce2, leafB.terminalTokenAmount);
        assertEq(suckerL1.inboxOf(token).root, root2, "Inbox should now hold root2");

        // Claim User B against root2 (2-leaf tree, sibling = leafA.hashed).
        bytes32[32] memory proofB = _zeroProof();
        proofB[0] = leafA.hashed;

        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leafB.index,
                    beneficiary: leafB.beneficiary,
                    projectTokenCount: leafB.projectTokenCount,
                    terminalTokenAmount: leafB.terminalTokenAmount
                }),
                proof: proofB
            })
        );
        assertEq(
            jbTokens().totalBalanceOf(userB, 1),
            leafB.projectTokenCount,
            "User B should receive tokens from nonce=2 claim"
        );

        // ── Verify double-claim for User A reverts (already claimed above) ──
        bytes32[32] memory proofA2 = _zeroProof();
        proofA2[0] = leafB.hashed;

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, token, leafA.index));
        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leafA.index,
                    beneficiary: leafA.beneficiary,
                    projectTokenCount: leafA.projectTokenCount,
                    terminalTokenAmount: leafA.terminalTokenAmount
                }),
                proof: proofA2
            })
        );
    }
}
