// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {JBPeerChainContext} from "../../src/structs/JBPeerChainContext.sol";
import {JBPeerChainValue} from "../../src/structs/JBPeerChainValue.sol";

contract RegistryProjectsMock {
    function ownerOf(uint256) external pure returns (address) {
        return address(0xBEEF);
    }
}

contract RegistryDirectoryMock {
    IJBProjects internal immutable _projects = IJBProjects(address(new RegistryProjectsMock()));

    function PROJECTS() external view returns (IJBProjects) {
        return _projects;
    }

    receive() external payable {}

    fallback() external payable {
        revert("unimplemented");
    }
}

contract RegistryHarness is JBSuckerRegistry {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    constructor()
        JBSuckerRegistry(
            IJBDirectory(address(new RegistryDirectoryMock())),
            IJBPermissions(address(0x1234)),
            IJBPrices(address(0xA4)),
            address(this),
            address(0)
        )
    {}

    function seedActive(uint256 projectId, address sucker) external {
        _suckersOf[projectId].set(sucker, _SUCKER_EXISTS);
    }

    function seedDeprecated(uint256 projectId, address sucker) external {
        _suckersOf[projectId].set(sucker, _SUCKER_DEPRECATED);
    }
}

/// @notice A sucker that reports one raw peer-chain context plus a supply for a single peer chain. The context currency
/// matches the test's query currency, so the registry values it at par (no price feed). The mock exposes no snapshot
/// freshness, so the reads report a zero freshness key; active-over-deprecated selection does not depend on freshness.
contract SameChainSuckerMock {
    uint256 internal immutable _chainId;
    uint128 internal immutable _surplus;
    uint256 internal immutable _supply;
    uint32 internal immutable _currency;

    constructor(uint256 chainId, uint128 surplus, uint256 supply, uint32 currency) {
        _chainId = chainId;
        _surplus = surplus;
        _supply = supply;
        _currency = currency;
    }

    function peerChainId() external view returns (uint256) {
        return _chainId;
    }

    function peerChainContextsOf() external view returns (JBPeerChainContext[] memory contexts, uint256, uint256) {
        contexts = new JBPeerChainContext[](1);
        contexts[0] = JBPeerChainContext({currency: _currency, decimals: 18, surplus: _surplus, balance: 0});
        return (contexts, _chainId, 0);
    }

    function peerChainTotalSupply() external view returns (uint256) {
        return _supply;
    }

    function peerChainTotalSupplyValue() external view returns (JBPeerChainValue memory) {
        return JBPeerChainValue({value: _supply, peerChainId: _chainId, snapshotTimestamp: 0});
    }
}

contract RegistryStaleDeprecatedMaxSurplusTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant PEER_CHAIN_ID = 10;

    /// @dev The contexts use this currency and the query requests it, so valuation is par (no feed consulted).
    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 internal constant CURRENCY = uint32(uint160(address(0xEEE)));

    function test_freshActiveSnapshotDominatesStaleDeprecatedSameChainSurplus() external {
        RegistryHarness registry = new RegistryHarness();

        // Old deprecated sucker: stale surplus snapshot from before the migration.
        SameChainSuckerMock deprecatedSucker = new SameChainSuckerMock({
            chainId: PEER_CHAIN_ID, surplus: 1000 ether, supply: 100 ether, currency: CURRENCY
        });

        // New active sucker: fresh snapshot after the remote chain already spent most of its surplus.
        SameChainSuckerMock activeSucker = new SameChainSuckerMock({
            chainId: PEER_CHAIN_ID, surplus: 100 ether, supply: 100 ether, currency: CURRENCY
        });

        registry.seedDeprecated(PROJECT_ID, address(deprecatedSucker));
        registry.seedActive(PROJECT_ID, address(activeSucker));

        uint256 reportedRemoteSurplus = registry.totalRemoteSurplusOf(PROJECT_ID, CURRENCY, 18);
        uint256 reportedRemoteSupply = registry.remoteTotalSupplyOf(PROJECT_ID);

        // The registry prefers the live active sucker over stale deprecated same-chain snapshots.
        assertEq(reportedRemoteSurplus, 100 ether, "fresh active surplus should dominate");
        assertEq(reportedRemoteSupply, 100 ether, "supply stays on the fresh/current value");

        uint256 localSurplus = 100 ether;
        uint256 localSupply = 100 ether;
        uint256 holderCashOut = 100 ether;

        uint256 payoutUsingRegistryValue = JBCashOuts.cashOutFrom({
            surplus: localSurplus + reportedRemoteSurplus,
            cashOutCount: holderCashOut,
            totalSupply: localSupply + reportedRemoteSupply,
            cashOutTaxRate: 0
        });

        uint256 payoutUsingFreshSameChainValue = JBCashOuts.cashOutFrom({
            surplus: localSurplus + 100 ether,
            cashOutCount: holderCashOut,
            totalSupply: localSupply + 100 ether,
            cashOutTaxRate: 0
        });

        assertEq(payoutUsingFreshSameChainValue, 100 ether, "fresh omnichain accounting");
        assertEq(payoutUsingRegistryValue, payoutUsingFreshSameChainValue, "registry uses fresh omnichain accounting");
    }
}
