// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Interface for the OP cross-domain messenger.
interface IOPMessenger {
    // State-changing functions

    /// @notice Bridge ERC-20 tokens to a recipient on the other chain.
    function bridgeERC20To(
        address localToken,
        address remoteToken,
        address to,
        uint256 amount,
        uint32 minGasLimit,
        bytes calldata extraData
    )
        external;

    /// @notice Send a cross-domain message to a target address on the other chain.
    function sendMessage(address target, bytes memory message, uint32 gasLimit) external payable;

    /// @notice The address of the sender of the currently executing cross-domain message.
    function xDomainMessageSender() external returns (address);
}
