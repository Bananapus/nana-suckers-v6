// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBInboxTreeRoot} from "./JBInboxTreeRoot.sol";

/// @notice Information about the remote (inbox) tree's root, passed in a message from the remote chain.
/// @custom:member version The message format version. Used to reject incompatible messages.
/// @custom:member token The remote token address (bytes32 for cross-VM compatibility with SVM).
/// @custom:member amount The amount of tokens being sent.
/// @custom:member remoteRoot The root of the merkle tree.
/// @custom:member sourceTotalSupply The total token supply (including reserved tokens) on the source chain at the
/// time the message was sent. Used by the receiving chain to track cross-chain supply for cash out tax calculations.
// forge-lint: disable-next-line(pascal-case-struct)
struct JBMessageRoot {
    uint8 version;
    bytes32 token;
    uint256 amount;
    JBInboxTreeRoot remoteRoot;
    uint256 sourceTotalSupply;
}
