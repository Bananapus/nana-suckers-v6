// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IArbGatewayRouter} from "../interfaces/IArbGatewayRouter.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {JBLayer} from "../enums/JBLayer.sol";

/// @notice Interface for a deployer of Arbitrum-specific suckers.
interface IJBArbitrumSuckerDeployer {
    // View functions

    /// @notice The Arbitrum gateway router used by deployed suckers.
    function arbGatewayRouter() external view returns (IArbGatewayRouter);

    /// @notice The Arbitrum inbox used by deployed suckers.
    function arbInbox() external view returns (IInbox);

    /// @notice The Arbitrum layer (L1 or L2) that deployed suckers target.
    function arbLayer() external view returns (JBLayer);
}
