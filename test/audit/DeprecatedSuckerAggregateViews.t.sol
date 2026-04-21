// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../../src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";
import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";

/// @notice A mock sucker whose peer chain ID, total supply, balance, and surplus can be set for testing.
contract DeprecatedViewMockSucker is JBSucker {
    uint256 internal _peerChain;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function test_setPeerChain(uint256 chainId) external {
        _peerChain = chainId;
    }

    function peerChainId() external view override returns (uint256) {
        return _peerChain;
    }

    function test_setPeerChainTotalSupply(uint256 supply) external {
        peerChainTotalSupply = supply;
    }

    function test_setDeprecatedAfter(uint256 timestamp) external {
        deprecatedAfter = timestamp;
    }

    function _isRemotePeer(address) internal pure override returns (bool) {
        return true;
    }

    function _sendRootOverAMB(
        uint256,
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBMessageRoot memory
    )
        internal
        override
    {}
}

/// @notice A deployer that returns a pre-created sucker. Allows deploying multiple distinct suckers.
contract DeprecatedViewMockDeployer is IJBSuckerDeployer {
    IJBSucker[] internal _suckers;
    uint256 internal _index;

    function addSucker(IJBSucker sucker) external {
        _suckers.push(sucker);
    }

    function DIRECTORY() external pure returns (IJBDirectory) {
        return IJBDirectory(address(0));
    }

    function LAYER_SPECIFIC_CONFIGURATOR() external pure returns (address) {
        return address(0);
    }

    function TOKENS() external pure returns (IJBTokens) {
        return IJBTokens(address(0));
    }

    function isSucker(address addr) external view returns (bool) {
        for (uint256 i; i < _suckers.length; i++) {
            if (addr == address(_suckers[i])) return true;
        }
        return false;
    }

    function createForSender(uint256, bytes32) external returns (IJBSucker) {
        IJBSucker sucker = _suckers[_index];
        _index++;
        return sucker;
    }
}

/// @title DeprecatedSuckerAggregateViewsTest
/// @notice Tests that remoteTotalSupplyOf includes deprecated suckers and uses per-chain
/// deduplication to prevent double-counting during migration windows.
contract DeprecatedSuckerAggregateViewsTest is Test {
    address internal constant DIRECTORY = address(0xD1);
    address internal constant PERMISSIONS = address(0xD2);
    address internal constant PROJECTS = address(0xD3);
    address internal constant TOKENS = address(0xD4);
    uint256 internal constant PROJECT_ID = 1;

    JBSuckerRegistry internal registry;
    DeprecatedViewMockSucker internal suckerA;
    DeprecatedViewMockSucker internal suckerB;
    DeprecatedViewMockDeployer internal deployer;

    function setUp() public {
        vm.warp(100 days);

        vm.mockCall(DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(PROJECTS));
        vm.mockCall(PROJECTS, abi.encodeWithSelector(IERC721.ownerOf.selector, PROJECT_ID), abi.encode(address(this)));

        registry = new JBSuckerRegistry(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), address(this), address(0));

        // Create singleton.
        DeprecatedViewMockSucker singleton =
            new DeprecatedViewMockSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS));

        // Clone two suckers targeting different chains.
        suckerA = DeprecatedViewMockSucker(
            payable(address(LibClone.cloneDeterministic(address(singleton), bytes32("dedup-sucker-a"))))
        );
        suckerA.initialize(PROJECT_ID);
        suckerA.test_setPeerChain(10); // Optimism

        suckerB = DeprecatedViewMockSucker(
            payable(address(LibClone.cloneDeterministic(address(singleton), bytes32("dedup-sucker-b"))))
        );
        suckerB.initialize(PROJECT_ID);
        suckerB.test_setPeerChain(42_161); // Arbitrum

        // Register both via deployer.
        deployer = new DeprecatedViewMockDeployer();
        deployer.addSucker(IJBSucker(address(suckerA)));
        deployer.addSucker(IJBSucker(address(suckerB)));
        registry.allowSuckerDeployer(address(deployer));

        JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](2);
        configs[0] = JBSuckerDeployerConfig({deployer: deployer, mappings: new JBTokenMapping[](0)});
        configs[1] = JBSuckerDeployerConfig({deployer: deployer, mappings: new JBTokenMapping[](0)});
        registry.deploySuckersFor({projectId: PROJECT_ID, salt: bytes32("dedup"), configurations: configs});
    }

    /// @notice After removing a deprecated sucker, its supply must still be included in
    /// remoteTotalSupplyOf to prevent undercounting during migration windows.
    function test_deprecatedSuckerSupplyIncludedInRemoteTotalSupply() external {
        suckerA.test_setPeerChainTotalSupply(500e18);
        suckerB.test_setPeerChainTotalSupply(300e18);

        // Before deprecation: both suckers contribute.
        uint256 supplyBefore = registry.remoteTotalSupplyOf(PROJECT_ID);
        assertEq(supplyBefore, 800e18, "both active suckers contribute to total supply");

        // Deprecate and remove sucker A.
        suckerA.test_setDeprecatedAfter(block.timestamp - 1);
        registry.removeDeprecatedSucker({projectId: PROJECT_ID, sucker: address(suckerA)});

        // After removal: deprecated sucker A must still be counted.
        uint256 supplyAfter = registry.remoteTotalSupplyOf(PROJECT_ID);
        assertEq(supplyAfter, 800e18, "deprecated sucker supply must still be included in aggregate views");
    }

    /// @notice When both a deprecated and an active sucker target the same chain, the registry
    /// must take the max (not the sum) to prevent double-counting.
    function test_sameChainDeprecatedAndActiveDoesNotDoubleCount() external {
        // Make both suckers target the same chain.
        suckerA.test_setPeerChain(10);
        suckerB.test_setPeerChain(10);

        suckerA.test_setPeerChainTotalSupply(1000e18);
        suckerB.test_setPeerChainTotalSupply(800e18);

        // Deprecate sucker A (the one with higher supply).
        suckerA.test_setDeprecatedAfter(block.timestamp - 1);
        registry.removeDeprecatedSucker({projectId: PROJECT_ID, sucker: address(suckerA)});

        // The registry should take max(1000, 800) = 1000, NOT sum(1000 + 800) = 1800.
        uint256 totalSupply = registry.remoteTotalSupplyOf(PROJECT_ID);
        assertEq(totalSupply, 1000e18, "same-chain suckers should use max, not sum (dedup)");
    }

    /// @notice When deprecated and active suckers target different chains, both contribute
    /// independently (no dedup needed across chains).
    function test_differentChainSuckersSumNormally() external {
        suckerA.test_setPeerChain(10);
        suckerB.test_setPeerChain(42_161);

        suckerA.test_setPeerChainTotalSupply(500e18);
        suckerB.test_setPeerChainTotalSupply(300e18);

        // Deprecate sucker A.
        suckerA.test_setDeprecatedAfter(block.timestamp - 1);
        registry.removeDeprecatedSucker({projectId: PROJECT_ID, sucker: address(suckerA)});

        // Different chains: sum normally.
        uint256 totalSupply = registry.remoteTotalSupplyOf(PROJECT_ID);
        assertEq(totalSupply, 800e18, "different-chain suckers sum independently");
    }

    /// @notice Same-chain dedup takes the max even when the active sucker has higher supply.
    function test_sameChainDedupTakesMaxActiveHigher() external {
        suckerA.test_setPeerChain(10);
        suckerB.test_setPeerChain(10);

        suckerA.test_setPeerChainTotalSupply(200e18);
        suckerB.test_setPeerChainTotalSupply(900e18);

        // Deprecate sucker A (the one with lower supply).
        suckerA.test_setDeprecatedAfter(block.timestamp - 1);
        registry.removeDeprecatedSucker({projectId: PROJECT_ID, sucker: address(suckerA)});

        // max(200, 900) = 900.
        uint256 totalSupply = registry.remoteTotalSupplyOf(PROJECT_ID);
        assertEq(totalSupply, 900e18, "dedup should take max when active sucker has higher supply");
    }

    /// @notice isSuckerOf still returns true for deprecated suckers (mint permission retained).
    function test_isSuckerOfReturnsTrueForDeprecated() external {
        suckerA.test_setDeprecatedAfter(block.timestamp - 1);
        registry.removeDeprecatedSucker({projectId: PROJECT_ID, sucker: address(suckerA)});

        assertTrue(
            registry.isSuckerOf(PROJECT_ID, address(suckerA)), "isSuckerOf must return true for deprecated suckers"
        );
    }

    /// @notice suckersOf (active listing) excludes deprecated suckers.
    function test_suckersOfExcludesDeprecated() external {
        suckerA.test_setDeprecatedAfter(block.timestamp - 1);
        registry.removeDeprecatedSucker({projectId: PROJECT_ID, sucker: address(suckerA)});

        address[] memory active = registry.suckersOf(PROJECT_ID);
        assertEq(active.length, 1, "only the active sucker should appear in suckersOf");
        assertEq(active[0], address(suckerB), "the remaining active sucker should be sucker B");
    }
}
