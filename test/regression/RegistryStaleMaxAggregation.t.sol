// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {JBPeerChainContext} from "../../src/structs/JBPeerChainContext.sol";
import {JBPeerChainValue} from "../../src/structs/JBPeerChainValue.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";

contract RegistryHarness is JBSuckerRegistry {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    constructor(
        address directory,
        address permissions,
        address prices
    )
        JBSuckerRegistry(
            IJBDirectory(directory), IJBPermissions(permissions), IJBPrices(prices), address(this), address(0)
        )
    {}

    function forceSet(uint256 projectId, address sucker, uint256 status) external {
        _suckersOf[projectId].set(sucker, status);
    }
}

/// @notice A sucker that reports one raw peer-chain context plus a supply, used to exercise the registry's per-chain
/// dedup and valuation. The context currency matches the test's query currency, so valuation is par (no feed).
contract MockAggregateSucker {
    uint256 public immutable chainId;
    uint256 public immutable snapshotTimestamp;
    uint256 public peerChainTotalSupply;
    uint128 internal immutable _surplus;
    uint32 internal immutable _currency;

    constructor(uint256 _chainId, uint256 _supply, uint128 surplus_, uint32 currency_, uint256 _snapshotTimestamp) {
        chainId = _chainId;
        peerChainTotalSupply = _supply;
        _surplus = surplus_;
        _currency = currency_;
        snapshotTimestamp = _snapshotTimestamp;
    }

    function peerChainId() external view returns (uint256) {
        return chainId;
    }

    function peerChainContextsOf() external view returns (JBPeerChainContext[] memory contexts, uint256, uint256) {
        contexts = new JBPeerChainContext[](1);
        contexts[0] = JBPeerChainContext({currency: _currency, decimals: 18, surplus: _surplus, balance: 0});
        return (contexts, chainId, snapshotTimestamp);
    }

    function peerChainTotalSupplyValue() external view returns (JBPeerChainValue memory) {
        return
            JBPeerChainValue({value: peerChainTotalSupply, peerChainId: chainId, snapshotTimestamp: snapshotTimestamp});
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
    address internal constant PRICES = address(0xA4);

    /// @dev The contexts use this currency and the queries request it, so valuation is par (no feed consulted).
    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 internal constant CURRENCY = uint32(uint160(address(0xEEE)));

    RegistryHarness internal registry;

    function setUp() public {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(IJBProjects(PROJECTS)));
        registry = new RegistryHarness(DIRECTORY, PERMISSIONS, PRICES);
    }

    function test_sameChainAggregationPrefersActiveValuesOverStaleDeprecatedValues() public {
        MockAggregateSucker deprecatedSucker = new MockAggregateSucker(CHAIN_ID, 1000e18, 500e18, CURRENCY, 1);
        MockAggregateSucker activeSucker = new MockAggregateSucker(CHAIN_ID, 100e18, 50e18, CURRENCY, 2);

        registry.forceSet(PROJECT_ID, address(deprecatedSucker), DEPRECATED);
        registry.forceSet(PROJECT_ID, address(activeSucker), ACTIVE);

        assertEq(
            registry.remoteTotalSupplyOf(PROJECT_ID),
            100e18,
            "active supply should win even when a deprecated sucker reports more"
        );
        assertEq(
            registry.totalRemoteSurplusOf(PROJECT_ID, CURRENCY, 18),
            50e18,
            "active surplus should win even when a deprecated sucker reports more"
        );
    }

    function test_sameChainActiveAggregationPrefersFreshLowerValuesOverStaleHigherValues() public {
        MockAggregateSucker staleActive = new MockAggregateSucker(CHAIN_ID, 1000e18, 500e18, CURRENCY, 1);
        MockAggregateSucker freshActive = new MockAggregateSucker(CHAIN_ID, 100e18, 50e18, CURRENCY, 2);

        registry.forceSet(PROJECT_ID, address(staleActive), ACTIVE);
        registry.forceSet(PROJECT_ID, address(freshActive), ACTIVE);

        assertEq(
            registry.remoteTotalSupplyOf(PROJECT_ID),
            100e18,
            "fresh active supply should win even when stale active reports more"
        );
        assertEq(
            registry.totalRemoteSurplusOf(PROJECT_ID, CURRENCY, 18),
            50e18,
            "fresh active surplus should win even when stale active reports more"
        );
    }
}
