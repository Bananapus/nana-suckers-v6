// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Scratch space used while aggregating one value per peer chain across a project's suckers.
/// @dev Sized to the project's sucker count for in-memory de-duplication; `chainCount` tracks populated entries.
/// @custom:member chainIds The peer chain IDs that have been observed.
/// @custom:member values The selected aggregate value for each observed peer chain.
/// @custom:member snapshotTimestamps The freshness key associated with each selected value.
/// @custom:member hasActiveValue Whether the selected value came from an active sucker instead of a deprecated
/// fallback. @custom:member chainCount The number of populated peer-chain entries.
struct PeerValueScratch {
    uint256[] chainIds;
    uint256[] values;
    uint256[] snapshotTimestamps;
    bool[] hasActiveValue;
    uint256 chainCount;
}
