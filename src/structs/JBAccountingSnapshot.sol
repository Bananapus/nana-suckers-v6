// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBSourceContext} from "./JBSourceContext.sol";

/// @notice A peer-chain accounting snapshot, without any token-local merkle root or transported value.
/// @custom:member version The message format version. Used to reject incompatible messages.
/// @custom:member sourceTotalSupply The total token supply (including reserved tokens) on the source chain at the
/// time the message was sent. Used by the receiving chain to track cross-chain supply for cash out tax calculations.
/// @custom:member sourceContexts The source chain's surplus and balance per accounting context, each in the context's
/// own currency and decimals, un-valued.
/// @custom:member sourceTimestamp A monotonic source-chain freshness key for the snapshot. Used by the receiving
/// chain to reject stale surplus/balance/supply updates.
struct JBAccountingSnapshot {
    uint8 version;
    uint256 sourceTotalSupply;
    JBSourceContext[] sourceContexts;
    uint256 sourceTimestamp;
}
