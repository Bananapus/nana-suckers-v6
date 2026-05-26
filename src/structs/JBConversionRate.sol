// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Immutable conversion rate for one received root batch, keyed by nonce.
/// @dev Each batch stores its total leaf and local amounts. Individual claims compute their scaled amount as
/// `claimLeafAmount * localTotal / leafTotal` — no mutable state changes.
/// @custom:member leafTotal Total leaf-denomination (source chain) amount for this batch.
/// @custom:member localTotal Total local-denomination (after swap) amount for this batch.
struct JBConversionRate {
    uint256 leafTotal;
    uint256 localTotal;
}
