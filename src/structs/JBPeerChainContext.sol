// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A remote chain's surplus and balance for one local currency, as last received.
/// @dev One entry per local currency in the latest snapshot. The local currency is the project's authoritative
/// accounting-context currency for the token a remote context resolves to (identity for same-address tokens, or via
/// the sucker's token mapping for same-asset tokens at different addresses). `surplus`/`balance` are raw, un-valued
/// amounts in that currency's own units; a read values them into a requested currency via the prices contract, exactly
/// as the terminal store values local surplus (an identity short-circuit means same-currency reads are taken at par).
/// @custom:member currency The local currency this context resolves to.
/// @custom:member decimals The context's native decimal precision, used to rescale to a requested precision.
/// @custom:member surplus The raw surplus held in this currency on the peer chain.
/// @custom:member balance The raw recorded balance held in this currency on the peer chain.
struct JBPeerChainContext {
    uint32 currency;
    uint8 decimals;
    uint128 surplus;
    uint128 balance;
}
