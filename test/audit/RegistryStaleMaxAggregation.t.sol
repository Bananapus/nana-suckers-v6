// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";

contract RegistryHarness is JBSuckerRegistry {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    constructor(
        address directory,
        address permissions
    )
        JBSuckerRegistry(IJBDirectory(directory), IJBPermissions(permissions), address(this), address(0))
    {}

    function forceSet(uint256 projectId, address sucker, uint256 status) external {
        _suckersOf[projectId].set(sucker, status);
    }
}

contract MockAggregateSucker {
    uint256 public immutable chainId;
    uint256 public peerChainTotalSupply;
    uint256 public surplus;

    constructor(uint256 _chainId, uint256 _supply, uint256 _surplus) {
        chainId = _chainId;
        peerChainTotalSupply = _supply;
        surplus = _surplus;
    }

    function peerChainId() external view returns (uint256) {
        return chainId;
    }

    function peerChainSurplusOf(uint256 decimals, uint256 currency) external view returns (JBDenominatedAmount memory) {
        return JBDenominatedAmount({value: surplus, currency: uint32(currency), decimals: uint8(decimals)});
    }

    function peerChainBalanceOf(uint256 decimals, uint256 currency) external pure returns (JBDenominatedAmount memory) {
        return JBDenominatedAmount({value: 0, currency: uint32(currency), decimals: uint8(decimals)});
    }
}

contract RegistryStaleMaxAggregationTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant CHAIN_ID = 42_161;
    uint256 internal constant ACTIVE = 1;
    uint256 internal constant DEPRECATED = 2;

    address internal constant DIRECTORY = address(0xA1);
    address internal constant PERMISSIONS = address(0xA2);
    address internal constant PROJECTS = address(0xA3);

    RegistryHarness internal registry;

    function setUp() public {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(IJBProjects(PROJECTS)));
        registry = new RegistryHarness(DIRECTORY, PERMISSIONS);
    }

    function test_sameChainAggregationPrefersActiveValuesOverStaleDeprecatedValues() public {
        MockAggregateSucker deprecatedSucker = new MockAggregateSucker(CHAIN_ID, 1000e18, 500e18);
        MockAggregateSucker activeSucker = new MockAggregateSucker(CHAIN_ID, 100e18, 50e18);

        registry.forceSet(PROJECT_ID, address(deprecatedSucker), DEPRECATED);
        registry.forceSet(PROJECT_ID, address(activeSucker), ACTIVE);

        assertEq(
            registry.remoteTotalSupplyOf(PROJECT_ID),
            100e18,
            "active supply should win even when a deprecated sucker reports more"
        );
        assertEq(
            registry.remoteSurplusOf(PROJECT_ID, 18, uint256(uint160(address(0xEEE)))),
            50e18,
            "active surplus should win even when a deprecated sucker reports more"
        );
    }
}
