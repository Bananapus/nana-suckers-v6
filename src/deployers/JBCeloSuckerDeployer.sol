// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {IJBCeloSuckerDeployer} from "../interfaces/IJBCeloSuckerDeployer.sol";
import {IOPMessenger} from "../interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../interfaces/IOPStandardBridge.sol";
import {IWrappedNativeToken} from "../interfaces/IWrappedNativeToken.sol";
import {JBOptimismSuckerDeployer} from "./JBOptimismSuckerDeployer.sol";

/// @notice An `IJBSuckerDeployer` implementation to deploy `JBCeloSucker` contracts.
/// @dev Extends the OP deployer with a `wrappedNative` address for chains where ETH is an ERC-20.
contract JBCeloSuckerDeployer is JBOptimismSuckerDeployer, IJBCeloSuckerDeployer {
    //*********************************************************************//
    // ---------------------- public stored properties ------------------- //
    //*********************************************************************//

    /// @notice The wrapped native token (WETH) on the local chain.
    IWrappedNativeToken public override wrappedNative;

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
        JBOptimismSuckerDeployer(directory, permissions, tokens, configurator, trustedForwarder)
    {}

    //*********************************************************************//
    // ------------------------ internal views --------------------------- //
    //*********************************************************************//

    /// @notice Check if the layer specific configuration is set or not. Used as a sanity check.
    function _layerSpecificConfigurationIsSet() internal view override returns (bool) {
        return
            address(opMessenger) != address(0) && address(opBridge) != address(0)
                && address(wrappedNative) != address(0);
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Handles layer specific configuration including the wrapped native token.
    /// @param messenger The OPMessenger on this layer.
    /// @param bridge The OPStandardBridge on this layer.
    /// @param _wrappedNative The wrapped native token (WETH) on this layer.
    function setChainSpecificConstants(
        IOPMessenger messenger,
        IOPStandardBridge bridge,
        IWrappedNativeToken _wrappedNative
    )
        external
    {
        if (_layerSpecificConfigurationIsSet()) {
            revert JBSuckerDeployer_AlreadyConfigured();
        }

        if (_msgSender() != LAYER_SPECIFIC_CONFIGURATOR) {
            revert JBSuckerDeployer_Unauthorized(_msgSender(), LAYER_SPECIFIC_CONFIGURATOR);
        }

        // Configure these layer specific properties.
        opMessenger = messenger;
        opBridge = bridge;
        wrappedNative = _wrappedNative;

        // Make sure the layer specific configuration is properly configured.
        if (!_layerSpecificConfigurationIsSet()) {
            revert JBSuckerDeployer_InvalidLayerSpecificConfiguration();
        }
    }
}
