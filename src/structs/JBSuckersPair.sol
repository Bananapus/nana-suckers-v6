// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member local The local address.
/// @custom:member remote The remote address.
/// @custom:member remoteChainId The chain ID of the remote address.
struct JBSuckersPair {
    address local;
    bytes32 remote;
    uint256 remoteChainId;
}
