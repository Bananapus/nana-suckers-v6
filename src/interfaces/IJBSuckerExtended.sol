// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBSucker, JBClaim} from "./IJBSucker.sol";

/// @notice Contains the IJBSucker interface and extends it with additional functions and events.
interface IJBSuckerExtended is IJBSucker {
    // Events

    /// @notice Emitted when the deprecation timestamp is updated.
    /// @param timestamp The new deprecation timestamp.
    /// @param caller The address that updated the timestamp.
    event DeprecationTimeUpdated(uint40 timestamp, address caller);

    /// @notice Emitted when a beneficiary exits through the emergency hatch.
    /// @param beneficiary The beneficiary receiving the tokens.
    /// @param token The terminal token address.
    /// @param terminalTokenAmount The amount of terminal tokens returned.
    /// @param projectTokenCount The number of project tokens minted.
    /// @param caller The address that performed the emergency exit.
    event EmergencyExit(
        address indexed beneficiary,
        address indexed token,
        uint256 terminalTokenAmount,
        uint256 projectTokenCount,
        address caller
    );

    /// @notice Emitted when the emergency hatch is opened for one or more tokens.
    /// @param tokens The tokens for which the emergency hatch was opened.
    /// @param caller The address that opened the emergency hatch.
    event EmergencyHatchOpened(address[] tokens, address caller);

    // State-changing functions

    /// @notice Open the emergency hatch for the specified tokens, allowing direct claims without bridging.
    /// @param tokens The tokens to enable the emergency hatch for.
    function enableEmergencyHatchFor(address[] calldata tokens) external;

    /// @notice Claim tokens through the emergency hatch when bridging is unavailable.
    /// @param claimData The claim data including token, leaf, and proof.
    function exitThroughEmergencyHatch(JBClaim calldata claimData) external;

    /// @notice Set or update the deprecation timestamp for this sucker.
    /// @param timestamp The timestamp after which the sucker is deprecated.
    function setDeprecation(uint40 timestamp) external;
}
