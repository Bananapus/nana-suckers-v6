// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IJBCCIPSuckerDeployer} from "./IJBCCIPSuckerDeployer.sol";

/// @notice Interface for a deployer of swap-enabled CCIP suckers.
/// @dev Extends the base CCIP deployer with Uniswap V3/V4 swap configuration for cross-currency bridging.
interface IJBSwapCCIPSuckerDeployer is IJBCCIPSuckerDeployer {
    /// @notice The ERC-20 token used for CCIP bridging (e.g., USDC — exists on both chains).
    function bridgeToken() external view returns (IERC20);

    /// @notice The Uniswap V4 PoolManager. Can be address(0) if V4 is unavailable on this chain.
    function poolManager() external view returns (IPoolManager);

    /// @notice The Uniswap V3 factory. Can be address(0) if V3 is unavailable on this chain.
    function v3Factory() external view returns (IUniswapV3Factory);

    /// @notice The Uniswap V4 hook address used during pool discovery (optional).
    function univ4Hook() external view returns (address);

    /// @notice The wrapped native token address (e.g., WETH). Used for V3 native swaps.
    function weth() external view returns (address);
}
