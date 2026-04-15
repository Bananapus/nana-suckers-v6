// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// External packages (alphabetized).
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

// Local: interfaces (alphabetized).
import {IJBOpSuckerDeployer} from "../interfaces/IJBOpSuckerDeployer.sol";
import {IOPMessenger} from "../interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../interfaces/IOPStandardBridge.sol";

// Local: deployers.
import {JBSuckerDeployer} from "./JBSuckerDeployer.sol";

/// @notice An `IJBSuckerDeployer` implementation to deploy `JBOptimismSucker` contracts.
contract JBOptimismSuckerDeployer is JBSuckerDeployer, IJBOpSuckerDeployer {
    //*********************************************************************//
    // ---------------------- public stored properties ------------------- //
    //*********************************************************************//

    /// @notice The bridge used to bridge tokens between the local and remote chain.
    IOPStandardBridge public override opBridge;

    /// @notice The messenger used to send messages between the local and remote sucker.
    IOPMessenger public override opMessenger;

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
    function _layerSpecificConfigurationIsSet() internal view virtual override returns (bool) {
        // Use && (not ||) so the post-set check in setChainSpecificConstants rejects partial configurations
        // where only one of messenger/bridge is provided. Both are required for the sucker to function.
        return address(opMessenger) != address(0) && address(opBridge) != address(0);
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Handles some layer specific configuration that can't be done in the constructor otherwise deployment
    /// addresses would change.
    /// @param messenger The OPMessenger on this layer.
    /// @param bridge The OPStandardBridge on this layer.
    function setChainSpecificConstants(IOPMessenger messenger, IOPStandardBridge bridge) external {
        // Make sure the layer specific configuration has not already been set.
        if (_layerSpecificConfigurationIsSet()) {
            revert JBSuckerDeployer_AlreadyConfigured();
        }

        // Make sure only the configurator can call this function.
        if (_msgSender() != LAYER_SPECIFIC_CONFIGURATOR) {
            revert JBSuckerDeployer_Unauthorized(_msgSender(), LAYER_SPECIFIC_CONFIGURATOR);
        }

        // Configure these layer specific properties.
        // This is done in a separate call to make the deployment code chain agnostic.
        opMessenger = messenger;
        opBridge = bridge;

        // Make sure the layer specific configuration is properly configured.
        if (!_layerSpecificConfigurationIsSet()) {
            revert JBSuckerDeployer_InvalidLayerSpecificConfiguration();
        }
    }
}
