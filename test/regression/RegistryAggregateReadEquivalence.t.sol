// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../../src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBSourceContext} from "../../src/structs/JBSourceContext.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";
import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";

/// @notice A mock sucker that lets a test set its peer chain ID and populate a peer-chain snapshot
/// (total supply, balance, surplus, and freshness key) through the real `fromRemote` storage path.
contract AggregateMockSucker is JBSucker {
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

    function peerChainId() public view override returns (uint256) {
        return _peerChain;
    }

    function test_setDeprecatedAfter(uint256 timestamp) external {
        deprecatedAfter = timestamp;
    }

    /// @notice Populate the peer-chain snapshot fields the registry aggregates over.
    function test_setSnapshot(uint256 supply, uint256 balance, uint256 surplus, uint256 freshness) external {
        JBSourceContext[] memory contexts = new JBSourceContext[](1);
        contexts[0] = JBSourceContext({
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            decimals: 18,
            // forge-lint: disable-next-line(unsafe-typecast)
            surplus: uint128(surplus),
            // forge-lint: disable-next-line(unsafe-typecast)
            balance: uint128(balance)
        });

        JBMessageRoot memory root = JBMessageRoot({
            version: MESSAGE_VERSION,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: 0, root: bytes32(0)}),
            sourceTotalSupply: supply,
            sourceContexts: contexts,
            sourceTimestamp: freshness
        });

        // `_isRemotePeer` is overridden to always accept, so the populated snapshot is stored verbatim.
        this.fromRemote(root);
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

/// @notice A deployer that hands back pre-created suckers in registration order.
contract AggregateMockDeployer is IJBSuckerDeployer {
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

    function createForSender(uint256, bytes32, bytes32) external returns (IJBSucker) {
        IJBSucker sucker = _suckers[_index];
        _index++;
        return sucker;
    }
}

/// @title RegistryAggregateReadEquivalenceTest
/// @notice Pins the values returned by the registry's cross-chain aggregate views
/// (`totalRemoteBalanceOf` / `totalRemoteSurplusOf` / `remoteTotalSupplyOf`). These golden values must hold
/// regardless of how many calls the registry makes into each sucker, proving that folding the
/// per-sucker value / peer-chain-id / snapshot-freshness reads into a single call is behavior-preserving.
contract RegistryAggregateReadEquivalenceTest is Test {
    address internal constant DIRECTORY = address(0xD1);
    address internal constant PERMISSIONS = address(0xD2);
    address internal constant PROJECTS = address(0xD3);
    address internal constant TOKENS = address(0xD4);

    /// @dev Each context resolves to this currency and the queries request it, so valuation is par (no feed consulted),
    /// and any non-zero prices address suffices.
    address internal constant PRICES = address(0xD5);
    uint256 internal constant PROJECT_ID = 1;

    /// @dev With no local accounting context configured, each native context resolves to the token-keyed currency
    /// `uint32(uint160(NATIVE_TOKEN))`; the queries request that same currency, so the golden numbers are read at par.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 internal constant CURRENCY = uint32(uint160(JBConstants.NATIVE_TOKEN));
    uint8 internal constant ETH_DECIMALS = 18;

    JBSuckerRegistry internal registry;
    AggregateMockSucker internal suckerA;
    AggregateMockSucker internal suckerB;
    AggregateMockSucker internal suckerC;
    AggregateMockDeployer internal deployer;

    function setUp() public {
        vm.warp(100 days);

        vm.mockCall(DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(PROJECTS));
        vm.mockCall(PROJECTS, abi.encodeWithSelector(IERC721.ownerOf.selector, PROJECT_ID), abi.encode(address(this)));

        registry = new JBSuckerRegistry(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBPrices(PRICES), address(this), address(0)
        );

        AggregateMockSucker singleton =
            new AggregateMockSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS));

        suckerA = _clone(singleton, "aggregate-sucker-a");
        suckerB = _clone(singleton, "aggregate-sucker-b");
        suckerC = _clone(singleton, "aggregate-sucker-c");

        // Distinct peer chains by default; same-chain dedup is exercised in its own test.
        // The registry rejects a zero peer chain id at deploy time, so set these before registering.
        suckerA.test_setPeerChain(10); // Optimism
        suckerB.test_setPeerChain(42_161); // Arbitrum
        suckerC.test_setPeerChain(8453); // Base

        deployer = new AggregateMockDeployer();
        deployer.addSucker(IJBSucker(address(suckerA)));
        deployer.addSucker(IJBSucker(address(suckerB)));
        deployer.addSucker(IJBSucker(address(suckerC)));
        registry.allowSuckerDeployer(address(deployer));

        JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](3);
        for (uint256 i; i < 3; i++) {
            configs[i] =
                JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: new JBTokenMapping[](0)});
        }
        registry.deploySuckersFor({projectId: PROJECT_ID, salt: keccak256(bytes("aggregate")), configurations: configs});
    }

    function _clone(AggregateMockSucker singleton, bytes memory salt) internal returns (AggregateMockSucker clone) {
        // forge-lint: disable-next-line(unsafe-typecast)
        clone = AggregateMockSucker(payable(address(LibClone.cloneDeterministic(address(singleton), keccak256(salt)))));
        clone.initialize(PROJECT_ID);
    }

    /// @notice Three active suckers on three distinct peer chains sum independently across all three views.
    function test_distinctChainsSumIndependently() external {
        suckerA.test_setSnapshot({supply: 500e18, balance: 200e18, surplus: 100e18, freshness: 1});
        suckerB.test_setSnapshot({supply: 300e18, balance: 150e18, surplus: 80e18, freshness: 1});
        suckerC.test_setSnapshot({supply: 250e18, balance: 90e18, surplus: 40e18, freshness: 1});

        assertEq(registry.remoteTotalSupplyOf(PROJECT_ID), 1050e18, "total supply sums across distinct chains");
        assertEq(
            registry.totalRemoteBalanceOf({projectId: PROJECT_ID, currency: CURRENCY, decimals: ETH_DECIMALS}),
            440e18,
            "balance sums across distinct chains"
        );
        assertEq(
            registry.totalRemoteSurplusOf({projectId: PROJECT_ID, currency: CURRENCY, decimals: ETH_DECIMALS}),
            220e18,
            "surplus sums across distinct chains"
        );
    }

    /// @notice Two suckers on the SAME peer chain dedupe to the freshest snapshot, not the sum.
    function test_sameChainDedupesToFreshest() external {
        // suckerA and suckerB both report chain 10; suckerB's snapshot is fresher and must win.
        suckerA.test_setPeerChain(10);
        suckerB.test_setPeerChain(10);
        suckerC.test_setPeerChain(8453);

        suckerA.test_setSnapshot({supply: 500e18, balance: 200e18, surplus: 100e18, freshness: 1});
        suckerB.test_setSnapshot({supply: 700e18, balance: 350e18, surplus: 180e18, freshness: 5});
        suckerC.test_setSnapshot({supply: 250e18, balance: 90e18, surplus: 40e18, freshness: 1});

        // Chain 10 collapses to suckerB (freshest); chain 8453 adds suckerC.
        assertEq(registry.remoteTotalSupplyOf(PROJECT_ID), 950e18, "same-chain dedupe keeps the freshest supply");
        assertEq(
            registry.totalRemoteBalanceOf({projectId: PROJECT_ID, currency: CURRENCY, decimals: ETH_DECIMALS}),
            440e18,
            "same-chain dedupe keeps the freshest balance"
        );
        assertEq(
            registry.totalRemoteSurplusOf({projectId: PROJECT_ID, currency: CURRENCY, decimals: ETH_DECIMALS}),
            220e18,
            "same-chain dedupe keeps the freshest surplus"
        );
    }

    /// @notice A deprecated sucker still contributes when no active sucker answers for its chain.
    function test_deprecatedFallbackStillCounts() external {
        suckerA.test_setSnapshot({supply: 500e18, balance: 200e18, surplus: 100e18, freshness: 1});
        suckerB.test_setSnapshot({supply: 300e18, balance: 150e18, surplus: 80e18, freshness: 1});
        suckerC.test_setSnapshot({supply: 250e18, balance: 90e18, surplus: 40e18, freshness: 1});

        // Deprecate and remove suckerA from active listings; its chain (10) has no other answerer.
        suckerA.test_setDeprecatedAfter(block.timestamp - 1);
        registry.removeDeprecatedSucker({projectId: PROJECT_ID, sucker: address(suckerA)});

        assertEq(registry.remoteTotalSupplyOf(PROJECT_ID), 1050e18, "deprecated fallback keeps its supply");
        assertEq(
            registry.totalRemoteBalanceOf({projectId: PROJECT_ID, currency: CURRENCY, decimals: ETH_DECIMALS}),
            440e18,
            "deprecated fallback keeps its balance"
        );
        assertEq(
            registry.totalRemoteSurplusOf({projectId: PROJECT_ID, currency: CURRENCY, decimals: ETH_DECIMALS}),
            220e18,
            "deprecated fallback keeps its surplus"
        );
    }

    /// @notice An active sucker on a chain overrides a deprecated sucker's stale snapshot for that chain.
    function test_activeOverridesDeprecatedSameChain() external {
        suckerA.test_setPeerChain(10);
        suckerB.test_setPeerChain(10);
        suckerC.test_setPeerChain(8453);

        suckerA.test_setSnapshot({supply: 900e18, balance: 600e18, surplus: 400e18, freshness: 9});
        suckerB.test_setSnapshot({supply: 300e18, balance: 150e18, surplus: 80e18, freshness: 1});
        suckerC.test_setSnapshot({supply: 250e18, balance: 90e18, surplus: 40e18, freshness: 1});

        // Deprecate suckerA (the fresher one) — the remaining ACTIVE suckerB must win for chain 10,
        // even though the deprecated snapshot is fresher.
        suckerA.test_setDeprecatedAfter(block.timestamp - 1);
        registry.removeDeprecatedSucker({projectId: PROJECT_ID, sucker: address(suckerA)});

        // Chain 10 = active suckerB (300/150/80); chain 8453 = suckerC (250/90/40).
        assertEq(registry.remoteTotalSupplyOf(PROJECT_ID), 550e18, "active sucker overrides deprecated supply");
        assertEq(
            registry.totalRemoteBalanceOf({projectId: PROJECT_ID, currency: CURRENCY, decimals: ETH_DECIMALS}),
            240e18,
            "active sucker overrides deprecated balance"
        );
        assertEq(
            registry.totalRemoteSurplusOf({projectId: PROJECT_ID, currency: CURRENCY, decimals: ETH_DECIMALS}),
            120e18,
            "active sucker overrides deprecated surplus"
        );
    }

    /// @notice A sucker that reports a zero peer chain id reverts every aggregate view (after a successful value read).
    function test_zeroPeerChainIdRevertsAllViews() external {
        suckerA.test_setSnapshot({supply: 500e18, balance: 200e18, surplus: 100e18, freshness: 1});
        suckerB.test_setSnapshot({supply: 300e18, balance: 150e18, surplus: 80e18, freshness: 1});
        suckerC.test_setSnapshot({supply: 250e18, balance: 90e18, surplus: 40e18, freshness: 1});

        // Force suckerB to report a zero peer chain id.
        suckerB.test_setPeerChain(0);

        bytes memory expectedRevert =
            abi.encodeWithSelector(JBSuckerRegistry.JBSuckerRegistry_ZeroPeerChainId.selector, address(suckerB));

        vm.expectRevert(expectedRevert);
        registry.remoteTotalSupplyOf(PROJECT_ID);

        vm.expectRevert(expectedRevert);
        registry.totalRemoteBalanceOf({projectId: PROJECT_ID, currency: CURRENCY, decimals: ETH_DECIMALS});

        vm.expectRevert(expectedRevert);
        registry.totalRemoteSurplusOf({projectId: PROJECT_ID, currency: CURRENCY, decimals: ETH_DECIMALS});
    }

    /// @notice With no snapshots populated, every aggregate view returns zero.
    function test_emptySnapshotsReturnZero() external view {
        assertEq(registry.remoteTotalSupplyOf(PROJECT_ID), 0, "no snapshot => zero supply");
        assertEq(
            registry.totalRemoteBalanceOf({projectId: PROJECT_ID, currency: CURRENCY, decimals: ETH_DECIMALS}),
            0,
            "no snapshot => zero balance"
        );
        assertEq(
            registry.totalRemoteSurplusOf({projectId: PROJECT_ID, currency: CURRENCY, decimals: ETH_DECIMALS}),
            0,
            "no snapshot => zero surplus"
        );
    }
}
