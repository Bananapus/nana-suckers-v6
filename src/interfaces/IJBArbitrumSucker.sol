// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";

import {IArbGatewayRouter} from "./IArbGatewayRouter.sol";
import {JBLayer} from "./../enums/JBLayer.sol";

/// @notice Interface for an Arbitrum-specific sucker exposing Arbitrum bridge components.
interface IJBArbitrumSucker {
    // View functions

    /// @notice The Arbitrum inbox used for L1-to-L2 messaging.
    function ARBINBOX() external view returns (IInbox);

    /// @notice The Arbitrum gateway router used for token bridging.
    function GATEWAYROUTER() external view returns (IArbGatewayRouter);

    /// @notice The layer (L1 or L2) this sucker is deployed on.
    function LAYER() external view returns (JBLayer);
}
