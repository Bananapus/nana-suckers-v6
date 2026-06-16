// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBSourceContext} from "./JBSourceContext.sol";

/// @notice One source chain's project-wide accounting, carried as a record in a cross-chain gossip bundle.
/// @dev A sucker sends its own chain's record alongside every peer-chain record it already holds. Each record is
/// stamped with its originating chain's freshness key. The receiving chain stores the freshest record per source chain,
/// so a project's accounting propagates across a hub-and-spoke sucker mesh without a direct sucker between every pair
/// of chains. `contexts` are un-valued token-denominated amounts. A direct sender's own record carries source-chain
/// token addresses. Forwarded peer records use the forwarding hub's local same-asset token when a mapping exists, so
/// the next receiver only needs a mapping to that hub token. Trust is transitive across the mesh: a receiver
/// authenticates only the directly-bridged peer that delivers a bundle, not the origin of each forwarded record. A
/// record is therefore only as trustworthy as the project's same-address sucker invariant — the same CREATE2
/// same-bytecode assumption every paired sucker already relies on — and a peer running adversarial bytecode could
/// forge another chain's record. The freshest-per-chain gate bounds rollback, not authorship; the supply view it feeds
/// is clamped downstream by each chain's own local surplus, so a forged record cannot by itself over-credit a cash out.
/// @custom:member chainId The source chain this record describes. A receiver ignores a record for its own chain, since
/// it reads its own local accounting directly.
/// @custom:member totalSupply The total token supply (including reserved tokens) on the source chain when the record
/// was taken. Used by the receiving chain to track cross-chain supply for cash out tax calculations.
/// @custom:member contexts The source chain's surplus and balance per accounting context, each in its own decimals and
/// un-valued. The token key may be the source token for direct records or a forwarding hub's local same-asset token.
/// @custom:member timestamp A monotonic source-chain freshness key for the record. The receiver keeps the freshest
/// record per source chain, so stale relays cannot roll back surplus, balance, or supply.
struct JBChainAccounting {
    uint256 chainId;
    uint256 totalSupply;
    JBSourceContext[] contexts;
    uint256 timestamp;
}
