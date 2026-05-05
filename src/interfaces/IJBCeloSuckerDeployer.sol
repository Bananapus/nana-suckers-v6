// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBOpSuckerDeployer} from "./IJBOpSuckerDeployer.sol";
import {IWrappedNativeToken} from "./IWrappedNativeToken.sol";
import {IOPMessenger} from "./IOPMessenger.sol";
import {IOPStandardBridge} from "./IOPStandardBridge.sol";

/// @notice Interface for a deployer of Celo-specific suckers (OP Stack with custom gas token).
interface IJBCeloSuckerDeployer is IJBOpSuckerDeployer {
    // View functions

    /// @notice The ERC-20 wrapper for the chain's native token on the local chain.
    function wrappedNative() external view returns (IWrappedNativeToken);

    // State-changing functions

    /// @notice Set the chain-specific OP messenger, bridge, and wrapped native token constants.
    function setChainSpecificConstants(
        IOPMessenger messenger,
        IOPStandardBridge bridge,
        IWrappedNativeToken wrappedNative
    )
        external;
}
