// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBSuckerLib} from "../../src/libraries/JBSuckerLib.sol";

contract ConvertPeerValueHarness {
    function convert(
        IJBDirectory directory,
        uint256 projectId,
        JBDenominatedAmount memory source,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256)
    {
        return JBSuckerLib.convertPeerValue(directory, projectId, source, decimals, currency);
    }
}

contract RevertingStoreTerminal {
    function STORE() external pure returns (IJBTerminalStore) {
        revert("no store");
    }
}

contract FirstTerminalRemoteConversionGapTest is Test {
    address internal constant DIRECTORY = address(0x600);
    address internal constant MULTI_TERMINAL = address(0x800);
    address internal constant STORE = address(0x900);
    address internal constant PRICES = address(0xA00);

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant ETH_CURRENCY = 1;
    uint32 internal constant NATIVE_CURRENCY = uint32(uint160(JBConstants.NATIVE_TOKEN));

    ConvertPeerValueHarness internal harness;
    RevertingStoreTerminal internal forwardingTerminal;

    function setUp() external {
        harness = new ConvertPeerValueHarness();
        forwardingTerminal = new RevertingStoreTerminal();
        vm.etch(PRICES, hex"00");

        vm.mockCall(MULTI_TERMINAL, abi.encodeCall(IJBMultiTerminal.STORE, ()), abi.encode(STORE));
        vm.mockCall(STORE, abi.encodeCall(IJBTerminalStore.PRICES, ()), abi.encode(PRICES));
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, uint32(ETH_CURRENCY), uint256(NATIVE_CURRENCY), 18)),
            abi.encode(uint256(1e18))
        );
    }

    function test_forwardingTerminalFirstDoesNotZeroRemoteEthConversionWhenLiveStoreExistsLater() external {
        JBDenominatedAmount memory remoteEthSnapshot =
            JBDenominatedAmount({value: 10 ether, currency: uint32(ETH_CURRENCY), decimals: 18});

        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(address(forwardingTerminal));
        terminals[1] = IJBTerminal(MULTI_TERMINAL);

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));

        uint256 convertedWithForwarderFirst =
            harness.convert(IJBDirectory(DIRECTORY), PROJECT_ID, remoteEthSnapshot, 18, uint256(NATIVE_CURRENCY));
        assertEq(convertedWithForwarderFirst, 10 ether, "later live store should convert the remote value");

        terminals[0] = IJBTerminal(MULTI_TERMINAL);
        terminals[1] = IJBTerminal(address(forwardingTerminal));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));

        uint256 converted =
            harness.convert(IJBDirectory(DIRECTORY), PROJECT_ID, remoteEthSnapshot, 18, uint256(NATIVE_CURRENCY));
        assertEq(converted, 10 ether, "the later live store proves the remote value was valid all along");
    }
}
