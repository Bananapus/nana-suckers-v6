// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBChainAccounting} from "./JBChainAccounting.sol";
import {JBInboxTreeRoot} from "./JBInboxTreeRoot.sol";

/// @notice Information about the remote (inbox) tree's root passed in a message from the remote chain, carried
/// alongside a cross-chain accounting gossip bundle.
/// @dev The accounting bundle carries the sending chain's own record plus every peer-chain record the sender holds,
/// each in the originating chain's own currency and decimals, un-valued. The receiving chain folds each context into
/// its same-asset local context at par and stores the freshest record per source chain, so no price oracle is
/// consulted in the cross-chain surplus path and accounting propagates across the sucker mesh as roots are relayed.
/// Project token supply stays a single currency-agnostic scalar per source chain.
/// @custom:member version The message format version. Used to reject incompatible messages.
/// @custom:member token The remote token address (bytes32 for cross-VM compatibility with SVM).
/// @custom:member amount The amount of tokens to send.
/// @custom:member remoteRoot The root of the merkle tree.
/// @custom:member accounts One accounting record per source chain known to the sender: its own chain plus every peer
/// chain it has heard about, excluding the destination chain. Used by the receiving chain to track cross-chain
/// supply, surplus, and balance for cash out tax calculations.
struct JBMessageRoot {
    uint8 version;
    bytes32 token;
    uint256 amount;
    JBInboxTreeRoot remoteRoot;
    JBChainAccounting[] accounts;
}
