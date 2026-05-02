// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {IJBSucker} from "./IJBSucker.sol";

/// @notice The interface for deploying sucker contracts.
interface IJBSuckerDeployer {
    // View functions

    /// @notice The Juicebox directory.
    /// @return The directory contract.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The address authorized to set layer-specific configuration.
    /// @return The configurator address.
    function LAYER_SPECIFIC_CONFIGURATOR() external view returns (address);

    /// @notice The token registry.
    /// @return The tokens contract.
    function TOKENS() external view returns (IJBTokens);

    /// @notice Whether the given address is a sucker deployed by this deployer.
    /// @param sucker The address to check.
    /// @return Whether the address is a deployed sucker.
    function isSucker(address sucker) external view returns (bool);

    // State-changing functions

    /// @notice Deploy a new sucker for the given project with an explicit remote peer.
    /// @param localProjectId The project's ID on the local chain.
    /// @param salt The salt for deterministic deployment.
    /// @param peer The remote peer address. Leave zero to use the default deterministic same-address peer.
    /// @return sucker The newly deployed sucker.
    function createForSender(uint256 localProjectId, bytes32 salt, bytes32 peer) external returns (IJBSucker sucker);
}
