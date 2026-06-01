// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A single peer-chain aggregate read bundled with the keys the registry needs to dedupe and rank it.
/// @dev Returned by the sucker's combined peer-chain views so the registry can read the value, the peer chain it
/// belongs to, and its snapshot freshness in one call instead of three separate staticcalls.
/// @custom:member value The requested peer-chain amount (balance, surplus, or total supply), already converted to the
/// caller's currency and decimals where applicable.
/// @custom:member peerChainId The chain ID of the remote peer this snapshot describes.
/// @custom:member snapshotTimestamp The freshness key of the snapshot the value came from.
struct JBPeerChainValue {
    uint256 value;
    uint256 peerChainId;
    uint256 snapshotTimestamp;
}
