// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBChainAccounting} from "./JBChainAccounting.sol";

/// @notice Scratch space used while gathering the freshest accounting record per peer chain across a project's suckers.
/// @dev Sized to the total records across the project's suckers for in-memory de-duplication; `chainCount` tracks
/// populated entries. Bundled into one struct so the gather helpers stay under the stack-slot limit.
/// @custom:member chainIds The peer chain IDs that have been observed.
/// @custom:member records The selected record for each observed peer chain.
/// @custom:member hasActiveRecord Whether the selected record came from an active sucker instead of a deprecated one.
/// @custom:member chainCount The number of populated peer-chain entries.
struct PeerAccountScratch {
    uint256[] chainIds;
    JBChainAccounting[] records;
    bool[] hasActiveRecord;
    uint256 chainCount;
}
