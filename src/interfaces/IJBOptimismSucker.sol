// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOPMessenger} from "./IOPMessenger.sol";
import {IOPStandardBridge} from "./IOPStandardBridge.sol";

/// @notice Interface for an Optimism-specific sucker exposing OP bridge components.
interface IJBOptimismSucker {
    // View functions

    /// @notice The OP standard bridge used for token bridging.
    function OPBRIDGE() external view returns (IOPStandardBridge);

    /// @notice The OP cross-domain messenger used for cross-chain messaging.
    function OPMESSENGER() external view returns (IOPMessenger);
}
