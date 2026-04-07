// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MerkleLib} from "../utils/MerkleLib.sol";

/// @notice A merkle tree used to track the outbox for a given token in a `JBSucker`.
/// @dev The outbox is used to send from the local chain to the remote chain.
/// @custom:member nonce The nonce of the outbox.
/// @custom:member numberOfClaimsSent the number of claims that have been sent to the peer. Used to determine which
/// claims have been sent. Packed with `nonce` into one storage slot.
/// @custom:member balance The balance of the outbox.
/// @custom:member tree The merkle tree.
// forge-lint: disable-next-line(pascal-case-struct)
struct JBOutboxTree {
    uint64 nonce;
    uint192 numberOfClaimsSent;
    uint256 balance;
    MerkleLib.Tree tree;
}
