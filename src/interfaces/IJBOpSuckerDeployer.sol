// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOPMessenger} from "./IOPMessenger.sol";
import {IOPStandardBridge} from "./IOPStandardBridge.sol";

/// @notice Interface for a deployer of Optimism-specific suckers.
interface IJBOpSuckerDeployer {
    // View functions

    /// @notice The OP standard bridge used by deployed suckers.
    function opBridge() external view returns (IOPStandardBridge);

    /// @notice The OP cross-domain messenger used by deployed suckers.
    function opMessenger() external view returns (IOPMessenger);

    // State-changing functions

    /// @notice Set the chain-specific OP messenger and bridge constants.
    function setChainSpecificConstants(IOPMessenger messenger, IOPStandardBridge bridge) external;
}
