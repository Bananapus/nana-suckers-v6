// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";

import {JBChainAccounting} from "../structs/JBChainAccounting.sol";
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

    /// @notice Emitted when a local-to-remote token mapping is added to the allowlist.
    /// @param localToken The local token address.
    /// @param remoteChainId The ID of the remote chain.
    /// @param remoteToken The remote token address encoded as bytes32.
    /// @param caller The address that allowed the token mapping.
    event TokenMappingAllowed(address localToken, uint256 remoteChainId, bytes32 remoteToken, address caller);

    /// @notice Emitted when a local-to-remote token mapping is removed from the allowlist.
    /// @param localToken The local token address.
    /// @param remoteChainId The ID of the remote chain.
    /// @param remoteToken The remote token address encoded as bytes32.
    /// @param caller The address that removed the token mapping.
    event TokenMappingRemoved(address localToken, uint256 remoteChainId, bytes32 remoteToken, address caller);

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

    /// @notice All suckers for a project, INCLUDING deprecated entries that are no longer listed in `suckersOf`.
    /// @dev Used by consumers that need to detect "has any sucker ever peered to chain X?" — e.g. to prevent
    /// premature burn of bridgeable credit by `JBReferralSplitHook.burnUnbridgeableCreditFor`. Returns every key
    /// from `_suckersOf[projectId]` regardless of active/deprecated state.
    /// @param projectId The ID of the project.
    /// @return The addresses of every sucker ever registered for `projectId`.
    function allSuckersOf(uint256 projectId) external view returns (address[] memory);

    /// @notice Returns true if the specified sucker belongs to the project and was deployed through this registry.
    /// @param projectId The ID of the project to check for.
    /// @param addr The address of the sucker to check.
    /// @return Whether the sucker belongs to the project.
    function isSuckerOf(uint256 projectId, address addr) external view returns (bool);

    /// @notice The freshest accounting record per source chain that a project's suckers hold, for re-gossiping.
    /// @dev A sucker building an outbound gossip bundle calls this to gather the project's full cross-chain knowledge,
    /// deduped per chain (freshest wins; active supersedes deprecated), excluding the destination and local chains.
    /// @param projectId The ID of the project.
    /// @param exceptChainId The destination chain to exclude.
    /// @return accounts The deduped raw accounting records, one per known source chain.
    function peerChainAccountsOf(
        uint256 projectId,
        uint256 exceptChainId
    )
        external
        view
        returns (JBChainAccounting[] memory accounts);

    /// @notice The cumulative total supply across all remote peer chains for a project.
    /// @dev Aggregates over every (sucker, chain) pair and dedups per chain by freshest record. Silently skips suckers
    /// and records that revert.
    /// @param projectId The ID of the project.
    /// @return totalSupply The combined peer chain total supply.
    function remoteTotalSupplyOf(uint256 projectId) external view returns (uint256 totalSupply);

    /// @notice Reverts unless a token mapping can be chosen by a project.
    /// @dev Disable mappings never require owner approval. Non-native same-address mappings pass through directly.
    /// Native-to-native and differing-address mappings must be explicitly allowed.
    /// @param localToken The local token address.
    /// @param remoteChainId The ID of the remote chain.
    /// @param remoteToken The remote token address encoded as bytes32.
    function requireTokenMappingAllowed(address localToken, uint256 remoteChainId, bytes32 remoteToken) external view;

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

    /// @notice Whether a local-to-remote token mapping is approved by this registry.
    /// @param localToken The local token address.
    /// @param remoteChainId The ID of the remote chain.
    /// @param remoteToken The remote token address encoded as bytes32.
    /// @return Whether the token mapping is allowed.
    function tokenMappingIsAllowed(
        address localToken,
        uint256 remoteChainId,
        bytes32 remoteToken
    )
        external
        view
        returns (bool);

    /// @notice The ETH fee (in wei) paid into the fee project on each toRemote() call.
    /// @return The current fee.
    function toRemoteFee() external view returns (uint256);

    /// @notice The cumulative peer-chain balance across all remote peer chains for a project, valued into a currency.
    /// @dev Aggregates over every (sucker, chain) pair and dedups per chain by freshest record, then sums each chain's
    /// balance valued into `currency`. A context whose currency already matches is taken at par (no feed); a missing
    /// cross-currency feed reverts and that (sucker, chain) is silently skipped (conservative, bias-low).
    /// @param projectId The ID of the project.
    /// @param currency The currency to value the combined balance into.
    /// @param decimals The decimal precision for the returned value.
    /// @return balance The combined peer chain balance.
    function totalRemoteBalanceOf(
        uint256 projectId,
        uint256 currency,
        uint256 decimals
    )
        external
        view
        returns (uint256 balance);

    /// @notice The cumulative peer-chain surplus across all remote peer chains for a project, valued into a currency.
    /// @dev Aggregates over every (sucker, chain) pair and dedups per chain by freshest record, then sums each chain's
    /// surplus valued into `currency`. A context whose currency already matches is taken at par (no feed); a missing
    /// cross-currency feed reverts and that (sucker, chain) is silently skipped (conservative, bias-low).
    /// @param projectId The ID of the project.
    /// @param currency The currency to value the combined surplus into.
    /// @param decimals The decimal precision for the returned value.
    /// @return surplus The combined peer chain surplus.
    function totalRemoteSurplusOf(
        uint256 projectId,
        uint256 currency,
        uint256 decimals
    )
        external
        view
        returns (uint256 surplus);

    // State-changing functions

    /// @notice Add a sucker deployer to the allowlist.
    /// @param deployer The address of the deployer to allow.
    function allowSuckerDeployer(address deployer) external;

    /// @notice Add multiple sucker deployers to the allowlist.
    /// @param deployers The addresses of the deployers to allow.
    function allowSuckerDeployers(address[] calldata deployers) external;

    /// @notice Add a local-to-remote token mapping to the allowlist.
    /// @param localToken The local token address.
    /// @param remoteChainId The ID of the remote chain.
    /// @param remoteToken The remote token address encoded as bytes32.
    function allowTokenMapping(address localToken, uint256 remoteChainId, bytes32 remoteToken) external;

    /// @notice Add multiple local-to-remote token mappings to the allowlist.
    /// @param localTokens The local token addresses.
    /// @param remoteChainIds The remote chain IDs.
    /// @param remoteTokens The remote token addresses encoded as bytes32.
    function allowTokenMappings(
        address[] calldata localTokens,
        uint256[] calldata remoteChainIds,
        bytes32[] calldata remoteTokens
    )
        external;

    /// @notice Deploy one or more suckers for the specified project.
    /// @dev This call also applies each configuration's token mappings on the deployed suckers. `DEPLOY_SUCKERS`
    /// authorizes those initial mappings; use `MAP_SUCKER_TOKEN` for post-deployment mapping changes.
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

    /// @notice Remove a local-to-remote token mapping from the allowlist.
    /// @param localToken The local token address.
    /// @param remoteChainId The ID of the remote chain.
    /// @param remoteToken The remote token address encoded as bytes32.
    function removeTokenMapping(address localToken, uint256 remoteChainId, bytes32 remoteToken) external;

    /// @notice Remove multiple local-to-remote token mappings from the allowlist.
    /// @param localTokens The local token addresses.
    /// @param remoteChainIds The remote chain IDs.
    /// @param remoteTokens The remote token addresses encoded as bytes32.
    function removeTokenMappings(
        address[] calldata localTokens,
        uint256[] calldata remoteChainIds,
        bytes32[] calldata remoteTokens
    )
        external;

    /// @notice Set the ETH fee (in wei) paid on each toRemote() call. Owner only.
    /// @param fee The new fee amount in wei.
    function setToRemoteFee(uint256 fee) external;
}
