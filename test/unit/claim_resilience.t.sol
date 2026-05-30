// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
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
        JBSucker(directory, permissions, IJBPrices(address(1)), tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
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
    function _sendRootOverAMB(uint256, uint256, address, uint256, JBRemoteToken memory, JBMessageRoot memory)
        internal
        override
    {}

    function _isRemotePeer(address sender) internal view override returns (bool valid) {
        return sender == _toAddress(peer());
    }

    function peerChainId() external view override returns (uint256) {
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

        ResilienceTestSucker singleton =
            new ResilienceTestSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER);
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
