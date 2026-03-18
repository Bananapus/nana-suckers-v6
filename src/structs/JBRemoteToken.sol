// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A struct that represents a token on the remote chain.
/// @dev Invariant: If the `emergencyHatch` is true then the `enabled` is always false.
/// @custom:member enabled Whether the token is enabled.
/// @custom:member emergencyHatchOpened Whether the emergency hatch is opened.
/// @custom:member minGas The minimum gas to use when bridging.
/// @custom:member addr The address of the token on the remote chain.
/// @custom:member toRemoteFee The ETH fee (in wei) paid into the project via terminal.pay() on each toRemote() call.
struct JBRemoteToken {
    bool enabled;
    bool emergencyHatch;
    uint32 minGas;
    bytes32 addr;
    uint256 toRemoteFee;
}
