// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice One source-chain accounting context, carried raw (un-valued) in a cross-chain snapshot.
/// @dev The source chain reports its surplus and balance per accounting context in that context's own decimals — it
/// performs no price-feed valuation. The destination chain resolves `token` to its own local token (identity for
/// same-address tokens, or via the sucker's remote-to-local token mapping for same-asset tokens at different
/// addresses), derives that local token's currency as `uint32(uint160(localToken))`, and folds the context into its
/// same-currency local context at par. The destination derives the currency from the resolved local token rather than
/// trusting a wire-carried currency, so a same-asset token at a different address (e.g. USDC) still folds under the
/// receiver's own currency. The only conversions ever performed are the ones a project already needs for its own local
/// surplus.
/// @custom:member token The source-local token this context was read from, resolved to a local token (and thence a
/// local currency) on receipt. Padded to bytes32 for cross-VM compatibility.
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
