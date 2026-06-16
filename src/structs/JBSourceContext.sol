// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice One source-chain accounting context, carried un-valued in a cross-chain snapshot.
/// @dev The source chain reports its surplus and balance per accounting context in that context's own decimals — it
/// performs no price-feed valuation. A receiver stores `token` as its own local token when a remote-token mapping
/// exists, or leaves the token key unchanged otherwise. Read paths derive the context's currency from that stored token
/// key instead of trusting a wire-carried currency, so same-asset tokens at different addresses (e.g. USDC) still fold
/// under the receiver's own currency. Any later valuation uses the project's normal local surplus conversions.
/// @custom:member token The source token key, or a receiver-local token key after a remote-token mapping has been
/// applied. Padded to bytes32 for cross-VM compatibility.
/// @custom:member decimals The context's native decimal precision (e.g. 18 for ETH, 6 for USDC).
/// @custom:member surplus The raw, un-valued surplus held in this context, in the context's own units. Capped to
/// `uint128` for cross-VM (SVM) compatibility, matching the leaf-amount cap.
/// @custom:member balance The raw, un-valued recorded balance held in this context, in the context's own units. Capped
/// to `uint128` for the same reason. The difference `balance - surplus` is this context's payout-limit slice.
struct JBSourceContext {
    bytes32 token;
    uint8 decimals;
    uint128 surplus;
    uint128 balance;
}
