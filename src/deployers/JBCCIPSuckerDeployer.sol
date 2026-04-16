// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// External packages (alphabetized).
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

// Local: interfaces (alphabetized).
import {ICCIPRouter} from "../interfaces/ICCIPRouter.sol";
import {IJBCCIPSuckerDeployer} from "../interfaces/IJBCCIPSuckerDeployer.sol";

// Local: deployers.
import {JBSuckerDeployer} from "./JBSuckerDeployer.sol";

/// @notice An `IJBSuckerDeployer` implementation to deploy `JBCCIPSucker` contracts.
contract JBCCIPSuckerDeployer is JBSuckerDeployer, IJBCCIPSuckerDeployer {
    //*********************************************************************//
    // ---------------------- public stored properties ------------------- //
    //*********************************************************************//

    /// @notice Store the remote chain id.
    uint256 public ccipRemoteChainId;

    /// @notice The remote chain selector target of all sucker deployed by this contract.
    uint64 public ccipRemoteChainSelector;

    /// @notice Store the address of the CCIP router for this chain.
    ICCIPRouter public ccipRouter;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory The directory of terminals and controllers for projects.
    /// @param permissions The permissions contract for the deployer.
    /// @param tokens The contract that manages token minting and burning.
    /// @param configurator The address of the configurator.
    /// @param trustedForwarder The trusted forwarder for ERC-2771 meta-transactions.
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address configurator,
        address trustedForwarder
    )
        JBSuckerDeployer(directory, permissions, tokens, configurator, trustedForwarder)
    {}

    //*********************************************************************//
    // ------------------------ internal views --------------------------- //
    //*********************************************************************//

    /// @notice Check if the layer specific configuration is set or not. Used as a sanity check.
    /// @return A flag indicating whether the layer specific configuration has been set.
    function _layerSpecificConfigurationIsSet() internal view override returns (bool) {
        return ccipRemoteChainId != 0 && ccipRemoteChainSelector != 0 && address(ccipRouter) != address(0);
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Handles some layer specific configuration that can't be done in the constructor otherwise deployment
    /// addresses would change.
    /// @param remoteChainId The remote chain id.
    /// @param remoteChainSelector The CCIP remote chain selector.
    /// @param router The CCIP router for this chain.
    function setChainSpecificConstants(uint256 remoteChainId, uint64 remoteChainSelector, ICCIPRouter router) external {
        // Make sure the layer specific configuration has not already been set.
        if (_layerSpecificConfigurationIsSet()) {
            revert JBSuckerDeployer_AlreadyConfigured();
        }

        // Make sure only the configurator can call this function.
        if (_msgSender() != LAYER_SPECIFIC_CONFIGURATOR) {
            revert JBSuckerDeployer_Unauthorized(_msgSender(), LAYER_SPECIFIC_CONFIGURATOR);
        }

        // Store the CCIP remote chain ID.
        ccipRemoteChainId = remoteChainId;

        // Store the CCIP remote chain selector.
        ccipRemoteChainSelector = remoteChainSelector;

        // Store the CCIP router.
        ccipRouter = router;

        // Make sure the layer specific configuration is properly configured.
        if (!_layerSpecificConfigurationIsSet()) {
            revert JBSuckerDeployer_InvalidLayerSpecificConfiguration();
        }

        // Emit the configuration event.
        emit CCIPConstantsSet({
            ccipRouter: address(ccipRouter),
            ccipRemoteChainId: ccipRemoteChainId,
            ccipRemoteChainSelector: ccipRemoteChainSelector,
            caller: _msgSender()
        });
    }
}
