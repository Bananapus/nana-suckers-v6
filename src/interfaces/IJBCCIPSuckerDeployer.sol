// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICCIPRouter} from "./ICCIPRouter.sol";

/// @notice Interface for a deployer of CCIP-specific suckers.
interface IJBCCIPSuckerDeployer {
    // Events

    /// @notice Emitted when the CCIP-specific constants are configured.
    /// @param ccipRouter The address of the CCIP router.
    /// @param ccipRemoteChainId The remote chain ID.
    /// @param ccipRemoteChainSelector The CCIP chain selector for the remote chain.
    /// @param caller The address that triggered the configuration.
    event CCIPConstantsSet(
        address ccipRouter, uint256 ccipRemoteChainId, uint64 ccipRemoteChainSelector, address caller
    );

    // View functions

    /// @notice The remote chain ID used by deployed CCIP suckers.
    function ccipRemoteChainId() external view returns (uint256);

    /// @notice The CCIP chain selector for the remote chain.
    function ccipRemoteChainSelector() external view returns (uint64);

    /// @notice The CCIP router used by deployed suckers.
    function ccipRouter() external view returns (ICCIPRouter);
}
