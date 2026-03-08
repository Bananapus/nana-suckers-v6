// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {IJBCashOutTerminal} from "@bananapus/core-v5/src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "@bananapus/core-v5/src/interfaces/IJBController.sol";
import {IJBPayoutTerminal} from "@bananapus/core-v5/src/interfaces/IJBPayoutTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v5/src/structs/JBAccountingContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {JBSucker} from "./../JBSucker.sol";
import {IJBSuckerDeployerFeeless} from "../interfaces/IJBSuckerDeployerFeeless.sol";

abstract contract JBAllowanceSucker is JBSucker {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBAllowanceSucker_NoTerminalForToken(uint256 projectId, address token);
    error JBAllowanceSucker_TokenNotAccepted(uint256 projectId, address token);

    //*********************************************************************//
    // ---------------------- internal functions ------------------------- //
    //*********************************************************************//

    /// @notice Cash out the project tokens for the cash out tokens.
    /// @param projectToken the token to cash out.
    /// @param count the amount of project tokens to cash out.
    /// @param token the token to reclaim.
    /// @param minTokensReclaimed the minimum amount of tokens to receive.
    /// @return receivedAmount the amount of tokens received by cashing out.
    function _pullBackingAssets(
        IERC20 projectToken,
        uint256 count,
        address token,
        uint256 minTokensReclaimed
    )
        internal
        virtual
        override
        returns (uint256 receivedAmount)
    {
        // Get the projectToken total supply.
        uint256 totalSupply = projectToken.totalSupply();

        uint256 _projectId = projectId();

        // Burn the project tokens.
        IJBController(address(DIRECTORY.controllerOf(_projectId)))
            .burnTokensOf(address(this), _projectId, count, string(""));

        // Get the primary terminal of the project for the token.
        IJBCashOutTerminal terminal = IJBCashOutTerminal(address(DIRECTORY.primaryTerminalOf(_projectId, token)));

        // Make sure a terminal is configured for the token.
        if (address(terminal) == address(0)) {
            revert JBAllowanceSucker_NoTerminalForToken(_projectId, token);
        }

        // Get the accounting context for the token.
        JBAccountingContext[] memory accountingContext = new JBAccountingContext[](1);
        accountingContext[0] = terminal.accountingContextForTokenOf(_projectId, token);
        if (accountingContext[0].currency == 0) {
            revert JBAllowanceSucker_TokenNotAccepted(_projectId, token);
        }

        uint256 surplus = terminal.currentSurplusOf(
            _projectId, accountingContext, accountingContext[0].decimals, accountingContext[0].currency
        );

        uint256 backingAssets = mulDiv(count, surplus, totalSupply);

        // Get the balance before we cash out.
        uint256 balanceBefore = _balanceOf(token, address(this));
        receivedAmount = IJBSuckerDeployerFeeless(deployer)
            .useAllowanceFeeless({
                projectId: _projectId,
                terminal: IJBPayoutTerminal(address(terminal)),
                token: token,
                currency: accountingContext[0].currency,
                amount: backingAssets,
                minTokensReclaimed: minTokensReclaimed
            });

        // Sanity check to make sure we actually received the reported amount.
        // Prevents a malicious terminal from reporting a higher amount than it actually sent.
        // slither-disable-next-line incorrect-equality
        assert(receivedAmount == _balanceOf(token, address(this)) - balanceBefore);
    }
}
