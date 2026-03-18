// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";

import {JBSuckerDeployerConfig} from "../structs/JBSuckerDeployerConfig.sol";
import {JBSuckersPair} from "../structs/JBSuckersPair.sol";

/// @notice The interface for the sucker registry, which tracks deployed suckers and manages deployer allowlists.
interface IJBSuckerRegistry {
    // Events

    /// @notice Emitted when a sucker deployer is added to the allowlist.
    /// @param deployer The address of the deployer that was allowed.
    /// @param caller The address that allowed the deployer.
    event SuckerDeployerAllowed(address deployer, address caller);

    /// @notice Emitted when a sucker deployer is removed from the allowlist.
    /// @param deployer The address of the deployer that was removed.
    /// @param caller The address that removed the deployer.
    event SuckerDeployerRemoved(address deployer, address caller);

    /// @notice Emitted when a sucker is deployed for a project.
    /// @param projectId The ID of the project the sucker was deployed for.
    /// @param sucker The address of the deployed sucker.
    /// @param configuration The deployer configuration used.
    /// @param caller The address that triggered the deployment.
    event SuckerDeployedFor(uint256 projectId, address sucker, JBSuckerDeployerConfig configuration, address caller);

    /// @notice Emitted when a deprecated sucker is removed from a project.
    /// @param projectId The ID of the project.
    /// @param sucker The address of the deprecated sucker.
    /// @param caller The address that removed the sucker.
    event SuckerDeprecated(uint256 projectId, address sucker, address caller);

    /// @notice Emitted when the toRemoteFee is changed.
    /// @param oldFee The previous fee.
    /// @param newFee The new fee.
    /// @param caller The address that changed the fee.
    event ToRemoteFeeChanged(uint256 oldFee, uint256 newFee, address caller);

    // View functions

    /// @notice The Juicebox directory.
    /// @return The directory contract.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The maximum ETH fee (in wei) that the owner can set via setToRemoteFee().
    /// @return The max fee constant.
    function MAX_TO_REMOTE_FEE() external view returns (uint256);

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

    /// @notice The ETH fee (in wei) paid into the fee project on each toRemote() call.
    /// @return The current fee.
    function toRemoteFee() external view returns (uint256);

    // State-changing functions

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

    /// @notice Set the ETH fee (in wei) paid on each toRemote() call. Owner only.
    /// @param fee The new fee amount in wei.
    function setToRemoteFee(uint256 fee) external;
}
