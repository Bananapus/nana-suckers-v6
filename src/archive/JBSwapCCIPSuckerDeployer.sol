// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// External packages (alphabetized).
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

// Local: interfaces.
import {IJBSwapCCIPSuckerDeployer} from "../interfaces/IJBSwapCCIPSuckerDeployer.sol";

// Local: deployers.
import {JBCCIPSuckerDeployer} from "./JBCCIPSuckerDeployer.sol";

/// @notice An `IJBSuckerDeployer` implementation to deploy `JBSwapCCIPSucker` contracts.
/// @dev Extends `JBCCIPSuckerDeployer` with Uniswap V3/V4 swap configuration for cross-currency bridging.
contract JBSwapCCIPSuckerDeployer is JBCCIPSuckerDeployer, IJBSwapCCIPSuckerDeployer {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBSwapCCIPSuckerDeployer_InvalidSwapConfig(address bridgeToken);
    error JBSwapCCIPSuckerDeployer_SwapAlreadyConfigured(address bridgeToken);

    //*********************************************************************//
    // ---------------------- public stored properties ------------------- //
    //*********************************************************************//

    /// @notice The ERC-20 token used for CCIP bridging (e.g., USDC).
    IERC20 public bridgeToken;

    /// @notice The Uniswap V4 PoolManager. Can be address(0) if V4 is unavailable.
    IPoolManager public poolManager;

    /// @notice The Uniswap V3 factory. Can be address(0) if V3 is unavailable.
    IUniswapV3Factory public v3Factory;

    /// @notice The Uniswap V4 hook address for pool discovery (optional).
    address public univ4Hook;

    /// @notice The ERC-20 wrapper address for the chain's native token (e.g. WETH on Ethereum).
    address public wrappedNativeToken;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory The directory of terminals and controllers for projects.
    /// @param permissions The permissions contract for the deployer.
    /// @param tokens The contract that manages token minting and burning.
    /// @param configurator The address of the configurator.
    /// @param trustedForwarder The trusted forwarder for ERC-2771 meta-transactions.
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address configurator,
        address trustedForwarder
    )
        JBCCIPSuckerDeployer(directory, permissions, tokens, configurator, trustedForwarder)
    {}

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Configure the swap-specific constants. Can only be called once by the configurator.
    /// @param newBridgeToken The ERC-20 token used for CCIP bridging.
    /// @param newPoolManager The Uniswap V4 PoolManager (can be address(0) if V4 unavailable).
    /// @param newV3Factory The Uniswap V3 factory (can be address(0) if V3 unavailable).
    /// @param newUniv4Hook The V4 hook for pool discovery (optional, address(0) if none).
    /// @param newWrappedNativeToken The ERC-20 wrapper address for the chain's native token (e.g. WETH on Ethereum).
    function setSwapConstants(
        IERC20 newBridgeToken,
        IPoolManager newPoolManager,
        IUniswapV3Factory newV3Factory,
        address newUniv4Hook,
        address newWrappedNativeToken
    )
        external
    {
        // Make sure the swap configuration has not already been set.
        if (address(bridgeToken) != address(0)) {
            revert JBSwapCCIPSuckerDeployer_SwapAlreadyConfigured({bridgeToken: address(bridgeToken)});
        }

        // Make sure only the configurator can call this function.
        if (_msgSender() != LAYER_SPECIFIC_CONFIGURATOR) {
            revert JBSuckerDeployer_Unauthorized({caller: _msgSender(), expected: LAYER_SPECIFIC_CONFIGURATOR});
        }

        // Make sure the bridge token is not the zero address.
        if (address(newBridgeToken) == address(0)) {
            revert JBSwapCCIPSuckerDeployer_InvalidSwapConfig({bridgeToken: address(newBridgeToken)});
        }

        // Store the bridge token.
        bridgeToken = newBridgeToken;

        // Store the Uniswap V4 pool manager.
        poolManager = newPoolManager;

        // Store the Uniswap V3 factory.
        v3Factory = newV3Factory;

        // Store the Uniswap V4 hook address.
        univ4Hook = newUniv4Hook;

        // Store the wrapped native token address.
        wrappedNativeToken = newWrappedNativeToken;
    }
}
