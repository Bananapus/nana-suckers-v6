// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Common interface for Arbitrum L1 and L2 gateway routers.
interface IArbGatewayRouter {
    // View functions

    /// @notice The default gateway used for token bridging.
    function defaultGateway() external view returns (address gateway);

    /// @notice The gateway used to bridge a specific token.
    function getGateway(address _token) external view returns (address gateway);
}
