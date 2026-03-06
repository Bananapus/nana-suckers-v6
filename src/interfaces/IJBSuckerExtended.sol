// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBSucker, JBClaim} from "./IJBSucker.sol";

/// @notice Contains the IJBSucker interface and extends it with additional functions and events.
interface IJBSuckerExtended is IJBSucker {
    event EmergencyHatchOpened(address[] tokens, address caller);
    event DeprecationTimeUpdated(uint40 timestamp, address caller);

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
