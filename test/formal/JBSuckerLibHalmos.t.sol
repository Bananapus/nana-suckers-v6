// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";

import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";

/// @notice Small Halmos entrypoints for cross-chain peer value decimal conversion.
/// @dev These proofs stay on the same-currency path so no oracle mocking is required.
contract JBSuckerLibHalmos {
    /// @notice A sentinel prices address. The same-currency and zero-value paths must not call it.
    IJBPrices internal constant _NO_PRICES = IJBPrices(address(0));

    /// @notice An arbitrary project ID for the library call.
    uint256 internal constant _PROJECT_ID = 1;

    /// @notice Proves zero source values convert to zero for every currency/decimal combination.
    /// @param sourceDecimals The source value's decimal precision.
    /// @param targetDecimals The requested output decimal precision.
    /// @param sourceCurrency The source currency ID.
    /// @param targetCurrency The requested output currency ID.
    function check_zeroPeerValueReturnsZero(
        uint8 sourceDecimals,
        uint8 targetDecimals,
        uint32 sourceCurrency,
        uint32 targetCurrency
    )
        public
        view
    {
        JBDenominatedAmount memory source =
            JBDenominatedAmount({value: 0, currency: sourceCurrency, decimals: sourceDecimals});

        uint256 converted = JBSuckerLib.convertPeerValue({
            prices: _NO_PRICES,
            projectId: _PROJECT_ID,
            source: source,
            decimals: targetDecimals,
            currency: targetCurrency
        });

        assert(converted == 0);
    }

    /// @notice Proves same-currency, same-decimal conversion is identity over the full uint256 value domain.
    /// @param value The source value.
    /// @param decimals The shared source and target decimal precision.
    /// @param currency The shared source and target currency ID.
    function check_sameCurrencySameDecimalsIdentity(uint256 value, uint8 decimals, uint32 currency) public view {
        JBDenominatedAmount memory source = JBDenominatedAmount({value: value, currency: currency, decimals: decimals});

        uint256 converted = JBSuckerLib.convertPeerValue({
            prices: _NO_PRICES, projectId: _PROJECT_ID, source: source, decimals: decimals, currency: currency
        });

        assert(converted == value);
    }

    /// @notice Proves same-currency conversion matches the shared fixed-point decimal helper.
    /// @param value The source value, bounded for solver speed and multiplication safety.
    /// @param sourceDecimals The source value's decimal precision.
    /// @param targetDecimals The requested output decimal precision.
    /// @param currency The shared source and target currency ID.
    function check_sameCurrencyMatchesAdjustDecimals(
        uint64 value,
        uint8 sourceDecimals,
        uint8 targetDecimals,
        uint32 currency
    )
        public
        view
    {
        if (sourceDecimals > 18 || targetDecimals > 18) return;

        JBDenominatedAmount memory source =
            JBDenominatedAmount({value: uint256(value), currency: currency, decimals: sourceDecimals});

        uint256 converted = JBSuckerLib.convertPeerValue({
            prices: _NO_PRICES, projectId: _PROJECT_ID, source: source, decimals: targetDecimals, currency: currency
        });

        uint256 expected = JBFixedPointNumber.adjustDecimals({
            value: uint256(value), decimals: sourceDecimals, targetDecimals: targetDecimals
        });

        assert(converted == expected);
    }
}
