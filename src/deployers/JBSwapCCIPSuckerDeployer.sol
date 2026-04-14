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

    error JBSwapCCIPSuckerDeployer_SwapAlreadyConfigured();
    error JBSwapCCIPSuckerDeployer_InvalidSwapConfig();

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

    /// @notice The wrapped native token address (e.g., WETH).
    address public weth;

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
    /// @param _bridgeToken The ERC-20 token used for CCIP bridging.
    /// @param _poolManager The Uniswap V4 PoolManager (can be address(0) if V4 unavailable).
    /// @param _v3Factory The Uniswap V3 factory (can be address(0) if V3 unavailable).
    /// @param _univ4Hook The V4 hook for pool discovery (optional, address(0) if none).
    /// @param _weth The wrapped native token address (e.g., WETH).
    function setSwapConstants(
        IERC20 _bridgeToken,
        IPoolManager _poolManager,
        IUniswapV3Factory _v3Factory,
        address _univ4Hook,
        address _weth
    )
        external
    {
        if (address(bridgeToken) != address(0)) {
            revert JBSwapCCIPSuckerDeployer_SwapAlreadyConfigured();
        }

        if (_msgSender() != LAYER_SPECIFIC_CONFIGURATOR) {
            revert JBSuckerDeployer_Unauthorized(_msgSender(), LAYER_SPECIFIC_CONFIGURATOR);
        }

        if (address(_bridgeToken) == address(0)) {
            revert JBSwapCCIPSuckerDeployer_InvalidSwapConfig();
        }

        bridgeToken = _bridgeToken;
        poolManager = _poolManager;
        v3Factory = _v3Factory;
        univ4Hook = _univ4Hook;
        weth = _weth;
    }
}
