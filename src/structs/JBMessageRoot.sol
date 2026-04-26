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
/// @custom:member sourceCurrency The currency the source chain used to denominate `sourceSurplus` and
/// `sourceBalance` (e.g. `uint256(uint160(JBConstants.NATIVE_TOKEN))` for ETH).
/// @custom:member sourceDecimals The decimal precision of `sourceSurplus` and `sourceBalance` (e.g. 18 for ETH).
/// @custom:member sourceSurplus The project-wide surplus on the source chain, denominated in `sourceCurrency` at
/// `sourceDecimals` precision.
/// @custom:member sourceBalance The total recorded balance on the source chain, denominated in `sourceCurrency` at
/// `sourceDecimals` precision.
/// @custom:member sourceTimestamp The `block.timestamp` on the source chain when the snapshot was taken. Used by the
/// receiving chain to reject stale surplus/balance/supply updates without blocking token-local inbox root updates.
struct JBMessageRoot {
    uint8 version;
    bytes32 token;
    uint256 amount;
    JBInboxTreeRoot remoteRoot;
    uint256 sourceTotalSupply;
    uint256 sourceCurrency;
    uint8 sourceDecimals;
    uint256 sourceSurplus;
    uint256 sourceBalance;
    uint256 sourceTimestamp;
}
