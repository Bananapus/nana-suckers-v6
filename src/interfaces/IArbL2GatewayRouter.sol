// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Interface for the Arbitrum L2 gateway router's outbound transfer.
interface IArbL2GatewayRouter {
    // State-changing functions

    /// @notice Transfer tokens from L2 to L1.
    function outboundTransfer(
        address l1Token,
        address to,
        uint256 amount,
        bytes calldata data
    )
        external
        payable
        returns (bytes memory);
}
