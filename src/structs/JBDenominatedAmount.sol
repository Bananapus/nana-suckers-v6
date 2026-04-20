// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A value denominated in a specific currency at a specific decimal precision.
/// @custom:member value The amount.
/// @custom:member currency The currency identifier (e.g. `JBCurrencyIds.ETH`).
/// @custom:member decimals The decimal precision of `value`.
struct JBDenominatedAmount {
    uint256 value;
    uint32 currency;
    uint8 decimals;
}
