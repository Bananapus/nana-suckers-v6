// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Arbitrum chain IDs for mainnet and Sepolia testnet pairs.
library ARBChains {
    /// @notice The EVM chain ID for Ethereum mainnet.
    uint256 public constant ETH_CHAINID = 1;
    /// @notice The EVM chain ID for Ethereum Sepolia.
    uint256 public constant ETH_SEP_CHAINID = 11_155_111;
    /// @notice The EVM chain ID for Arbitrum One.
    uint256 public constant ARB_CHAINID = 42_161;
    /// @notice The EVM chain ID for Arbitrum Sepolia.
    uint256 public constant ARB_SEP_CHAINID = 421_614;
}
