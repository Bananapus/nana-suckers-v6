// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBSourceContext} from "./JBSourceContext.sol";

/// @notice One source chain's project-wide accounting, carried as a record in a cross-chain gossip bundle.
/// @dev A sucker sends its own chain's record alongside every peer-chain record it already holds, each stamped with
/// the originating chain's own freshness key. The receiving chain stores the freshest record per source chain, so a
/// project's accounting propagates across a hub-and-spoke sucker mesh (L2s bridged only through mainnet) without a
/// direct sucker between every pair of chains. `contexts` carry the source chain's own token addresses, so each
/// receiver resolves them to its own local currencies independently; a record is only ever as trustworthy as the
/// source chain's own sucker, exactly as for the directly-paired peer.
/// @custom:member chainId The source chain this record describes. A receiver ignores a record for its own chain, since
/// it reads its own local accounting directly.
/// @custom:member totalSupply The total token supply (including reserved tokens) on the source chain when the record
/// was taken. Used by the receiving chain to track cross-chain supply for cash out tax calculations.
/// @custom:member contexts The source chain's surplus and balance per accounting context, each in the context's own
/// currency and decimals, un-valued. The receiver resolves each entry to its same-asset local context and folds it in
/// at par.
/// @custom:member timestamp A monotonic source-chain freshness key for the record. The receiver keeps the freshest
/// record per source chain, so stale relays cannot roll back surplus, balance, or supply.
struct JBChainAccounting {
    uint256 chainId;
    uint256 totalSupply;
    JBSourceContext[] contexts;
    uint256 timestamp;
}
