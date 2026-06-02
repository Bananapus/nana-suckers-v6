// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice One source-chain accounting context, carried raw (un-valued) in a cross-chain snapshot.
/// @dev The source chain reports its surplus and balance per accounting context in each context's own currency and
/// decimals — it performs no price-feed valuation. The destination chain folds each context into its same-asset local
/// context at par (identity for same-address tokens, or via the sucker's token mapping for same-asset tokens at
/// different addresses), so the only conversions ever performed are the ones a project already needs for its own local
/// surplus. `token` is the source-local token this context was read from; the receiver resolves it to its own local
/// token via the sucker's remote-to-local token mapping (identity for same-address tokens).
/// @custom:member token The source-local token this context was read from, resolved to a local token on receipt via
/// the sucker's remote-to-local token mapping. Padded to bytes32 for cross-VM compatibility.
/// @custom:member currency The context's native currency identifier (token-keyed or a standard id).
/// @custom:member decimals The context's native decimal precision (e.g. 18 for ETH, 6 for USDC).
/// @custom:member surplus The raw, un-valued surplus held in this context, in the context's own units. Capped to
/// `uint128` for cross-VM (SVM) compatibility, matching the leaf-amount cap.
/// @custom:member balance The raw, un-valued recorded balance held in this context, in the context's own units. Capped
/// to `uint128` for the same reason. The difference `balance - surplus` is this context's payout-limit slice.
struct JBSourceContext {
    bytes32 token;
    uint32 currency;
    uint8 decimals;
    uint128 surplus;
    uint128 balance;
}
