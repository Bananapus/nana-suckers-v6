// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Optional data-hook interface for adding project-specific adjusted accounts to peer-chain snapshots.
interface IJBPeerChainAdjustedAccounts {
    /// @notice Extra supply, surplus, and balance that should be included in cross-chain peer snapshots.
    /// @param projectId The ID of the project being snapshotted.
    /// @param decimals The decimals the returned surplus and balance should use.
    /// @param currency The currency the returned surplus and balance should be in terms of.
    /// @return supply The extra supply to include in `sourceTotalSupply`.
    /// @return surplus The extra surplus to include in `sourceSurplus`.
    /// @return balance The extra balance to include in `sourceBalance`.
    function peerChainAdjustedAccountsOf(
        uint256 projectId,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256 supply, uint256 surplus, uint256 balance);
}
