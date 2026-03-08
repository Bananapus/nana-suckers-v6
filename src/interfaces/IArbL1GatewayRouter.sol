// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Interface for the Arbitrum L1 gateway router's outbound transfer with custom refund.
interface IArbL1GatewayRouter {
    // State-changing functions

    /// @notice Transfer tokens from L1 to L2 with a custom refund address.
    function outboundTransferCustomRefund(
        address token,
        address refundTo,
        address to,
        uint256 amount,
        uint256 maxGas,
        uint256 gasPriceBid,
        bytes calldata data
    )
        external
        payable
        returns (bytes memory);
}
