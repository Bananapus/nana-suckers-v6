// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// External packages (alphabetized).
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

// Local: deployers.
import {JBOptimismSuckerDeployer} from "./JBOptimismSuckerDeployer.sol";

/// @notice An `IJBSuckerDeployer` implementation to deploy `JBBaseSucker` contracts (same as OP, separate artifact).
contract JBBaseSuckerDeployer is JBOptimismSuckerDeployer {
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
        JBOptimismSuckerDeployer(directory, permissions, tokens, configurator, trustedForwarder)
    {}
}
