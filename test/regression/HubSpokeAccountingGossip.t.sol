// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../../src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBAccountingSnapshot} from "../../src/structs/JBAccountingSnapshot.sol";
import {JBChainAccounting} from "../../src/structs/JBChainAccounting.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBSourceContext} from "../../src/structs/JBSourceContext.sol";
import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";

/// @notice A real `JBSucker` with a settable direct-peer chain, a permissive peer auth, an inbound-bundle helper, and
/// outbound-bundle capture. Used to drive the cross-chain accounting gossip end to end against a real registry.
contract GossipSuckerHarness is JBSucker {
    uint256 internal _peerChainId;
    JBChainAccounting[] internal _lastSentBundle;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        IJBSuckerRegistry registry
    )
        JBSucker(directory, permissions, tokens, 1, registry, address(0))
    {}

    function test_setPeerChainId(uint256 chainId) external {
        _peerChainId = chainId;
    }

    /// @notice Deliver a gossip bundle as if relayed from the peer.
    function test_receive(JBChainAccounting[] calldata accounts) external {
        this.fromRemoteAccounting(JBAccountingSnapshot({version: MESSAGE_VERSION, accounts: accounts}));
    }

    function test_lastSentBundle() external view returns (JBChainAccounting[] memory) {
        return _lastSentBundle;
    }

    function peerChainId() public view override returns (uint256) {
        return _peerChainId;
    }

    function _isRemotePeer(address) internal pure override returns (bool) {
        return true;
    }

    function _sendAccountingSnapshotOverAMB(uint256, JBAccountingSnapshot memory snapshot) internal override {
        _captureBundle(snapshot.accounts);
    }

    function _sendRootOverAMB(
        uint256,
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBMessageRoot memory message
    )
        internal
        override
    {
        _captureBundle(message.accounts);
    }

    function _captureBundle(JBChainAccounting[] memory accounts) internal {
        delete _lastSentBundle;
        for (uint256 i; i < accounts.length;) {
            _lastSentBundle.push(accounts[i]);
            unchecked {
                ++i;
            }
        }
    }
}

/// @notice A deployer stub that hands a pre-created sucker back to `deploySuckersFor`, so a harness clone can be
/// registered against a real `JBSuckerRegistry`.
contract StubDeployer is IJBSuckerDeployer {
    IJBSucker internal _sucker;

    function setSucker(IJBSucker sucker) external {
        _sucker = sucker;
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

    function isSucker(address sucker) external view returns (bool) {
        return sucker == address(_sucker);
    }

    function createForSender(uint256, bytes32, bytes32) external view returns (IJBSucker) {
        return _sucker;
    }
}

/// @notice A prices contract that values every same-currency lookup at par (the only conversion these tests need).
contract ParPrices {
    function pricePerUnitOf(uint256, uint256, uint256, uint256 decimals) external pure returns (uint256) {
        return 10 ** decimals;
    }
}

/// @notice End-to-end coverage for the cross-chain accounting gossip: a project's accounting propagates across a
/// hub-and-spoke sucker mesh (L2 spokes bridged only through a mainnet hub) without a direct sucker between every pair
/// of chains.
/// @dev The single local EVM is the implicit "own" chain (`block.chainid`); records carry remote chain ids. The hub
/// holds one sucker per spoke (each tracking that spoke), while a spoke holds one sucker to the hub that accumulates
/// every chain it hears about. The registry is real, so its cross-sucker aggregation and re-gossip gather are
/// exercised.
contract HubSpokeAccountingGossipTest is Test {
    address internal constant DIRECTORY = address(0xD1);
    address internal constant PERMISSIONS = address(0xD2);
    address internal constant PROJECTS = address(0xD3);
    address internal constant TOKENS = address(0xD4);
    address internal constant CONTROLLER = address(0xD5);

    uint256 internal constant HUB_PROJECT = 1;
    uint256 internal constant SPOKE_PROJECT = 2;

    // Remote chain ids carried by gossip records — all distinct from the local `block.chainid`.
    uint256 internal constant MAINNET = 1;
    uint256 internal constant OPTIMISM = 10;
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant BASE = 8453;

    JBSuckerRegistry internal registry;
    GossipSuckerHarness internal singleton;
    uint256 internal saltNonce;

    function setUp() public {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));
        vm.mockCall(PROJECTS, abi.encodeWithSelector(IERC721.ownerOf.selector), abi.encode(address(this)));

        registry = new JBSuckerRegistry({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            prices: IJBPrices(address(new ParPrices())),
            initialOwner: address(this),
            trustedForwarder: address(0)
        });

        singleton = new GossipSuckerHarness(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), IJBSuckerRegistry(registry)
        );
    }

    // =========================================================================
    // Headline: a spoke learns sibling-spoke accounting it has no direct sucker to.
    // =========================================================================

    /// @notice A spoke holds a single sucker to the hub. After the hub gossips a bundle carrying the hub's own record
    /// plus the records it forwards for the other spokes, the spoke's registry aggregates the FULL cross-chain supply
    /// and surplus — including the sibling spokes the spoke has no direct sucker to.
    function test_spokeLearnsSiblingSpokesFromHubGossip() external {
        GossipSuckerHarness spoke = _registeredSucker(SPOKE_PROJECT, MAINNET);

        // The hub relays its own record (mainnet) plus the records it forwards for the two other spokes.
        JBChainAccounting[] memory bundle = new JBChainAccounting[](3);
        bundle[0] = _record(MAINNET, 100 ether, 40 ether, 1);
        bundle[1] = _record(OPTIMISM, 200 ether, 70 ether, 1);
        bundle[2] = _record(ARBITRUM, 300 ether, 90 ether, 1);
        spoke.test_receive(bundle);

        // The spoke is directly bridged only to the hub (mainnet), but virtually knows all three chains.
        assertEq(spoke.peerChainIds(false).length, 1, "directly bridged only to the hub");
        assertEq(spoke.peerChainIds(false)[0], MAINNET, "the direct peer is the hub");
        assertEq(spoke.peerChainIds(true).length, 3, "virtually tracks every chain the hub gossiped");

        // The registry sums every chain's supply, including the sibling spokes reached only through the hub.
        assertEq(
            registry.remoteTotalSupplyOf(SPOKE_PROJECT),
            600 ether,
            "cross-chain supply includes mainnet + both sibling spokes"
        );

        // Surplus aggregates the same way (native contexts value at par).
        assertEq(
            registry.totalRemoteSurplusOf(SPOKE_PROJECT, _nativeCurrency(), 18),
            200 ether,
            "cross-chain surplus includes mainnet + both sibling spokes"
        );
    }

    // =========================================================================
    // Hub side: the registry gathers sibling-sucker records for re-gossip, minus the destination.
    // =========================================================================

    /// @notice On the hub, each spoke's accounting lives in a separate sucker. The registry's `peerChainAccountsOf`
    /// gathers all of them, deduped per chain, excluding the destination chain — which is exactly the peer set a hub
    /// sucker forwards to a spoke.
    function test_hubRegistryGathersSiblingRecordsExcludingDestination() external {
        _hubSuckerHolding(OPTIMISM, 200 ether, 70 ether);
        _hubSuckerHolding(ARBITRUM, 300 ether, 90 ether);
        _hubSuckerHolding(BASE, 400 ether, 120 ether);

        // Sending to the Optimism spoke excludes Optimism's own record; the gather is what the hub forwards.
        JBChainAccounting[] memory gathered = registry.peerChainAccountsOf(HUB_PROJECT, OPTIMISM);
        assertEq(gathered.length, 2, "gather excludes the destination chain");

        (bool hasArb, JBChainAccounting memory arb) = _find(gathered, ARBITRUM);
        (bool hasBase, JBChainAccounting memory base) = _find(gathered, BASE);
        (bool hasOp,) = _find(gathered, OPTIMISM);
        assertTrue(hasArb && hasBase, "gather carries the other spokes");
        assertTrue(!hasOp, "gather omits the destination spoke");
        assertEq(arb.totalSupply, 300 ether, "forwarded record keeps its supply");
        assertEq(base.totalSupply, 400 ether, "forwarded record keeps its supply");
    }

    // =========================================================================
    // End-to-end build: a hub sucker's outbound bundle is its own record plus the gathered siblings.
    // =========================================================================

    /// @notice When a hub sucker builds an outbound gossip bundle, it leads with its own chain's record and appends the
    /// sibling-spoke records gathered from the registry, excluding the destination spoke.
    function test_hubSuckerBuildsOwnPlusSiblingBundle() external {
        // Two sibling suckers hold the other spokes' data.
        _hubSuckerHolding(ARBITRUM, 300 ether, 90 ether);
        _hubSuckerHolding(BASE, 400 ether, 120 ether);

        // The sucker that sends to the Optimism spoke. The hub's own local supply is read through the controller.
        _mockLocalSupply(HUB_PROJECT, 500 ether);
        GossipSuckerHarness sender = _registeredSucker(HUB_PROJECT, OPTIMISM);
        sender.syncAccountingData();

        JBChainAccounting[] memory sent = sender.test_lastSentBundle();
        assertEq(sent.length, 3, "own record plus the two siblings");
        assertEq(sent[0].chainId, block.chainid, "local record leads the bundle");
        assertEq(sent[0].totalSupply, 500 ether, "local record carries the local supply");

        (bool hasArb,) = _find(sent, ARBITRUM);
        (bool hasBase,) = _find(sent, BASE);
        (bool hasOp,) = _find(sent, OPTIMISM);
        assertTrue(hasArb && hasBase, "siblings forwarded");
        assertTrue(!hasOp, "destination spoke excluded");
    }

    // =========================================================================
    // Per-chain freshness, and dropping self / zero chain records.
    // =========================================================================

    /// @notice Each source chain is gated independently: a staler record never rolls a chain back, a fresher one
    /// supersedes it, and records for the local chain or chain 0 are dropped as not-a-peer.
    function test_perChainFreshnessAndSelfDrop() external {
        GossipSuckerHarness spoke = _registeredSucker(SPOKE_PROJECT, MAINNET);

        // Establish Optimism at freshness 5.
        spoke.test_receive(_single(_record(OPTIMISM, 200 ether, 70 ether, 5)));
        assertEq(spoke.peerChainTotalSupplyOf(OPTIMISM), 200 ether, "optimism stored");

        // A staler Optimism record is ignored.
        spoke.test_receive(_single(_record(OPTIMISM, 999 ether, 999 ether, 4)));
        assertEq(spoke.peerChainTotalSupplyOf(OPTIMISM), 200 ether, "stale relay does not roll the chain back");

        // A fresher Optimism record supersedes it.
        spoke.test_receive(_single(_record(OPTIMISM, 250 ether, 80 ether, 6)));
        assertEq(spoke.peerChainTotalSupplyOf(OPTIMISM), 250 ether, "fresher relay supersedes");

        // A record for the local chain and one for chain 0 are both dropped.
        JBChainAccounting[] memory junk = new JBChainAccounting[](2);
        junk[0] = _record(block.chainid, 123 ether, 0, 9);
        junk[1] = _record(0, 456 ether, 0, 9);
        spoke.test_receive(junk);

        // Only the optimism record was stored; the self and chain-0 junk never entered the store.
        JBChainAccounting[] memory stored = spoke.peerChainAccountsOf();
        assertEq(stored.length, 1, "only optimism is stored; self and chain 0 are dropped");
        assertEq(stored[0].chainId, OPTIMISM, "self and chain 0 never enter the store");

        // The aggregate reflects optimism (250) plus the hub's own direct-peer claim (0 — no record delivered).
        assertEq(registry.remoteTotalSupplyOf(SPOKE_PROJECT), 250 ether, "aggregate reflects the real peer chains");
    }

    // =========================================================================
    // helpers
    // =========================================================================

    /// @notice Clone, initialize, set the direct peer chain, and register a sucker for a project against the registry.
    function _registeredSucker(uint256 projectId, uint256 peerChainId) internal returns (GossipSuckerHarness sucker) {
        sucker = GossipSuckerHarness(
            payable(address(LibClone.cloneDeterministic(address(singleton), keccak256(abi.encode(saltNonce++)))))
        );
        sucker.initialize(projectId);
        sucker.test_setPeerChainId(peerChainId);

        StubDeployer deployer = new StubDeployer();
        deployer.setSucker(IJBSucker(address(sucker)));
        registry.allowSuckerDeployer(address(deployer));

        JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](1);
        configs[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: new JBTokenMapping[](0)});
        registry.deploySuckersFor({
            projectId: projectId, salt: keccak256(abi.encode(saltNonce++)), configurations: configs
        });
    }

    /// @notice Register a hub sucker for `HUB_PROJECT` peered to `chainId`, and seed it with that chain's record.
    function _hubSuckerHolding(uint256 chainId, uint256 supply, uint256 surplus) internal {
        GossipSuckerHarness sucker = _registeredSucker(HUB_PROJECT, chainId);
        sucker.test_receive(_single(_record(chainId, supply, surplus, 1)));
    }

    /// @notice One accounting record for `chainId` carrying a single native-token context.
    function _record(
        uint256 chainId,
        uint256 supply,
        uint256 surplus,
        uint256 freshness
    )
        internal
        pure
        returns (JBChainAccounting memory)
    {
        JBSourceContext[] memory contexts = new JBSourceContext[](1);
        contexts[0] = JBSourceContext({
            token: bytes32(uint256(uint160(_nativeToken()))),
            decimals: 18,
            // forge-lint: disable-next-line(unsafe-typecast)
            surplus: uint128(surplus),
            // forge-lint: disable-next-line(unsafe-typecast)
            balance: uint128(surplus)
        });
        return JBChainAccounting({chainId: chainId, totalSupply: supply, contexts: contexts, timestamp: freshness});
    }

    function _single(JBChainAccounting memory record) internal pure returns (JBChainAccounting[] memory bundle) {
        bundle = new JBChainAccounting[](1);
        bundle[0] = record;
    }

    function _find(
        JBChainAccounting[] memory accounts,
        uint256 chainId
    )
        internal
        pure
        returns (bool found, JBChainAccounting memory record)
    {
        for (uint256 i; i < accounts.length;) {
            if (accounts[i].chainId == chainId) return (true, accounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Mock the controller so a sender's local supply snapshot resolves to `supply` with no terminals.
    function _mockLocalSupply(uint256 projectId, uint256 supply) internal {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (projectId)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER, abi.encodeCall(IERC165.supportsInterface, (type(IJBController).interfaceId)), abi.encode(true)
        );
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (projectId)),
            abi.encode(supply)
        );
        vm.mockCall(CONTROLLER, abi.encodeWithSelector(IJBController.currentRulesetOf.selector), abi.encode());
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (projectId)), abi.encode(new IJBTerminal[](0)));
    }

    function _nativeToken() internal pure returns (address) {
        return address(0x000000000000000000000000000000000000EEEe);
    }

    function _nativeCurrency() internal pure returns (uint256) {
        // The native token resolves to its address-convention currency (no terminal mock means the fallback applies),
        // which is what a same-asset peer context folds under at par.
        return uint32(uint160(_nativeToken()));
    }
}
