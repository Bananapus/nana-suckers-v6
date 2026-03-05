// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBLayer} from "../enums/JBLayer.sol";
import {IArbGatewayRouter} from "../interfaces/IArbGatewayRouter.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";

interface IJBArbitrumSuckerDeployer {
    function arbGatewayRouter() external view returns (IArbGatewayRouter);
    function arbInbox() external view returns (IInbox);
    function arbLayer() external view returns (JBLayer);
}
