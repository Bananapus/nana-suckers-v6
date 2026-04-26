// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A cross-chain pay message sent via CCIP from a remote chain to the home chain.
/// @custom:member realProjectId The ID of the real project on the home chain.
/// @custom:member beneficiary The address to receive proxy tokens.
/// @custom:member memo A memo to attach to the payment.
/// @custom:member metadata Additional metadata for the payment.
// forge-lint: disable-next-line(pascal-case-struct)
struct JBRelayPayMessage {
    uint256 realProjectId;
    address beneficiary;
    string memo;
    bytes metadata;
}
