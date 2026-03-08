// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Interface for the OP standard bridge's ERC-20 bridging.
interface IOPStandardBridge {
    // State-changing functions

    /// @notice Send ERC-20 tokens to a receiver's address on the other chain.
    function bridgeERC20To(
        address localToken,
        address remoteToken,
        address to,
        uint256 amount,
        uint32 minGasLimit,
        bytes calldata extraData
    )
        external;
}
