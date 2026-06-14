// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBChainAccounting} from "./JBChainAccounting.sol";

/// @notice A cross-chain accounting gossip bundle, sent without any token-local merkle root or transported value.
/// @dev Carries the sending chain's own accounting record plus every peer-chain record the sender currently holds,
/// each stamped with its originating chain's freshness key. The receiving chain stores the freshest record per source
/// chain, so accounting propagates across a hub-and-spoke sucker mesh without a direct sucker between every pair of
/// chains.
/// @custom:member version The message format version. Used to reject incompatible messages.
/// @custom:member accounts One accounting record per source chain known to the sender: its own chain plus every peer
/// chain it has heard about, excluding the destination chain.
struct JBAccountingSnapshot {
    uint8 version;
    JBChainAccounting[] accounts;
}
