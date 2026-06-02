// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBSourceContext} from "../structs/JBSourceContext.sol";

/// @notice Optional data-hook interface for adding project-specific adjusted accounts to peer-chain snapshots.
interface IJBPeerChainAdjustedAccounts {
    /// @notice Extra project token supply and per-context surplus/balance to include in cross-chain peer snapshots.
    /// @dev The hook reports off-terminal surplus and balance per accounting context in each context's own currency,
    /// un-valued — exactly like the terminal contexts. The receiving chain folds each one into its same-asset local
    /// context at par, so no price oracle is consulted for the hook's contribution either.
    /// @param projectId The ID of the project to snapshot.
    /// @return supply The extra project token supply to include in `sourceTotalSupply`.
    /// @return contexts The extra per-context surplus and balance to include in the snapshot, un-valued.
    function peerChainAdjustedAccountsOf(uint256 projectId)
        external
        view
        returns (uint256 supply, JBSourceContext[] memory contexts);
}
