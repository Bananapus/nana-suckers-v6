// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member localToken The local token address.
/// @custom:member minGas The minimum gas amount to bridge.
/// @custom:member remoteToken The remote token address.
// forge-lint: disable-next-line(pascal-case-struct)
struct JBTokenMapping {
    address localToken;
    uint32 minGas;
    bytes32 remoteToken;
}
