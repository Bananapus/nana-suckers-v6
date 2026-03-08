// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IWrappedNativeToken} from "./IWrappedNativeToken.sol";

/// @notice Interface for a CCIP router that exposes the wrapped native token.
interface ICCIPRouter is IRouterClient {
    // View functions

    /// @notice The wrapped native token used by this CCIP router.
    function getWrappedNative() external view returns (IWrappedNativeToken);
}
