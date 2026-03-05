// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBProjects} from "@bananapus/core-v5/src/interfaces/IJBProjects.sol";
import {JBSuckerDeployerConfig} from "../structs/JBSuckerDeployerConfig.sol";
import {JBSuckersPair} from "../structs/JBSuckersPair.sol";

/// @notice The interface for the sucker registry, which tracks deployed suckers and manages deployer allowlists.
interface IJBSuckerRegistry {
    event SuckerDeployedFor(uint256 projectId, address sucker, JBSuckerDeployerConfig configuration, address caller);
    event SuckerDeployerAllowed(address deployer, address caller);
    event SuckerDeployerRemoved(address deployer, address caller);
    event SuckerDeprecated(uint256 projectId, address sucker, address caller);

    /// @notice The Juicebox directory.
    /// @return The directory contract.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The project registry.
    /// @return The projects contract.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice Returns true if the specified sucker belongs to the specified project and was deployed through this
    /// registry.
    /// @param projectId The ID of the project to check for.
    /// @param addr The address of the sucker to check.
    /// @return Whether the sucker belongs to the project.
    function isSuckerOf(uint256 projectId, address addr) external view returns (bool);

    /// @notice Whether the specified sucker deployer is approved by this registry.
    /// @param deployer The address of the deployer to check.
    /// @return Whether the deployer is allowed.
    function suckerDeployerIsAllowed(address deployer) external view returns (bool);

    /// @notice Returns the pairs of suckers and their metadata for a project.
    /// @param projectId The ID of the project.
    /// @return pairs The local/remote sucker pairs.
    function suckerPairsOf(uint256 projectId) external view returns (JBSuckersPair[] memory pairs);

    /// @notice Returns all suckers for a project.
    /// @param projectId The ID of the project.
    /// @return The addresses of the suckers.
    function suckersOf(uint256 projectId) external view returns (address[] memory);

    /// @notice Add a sucker deployer to the allowlist.
    /// @param deployer The address of the deployer to allow.
    function allowSuckerDeployer(address deployer) external;

    /// @notice Add multiple sucker deployers to the allowlist.
    /// @param deployers The addresses of the deployers to allow.
    function allowSuckerDeployers(address[] calldata deployers) external;

    /// @notice Deploy one or more suckers for the specified project.
    /// @param projectId The ID of the project to deploy suckers for.
    /// @param salt The salt used for deterministic deployment.
    /// @param configurations The deployer configs to use.
    /// @return suckers The addresses of the deployed suckers.
    function deploySuckersFor(
        uint256 projectId,
        bytes32 salt,
        JBSuckerDeployerConfig[] calldata configurations
    )
        external
        returns (address[] memory suckers);

    /// @notice Remove a deprecated sucker from a project.
    /// @param projectId The ID of the project.
    /// @param sucker The address of the deprecated sucker to remove.
    function removeDeprecatedSucker(uint256 projectId, address sucker) external;

    /// @notice Remove a sucker deployer from the allowlist.
    /// @param deployer The address of the deployer to remove.
    function removeSuckerDeployer(address deployer) external;
}
