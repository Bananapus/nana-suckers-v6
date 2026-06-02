// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A remote chain's surplus and balance for one local accounting context, as last received.
/// @dev Stored keyed by the local token a remote context resolves to (identity for same-address tokens, or via the
/// sucker's token mapping for same-asset tokens at different addresses). `surplus`/`balance` are raw, un-valued amounts
/// in the context's own currency; a consumer that requests this context's currency reads them at par. `snapshotEpoch`
/// versions the entry against the sucker's current snapshot so a context that dropped out of a fresher snapshot is
/// treated as absent without clearing the map.
/// @custom:member surplus The raw surplus held in this context on the peer chain.
/// @custom:member balance The raw recorded balance held in this context on the peer chain.
/// @custom:member currency The context's native currency identifier.
/// @custom:member decimals The context's native decimal precision.
/// @custom:member snapshotEpoch The source freshness key of the snapshot this entry was written from. Valid only when
/// it equals the sucker's current `snapshotTimestamp`.
struct JBPeerChainContext {
    uint128 surplus;
    uint128 balance;
    uint32 currency;
    uint8 decimals;
    uint256 snapshotEpoch;
}
