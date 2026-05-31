// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Bridge tokens from a failed inbound swap, stored for later retry via `retrySwap`.
/// @custom:member bridgeToken The bridge token received from CCIP.
/// @custom:member bridgeAmount Amount of bridge tokens to swap.
/// @custom:member leafTotal Original leaf-denomination total (for conversion rate).
struct JBPendingSwap {
    address bridgeToken;
    uint256 bridgeAmount;
    uint256 leafTotal;
}
