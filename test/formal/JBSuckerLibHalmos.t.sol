// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";

import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @notice A directory stub whose only job is to answer the registry constructor's `PROJECTS()` lookup.
/// @dev The valuation under proof never reads the projects registry, so a zero address is sufficient.
contract HalmosValuationDirectory {
    function PROJECTS() external pure returns (address) {
        return address(0);
    }
}

/// @notice Exposes the registry's internal per-context valuation so Halmos can prove its currency/decimal invariants.
/// @dev The same-currency and zero-amount proofs never reach the price feed, so a zero prices address is sufficient.
contract HalmosValuationHarness is JBSuckerRegistry {
    constructor(IJBDirectory directory)
        JBSuckerRegistry(directory, IJBPermissions(address(0)), IJBPrices(address(0)), address(this), address(0))
    {}

    /// @notice Values an amount from one currency/decimal pair into another, delegating to the registry internals.
    /// @param amount The amount to value.
    /// @param fromCurrency The currency the amount is denominated in.
    /// @param fromDecimals The decimal precision the amount is denominated in.
    /// @param toCurrency The currency to value the amount into.
    /// @param toDecimals The decimal precision to value the amount into.
    /// @param projectId The project whose price feeds are consulted for cross-currency valuation.
    /// @return The amount valued into the target currency and decimal precision.
    function valued(
        uint256 amount,
        uint256 fromCurrency,
        uint256 fromDecimals,
        uint256 toCurrency,
        uint256 toDecimals,
        uint256 projectId
    )
        external
        view
        returns (uint256)
    {
        return _valued({
            amount: amount,
            fromCurrency: fromCurrency,
            fromDecimals: fromDecimals,
            toCurrency: toCurrency,
            toDecimals: toDecimals,
            projectId: projectId
        });
    }
}

/// @notice Small Halmos entrypoints for cross-chain peer value and merkle helper invariants.
/// @dev The peer-value proofs stay on the same-currency path so the registry's price feed is never consulted.
contract JBSuckerLibHalmos {
    /// @notice An arbitrary project ID for the valuation call.
    uint256 internal constant _PROJECT_ID = 1;

    /// @notice The largest decimal precision the valuation proofs exercise, keeping `10 ** delta` within `uint256`.
    uint256 internal constant _MAX_DECIMALS = 18;

    /// @notice The registry harness whose internal per-context valuation is under proof.
    HalmosValuationHarness internal immutable _registry;

    constructor() {
        _registry = new HalmosValuationHarness(IJBDirectory(address(new HalmosValuationDirectory())));
    }

    /// @notice Proves zero source values value to zero for every currency pair and bounded decimal combination.
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
        if (sourceDecimals > _MAX_DECIMALS || targetDecimals > _MAX_DECIMALS) return;

        uint256 converted = _registry.valued({
            amount: 0,
            fromCurrency: sourceCurrency,
            fromDecimals: sourceDecimals,
            toCurrency: targetCurrency,
            toDecimals: targetDecimals,
            projectId: _PROJECT_ID
        });

        assert(converted == 0);
    }

    /// @notice Proves same-currency, same-decimal valuation is identity over the full uint256 amount domain.
    /// @param amount The source amount.
    /// @param decimals The shared source and target decimal precision.
    /// @param currency The shared source and target currency ID.
    function check_sameCurrencySameDecimalsIdentity(uint256 amount, uint8 decimals, uint32 currency) public view {
        uint256 converted = _registry.valued({
            amount: amount,
            fromCurrency: currency,
            fromDecimals: decimals,
            toCurrency: currency,
            toDecimals: decimals,
            projectId: _PROJECT_ID
        });

        assert(converted == amount);
    }

    /// @notice Proves same-currency valuation matches the shared fixed-point decimal helper.
    /// @param amount The source amount, bounded for solver speed and multiplication safety.
    /// @param sourceDecimals The source value's decimal precision.
    /// @param targetDecimals The requested output decimal precision.
    /// @param currency The shared source and target currency ID.
    function check_sameCurrencyMatchesAdjustDecimals(
        uint64 amount,
        uint8 sourceDecimals,
        uint8 targetDecimals,
        uint32 currency
    )
        public
        view
    {
        if (sourceDecimals > _MAX_DECIMALS || targetDecimals > _MAX_DECIMALS) return;

        uint256 converted = _registry.valued({
            amount: uint256(amount),
            fromCurrency: currency,
            fromDecimals: sourceDecimals,
            toCurrency: currency,
            toDecimals: targetDecimals,
            projectId: _PROJECT_ID
        });

        uint256 expected = JBFixedPointNumber.adjustDecimals({
            value: uint256(amount), decimals: sourceDecimals, targetDecimals: targetDecimals
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

    /// @notice Proves tree-root helper parity for every single-active-branch level.
    /// @dev The arbitrary symbolic `count` proof exceeds the 30-minute CI budget. These fixed counts still keep
    /// `branch` fully symbolic and exercise each one-bit count shape from leaf 1 through the top active branch slot.
    /// @param branch The active merkle branch entries.
    function check_treeRootPowerOfTwoCountsMatchReference(bytes32[32] memory branch) public pure {
        _assertTreeRootMatchesReference({branch: branch, count: 0});

        for (uint256 i; i < MerkleLib.TREE_DEPTH;) {
            _assertTreeRootMatchesReference({branch: branch, count: uint256(1) << i});

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Proves tree-root helper parity for dense low-bit count masks at every depth.
    /// @dev These counts exercise the opposite shape from powers of two: every lower branch bit is active.
    /// @param branch The active merkle branch entries.
    function check_treeRootDenseCountsMatchReference(bytes32[32] memory branch) public pure {
        for (uint256 i = 1; i <= MerkleLib.TREE_DEPTH;) {
            _assertTreeRootMatchesReference({branch: branch, count: (uint256(1) << i) - 1});

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Asserts one fixed tree count against the readable reference implementation.
    function _assertTreeRootMatchesReference(bytes32[32] memory branch, uint256 count) internal pure {
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
