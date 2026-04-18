// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";
import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";

/// @notice Proves computeTreeRoot ≡ MerkleLib.root() for every tree state after 0..N inserts.
/// Also proves computeBranchRoot ≡ MerkleLib.branchRoot().
contract MerkleEquivalenceTest is Test {
    using MerkleLib for MerkleLib.Tree;

    MerkleLib.Tree internal _tree;

    // ------- computeTreeRoot equivalence ------- //

    /// @dev Empty tree: both must return Z_32.
    function test_equivalence_emptyTree() public view {
        bytes32 original = _tree.root();
        bytes32[32] memory branch;
        bytes32 replacement = JBSuckerLib.computeTreeRoot(branch, 0);
        assertEq(original, replacement, "empty tree mismatch");
        assertEq(original, MerkleLib.Z_32, "empty tree should be Z_32");
    }

    /// @dev Insert 1..64 leaves, checking equivalence after each insert.
    function test_equivalence_sequential_1_to_64() public {
        for (uint256 n = 1; n <= 64; n++) {
            bytes32 leaf = keccak256(abi.encodePacked("leaf", n));
            _tree.insert(leaf);
            _assertRootEquivalence(n);
        }
    }

    /// @dev Powers of 2 are important edge cases (all branch slots filled at that level).
    function test_equivalence_powersOfTwo() public {
        // Insert up to 128 leaves, check at powers of 2.
        for (uint256 n = 1; n <= 128; n++) {
            _tree.insert(keccak256(abi.encodePacked("pow2leaf", n)));
            // Check at every power of 2 and power-of-2 ± 1.
            if (_isPowerOfTwo(n) || _isPowerOfTwo(n + 1) || (n > 1 && _isPowerOfTwo(n - 1))) {
                _assertRootEquivalence(n);
            }
        }
    }

    /// @dev Single leaf.
    function test_equivalence_singleLeaf() public {
        _tree.insert(bytes32(uint256(0xdead)));
        _assertRootEquivalence(1);
    }

    /// @dev Fuzz test: insert up to 200 leaves with random data, check after each.
    function test_fuzz_equivalence(uint256 seed) public {
        uint256 count = (seed % 200) + 1;
        for (uint256 i = 1; i <= count; i++) {
            _tree.insert(keccak256(abi.encodePacked(seed, i)));
        }
        _assertRootEquivalence(count);
    }

    /// @dev Selective copy optimization: only copy branch[i] where bit i is set.
    ///      Mirrors _computeOutboxRoot in JBSucker.sol.
    function test_equivalence_selectiveCopy() public {
        // Insert 42 leaves (binary: 101010 — bits 1, 3, 5 set).
        for (uint256 n = 1; n <= 42; n++) {
            _tree.insert(keccak256(abi.encodePacked("sel", n)));
        }

        bytes32 original = _tree.root();

        // Selective copy — only load branch[i] where bit i is set in count.
        uint256 count = _tree.count;
        bytes32[32] memory branch;
        for (uint256 i; i < 32; i++) {
            if (count & (1 << i) != 0) {
                branch[i] = _tree.branch[i];
            }
            // Other slots stay bytes32(0) — computeTreeRoot must handle this.
        }

        bytes32 replacement = JBSuckerLib.computeTreeRoot(branch, count);
        assertEq(original, replacement, "selective copy mismatch at count=42");
    }

    // ------- computeBranchRoot equivalence ------- //

    /// @dev For each leaf inserted, verify computeBranchRoot matches MerkleLib.branchRoot.
    function test_branchRoot_equivalence() public pure {
        bytes32[32] memory branch;
        for (uint256 n = 0; n < 32; n++) {
            branch[n] = keccak256(abi.encodePacked("branch", n));
        }
        bytes32 item = keccak256("item");

        for (uint256 idx = 0; idx < 64; idx++) {
            bytes32 original = MerkleLib.branchRoot(item, branch, idx);
            bytes32 replacement = JBSuckerLib.computeBranchRoot(item, branch, idx);
            assertEq(original, replacement, string.concat("branchRoot mismatch at idx=", vm.toString(idx)));
        }
    }

    // ------- helpers ------- //

    function _assertRootEquivalence(uint256 expectedCount) internal view {
        assertEq(_tree.count, expectedCount, "count mismatch");
        bytes32 original = _tree.root();

        // Full copy — mirrors what would happen if all 32 slots are copied.
        bytes32[32] memory branch;
        for (uint256 i; i < 32; i++) {
            branch[i] = _tree.branch[i];
        }
        bytes32 replacement = JBSuckerLib.computeTreeRoot(branch, _tree.count);
        assertEq(original, replacement, string.concat("root mismatch at count=", vm.toString(expectedCount)));
    }

    function _isPowerOfTwo(uint256 n) internal pure returns (bool) {
        return n != 0 && (n & (n - 1)) == 0;
    }
}
