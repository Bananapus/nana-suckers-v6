// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Arbitrum chain IDs for mainnet and Sepolia testnet pairs.
library ARBChains {
    /// @notice Arbitrum relevant chains and their respective ids.
    uint256 public constant ETH_CHAINID = 1;
    uint256 public constant ETH_SEP_CHAINID = 11_155_111;
    uint256 public constant ARB_CHAINID = 42_161;
    uint256 public constant ARB_SEP_CHAINID = 421_614;
}
