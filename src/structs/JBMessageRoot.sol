// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBInboxTreeRoot} from "./JBInboxTreeRoot.sol";
import {JBSourceContext} from "./JBSourceContext.sol";

/// @notice Information about the remote (inbox) tree's root, passed in a message from the remote chain.
/// @dev The snapshot carries surplus and balance per accounting context in each context's own currency — the source
/// chain performs no price-feed valuation. The receiving chain folds each context into its same-asset local context at
/// par, so no price oracle is consulted in the cross-chain surplus path. Project token supply stays a single
/// currency-agnostic scalar.
/// @custom:member version The message format version. Used to reject incompatible messages.
/// @custom:member token The remote token address (bytes32 for cross-VM compatibility with SVM).
/// @custom:member amount The amount of tokens to send.
/// @custom:member remoteRoot The root of the merkle tree.
/// @custom:member sourceTotalSupply The total token supply (including reserved tokens) on the source chain at the
/// time the message was sent. Used by the receiving chain to track cross-chain supply for cash out tax calculations.
/// @custom:member sourceContexts The source chain's surplus and balance per accounting context, each in the context's
/// own currency and decimals, un-valued. The receiving chain resolves each entry to its same-asset local context and
/// folds it in at par.
/// @custom:member sourceTimestamp A monotonic source-chain freshness key for the snapshot. Used by the receiving
/// chain to reject stale surplus/balance/supply updates without blocking token-local inbox root updates.
struct JBMessageRoot {
    uint8 version;
    bytes32 token;
    uint256 amount;
    JBInboxTreeRoot remoteRoot;
    uint256 sourceTotalSupply;
    JBSourceContext[] sourceContexts;
    uint256 sourceTimestamp;
}
