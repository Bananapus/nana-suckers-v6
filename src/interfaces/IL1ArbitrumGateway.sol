// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Interface for Arbitrum L1 gateways to query the exact calldata they construct for retryable tickets.
interface IL1ArbitrumGateway {
    /// @notice Returns the calldata that the gateway will submit as a retryable ticket to the Inbox.
    /// @param _token The L1 token address.
    /// @param _from The sender on L1.
    /// @param _to The recipient on L2.
    /// @param _amount The amount of tokens to bridge.
    /// @param _data Additional data (forwarded to the L2 gateway).
    /// @return The ABI-encoded calldata for `finalizeInboundTransfer` on the L2 gateway.
    function getOutboundCalldata(
        address _token,
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _data
    )
        external
        view
        returns (bytes memory);
}
