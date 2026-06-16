// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBSucker.sol";
import {JBLeaf} from "../../src/structs/JBLeaf.sol";
import {JBClaim} from "../../src/structs/JBClaim.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBChainAccounting} from "../../src/structs/JBChainAccounting.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @dev Minimal mock directory that returns a mock PROJECTS address.
contract MockDirectory {
    address public projectsAddr;

    constructor(address _projects) {
        projectsAddr = _projects;
    }

    function PROJECTS() external view returns (IJBProjects) {
        return IJBProjects(projectsAddr);
    }
}

//*********************************************************************//
// ---------------- STEP 2: batch claim resilience ------------------- //
//*********************************************************************//

/// @notice A test sucker whose merkle check and add-to-balance are controllable, mirroring `emergency.t.sol`'s
/// `TestSucker`. It lets us force a specific leaf's `claim` to revert (stale/bad leaf) while letting others pass,
/// so we can prove batch resilience without constructing real merkle proofs.
contract ResilienceTestSucker is JBSucker {
    using BitMaps for BitMaps.BitMap;

    /// @notice If the leaf hash is in this set, its `_validateBranchRoot` reverts (simulating a stale/bad leaf).
    mapping(bytes32 leafHash => bool) public shouldRejectLeaf;

    /// @notice If true, the next `mintTokensOf` path is allowed; otherwise we simulate a transient mint failure.
    mapping(bytes32 leafHash => bool) public shouldRevertMint;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
    {}

    function test_setInboxRoot(address token, bytes32 root) external {
        _inboxOf[token] = JBInboxTreeRoot({nonce: 1, root: root});
    }

    function test_setRejectLeaf(bytes32 leafHash, bool reject) external {
        shouldRejectLeaf[leafHash] = reject;
    }

    function test_setRevertMint(bytes32 leafHash, bool revertMint) external {
        shouldRevertMint[leafHash] = revertMint;
    }

    function test_isExecuted(address token, uint256 index) external view returns (bool) {
        return _executedFor[token].get(index);
    }

    function leafHashFor(JBLeaf calldata leaf) external pure returns (bytes32) {
        return _buildTreeHash(leaf.projectTokenCount, leaf.terminalTokenAmount, leaf.beneficiary, leaf.metadata);
    }

    // forge-lint: disable-next-line(mixed-case-function)
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

    function _isRemotePeer(address sender) internal view override returns (bool valid) {
        return sender == _toAddress(peer());
    }

    function peerChainId() public view override returns (uint256) {
        return block.chainid;
    }

    /// @dev Force a chosen leaf to fail the merkle check; otherwise accept.
    function _validateBranchRoot(
        bytes32 expectedRoot,
        bytes32 leafHash,
        uint256, /* index */
        bytes32[_TREE_DEPTH] calldata /* leaves */
    )
        internal
        view
        override
    {
        // A bad/stale leaf reverts here exactly as a genuine proof mismatch would.
        if (shouldRejectLeaf[leafHash]) {
            revert JBSucker_InvalidProof({root: bytes32(0), inboxRoot: expectedRoot});
        }
        // Simulate a downstream/transient revert (e.g. mint) for a chosen leaf.
        if (shouldRevertMint[leafHash]) {
            revert("transient mint failure");
        }
    }

    /// @dev No-op add-to-balance: these tests focus on the resilience control flow, not balance mechanics.
    function _addToBalance(address, uint256, uint256) internal override {}
}

contract BatchClaimResilienceTest is Test {
    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);

    uint256 constant PROJECT_ID = 1;

    ResilienceTestSucker sucker;

    function setUp() public {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));

        ResilienceTestSucker singleton = new ResilienceTestSucker(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER
        );
        sucker = ResilienceTestSucker(payable(address(LibClone.cloneDeterministic(address(singleton), bytes32(0)))));
        sucker.initialize(PROJECT_ID);

        // Mint mock for the controller — minting always succeeds at the controller level.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(CONTROLLER, abi.encodeWithSelector(IJBController.mintTokensOf.selector), abi.encode(uint256(0)));

        // A non-zero inbox root so the (no-op) merkle check has something to validate against.
        sucker.test_setInboxRoot(JBConstants.NATIVE_TOKEN, bytes32(uint256(0xABCD)));
    }

    function _leaf(uint256 index, address beneficiary, uint256 amount) internal pure returns (JBLeaf memory) {
        return JBLeaf({
            index: index,
            beneficiary: bytes32(uint256(uint160(beneficiary))),
            projectTokenCount: amount,
            terminalTokenAmount: amount,
            metadata: bytes32(0)
        });
    }

    function _claim(JBLeaf memory leaf) internal pure returns (JBClaim memory) {
        bytes32[32] memory proof;
        return JBClaim({token: JBConstants.NATIVE_TOKEN, leaf: leaf, proof: proof});
    }

    /// @notice A batch with one stale/bad leaf in the middle still claims the good leaves, and the bad leaf remains
    /// claimable later (once its proof/root is fixed).
    function test_batchSkipsBadLeafAndClaimsGood() external {
        JBLeaf memory good0 = _leaf(0, address(0x111), 1 ether);
        JBLeaf memory bad1 = _leaf(1, address(0x222), 2 ether);
        JBLeaf memory good2 = _leaf(2, address(0x333), 3 ether);

        // Mark the middle leaf as failing its merkle check (stale/wrong proof).
        bytes32 badHash = sucker.leafHashFor(bad1);
        sucker.test_setRejectLeaf(badHash, true);

        JBClaim[] memory claims = new JBClaim[](3);
        claims[0] = _claim(good0);
        claims[1] = _claim(bad1);
        claims[2] = _claim(good2);

        // Expect a ClaimFailed event for the bad leaf (token + index), batch must not revert.
        vm.expectEmit(true, false, false, true, address(sucker));
        emit IJBSucker.ClaimFailed(JBConstants.NATIVE_TOKEN, 1, address(this));

        sucker.claim(claims);

        // Good leaves executed; bad leaf NOT executed (its sub-call reverted atomically).
        assertTrue(sucker.test_isExecuted(JBConstants.NATIVE_TOKEN, 0), "good leaf 0 should be executed");
        assertFalse(sucker.test_isExecuted(JBConstants.NATIVE_TOKEN, 1), "bad leaf 1 must remain unexecuted");
        assertTrue(sucker.test_isExecuted(JBConstants.NATIVE_TOKEN, 2), "good leaf 2 should be executed");
        // No persisted leaf hash for the failed leaf — proof that the reverted sub-call rolled back all state.
        assertEq(
            sucker.executedLeafHashOf(JBConstants.NATIVE_TOKEN, 1), bytes32(0), "failed leaf must persist no state"
        );

        // The bad leaf becomes claimable once its proof/root is corrected (stop rejecting it).
        sucker.test_setRejectLeaf(badHash, false);
        JBClaim[] memory retry = new JBClaim[](1);
        retry[0] = _claim(bad1);
        sucker.claim(retry);
        assertTrue(sucker.test_isExecuted(JBConstants.NATIVE_TOKEN, 1), "previously-failed leaf now claimable");
    }

    /// @notice A transient downstream failure (e.g. mint/add-to-balance revert) on one leaf is also isolated and the
    /// leaf stays claimable once the dependency recovers.
    function test_batchSkipsTransientFailureAndClaimsGood() external {
        JBLeaf memory good0 = _leaf(0, address(0x111), 1 ether);
        JBLeaf memory transient1 = _leaf(1, address(0x222), 2 ether);

        bytes32 tHash = sucker.leafHashFor(transient1);
        sucker.test_setRevertMint(tHash, true);

        JBClaim[] memory claims = new JBClaim[](2);
        claims[0] = _claim(good0);
        claims[1] = _claim(transient1);

        sucker.claim(claims);

        assertTrue(sucker.test_isExecuted(JBConstants.NATIVE_TOKEN, 0), "good leaf executed");
        assertFalse(sucker.test_isExecuted(JBConstants.NATIVE_TOKEN, 1), "transient-fail leaf unexecuted");

        // Dependency recovers; leaf now claims.
        sucker.test_setRevertMint(tHash, false);
        JBClaim[] memory retry = new JBClaim[](1);
        retry[0] = _claim(transient1);
        sucker.claim(retry);
        assertTrue(sucker.test_isExecuted(JBConstants.NATIVE_TOKEN, 1), "recovered leaf now claimable");
    }

    /// @notice An already-executed leaf included again in a batch is skipped (not reverting the batch), and other
    /// leaves still claim.
    function test_batchSkipsAlreadyExecutedLeaf() external {
        JBLeaf memory leaf0 = _leaf(0, address(0x111), 1 ether);
        JBLeaf memory leaf1 = _leaf(1, address(0x222), 2 ether);

        // Execute leaf0 first.
        JBClaim[] memory first = new JBClaim[](1);
        first[0] = _claim(leaf0);
        sucker.claim(first);
        assertTrue(sucker.test_isExecuted(JBConstants.NATIVE_TOKEN, 0));

        // Now a batch that re-includes the executed leaf0 plus a fresh leaf1.
        JBClaim[] memory batch = new JBClaim[](2);
        batch[0] = _claim(leaf0); // already executed -> should be skipped
        batch[1] = _claim(leaf1);

        vm.expectEmit(true, false, false, true, address(sucker));
        emit IJBSucker.ClaimFailed(JBConstants.NATIVE_TOKEN, 0, address(this));

        sucker.claim(batch);

        assertTrue(sucker.test_isExecuted(JBConstants.NATIVE_TOKEN, 1), "fresh leaf1 claimed despite duplicate leaf0");
    }

    /// @notice Sanity: the single-leaf `claim` still reverts on a bad leaf (resilience lives only in the batch path).
    function test_singleClaimStillRevertsOnBadLeaf() external {
        JBLeaf memory bad = _leaf(5, address(0x999), 1 ether);
        sucker.test_setRejectLeaf(sucker.leafHashFor(bad), true);

        vm.expectRevert();
        sucker.claim(_claim(bad));
    }
}

//*********************************************************************//
// ----------------- STEP 3: inbox root ring ------------------------- //
//*********************************************************************//

/// @notice A test sucker that extends `JBSucker` directly and uses the REAL merkle library, so we can drive genuine
/// roots through `fromRemote` and prove that proofs against a recent-but-superseded root still validate (the ring),
/// while double-spend remains blocked. Mirrors `merkle.t.sol`'s `MerkleUnitTest` harness.
contract RingTestSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    address public immutable PEER_ADDR;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address peerAddr
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(this)), address(0))
    {
        PEER_ADDR = peerAddr;
    }

    function buildLeaf(uint256 ptc, uint256 tta, bytes32 beneficiary, bytes32 metadata)
        external
        pure
        returns (bytes32)
    {
        return _buildTreeHash(ptc, tta, beneficiary, metadata);
    }

    function inboxRootRingOf(address token, uint256 i) external view returns (bytes32) {
        return _inboxRootRingOf[token][i];
    }

    function inboxRootRingCursorOf(address token) external view returns (uint256) {
        return _inboxRootRingCursorOf[token];
    }

    function isExecuted(address token, uint256 index) external view returns (bool) {
        return _executedFor[token].get(index);
    }

    function _isRemotePeer(address sender) internal view override returns (bool valid) {
        return sender == PEER_ADDR;
    }

    function peerChainId() public view override returns (uint256) {
        return block.chainid;
    }

    // forge-lint: disable-next-line(mixed-case-function)
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

    /// @dev No-op add-to-balance: ring tests focus on proof validation across roots, not balance mechanics.
    function _addToBalance(address, uint256, uint256) internal override {}
}

/// @notice A helper that builds an incremental merkle tree off-chain (in test memory) so we can compute genuine roots
/// and branch proofs for arbitrary leaf sets, matching the on-chain `MerkleLib` construction exactly.
contract MerkleTreeBuilder is Test {
    bytes32[][] internal _layers; // layer 0 = leaves

    function _zHash(uint256 level) internal pure returns (bytes32) {
        // Empty-subtree hashes, same as MerkleLib Z_i.
        bytes32 z = bytes32(0);
        for (uint256 i; i < level; ++i) {
            z = keccak256(abi.encodePacked(z, z));
        }
        return z;
    }

    /// @notice Compute the merkle root of `leaves` for a depth-32 tree (matching MerkleLib).
    function rootOf(bytes32[] memory leaves) public pure returns (bytes32) {
        bytes32 node;
        uint256 count = leaves.length;
        // Build level by level.
        bytes32[] memory current = leaves;
        for (uint256 level; level < 32; ++level) {
            uint256 n = current.length;
            uint256 parentCount = (n + 1) / 2;
            bytes32[] memory next = new bytes32[](parentCount == 0 ? 1 : parentCount);
            bytes32 zAtLevel = _zHashPure(level);
            if (n == 0) {
                // All-empty subtree at this level.
                next[0] = _zHashPure(level + 1);
                current = next;
                continue;
            }
            for (uint256 i; i < parentCount; ++i) {
                bytes32 left = current[2 * i];
                bytes32 right = (2 * i + 1 < n) ? current[2 * i + 1] : zAtLevel;
                next[i] = keccak256(abi.encodePacked(left, right));
            }
            current = next;
        }
        node = current[0];
        count;
        return node;
    }

    /// @notice Compute the branch proof (siblings) for `index` over `leaves`, padded with z-hashes to depth 32.
    function proofOf(bytes32[] memory leaves, uint256 index) public pure returns (bytes32[32] memory proof) {
        bytes32[] memory current = leaves;
        uint256 idx = index;
        for (uint256 level; level < 32; ++level) {
            uint256 n = current.length;
            bytes32 zAtLevel = _zHashPure(level);
            uint256 siblingIdx = idx ^ 1;
            bytes32 sibling;
            if (siblingIdx < n) {
                sibling = current[siblingIdx];
            } else {
                sibling = zAtLevel;
            }
            proof[level] = sibling;

            // Build next layer.
            uint256 parentCount = (n + 1) / 2;
            if (parentCount == 0) parentCount = 1;
            bytes32[] memory next = new bytes32[](parentCount);
            for (uint256 i; i < parentCount; ++i) {
                bytes32 left = (2 * i < n) ? current[2 * i] : zAtLevel;
                bytes32 right = (2 * i + 1 < n) ? current[2 * i + 1] : zAtLevel;
                next[i] = keccak256(abi.encodePacked(left, right));
            }
            current = next;
            idx = idx / 2;
        }
    }

    function _zHashPure(uint256 level) internal pure returns (bytes32) {
        bytes32 z = bytes32(0);
        for (uint256 i; i < level; ++i) {
            z = keccak256(abi.encodePacked(z, z));
        }
        return z;
    }
}

contract InboxRootRingTest is Test {
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);

    uint256 constant PROJECT_ID = 1;

    RingTestSucker sucker;
    address peer;
    address directory;
    MerkleTreeBuilder builder;

    function setUp() public {
        builder = new MerkleTreeBuilder();
        directory = address(new MockDirectory(PROJECT));

        // The peer is the deterministic same-address peer (the clone's own address). We deploy via clone so peer()
        // returns the clone address; we set _isRemotePeer to compare against PEER_ADDR which we pass = clone addr.
        // Simpler: deploy the singleton, predict the clone addr is the singleton path; instead we use a fixed peer.
        peer = address(0xBEEF);

        RingTestSucker singleton =
            new RingTestSucker(IJBDirectory(directory), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), peer);
        sucker = RingTestSucker(payable(address(LibClone.cloneDeterministic(address(singleton), bytes32(0)))));
        sucker.initialize(PROJECT_ID);

        // Mint mock: minting succeeds.
        vm.mockCall(directory, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(CONTROLLER, abi.encodeWithSelector(IJBController.mintTokensOf.selector), abi.encode(uint256(0)));
    }

    function _msgRoot(bytes32 root, uint64 nonce, uint256) internal pure returns (JBMessageRoot memory) {
        return JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: root}),
            accounts: new JBChainAccounting[](0)
        });
    }

    function _leafHash(uint256 ptc, uint256 tta, address beneficiary) internal view returns (bytes32) {
        return sucker.buildLeaf(ptc, tta, bytes32(uint256(uint160(beneficiary))), bytes32(0));
    }

    function _claim(
        uint256 index,
        uint256 ptc,
        uint256 tta,
        address beneficiary,
        bytes32[32] memory proof
    )
        internal
        pure
        returns (JBClaim memory)
    {
        return JBClaim({
            token: JBConstants.NATIVE_TOKEN,
            leaf: JBLeaf({
                index: index,
                beneficiary: bytes32(uint256(uint160(beneficiary))),
                projectTokenCount: ptc,
                terminalTokenAmount: tta,
                metadata: bytes32(0)
            }),
            proof: proof
        });
    }

    /// @notice (a) A proof generated against root N still validates after a later `fromRemote` advances the inbox to
    /// root N+1 (within the ring).
    function test_proofAgainstOlderRootStillValidatesWithinRing() external {
        // Tree N: a single leaf at index 0.
        bytes32 leaf0 = _leafHash(1 ether, 1 ether, address(0x111));
        bytes32[] memory treeN = new bytes32[](1);
        treeN[0] = leaf0;
        bytes32 rootN = builder.rootOf(treeN);
        bytes32[32] memory proof0 = builder.proofOf(treeN, 0);

        // Deliver root N (nonce 1) via the real fromRemote path.
        vm.prank(peer);
        sucker.fromRemote(_msgRoot(rootN, 1, 100));

        // The cumulative tree grows: index 1 added, producing root N+1.
        bytes32 leaf1 = _leafHash(2 ether, 2 ether, address(0x222));
        bytes32[] memory treeN1 = new bytes32[](2);
        treeN1[0] = leaf0;
        treeN1[1] = leaf1;
        bytes32 rootN1 = builder.rootOf(treeN1);

        // Deliver root N+1 (nonce 2).
        vm.prank(peer);
        sucker.fromRemote(_msgRoot(rootN1, 2, 101));

        // Latest inbox root is now N+1.
        assertEq(sucker.inboxOf(JBConstants.NATIVE_TOKEN).root, rootN1, "latest root advanced to N+1");

        // The OLD proof (against root N) for leaf0 must still validate, because root N is retained in the ring.
        // (Note: the leaf's index/hash are unchanged across roots; only its proof differs.)
        sucker.claim(_claim(0, 1 ether, 1 ether, address(0x111), proof0));
        assertTrue(sucker.isExecuted(JBConstants.NATIVE_TOKEN, 0), "leaf0 claimed via retained older root N");
    }

    /// @notice A leaf can also be claimed via the latest root using a current proof.
    function test_proofAgainstLatestRootValidates() external {
        bytes32 leaf0 = _leafHash(1 ether, 1 ether, address(0x111));
        bytes32 leaf1 = _leafHash(2 ether, 2 ether, address(0x222));
        bytes32[] memory treeN1 = new bytes32[](2);
        treeN1[0] = leaf0;
        treeN1[1] = leaf1;
        bytes32 rootN1 = builder.rootOf(treeN1);

        vm.prank(peer);
        sucker.fromRemote(_msgRoot(rootN1, 1, 100));

        // Current proof for leaf1 against the latest root.
        bytes32[32] memory proof1 = builder.proofOf(treeN1, 1);
        sucker.claim(_claim(1, 2 ether, 2 ether, address(0x222), proof1));
        assertTrue(sucker.isExecuted(JBConstants.NATIVE_TOKEN, 1), "leaf1 claimed via latest root");
    }

    /// @notice (b) NO double-spend: a leaf executed via one retained root cannot be re-executed via another retained
    /// root. The `_executedFor` guard is keyed by leaf index, independent of which retained root validated it.
    function test_noDoubleSpendAcrossRetainedRoots() external {
        // Root N: leaf0 only.
        bytes32 leaf0 = _leafHash(1 ether, 1 ether, address(0x111));
        bytes32[] memory treeN = new bytes32[](1);
        treeN[0] = leaf0;
        bytes32 rootN = builder.rootOf(treeN);
        bytes32[32] memory proofN_0 = builder.proofOf(treeN, 0);

        vm.prank(peer);
        sucker.fromRemote(_msgRoot(rootN, 1, 100));

        // Root N+1: leaf0 + leaf1. leaf0 keeps index 0 but its proof changes.
        bytes32 leaf1 = _leafHash(2 ether, 2 ether, address(0x222));
        bytes32[] memory treeN1 = new bytes32[](2);
        treeN1[0] = leaf0;
        treeN1[1] = leaf1;
        bytes32 rootN1 = builder.rootOf(treeN1);
        bytes32[32] memory proofN1_0 = builder.proofOf(treeN1, 0);

        vm.prank(peer);
        sucker.fromRemote(_msgRoot(rootN1, 2, 101));

        // Both roots are retained in the ring.
        // First execution: claim leaf0 via the OLD root N proof.
        sucker.claim(_claim(0, 1 ether, 1 ether, address(0x111), proofN_0));
        assertTrue(sucker.isExecuted(JBConstants.NATIVE_TOKEN, 0), "leaf0 executed once via root N");

        // Second execution attempt: same leaf0 via the NEWER root N+1 proof MUST revert (already executed).
        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, JBConstants.NATIVE_TOKEN, 0)
        );
        sucker.claim(_claim(0, 1 ether, 1 ether, address(0x111), proofN1_0));
    }

    /// @notice A proof against a root that has been evicted from the ring (older than the last `_INBOX_ROOT_RING_SIZE`
    /// distinct roots) no longer validates — bounding the acceptance window.
    function test_proofAgainstEvictedRootFails() external {
        // Build 5 successive cumulative roots; the ring holds only 4. Root #1 should be evicted.
        bytes32 l0 = _leafHash(1 ether, 1 ether, address(0x111));
        bytes32[] memory t1 = new bytes32[](1);
        t1[0] = l0;
        bytes32 r1 = builder.rootOf(t1);
        bytes32[32] memory proof_r1_l0 = builder.proofOf(t1, 0);

        vm.prank(peer);
        sucker.fromRemote(_msgRoot(r1, 1, 100));

        // Add 4 more leaves -> 4 more distinct roots (r2..r5). After r5, the ring contains r2,r3,r4,r5; r1 is evicted.
        bytes32[] memory leaves = new bytes32[](5);
        leaves[0] = l0;
        for (uint256 k = 1; k <= 4; ++k) {
            // forge-lint: disable-next-line(unsafe-typecast)
            leaves[k] = _leafHash((k + 1) * 1 ether, (k + 1) * 1 ether, address(uint160(0x100 + k)));
            bytes32[] memory sub = new bytes32[](k + 1);
            for (uint256 j; j <= k; ++j) {
                sub[j] = leaves[j];
            }
            bytes32 rk = builder.rootOf(sub);
            vm.prank(peer);
            // forge-lint: disable-next-line(unsafe-typecast)
            sucker.fromRemote(_msgRoot(rk, uint64(k + 1), 100 + k));
        }

        // r1 is now evicted. The old proof for leaf0 against r1 must NOT validate.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSucker.JBSucker_InvalidProof.selector, r1, sucker.inboxOf(JBConstants.NATIVE_TOKEN).root
            )
        );
        sucker.claim(_claim(0, 1 ether, 1 ether, address(0x111), proof_r1_l0));

        // But leaf0 is still claimable via a current (root r5) proof.
        bytes32[] memory full = leaves;
        bytes32[32] memory proof_r5_l0 = builder.proofOf(full, 0);
        sucker.claim(_claim(0, 1 ether, 1 ether, address(0x111), proof_r5_l0));
        assertTrue(sucker.isExecuted(JBConstants.NATIVE_TOKEN, 0), "leaf0 still claimable via current root");
    }

    /// @notice The ring stores roots and advances its cursor as expected.
    function test_ringPopulationAndCursor() external {
        bytes32 l0 = _leafHash(1 ether, 1 ether, address(0x111));
        bytes32[] memory t1 = new bytes32[](1);
        t1[0] = l0;
        bytes32 r1 = builder.rootOf(t1);

        // First accepted root goes to slot 1 (cursor pre-increment from 0).
        vm.prank(peer);
        sucker.fromRemote(_msgRoot(r1, 1, 100));
        assertEq(sucker.inboxRootRingCursorOf(JBConstants.NATIVE_TOKEN), 1, "cursor at 1 after first root");
        assertEq(sucker.inboxRootRingOf(JBConstants.NATIVE_TOKEN, 1), r1, "root stored at slot 1");

        // A stale (non-increasing nonce) root does NOT advance the ring.
        vm.prank(peer);
        sucker.fromRemote(_msgRoot(r1, 1, 100));
        assertEq(sucker.inboxRootRingCursorOf(JBConstants.NATIVE_TOKEN), 1, "stale root must not advance ring");
    }
}
