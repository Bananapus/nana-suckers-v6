// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";

import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";

contract ConvertPeerValueHarness {
    function convert(
        IJBPrices prices,
        uint256 projectId,
        JBDenominatedAmount memory source,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256)
    {
        return JBSuckerLib.convertPeerValue(prices, projectId, source, decimals, currency);
    }
}

/// @notice Validates `convertPeerValue` with asymmetric decimal currencies (ETH ↔ USDC).
///
/// All chain state (PRICES) is mocked via `vm.etch` + `vm.mockCall`, so the test does not need a fork.
/// Previously this used `vm.createSelectFork("ethereum")`, but the implicit latest-block pin made CI flaky
/// whenever the upstream RPC pruned the block forge had cached during setup.
contract ConvertPeerValueForkTest is Test {
    address internal constant PRICES = address(0xA00);

    uint256 internal constant PROJECT_ID = 1;
    uint32 internal constant ETH_CURRENCY = 1;
    uint32 internal constant USD_CURRENCY = 2;

    ConvertPeerValueHarness internal harness;

    function setUp() external {
        harness = new ConvertPeerValueHarness();
        vm.etch(PRICES, hex"00");

        // Mock: 1 USD = 0.0005 ETH → price of 1 USD in ETH at 18 decimals = 5e14.
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, ETH_CURRENCY, USD_CURRENCY, 18)),
            abi.encode(uint256(5e14))
        );

        // Mock: 1 ETH = 2000 USD → price of 1 ETH in USD at 6 decimals = 2000e6.
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, USD_CURRENCY, ETH_CURRENCY, 6)),
            abi.encode(uint256(2000e6))
        );

        // Mock: 1:1 ETH→ETH for same-currency sanity check.
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, ETH_CURRENCY, ETH_CURRENCY, 18)),
            abi.encode(uint256(1e18))
        );
    }

    /// @notice 10 ETH (18 dec) → USD (6 dec) at $2000/ETH should yield 20,000 USDC.
    function test_ethToUsdc() external view {
        JBDenominatedAmount memory source = JBDenominatedAmount({value: 10 ether, currency: ETH_CURRENCY, decimals: 18});

        uint256 converted = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 6, uint256(USD_CURRENCY));
        assertEq(converted, 20_000e6, "10 ETH at $2000 should convert to 20,000 USDC");
    }

    /// @notice 20,000 USDC (6 dec) → ETH (18 dec) at $2000/ETH should yield 10 ETH.
    function test_usdcToEth() external view {
        JBDenominatedAmount memory source = JBDenominatedAmount({value: 20_000e6, currency: USD_CURRENCY, decimals: 6});

        uint256 converted = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 18, uint256(ETH_CURRENCY));
        assertEq(converted, 10 ether, "20,000 USDC at $2000/ETH should convert to 10 ETH");
    }

    /// @notice Same-currency conversion (18 → 18) should return the original value.
    function test_sameCurrencySameDecimals() external view {
        JBDenominatedAmount memory source = JBDenominatedAmount({value: 5 ether, currency: ETH_CURRENCY, decimals: 18});

        uint256 converted = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 18, uint256(ETH_CURRENCY));
        assertEq(converted, 5 ether, "same currency same decimals should return original");
    }

    /// @notice Zero source value should short-circuit to zero.
    function test_zeroValueReturnsZero() external view {
        JBDenominatedAmount memory source = JBDenominatedAmount({value: 0, currency: ETH_CURRENCY, decimals: 18});

        uint256 converted = harness.convert(IJBPrices(PRICES), PROJECT_ID, source, 6, uint256(USD_CURRENCY));
        assertEq(converted, 0, "zero input should return zero");
    }
}
