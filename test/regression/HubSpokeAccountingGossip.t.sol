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
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../../src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBAccountingSnapshot} from "../../src/structs/JBAccountingSnapshot.sol";
import {JBChainAccounting} from "../../src/structs/JBChainAccounting.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBPeerChainContext} from "../../src/structs/JBPeerChainContext.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBSourceContext} from "../../src/structs/JBSourceContext.sol";
import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";
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

    /// @notice A direct peer record whose token address differs on the two chains resolves through the sucker's
    /// remote/local token mapping for supply, balance, and surplus aggregate reads.
    function test_directMappedTokenAggregatesSupplyBalanceAndSurplus() external {
        address hubUsdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        address baseUsdc = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

        GossipSuckerHarness spoke = _registeredSucker(
            SPOKE_PROJECT,
            MAINNET,
            _singleMapping({localToken: baseUsdc, remoteToken: bytes32(uint256(uint160(hubUsdc)))})
        );
        spoke.test_receive(
            _single(
                _recordWithToken({
                    chainId: MAINNET,
                    supply: 111 ether,
                    surplus: 45_000e6,
                    balance: 125_000e6,
                    freshness: 1,
                    token: hubUsdc,
                    decimals: 6
                })
            )
        );

        JBChainAccounting[] memory stored = spoke.peerChainAccountsOf();
        assertEq(stored.length, 1, "one direct peer record");
        assertEq(stored[0].contexts[0].token, bytes32(uint256(uint160(baseUsdc))), "stored under local token");

        uint32 baseUsdcCurrency = _addressCurrency(baseUsdc);
        (JBPeerChainContext[] memory contexts,) = spoke.peerChainContextsOf(MAINNET);
        assertEq(contexts.length, 1, "one local currency context");
        assertEq(contexts[0].currency, baseUsdcCurrency, "direct context resolves to local currency");
        assertEq(contexts[0].decimals, 6, "source decimals are preserved");
        assertEq(contexts[0].surplus, 45_000e6, "direct surplus is preserved");
        assertEq(contexts[0].balance, 125_000e6, "direct balance is preserved");

        assertEq(registry.remoteTotalSupplyOf(SPOKE_PROJECT), 111 ether, "direct supply aggregates");
        assertEq(
            registry.totalRemoteBalanceOf({projectId: SPOKE_PROJECT, currency: baseUsdcCurrency, decimals: 6}),
            125_000e6,
            "direct balance aggregates through mapping"
        );
        assertEq(
            registry.totalRemoteSurplusOf({projectId: SPOKE_PROJECT, currency: baseUsdcCurrency, decimals: 6}),
            45_000e6,
            "direct surplus aggregates through mapping"
        );
    }

    /// @notice The direct mapped-token aggregate path is address-agnostic: any configured remote token key resolves to
    /// the configured local token before balance, surplus, and supply aggregation.
    function testFuzz_directMappedTokenAggregatesSupplyBalanceAndSurplus(
        address remoteToken,
        address localToken
    )
        external
    {
        _assumeMappedTokenPair({remoteToken: remoteToken, localToken: localToken});

        GossipSuckerHarness spoke = _registeredSucker(
            SPOKE_PROJECT,
            MAINNET,
            _singleMapping({localToken: localToken, remoteToken: bytes32(uint256(uint160(remoteToken)))})
        );
        spoke.test_receive(
            _single(
                _recordWithToken({
                    chainId: MAINNET,
                    supply: 111 ether,
                    surplus: 45_000e6,
                    balance: 125_000e6,
                    freshness: 1,
                    token: remoteToken,
                    decimals: 6
                })
            )
        );

        uint32 localCurrency = _addressCurrency(localToken);
        (JBPeerChainContext[] memory contexts,) = spoke.peerChainContextsOf(MAINNET);
        assertEq(contexts.length, 1, "one local currency context");
        assertEq(contexts[0].currency, localCurrency, "direct context resolves to local currency");
        assertEq(contexts[0].balance, 125_000e6, "direct balance is preserved");
        assertEq(contexts[0].surplus, 45_000e6, "direct surplus is preserved");

        assertEq(registry.remoteTotalSupplyOf(SPOKE_PROJECT), 111 ether, "direct supply aggregates");
        assertEq(
            registry.totalRemoteBalanceOf({projectId: SPOKE_PROJECT, currency: localCurrency, decimals: 6}),
            125_000e6,
            "direct balance aggregates for arbitrary mapped pair"
        );
        assertEq(
            registry.totalRemoteSurplusOf({projectId: SPOKE_PROJECT, currency: localCurrency, decimals: 6}),
            45_000e6,
            "direct surplus aggregates for arbitrary mapped pair"
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

    /// @notice When a hub forwards a sibling spoke's accounting, mapped remote tokens are rewritten at each hop. The
    /// destination spoke only needs to know its local token's mapping to the hub token, not every sibling chain's token
    /// address, and its aggregate reads include the sibling's supply, balance, and surplus.
    function test_meshMappedTokenAggregatesSupplyBalanceAndSurplusThroughHub() external {
        address hubUsdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        address arbUsdc = address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
        address baseUsdc = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

        // The hub's Arbitrum sucker knows how Arbitrum USDC maps to hub-local USDC.
        GossipSuckerHarness arbLane = _registeredSucker(
            HUB_PROJECT,
            ARBITRUM,
            _singleMapping({localToken: hubUsdc, remoteToken: bytes32(uint256(uint160(arbUsdc)))})
        );
        arbLane.test_receive(
            _single(
                _recordWithToken({
                    chainId: ARBITRUM,
                    supply: 300 ether,
                    surplus: 90_000e6,
                    balance: 170_000e6,
                    freshness: 1,
                    token: arbUsdc,
                    decimals: 6
                })
            )
        );

        // The hub's Base sender only knows Base USDC. It does not know Arbitrum USDC.
        _mockLocalSupply(HUB_PROJECT, 500 ether);
        GossipSuckerHarness hubToBase = _registeredSucker(
            HUB_PROJECT, BASE, _singleMapping({localToken: hubUsdc, remoteToken: bytes32(uint256(uint160(baseUsdc)))})
        );
        hubToBase.syncAccountingData();

        JBChainAccounting[] memory sent = hubToBase.test_lastSentBundle();
        (bool hasArb, JBChainAccounting memory arbRecord) = _find(sent, ARBITRUM);
        assertTrue(hasArb, "hub forwards Arbitrum record to Base");
        assertEq(arbRecord.contexts.length, 1, "one Arbitrum context");
        assertEq(arbRecord.contexts[0].token, bytes32(uint256(uint160(hubUsdc))), "Arbitrum USDC rekeyed to hub USDC");

        // Base only maps its local USDC to hub USDC. It has no Arbitrum USDC mapping, but the forwarded record still
        // folds under Base USDC because the hub already normalized the sibling token key.
        GossipSuckerHarness baseSpoke = _registeredSucker(
            SPOKE_PROJECT,
            MAINNET,
            _singleMapping({localToken: baseUsdc, remoteToken: bytes32(uint256(uint160(hubUsdc)))})
        );
        baseSpoke.test_receive(sent);

        uint32 baseUsdcCurrency = _addressCurrency(baseUsdc);
        (JBPeerChainContext[] memory contexts,) = baseSpoke.peerChainContextsOf(ARBITRUM);
        assertEq(contexts.length, 1, "Arbitrum context resolves on Base");
        assertEq(contexts[0].currency, baseUsdcCurrency, "resolved through Base's hub-USDC mapping");
        assertEq(contexts[0].decimals, 6, "source decimals preserved");
        assertEq(contexts[0].surplus, 90_000e6, "source amount preserved");
        assertEq(contexts[0].balance, 170_000e6, "source balance preserved");

        JBChainAccounting[] memory stored = baseSpoke.peerChainAccountsOf();
        (bool storedArb, JBChainAccounting memory storedArbRecord) = _find(stored, ARBITRUM);
        assertTrue(storedArb, "Base stores the Arbitrum record");
        assertEq(storedArbRecord.contexts[0].token, bytes32(uint256(uint160(baseUsdc))), "Base stores its local token");

        assertEq(registry.remoteTotalSupplyOf(SPOKE_PROJECT), 300 ether, "mesh supply aggregates");
        assertEq(
            registry.totalRemoteBalanceOf({projectId: SPOKE_PROJECT, currency: baseUsdcCurrency, decimals: 6}),
            170_000e6,
            "mesh balance aggregates through hub and spoke mappings"
        );
        assertEq(
            registry.totalRemoteSurplusOf({projectId: SPOKE_PROJECT, currency: baseUsdcCurrency, decimals: 6}),
            90_000e6,
            "mesh surplus aggregates through hub and spoke mappings"
        );
    }

    /// @notice The mesh aggregate path is address-agnostic across both hops: source token -> hub token -> destination
    /// token, with no destination-side knowledge of the source token.
    function testFuzz_meshMappedTokenAggregatesSupplyBalanceAndSurplusThroughHub(
        address hubToken,
        address sourceToken,
        address destinationToken
    )
        external
    {
        _assumeMappedTokenPair({remoteToken: sourceToken, localToken: hubToken});
        _assumeMappedTokenPair({remoteToken: destinationToken, localToken: hubToken});
        _assumeMappedTokenPair({remoteToken: hubToken, localToken: destinationToken});

        GossipSuckerHarness sourceLane = _registeredSucker(
            HUB_PROJECT,
            ARBITRUM,
            _singleMapping({localToken: hubToken, remoteToken: bytes32(uint256(uint160(sourceToken)))})
        );
        sourceLane.test_receive(
            _single(
                _recordWithToken({
                    chainId: ARBITRUM,
                    supply: 300 ether,
                    surplus: 90_000e6,
                    balance: 170_000e6,
                    freshness: 1,
                    token: sourceToken,
                    decimals: 6
                })
            )
        );

        _mockLocalSupply(HUB_PROJECT, 500 ether);
        GossipSuckerHarness hubToDestination = _registeredSucker(
            HUB_PROJECT,
            BASE,
            _singleMapping({localToken: hubToken, remoteToken: bytes32(uint256(uint160(destinationToken)))})
        );
        hubToDestination.syncAccountingData();

        JBChainAccounting[] memory sent = hubToDestination.test_lastSentBundle();
        (bool hasSource, JBChainAccounting memory sourceRecord) = _find(sent, ARBITRUM);
        assertTrue(hasSource, "hub forwards source record");
        assertEq(sourceRecord.contexts[0].token, bytes32(uint256(uint160(hubToken))), "hub record uses hub token");

        GossipSuckerHarness destinationSpoke = _registeredSucker(
            SPOKE_PROJECT,
            MAINNET,
            _singleMapping({localToken: destinationToken, remoteToken: bytes32(uint256(uint160(hubToken)))})
        );
        destinationSpoke.test_receive(sent);

        uint32 destinationCurrency = _addressCurrency(destinationToken);
        (JBPeerChainContext[] memory contexts,) = destinationSpoke.peerChainContextsOf(ARBITRUM);
        assertEq(contexts.length, 1, "source context resolves on destination");
        assertEq(contexts[0].currency, destinationCurrency, "destination resolves through hub mapping");
        assertEq(contexts[0].balance, 170_000e6, "mesh balance is preserved");
        assertEq(contexts[0].surplus, 90_000e6, "mesh surplus is preserved");

        assertEq(registry.remoteTotalSupplyOf(SPOKE_PROJECT), 300 ether, "mesh supply aggregates");
        assertEq(
            registry.totalRemoteBalanceOf({projectId: SPOKE_PROJECT, currency: destinationCurrency, decimals: 6}),
            170_000e6,
            "mesh balance aggregates for arbitrary mapped pair"
        );
        assertEq(
            registry.totalRemoteSurplusOf({projectId: SPOKE_PROJECT, currency: destinationCurrency, decimals: 6}),
            90_000e6,
            "mesh surplus aggregates for arbitrary mapped pair"
        );
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
        sucker = _registeredSucker(projectId, peerChainId, new JBTokenMapping[](0));
    }

    function _registeredSucker(
        uint256 projectId,
        uint256 peerChainId,
        JBTokenMapping[] memory mappings
    )
        internal
        returns (GossipSuckerHarness sucker)
    {
        sucker = GossipSuckerHarness(
            payable(address(LibClone.cloneDeterministic(address(singleton), keccak256(abi.encode(saltNonce++)))))
        );
        sucker.initialize(projectId);
        sucker.test_setPeerChainId(peerChainId);

        StubDeployer deployer = new StubDeployer();
        deployer.setSucker(IJBSucker(address(sucker)));
        registry.allowSuckerDeployer(address(deployer));

        JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](1);
        configs[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: mappings});
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
        return _recordWithToken({
            chainId: chainId,
            supply: supply,
            surplus: surplus,
            balance: surplus,
            freshness: freshness,
            token: _nativeToken(),
            decimals: 18
        });
    }

    function _recordWithToken(
        uint256 chainId,
        uint256 supply,
        uint256 surplus,
        uint256 balance,
        uint256 freshness,
        address token,
        uint8 decimals
    )
        internal
        pure
        returns (JBChainAccounting memory)
    {
        JBSourceContext[] memory contexts = new JBSourceContext[](1);
        contexts[0] = JBSourceContext({
            token: bytes32(uint256(uint160(token))),
            decimals: decimals,
            // forge-lint: disable-next-line(unsafe-typecast)
            surplus: uint128(surplus),
            // forge-lint: disable-next-line(unsafe-typecast)
            balance: uint128(balance)
        });
        return JBChainAccounting({chainId: chainId, totalSupply: supply, contexts: contexts, timestamp: freshness});
    }

    function _single(JBChainAccounting memory record) internal pure returns (JBChainAccounting[] memory bundle) {
        bundle = new JBChainAccounting[](1);
        bundle[0] = record;
    }

    function _singleMapping(
        address localToken,
        bytes32 remoteToken
    )
        internal
        pure
        returns (JBTokenMapping[] memory mappings)
    {
        mappings = new JBTokenMapping[](1);
        mappings[0] = JBTokenMapping({localToken: localToken, minGas: 200_000, remoteToken: remoteToken});
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

    function _addressCurrency(address token) internal pure returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(uint160(token));
    }

    function _assumeMappedTokenPair(address remoteToken, address localToken) internal pure {
        vm.assume(remoteToken != address(0));
        vm.assume(localToken != address(0));
        if (localToken == _nativeToken()) vm.assume(remoteToken == _nativeToken());
    }
}
