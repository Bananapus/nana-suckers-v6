// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {JBLayer} from "../enums/JBLayer.sol";
import {IArbGatewayRouter} from "../interfaces/IArbGatewayRouter.sol";
import {IJBArbitrumSuckerDeployer} from "../interfaces/IJBArbitrumSuckerDeployer.sol";
import {JBSuckerDeployer} from "./JBSuckerDeployer.sol";

/// @notice An `IJBSuckerDeployer` implementation to deploy `JBArbitrumSucker` contracts.
contract JBArbitrumSuckerDeployer is JBSuckerDeployer, IJBArbitrumSuckerDeployer {
    //*********************************************************************//
    // ---------------------- public stored properties ------------------- //
    //*********************************************************************//

    /// @notice The gateway router for the specific chain.
    IArbGatewayRouter public override arbGatewayRouter;

    /// @notice The inbox used to send messages between the local and remote sucker.
    IInbox public override arbInbox;

    /// @notice The layer that this contract is on.
    JBLayer public arbLayer;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory The directory of terminals and controllers for projects.
    /// @param permissions The permissions contract for the deployer.
    /// @param tokens The contract that manages token minting and burning.
    /// @param configurator The address of the configurator.
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
    function _layerSpecificConfigurationIsSet() internal view override returns (bool) {
        // On L2, the inbox is legitimately address(0) — only the gateway router is needed.
        // On L1, both the inbox and gateway router must be set.
        if (arbLayer == JBLayer.L2) return address(arbGatewayRouter) != address(0);
        return address(arbInbox) != address(0) && address(arbGatewayRouter) != address(0);
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Handles some layer specific configuration that can't be done in the constructor otherwise deployment
    /// addresses would change.
    /// @param layer The Arbitrum layer (L1 or L2).
    /// @param inbox The Arbitrum inbox on this layer.
    /// @param gatewayRouter The Arbitrum gateway router on this layer.
    function setChainSpecificConstants(JBLayer layer, IInbox inbox, IArbGatewayRouter gatewayRouter) external {
        if (_layerSpecificConfigurationIsSet()) {
            revert JBSuckerDeployer_AlreadyConfigured();
        }

        if (_msgSender() != LAYER_SPECIFIC_CONFIGURATOR) {
            revert JBSuckerDeployer_Unauthorized(_msgSender(), LAYER_SPECIFIC_CONFIGURATOR);
        }

        // Configure these layer specific properties.
        // This is done in a separate call to make the deployment code chain agnostic.
        arbLayer = layer;
        arbInbox = inbox;
        arbGatewayRouter = gatewayRouter;

        // Make sure the layer specific configuration is properly configured.
        if (!_layerSpecificConfigurationIsSet()) {
            revert JBSuckerDeployer_InvalidLayerSpecificConfiguration();
        }
    }
}
