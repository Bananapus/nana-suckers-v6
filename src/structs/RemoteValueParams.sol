// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The valuation parameters for one aggregate-view pass, bundled so per-chain aggregation helpers stay under
/// the stack-slot limit.
/// @custom:member projectId The project whose price feeds to use.
/// @custom:member currency The currency to value into.
/// @custom:member decimals The decimal precision to value into.
/// @custom:member surplus Whether the pass aggregates surplus (true) or balance (false).
struct RemoteValueParams {
    uint256 projectId;
    uint256 currency;
    uint256 decimals;
    bool surplus;
}
