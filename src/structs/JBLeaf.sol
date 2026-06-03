// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A leaf in the inbox or outbox tree of a `JBSucker`. Used to `claim` tokens from the inbox tree.
/// @custom:member index The index of the leaf.
/// @custom:member beneficiary The beneficiary of the leaf.
/// @custom:member projectTokenCount The number of project tokens to claim.
/// @custom:member terminalTokenAmount The amount of terminal tokens to claim.
/// @custom:member metadata Opaque, caller-defined payload that travels with the leaf inside the merkle root. The
/// sucker protocol itself never inspects this field — it's covered by the leaf hash, so receivers can trust the value
/// once the merkle proof verifies. Pass `bytes32(0)` when no extra claim context is needed.
struct JBLeaf {
    uint256 index;
    bytes32 beneficiary;
    uint256 projectTokenCount;
    uint256 terminalTokenAmount;
    bytes32 metadata;
}
