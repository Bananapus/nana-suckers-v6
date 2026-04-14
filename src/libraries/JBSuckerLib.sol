// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {JBDenominatedAmount} from "../structs/JBDenominatedAmount.sol";

/// @notice Library with bytecode-heavy view functions extracted from JBSucker to reduce child contract sizes.
/// @dev These are `external` library functions, so they are deployed as a separate contract and called via
/// DELEGATECALL. This avoids duplicating the bytecode in every sucker implementation.
library JBSuckerLib {
    // ------------------------- internal constants ----------------------- //

    uint256 internal constant _ETH_CURRENCY = JBCurrencyIds.ETH;
    uint8 internal constant _ETH_DECIMALS = 18;

    // ------------------------- external views -------------------------- //

    /// @notice Build ETH-denominated aggregate surplus and balance across all terminals for a project.
    /// @param directory The JB directory to look up terminals.
    /// @param projectId The project ID.
    /// @return ethSurplus The total surplus denominated in ETH at 18 decimals.
    /// @return ethBalance The total balance denominated in ETH at 18 decimals.
    // forge-lint: disable-next-line(mixed-case-function)
    function buildETHAggregate(
        IJBDirectory directory,
        uint256 projectId
    )
        external
        view
        returns (uint256 ethSurplus, uint256 ethBalance)
    {
        // Get all terminals registered for the project.
        IJBTerminal[] memory terminals = directory.terminalsOf(projectId);

        // Get the number of terminals.
        uint256 numTerminals = terminals.length;

        // If there are no terminals, return zeros.
        if (numTerminals == 0) return (0, 0);

        // Get the surplus denominated in ETH. currentSurplusOf aggregates across all terminals internally.
        // slither-disable-next-line calls-loop
        try terminals[0].currentSurplusOf({
            projectId: projectId, tokens: new address[](0), decimals: _ETH_DECIMALS, currency: uint32(_ETH_CURRENCY)
        }) returns (
            uint256 surplus
        ) {
            ethSurplus = surplus;
        } catch {}

        // Get a reference to JBPrices for balance conversion.
        IJBPrices prices;
        {
            // slither-disable-next-line calls-loop
            try IJBMultiTerminal(address(terminals[0])).STORE() returns (IJBTerminalStore store) {
                // Get the price oracle from the terminal store.
                prices = store.PRICES();
            } catch {
                // If the store lookup fails, return surplus only with zero balance.
                return (ethSurplus, 0);
            }
        }

        // Aggregate balance from each terminal, converting each token to ETH.
        for (uint256 i; i < numTerminals;) {
            // slither-disable-next-line calls-loop
            try terminals[i].accountingContextsOf(projectId) returns (JBAccountingContext[] memory contexts) {
                // Iterate over each accounting context (token) for this terminal.
                for (uint256 j; j < contexts.length;) {
                    // Get the token address for this context.
                    address tkn = contexts[j].token;

                    // Get the decimal precision for this token.
                    uint8 dec = contexts[j].decimals;

                    // Derive the currency ID from the token address.
                    uint32 tokenCurrency = uint32(uint160(tkn));

                    // slither-disable-next-line calls-loop
                    try IJBMultiTerminal(address(terminals[i])).STORE()
                        .balanceOf({terminal: address(terminals[i]), projectId: projectId, token: tkn}) returns (
                        uint256 bal
                    ) {
                        if (bal != 0) {
                            // If the token is already ETH-denominated, adjust decimals directly.
                            if (tokenCurrency == uint32(_ETH_CURRENCY)) {
                                ethBalance += JBFixedPointNumber.adjustDecimals({
                                    value: bal, decimals: dec, targetDecimals: _ETH_DECIMALS
                                });
                            } else {
                                // Otherwise, convert the balance to ETH using the price oracle.
                                // slither-disable-next-line calls-loop
                                try prices.pricePerUnitOf({
                                    projectId: projectId,
                                    pricingCurrency: tokenCurrency,
                                    unitCurrency: uint32(_ETH_CURRENCY),
                                    decimals: _ETH_DECIMALS
                                }) returns (
                                    uint256 price
                                ) {
                                    ethBalance += mulDiv({x: bal, y: price, denominator: 10 ** dec});
                                } catch {}
                            }
                        }
                    } catch {}

                    unchecked {
                        ++j;
                    }
                }
            } catch {}
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Convert a peer chain snapshot value to the requested currency and decimal precision.
    /// @param directory The JB directory to look up terminals.
    /// @param projectId The project ID.
    /// @param source The peer chain snapshot containing value, currency, and decimals.
    /// @param decimals The target decimal precision.
    /// @param currency The target currency.
    /// @return converted The converted value.
    function convertPeerValue(
        IJBDirectory directory,
        uint256 projectId,
        JBDenominatedAmount memory source,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256 converted)
    {
        // Nothing to convert if the source value is zero.
        if (source.value == 0) return 0;

        // If the source currency matches the target, just adjust decimals.
        if (source.currency == uint32(currency)) {
            converted = JBFixedPointNumber.adjustDecimals({
                value: source.value, decimals: source.decimals, targetDecimals: decimals
            });
        } else {
            // Look up terminals to access the price oracle.
            IJBTerminal[] memory terminals = directory.terminalsOf(projectId);

            // If there are no terminals, return zero.
            if (terminals.length == 0) return 0;

            // slither-disable-next-line calls-loop
            try IJBMultiTerminal(address(terminals[0])).STORE() returns (IJBTerminalStore store) {
                // Get the price oracle from the terminal store.
                IJBPrices prices = store.PRICES();

                // Convert using the price oracle.
                // slither-disable-next-line calls-loop
                try prices.pricePerUnitOf({
                    projectId: projectId,
                    pricingCurrency: source.currency,
                    unitCurrency: uint32(currency),
                    decimals: uint8(decimals)
                }) returns (
                    uint256 price
                ) {
                    converted = mulDiv({x: source.value, y: price, denominator: 10 ** source.decimals});
                } catch {}
            } catch {}
        }
    }
}
