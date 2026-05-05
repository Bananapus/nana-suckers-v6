// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";

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

contract SameChainSuckerMock {
    uint256 internal immutable _chainId;
    uint256 internal immutable _surplus;
    uint256 internal immutable _supply;

    constructor(uint256 chainId, uint256 surplus, uint256 supply) {
        _chainId = chainId;
        _surplus = surplus;
        _supply = supply;
    }

    function peerChainId() external view returns (uint256) {
        return _chainId;
    }

    function peerChainSurplusOf(uint256 decimals, uint256 currency) external view returns (JBDenominatedAmount memory) {
        return JBDenominatedAmount({value: _surplus, currency: uint32(currency), decimals: uint8(decimals)});
    }

    function peerChainTotalSupply() external view returns (uint256) {
        return _supply;
    }
}

contract RegistryStaleDeprecatedMaxSurplusTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant PEER_CHAIN_ID = 10;

    function test_freshActiveSnapshotDominatesStaleDeprecatedSameChainSurplus() external {
        RegistryHarness registry = new RegistryHarness();

        // Old deprecated sucker: stale surplus snapshot from before the migration.
        SameChainSuckerMock deprecatedSucker =
            new SameChainSuckerMock({chainId: PEER_CHAIN_ID, surplus: 1000 ether, supply: 100 ether});

        // New active sucker: fresh snapshot after the remote chain already spent most of its surplus.
        SameChainSuckerMock activeSucker =
            new SameChainSuckerMock({chainId: PEER_CHAIN_ID, surplus: 100 ether, supply: 100 ether});

        registry.seedDeprecated(PROJECT_ID, address(deprecatedSucker));
        registry.seedActive(PROJECT_ID, address(activeSucker));

        uint256 reportedRemoteSurplus = registry.remoteSurplusOf(PROJECT_ID, 18, uint256(uint160(address(0xEEE))));
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
