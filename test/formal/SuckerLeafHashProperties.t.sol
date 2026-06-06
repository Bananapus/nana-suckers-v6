// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @notice A faithful, standalone mirror of `JBSucker._buildTreeHash`.
/// @dev `_buildTreeHash` is `internal pure` on the abstract `JBSucker`; constructing a concrete sucker for symbolic
/// execution drags in the whole controller/directory/permissions constructor graph, which Halmos cannot keep tractable.
/// Instead this harness copies the production assembly verbatim. `testFuzz_mirrorMatchesProductionSucker` (in
/// `test/InteropCompat.t.sol`'s spirit) is NOT re-run here, but the mirror is byte-for-byte identical to
/// `JBSucker.sol:1691-1697`, and `check_buildTreeHashEqualsEncodePacked` proves the mirror equals the canonical
/// `keccak256(abi.encodePacked(...))` pre-image that downstream consumers (e.g. `JBReferralSplitHook.claimAndPush`)
/// re-derive. This is the load-bearing front-run-defense equivalence documented in the
/// `jb-sucker-claim-front-run-defense` skill: the per-leaf hash must equal exactly
/// `keccak256(abi.encodePacked(projectTokenCount, terminalTokenAmount,
/// beneficiary, metadata))` so a beneficiary contract can authenticate a (possibly front-run) settlement.
library LeafHashMirror {
    /// @notice Mirror of `JBSucker._buildTreeHash` (production assembly copied verbatim).
    function buildTreeHash(
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        bytes32 metadata
    )
        internal
        pure
        returns (bytes32 hash)
    {
        // forge-lint: disable-next-line(asm-keccak256)
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, projectTokenCount)
            mstore(add(ptr, 0x20), terminalTokenAmount)
            mstore(add(ptr, 0x40), beneficiary)
            mstore(add(ptr, 0x60), metadata)
            hash := keccak256(ptr, 0x80)
        }
    }
}

/// @notice Symbolic + fuzz proofs for the sucker's leaf-hash and merkle-proof primitives.
/// @dev Dual-implemented per the repo's house convention (`check_*` for Halmos, `testFuzz_*` for forge), following
/// `nana-core-v6/test/formal/FeeProperties.t.sol`.
contract SuckerLeafHashProperties is Test {
    /// @notice The merkle tree depth (32) used by every sucker proof.
    uint256 internal constant _TREE_DEPTH = 32;

    // ------------------------------------------------------------------ //
    // Property 1: leaf hash == keccak256(abi.encodePacked(...))           //
    // ------------------------------------------------------------------ //
    // The four 32-byte fields are packed left-aligned, so `abi.encodePacked` and the production assembly's free-memory
    // write produce identical pre-images. Halmos models keccak as an uninterpreted function applied to the SAME
    // 128-byte pre-image on both sides, so this equivalence is provable symbolically.

    /// @notice [HALMOS] The production-mirror leaf hash equals the canonical encodePacked pre-image hash.
    function check_buildTreeHashEqualsEncodePacked(
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        bytes32 metadata
    )
        public
        pure
    {
        bytes32 produced = LeafHashMirror.buildTreeHash({
            projectTokenCount: projectTokenCount,
            terminalTokenAmount: terminalTokenAmount,
            beneficiary: beneficiary,
            metadata: metadata
        });

        bytes32 canonical = keccak256(abi.encodePacked(projectTokenCount, terminalTokenAmount, beneficiary, metadata));

        assert(produced == canonical);
    }

    /// @notice [FUZZ] Same equivalence, fuzzed over concrete keccak.
    function testFuzz_buildTreeHashEqualsEncodePacked(
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        bytes32 metadata
    )
        public
        pure
    {
        bytes32 produced = LeafHashMirror.buildTreeHash({
            projectTokenCount: projectTokenCount,
            terminalTokenAmount: terminalTokenAmount,
            beneficiary: beneficiary,
            metadata: metadata
        });

        bytes32 canonical = keccak256(abi.encodePacked(projectTokenCount, terminalTokenAmount, beneficiary, metadata));

        assertEq(produced, canonical, "leaf hash must equal keccak256(abi.encodePacked(...))");
    }

    // ------------------------------------------------------------------ //
    // Property 2: determinism                                            //
    // ------------------------------------------------------------------ //

    /// @notice [HALMOS] Hashing the same leaf twice yields the same hash (pure determinism).
    function check_buildTreeHashDeterministic(
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        bytes32 metadata
    )
        public
        pure
    {
        bytes32 a = LeafHashMirror.buildTreeHash(projectTokenCount, terminalTokenAmount, beneficiary, metadata);
        bytes32 b = LeafHashMirror.buildTreeHash(projectTokenCount, terminalTokenAmount, beneficiary, metadata);
        assert(a == b);
    }

    // ------------------------------------------------------------------ //
    // Property 3: field isolation / order sensitivity (injectivity)      //
    // ------------------------------------------------------------------ //
    // Each of the four fields independently changes the hash, and field order matters (swapping count<->amount
    // changes the hash unless they are equal). Keccak injectivity is not provable in the SMT model, so this is FUZZ
    // only. This is the property that defends `executedLeafHashOf` against a front-running attacker reshaping a leaf.

    /// @notice [FUZZ] Changing the project token count changes the leaf hash.
    function testFuzz_countFieldIsolated(
        uint256 count,
        uint256 amount,
        bytes32 beneficiary,
        bytes32 metadata,
        uint256 count2
    )
        public
        pure
    {
        vm.assume(count != count2);
        bytes32 a = LeafHashMirror.buildTreeHash(count, amount, beneficiary, metadata);
        bytes32 b = LeafHashMirror.buildTreeHash(count2, amount, beneficiary, metadata);
        assertTrue(a != b, "count must affect leaf hash");
    }

    /// @notice [FUZZ] Changing the terminal token amount changes the leaf hash.
    function testFuzz_amountFieldIsolated(
        uint256 count,
        uint256 amount,
        bytes32 beneficiary,
        bytes32 metadata,
        uint256 amount2
    )
        public
        pure
    {
        vm.assume(amount != amount2);
        bytes32 a = LeafHashMirror.buildTreeHash(count, amount, beneficiary, metadata);
        bytes32 b = LeafHashMirror.buildTreeHash(count, amount2, beneficiary, metadata);
        assertTrue(a != b, "amount must affect leaf hash");
    }

    /// @notice [FUZZ] Changing the beneficiary changes the leaf hash (a front-runner cannot redirect funds).
    function testFuzz_beneficiaryFieldIsolated(
        uint256 count,
        uint256 amount,
        bytes32 beneficiary,
        bytes32 metadata,
        bytes32 beneficiary2
    )
        public
        pure
    {
        vm.assume(beneficiary != beneficiary2);
        bytes32 a = LeafHashMirror.buildTreeHash(count, amount, beneficiary, metadata);
        bytes32 b = LeafHashMirror.buildTreeHash(count, amount, beneficiary2, metadata);
        assertTrue(a != b, "beneficiary must affect leaf hash");
    }

    /// @notice [FUZZ] Changing the attribution metadata changes the leaf hash.
    function testFuzz_metadataFieldIsolated(
        uint256 count,
        uint256 amount,
        bytes32 beneficiary,
        bytes32 metadata,
        bytes32 metadata2
    )
        public
        pure
    {
        vm.assume(metadata != metadata2);
        bytes32 a = LeafHashMirror.buildTreeHash(count, amount, beneficiary, metadata);
        bytes32 b = LeafHashMirror.buildTreeHash(count, amount, beneficiary, metadata2);
        assertTrue(a != b, "metadata must affect leaf hash");
    }

    /// @notice [FUZZ] Field order matters: swapping count and amount changes the hash unless they are equal.
    function testFuzz_fieldOrderSensitive(
        uint256 count,
        uint256 amount,
        bytes32 beneficiary,
        bytes32 metadata
    )
        public
        pure
    {
        vm.assume(count != amount);
        bytes32 a = LeafHashMirror.buildTreeHash(count, amount, beneficiary, metadata);
        bytes32 b = LeafHashMirror.buildTreeHash(amount, count, beneficiary, metadata);
        assertTrue(a != b, "field order must be significant");
    }

    // ------------------------------------------------------------------ //
    // Property 4: computeBranchRoot determinism + reference parity        //
    // ------------------------------------------------------------------ //
    // `JBSuckerLibHalmos` already proves `computeBranchRoot` against a readable reference for FIXED indices (0, 1, 2,
    // MAX). The symbolic index domain is intractable for Halmos (assembly memory offsets derived from index bits), so
    // here we fuzz arbitrary indices against the same reference — this is the verification of choice for the heavy
    // branch.

    /// @notice [FUZZ] `computeBranchRoot` matches a readable reference implementation for arbitrary index.
    function testFuzz_branchRootMatchesReference(bytes32 item, bytes32[32] memory branch, uint256 index) public pure {
        bytes32 optimized = JBSuckerLib.computeBranchRoot({item: item, branch: branch, index: index});
        bytes32 expected = _referenceBranchRoot({item: item, branch: branch, index: index});
        assertEq(optimized, expected, "branchRoot mismatch vs reference");
    }

    /// @notice [FUZZ] `computeBranchRoot` ignores index bits at or above the tree depth (only the low 32 bits matter).
    /// @dev The 32-level proof only consults bits 0..31 of `index`; setting any higher bit must not change the root.
    /// This is what makes the `_validate` index-bounds check (`index < 2^32`) the sole gate against out-of-range
    /// leaves.
    function testFuzz_branchRootIgnoresHighIndexBits(
        bytes32 item,
        bytes32[32] memory branch,
        uint256 lowIndex,
        uint256 highBits
    )
        public
        pure
    {
        uint256 low = lowIndex & ((uint256(1) << _TREE_DEPTH) - 1);
        // Force `highBits` to occupy only bits >= 32.
        uint256 high = low | (highBits << _TREE_DEPTH);

        bytes32 a = JBSuckerLib.computeBranchRoot({item: item, branch: branch, index: low});
        bytes32 b = JBSuckerLib.computeBranchRoot({item: item, branch: branch, index: high});
        assertEq(a, b, "branchRoot must depend only on low 32 index bits");
    }

    /// @notice Readable reference for a claim-proof root, mirroring `JBSuckerLibHalmos._referenceBranchRoot`.
    function _referenceBranchRoot(
        bytes32 item,
        bytes32[32] memory branch,
        uint256 index
    )
        internal
        pure
        returns (bytes32 current)
    {
        current = item;
        for (uint256 i; i < MerkleLib.TREE_DEPTH;) {
            if (index & (uint256(1) << i) == 0) {
                current = keccak256(abi.encodePacked(current, branch[i]));
            } else {
                current = keccak256(abi.encodePacked(branch[i], current));
            }
            unchecked {
                ++i;
            }
        }
    }
}
