// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

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

contract FirstTerminalRemoteConversionGapTest is Test {
    address internal constant DIRECTORY = address(0x600);
    address internal constant CONTROLLER = address(0x800);
    address internal constant PRICES = address(0xA00);

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant ETH_CURRENCY = 1;
    uint32 internal constant NATIVE_CURRENCY = uint32(uint160(JBConstants.NATIVE_TOKEN));

    ConvertPeerValueHarness internal harness;

    function setUp() external {
        harness = new ConvertPeerValueHarness();
        vm.etch(CONTROLLER, hex"00");
        vm.etch(PRICES, hex"00");

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER, abi.encodeCall(IERC165.supportsInterface, (type(IJBController).interfaceId)), abi.encode(true)
        );
        vm.mockCall(CONTROLLER, abi.encodeCall(IJBController.PRICES, ()), abi.encode(PRICES));
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, uint32(ETH_CURRENCY), uint256(NATIVE_CURRENCY), 18)),
            abi.encode(uint256(1e18))
        );
    }

    function test_controllerPriceOracleConvertsRemoteEthSnapshot() external view {
        JBDenominatedAmount memory remoteEthSnapshot =
            JBDenominatedAmount({value: 10 ether, currency: uint32(ETH_CURRENCY), decimals: 18});

        uint256 converted =
            harness.convert(IJBDirectory(DIRECTORY), PROJECT_ID, remoteEthSnapshot, 18, uint256(NATIVE_CURRENCY));
        assertEq(converted, 10 ether, "controller price oracle should convert the remote value");
    }
}
