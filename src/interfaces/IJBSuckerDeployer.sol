// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {IJBSucker} from "./IJBSucker.sol";

/// @notice The interface for deploying sucker contracts.
interface IJBSuckerDeployer {
    error JBSuckerDeployer_AlreadyConfigured();
    error JBSuckerDeployer_DeployerIsNotConfigured();
    error JBSuckerDeployer_InvalidLayerSpecificConfiguration();
    error JBSuckerDeployer_LayerSpecificNotConfigured();
    error JBSuckerDeployer_Unauthorized(address caller, address expected);
    error JBSuckerDeployer_ZeroConfiguratorAddress();

    /// @notice The Juicebox directory.
    /// @return The directory contract.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The token registry.
    /// @return The tokens contract.
    function TOKENS() external view returns (IJBTokens);

    /// @notice The address authorized to set layer-specific configuration.
    /// @return The configurator address.
    function LAYER_SPECIFIC_CONFIGURATOR() external view returns (address);

    /// @notice Whether the given address is a sucker deployed by this deployer.
    /// @param sucker The address to check.
    /// @return Whether the address is a deployed sucker.
    function isSucker(address sucker) external view returns (bool);

    /// @notice Deploy a new sucker for the given project.
    /// @param localProjectId The project's ID on the local chain.
    /// @param salt The salt for deterministic deployment.
    /// @return sucker The newly deployed sucker.
    function createForSender(uint256 localProjectId, bytes32 salt) external returns (IJBSucker sucker);
}
