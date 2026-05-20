// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";

import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @notice Small Halmos entrypoints for cross-chain peer value and merkle helper invariants.
/// @dev The peer-value proofs stay on the same-currency path so no oracle mocking is required.
contract JBSuckerLibHalmos {
    /// @notice A sentinel prices address. The same-currency and zero-value paths must not call it.
    IJBPrices internal constant _NO_PRICES = IJBPrices(address(0));

    /// @notice An arbitrary project ID for the library call.
    uint256 internal constant _PROJECT_ID = 1;

    /// @notice Proves zero source values convert to zero for every currency/decimal combination.
    /// @param sourceDecimals The source value's decimal precision.
    /// @param targetDecimals The requested output decimal precision.
    /// @param sourceCurrency The source currency ID.
    /// @param targetCurrency The requested output currency ID.
    function check_zeroPeerValueReturnsZero(
        uint8 sourceDecimals,
        uint8 targetDecimals,
        uint32 sourceCurrency,
        uint32 targetCurrency
    )
        public
        view
    {
        JBDenominatedAmount memory source =
            JBDenominatedAmount({value: 0, currency: sourceCurrency, decimals: sourceDecimals});

        uint256 converted = JBSuckerLib.convertPeerValue({
            prices: _NO_PRICES,
            projectId: _PROJECT_ID,
            source: source,
            decimals: targetDecimals,
            currency: targetCurrency
        });

        assert(converted == 0);
    }

    /// @notice Proves same-currency, same-decimal conversion is identity over the full uint256 value domain.
    /// @param value The source value.
    /// @param decimals The shared source and target decimal precision.
    /// @param currency The shared source and target currency ID.
    function check_sameCurrencySameDecimalsIdentity(uint256 value, uint8 decimals, uint32 currency) public view {
        JBDenominatedAmount memory source = JBDenominatedAmount({value: value, currency: currency, decimals: decimals});

        uint256 converted = JBSuckerLib.convertPeerValue({
            prices: _NO_PRICES, projectId: _PROJECT_ID, source: source, decimals: decimals, currency: currency
        });

        assert(converted == value);
    }

    /// @notice Proves same-currency conversion matches the shared fixed-point decimal helper.
    /// @param value The source value, bounded for solver speed and multiplication safety.
    /// @param sourceDecimals The source value's decimal precision.
    /// @param targetDecimals The requested output decimal precision.
    /// @param currency The shared source and target currency ID.
    function check_sameCurrencyMatchesAdjustDecimals(
        uint64 value,
        uint8 sourceDecimals,
        uint8 targetDecimals,
        uint32 currency
    )
        public
        view
    {
        if (sourceDecimals > 18 || targetDecimals > 18) return;

        JBDenominatedAmount memory source =
            JBDenominatedAmount({value: uint256(value), currency: currency, decimals: sourceDecimals});

        uint256 converted = JBSuckerLib.convertPeerValue({
            prices: _NO_PRICES, projectId: _PROJECT_ID, source: source, decimals: targetDecimals, currency: currency
        });

        uint256 expected = JBFixedPointNumber.adjustDecimals({
            value: uint256(value), decimals: sourceDecimals, targetDecimals: targetDecimals
        });

        assert(converted == expected);
    }

    /// @notice Proves the delegated branch-root helper matches a simple loop implementation for edge index patterns.
    /// @dev `MerkleLib.branchRoot` uses assembly memory offsets derived from index bits, which Halmos cannot keep fully
    /// symbolic. These fixed indices still prove arbitrary leaf/proof inputs for all-right, all-left, and mixed paths.
    /// @param item The leaf hash.
    /// @param branch The merkle proof branch.
    function check_branchRootEdgeIndicesMatchReference(bytes32 item, bytes32[32] memory branch) public pure {
        _assertBranchRootMatchesReference({item: item, branch: branch, index: 0});
        _assertBranchRootMatchesReference({item: item, branch: branch, index: 1});
        _assertBranchRootMatchesReference({item: item, branch: branch, index: 2});
        _assertBranchRootMatchesReference({item: item, branch: branch, index: MerkleLib.MAX_LEAVES});
    }

    /// @notice Proves the loop-based tree-root helper matches a simple reference implementation for valid counts.
    /// @param branch The active merkle branch entries.
    /// @param count The number of inserted leaves.
    function check_treeRootMatchesReference(bytes32[32] memory branch, uint256 count) public pure {
        // `computeTreeRoot` is only called with real tree counts. Counts above `MAX_LEAVES` are unreachable because
        // `MerkleLib.insert` rejects a full tree before any caller can send that count across this helper boundary.
        if (count > MerkleLib.MAX_LEAVES) return;

        bytes32 optimized = JBSuckerLib.computeTreeRoot({branch: branch, count: count});
        bytes32 expected = _referenceTreeRoot({branch: branch, count: count});

        assert(optimized == expected);
    }

    /// @notice Asserts one fixed claim-proof index against the readable reference implementation.
    function _assertBranchRootMatchesReference(bytes32 item, bytes32[32] memory branch, uint256 index) internal pure {
        bytes32 optimized = JBSuckerLib.computeBranchRoot({item: item, branch: branch, index: index});
        bytes32 expected = _referenceBranchRoot({item: item, branch: branch, index: index});

        assert(optimized == expected);
    }

    /// @notice Reference implementation for a claim proof root.
    /// @dev The production path uses unrolled assembly for size/gas; this keeps the proof target readable.
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

    /// @notice Reference implementation for an incremental tree root from branch entries and leaf count.
    /// @dev Mirrors the eth2-style zero-hash merge rules without using assembly.
    function _referenceTreeRoot(bytes32[32] memory branch, uint256 count) internal pure returns (bytes32 current) {
        if (count == 0) return MerkleLib.Z_32;

        bytes32[33] memory zeroes;
        for (uint256 i; i < MerkleLib.TREE_DEPTH;) {
            zeroes[i + 1] = keccak256(abi.encodePacked(zeroes[i], zeroes[i]));

            unchecked {
                ++i;
            }
        }

        bool started;
        for (uint256 i; i < MerkleLib.TREE_DEPTH;) {
            if (!started) {
                if (count & (uint256(1) << i) != 0) {
                    current = keccak256(abi.encodePacked(branch[i], zeroes[i]));
                    started = true;
                }
            } else if (count & (uint256(1) << i) == 0) {
                current = keccak256(abi.encodePacked(current, zeroes[i]));
            } else {
                current = keccak256(abi.encodePacked(branch[i], current));
            }

            unchecked {
                ++i;
            }
        }
    }
}
