// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Optional data-hook interface for adding project-specific accounting to peer-chain snapshots.
interface IJBPeerChainAccountingContext {
    /// @notice Additional supply and surplus that should be included in cross-chain peer snapshots.
    /// @param projectId The ID of the project being snapshotted.
    /// @param decimals The decimals the returned surplus should use.
    /// @param currency The currency the returned surplus should be in terms of.
    /// @return supply The additional supply to include in `sourceTotalSupply`.
    /// @return surplus The additional surplus to include in `sourceSurplus`.
    function peerChainAccountingContextOf(
        uint256 projectId,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256 supply, uint256 surplus);
}
