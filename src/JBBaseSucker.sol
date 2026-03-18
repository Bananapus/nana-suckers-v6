// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {JBOptimismSucker} from "./JBOptimismSucker.sol";
import {JBOptimismSuckerDeployer} from "./deployers/JBOptimismSuckerDeployer.sol";

/// @notice A `JBSucker` implementation to suck tokens between two chains connected by a Base (OP Stack) bridge.
contract JBBaseSucker is JBOptimismSucker {
    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param deployer A contract that deploys the clones for this contracts.
    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param permissions A contract storing permissions.
    /// @param tokens A contract that manages token minting and burning.
    constructor(
        JBOptimismSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        uint256 feeProjectId,
        uint256 toRemoteFee,
        address feeOwner,
        address trustedForwarder
    )
        JBOptimismSucker(
            deployer, directory, permissions, tokens, feeProjectId, toRemoteFee, feeOwner, trustedForwarder
        )
    {}

    //*********************************************************************//
    // ------------------------ external views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the chain on which the peer is located.
    /// @return chainId of the peer.
    function peerChainId() external view virtual override returns (uint256) {
        uint256 chainId = block.chainid;
        if (chainId == 1) return 8453;
        if (chainId == 8453) return 1;
        if (chainId == 11_155_111) return 84_532;
        if (chainId == 84_532) return 11_155_111;
        return 0;
    }
}
