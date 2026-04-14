// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A snapshot of a token's surplus and balance on a chain, sent in cross-chain bridge messages.
/// @custom:member token The token address.
/// @custom:member decimals The token's decimal precision.
/// @custom:member surplus The total project surplus across all terminals, denominated in this token.
/// @custom:member balance The raw recorded balance of this token across all terminals (before payout limit
/// subtraction).
struct JBTokenSnapshot {
    address token;
    uint8 decimals;
    uint256 surplus;
    uint256 balance;
}
