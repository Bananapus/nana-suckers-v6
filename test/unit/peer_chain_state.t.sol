// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBSucker.sol";

import {IJBPeerChainAdjustedAccounts} from "../../src/interfaces/IJBPeerChainAdjustedAccounts.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBAccountingSnapshot} from "../../src/structs/JBAccountingSnapshot.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBPeerChainContext} from "../../src/structs/JBPeerChainContext.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBSourceContext} from "../../src/structs/JBSourceContext.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @notice Test harness sucker that exposes internals for peer chain state tests.
contract PeerChainStateSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    /// @notice The last JBMessageRoot passed to _sendRootOverAMB, abi-encoded (the struct's dynamic context array
    /// can't be copied straight to storage without the IR pipeline).
    bytes private _lastSentMessage;

    /// @notice The last JBAccountingSnapshot passed to _sendAccountingSnapshotOverAMB, abi-encoded.
    bytes private _lastSentAccountingSnapshot;

    /// @notice The transport payment passed to _sendAccountingSnapshotOverAMB.
    uint256 public lastAccountingTransportPayment;

    /// @notice Whether _sendAccountingSnapshotOverAMB was called.
    // forge-lint: disable-next-line(mixed-case-variable)
    bool public sendAccountingSnapshotOverAMBCalled;

    /// @notice Whether _sendRootOverAMB was called.
    // forge-lint: disable-next-line(mixed-case-variable)
    bool public sendRootOverAMBCalled;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
    {}

    // forge-lint: disable-next-line(mixed-case-function)
    function _sendAccountingSnapshotOverAMB(
        uint256 transportPayment,
        JBAccountingSnapshot memory snapshot
    )
        internal
        override
    {
        _lastSentAccountingSnapshot = abi.encode(snapshot);
        lastAccountingTransportPayment = transportPayment;
        sendAccountingSnapshotOverAMBCalled = true;
    }

    // forge-lint: disable-next-line(mixed-case-function)
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
        _lastSentMessage = abi.encode(message);
        sendRootOverAMBCalled = true;
    }

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == _toAddress(peer());
    }

    function peerChainId() public view virtual override returns (uint256) {
        return block.chainid;
    }

    // --- Test setters ---

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

    function test_setOutboxBalance(address token, uint256 amount) external {
        _outboxOf[token].balance = amount;
    }

    function test_insertIntoTree(
        uint256 projectTokenCount,
        address token,
        uint256 terminalTokenAmount,
        bytes32 beneficiary
    )
        external
    {
        _insertIntoTree(projectTokenCount, token, terminalTokenAmount, beneficiary, bytes32(0));
    }

    function test_resetSendRootOverAMBCalled() external {
        sendRootOverAMBCalled = false;
    }

    function test_getLastSentAccountingSnapshot() external view returns (JBAccountingSnapshot memory) {
        return abi.decode(_lastSentAccountingSnapshot, (JBAccountingSnapshot));
    }

    function test_getLastSentMessage() external view returns (JBMessageRoot memory) {
        return abi.decode(_lastSentMessage, (JBMessageRoot));
    }
}

/// @notice A data hook that contributes one extra off-terminal accounting context to the peer-chain snapshot.
contract PeerChainAdjustedAccountsHookMock is IJBPeerChainAdjustedAccounts {
    uint256 internal immutable _supply;
    uint128 internal immutable _surplus;
    uint128 internal immutable _balance;
    address internal immutable _token;
    uint8 internal immutable _decimals;

    constructor(uint256 supply, uint128 surplus, uint128 balance, address token, uint8 decimals) {
        _supply = supply;
        _surplus = surplus;
        _balance = balance;
        _token = token;
        _decimals = decimals;
    }

    function peerChainAdjustedAccountsOf(uint256)
        external
        view
        returns (uint256 supply, JBSourceContext[] memory contexts)
    {
        contexts = new JBSourceContext[](1);
        contexts[0] = JBSourceContext({
            token: bytes32(uint256(uint160(_token))), decimals: _decimals, surplus: _surplus, balance: _balance
        });
        return (_supply, contexts);
    }
}

/// @notice A hook with the peer-chain accounting selector that returns malformed successful data.
contract MalformedPeerChainAdjustedAccountsHookMock {
    function peerChainAdjustedAccountsOf(uint256) external pure {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

/// @title PeerChainStateTest
/// @notice Tests the sucker as a raw cross-chain data carrier: fromRemote rebuilds the per-currency context set
/// (deriving and caching each token's authoritative currency), peerChainContextsOf exposes it un-valued, and toRemote
/// emits one un-valued context per accounting context. Valuation lives in the registry and is tested there.
contract PeerChainStateTest is Test {
    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);
    address constant TERMINAL = address(1200);
    address constant STORE = address(1300);

    uint256 constant PROJECT_ID = 1;
    address constant TOKEN = address(0x000000000000000000000000000000000000EEEe);

    uint8 constant ETH_DECIMALS = 18;

    /// @dev With no local accounting context configured for a token, the sucker derives the conventional token-keyed
    /// currency `uint32(uint160(token))`. The tests rely on that fallback unless they explicitly mock a context.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 constant NATIVE_CURRENCY = uint32(uint160(TOKEN));

    PeerChainStateSucker sucker;

    function setUp() public {
        vm.warp(100 days);

        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");
        vm.label(TOKENS, "MOCK_TOKENS");
        vm.label(CONTROLLER, "MOCK_CONTROLLER");
        vm.label(PROJECT, "MOCK_PROJECT");
        vm.label(TERMINAL, "MOCK_TERMINAL");
        vm.label(STORE, "MOCK_STORE");

        // Mock PROJECTS() so the constructor can cache the immutable.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));

        sucker = _createSucker("peer_state_salt");

        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER, abi.encodeCall(IERC165.supportsInterface, (type(IJBController).interfaceId)), abi.encode(true)
        );
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, TOKEN)), abi.encode(TERMINAL)
        );
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(0)));

        // Mock the registry's toRemoteFee() to return 0.
        vm.mockCall(address(1), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));

        // Default: no terminals (overridden per test as needed).
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(new IJBTerminal[](0)));
    }

    // =========================================================================
    // Group 1: fromRemote rebuilds the per-currency context set
    // =========================================================================

    /// @notice fromRemote stores the supply and a single native context keyed by the native currency.
    function test_fromRemoteStoresPeerChainState() public {
        vm.prank(address(sucker));
        sucker.fromRemote(_makeMessageRoot({nonce: 1, totalSupply: 500 ether, surplus: 100 ether, balance: 200 ether}));

        assertEq(sucker.peerChainTotalSupply(), 500 ether, "peerChainTotalSupply should be stored");

        (JBPeerChainContext[] memory contexts, uint256 chainId, uint256 snapshot) = sucker.peerChainContextsOf();
        assertEq(contexts.length, 1, "one native context");
        assertEq(contexts[0].currency, NATIVE_CURRENCY, "native currency");
        assertEq(contexts[0].decimals, ETH_DECIMALS, "native decimals");
        assertEq(contexts[0].surplus, 100 ether, "native surplus stored");
        assertEq(contexts[0].balance, 200 ether, "native balance stored");
        assertEq(chainId, block.chainid, "chain id");
        assertEq(snapshot, 1, "snapshot freshness key");
    }

    /// @notice fromRemote with a non-increasing source freshness key does NOT update shared state.
    function test_fromRemoteOnlyUpdatesOnHigherFreshnessKey() public {
        vm.prank(address(sucker));
        sucker.fromRemote(_makeMessageRoot({nonce: 5, totalSupply: 500 ether, surplus: 100 ether, balance: 200 ether}));

        // Same freshness key — should NOT update.
        vm.prank(address(sucker));
        sucker.fromRemote(_makeMessageRoot({nonce: 5, totalSupply: 999 ether, surplus: 999 ether, balance: 999 ether}));

        assertEq(sucker.peerChainTotalSupply(), 500 ether, "supply should not update on same freshness key");
        assertEq(_contextFor(NATIVE_CURRENCY).surplus, 100 ether, "surplus should not update");
        assertEq(_contextFor(NATIVE_CURRENCY).balance, 200 ether, "balance should not update");
    }

    /// @notice fromRemote with a higher source freshness key updates shared state.
    function test_fromRemoteUpdatesOnNewFreshnessKey() public {
        vm.prank(address(sucker));
        sucker.fromRemote(_makeMessageRoot({nonce: 1, totalSupply: 500 ether, surplus: 100 ether, balance: 200 ether}));

        vm.prank(address(sucker));
        sucker.fromRemote(_makeMessageRoot({nonce: 2, totalSupply: 750 ether, surplus: 300 ether, balance: 400 ether}));

        assertEq(sucker.peerChainTotalSupply(), 750 ether, "supply should update on newer freshness key");
        assertEq(_contextFor(NATIVE_CURRENCY).surplus, 300 ether, "surplus should update");
        assertEq(_contextFor(NATIVE_CURRENCY).balance, 400 ether, "balance should update");
    }

    /// @notice fromRemote stores each context under the local currency it resolves to.
    function test_fromRemoteStoresMultipleContexts() public {
        address usdc = makeAddr("USDC");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 usdcCurrency = uint32(uint160(usdc));

        JBSourceContext[] memory contexts = new JBSourceContext[](2);
        contexts[0] = _ctx({token: TOKEN, decimals: 18, surplus: 100 ether, balance: 200 ether});
        contexts[1] = _ctx({token: usdc, decimals: 6, surplus: 5000e6, balance: 9000e6});

        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 1, totalSupply: 500 ether, contexts: contexts}));

        assertEq(_contextFor(NATIVE_CURRENCY).surplus, 100 ether, "native surplus");
        assertEq(_contextFor(NATIVE_CURRENCY).balance, 200 ether, "native balance");

        JBPeerChainContext memory usdcContext = _contextFor(usdcCurrency);
        assertEq(usdcContext.decimals, 6, "usdc decimals");
        assertEq(usdcContext.surplus, 5000e6, "usdc surplus");
        assertEq(usdcContext.balance, 9000e6, "usdc balance");
    }

    /// @notice fromRemote keys a context by the project's AUTHORITATIVE accounting-context currency (which may be a
    /// well-known id like USD), read from the terminal — not the token-keyed convention.
    function test_fromRemoteUsesAuthoritativeContextCurrency() public {
        address usdc = makeAddr("USDC_AUTHORITATIVE");
        uint32 usdCurrency = 2; // JBCurrencyIds.USD

        // The project configures USDC with currency = USD(2) on its terminal.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, usdc)), abi.encode(TERMINAL));
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(IJBTerminal.accountingContextForTokenOf, (PROJECT_ID, usdc)),
            abi.encode(JBAccountingContext({token: usdc, decimals: 6, currency: usdCurrency}))
        );

        JBSourceContext[] memory contexts = new JBSourceContext[](1);
        contexts[0] = _ctx({token: usdc, decimals: 6, surplus: 4000e6, balance: 7000e6});
        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 1, totalSupply: 0, contexts: contexts}));

        // Keyed by the authoritative currency (USD), not uint32(uint160(usdc)).
        JBPeerChainContext memory ctx = _contextFor(usdCurrency);
        assertEq(ctx.surplus, 4000e6, "kept under authoritative currency");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(_hasContext(uint32(uint160(usdc))), false, "not keyed by the token convention");
    }

    /// @notice An authoritative currency is cached: once derived, a later snapshot reuses it even if the terminal can
    /// no longer be read.
    function test_fromRemoteCachesAuthoritativeCurrency() public {
        address usdc = makeAddr("USDC_CACHED");
        uint32 usdCurrency = 2;

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, usdc)), abi.encode(TERMINAL));
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(IJBTerminal.accountingContextForTokenOf, (PROJECT_ID, usdc)),
            abi.encode(JBAccountingContext({token: usdc, decimals: 6, currency: usdCurrency}))
        );

        JBSourceContext[] memory first = new JBSourceContext[](1);
        first[0] = _ctx({token: usdc, decimals: 6, surplus: 4000e6, balance: 7000e6});
        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 1, totalSupply: 0, contexts: first}));

        // The terminal can no longer answer; a fresh read would fall back to the token convention.
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, usdc)), abi.encode(address(0))
        );

        JBSourceContext[] memory second = new JBSourceContext[](1);
        second[0] = _ctx({token: usdc, decimals: 6, surplus: 5000e6, balance: 8000e6});
        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 2, totalSupply: 0, contexts: second}));

        // Still keyed by the cached authoritative currency, not the fallback.
        assertEq(_contextFor(usdCurrency).surplus, 5000e6, "reused cached currency");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(_hasContext(uint32(uint160(usdc))), false, "did not fall back after caching");
    }

    /// @notice fromRemote sums contexts within the same snapshot that resolve to the same local currency.
    function test_fromRemoteSameCurrencyContextsAccumulate() public {
        JBSourceContext[] memory contexts = new JBSourceContext[](2);
        contexts[0] = _ctx({token: TOKEN, decimals: 18, surplus: 100 ether, balance: 200 ether});
        contexts[1] = _ctx({token: TOKEN, decimals: 18, surplus: 30 ether, balance: 50 ether});

        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 1, totalSupply: 500 ether, contexts: contexts}));

        (JBPeerChainContext[] memory stored,,) = sucker.peerChainContextsOf();
        assertEq(stored.length, 1, "same currency merged into one entry");
        assertEq(_contextFor(NATIVE_CURRENCY).surplus, 130 ether, "surplus accumulates");
        assertEq(_contextFor(NATIVE_CURRENCY).balance, 250 ether, "balance accumulates");
    }

    /// @notice A fresher snapshot rebuilds the set from scratch, so a context that dropped out is simply absent.
    function test_fromRemoteRebuildDropsAbsentContexts() public {
        address usdc = makeAddr("USDC");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 usdcCurrency = uint32(uint160(usdc));

        // Snapshot 1 carries both native and USDC contexts.
        JBSourceContext[] memory first = new JBSourceContext[](2);
        first[0] = _ctx({token: TOKEN, decimals: 18, surplus: 100 ether, balance: 200 ether});
        first[1] = _ctx({token: usdc, decimals: 6, surplus: 5000e6, balance: 9000e6});
        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 1, totalSupply: 500 ether, contexts: first}));

        // Snapshot 2 carries only the native context — USDC dropped out.
        JBSourceContext[] memory second = new JBSourceContext[](1);
        second[0] = _ctx({token: TOKEN, decimals: 18, surplus: 120 ether, balance: 220 ether});
        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 2, totalSupply: 600 ether, contexts: second}));

        (JBPeerChainContext[] memory stored,,) = sucker.peerChainContextsOf();
        assertEq(stored.length, 1, "only the native context remains");
        assertEq(_contextFor(NATIVE_CURRENCY).surplus, 120 ether, "native reflects fresher snapshot");
        assertEq(_hasContext(usdcCurrency), false, "dropped context is absent");
    }

    // =========================================================================
    // Group 2: per-context snapshot propagation via toRemote
    // =========================================================================

    /// @notice toRemote emits one raw context per terminal accounting context, un-valued.
    function test_toRemoteSendsPerContextSnapshot() public {
        _setRemoteTokenMapping();

        // Insert a leaf so the outbox is non-empty.
        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(1000 ether))
        );

        _mockSingleETHTerminal({ethBalance: 50 ether, ethSurplus: 30 ether});

        sucker.test_resetSendRootOverAMBCalled();
        sucker.toRemote(TOKEN);

        assertTrue(sucker.sendRootOverAMBCalled(), "sendRootOverAMB should be called");

        JBMessageRoot memory m = sucker.test_getLastSentMessage();
        assertEq(m.version, 1, "message version should be 1");
        assertEq(m.sourceTotalSupply, 1000 ether, "sourceTotalSupply should match mock");
        assertEq(m.sourceContexts.length, 1, "one terminal context");
        assertEq(m.sourceContexts[0].token, bytes32(uint256(uint160(TOKEN))), "context keyed by source-local token");
        assertEq(m.sourceContexts[0].decimals, ETH_DECIMALS, "context decimals are the terminal's");
        assertEq(m.sourceContexts[0].surplus, 30 ether, "context surplus is the raw per-token surplus");
        assertEq(m.sourceContexts[0].balance, 50 ether, "context balance is the raw per-token balance");
    }

    /// @notice toRemote appends the data hook's off-terminal contexts after the terminal contexts.
    function test_toRemoteAddsDataHookPeerChainAdjustedAccounts() public {
        _setRemoteTokenMapping();

        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(1000 ether))
        );
        _mockSingleETHTerminal({ethBalance: 50 ether, ethSurplus: 30 ether});

        PeerChainAdjustedAccountsHookMock accountingHook = new PeerChainAdjustedAccountsHookMock({
            supply: 12 ether, surplus: 3 ether, balance: 0, token: TOKEN, decimals: 18
        });
        _mockCurrentRulesetDataHook(address(accountingHook));

        sucker.test_resetSendRootOverAMBCalled();
        sucker.toRemote(TOKEN);

        JBMessageRoot memory m = sucker.test_getLastSentMessage();
        assertEq(m.sourceTotalSupply, 1012 ether, "sourceTotalSupply should include data-hook supply");
        assertEq(m.sourceContexts.length, 2, "terminal context plus hook context");

        // Terminal context first.
        assertEq(m.sourceContexts[0].surplus, 30 ether, "terminal surplus");
        assertEq(m.sourceContexts[0].balance, 50 ether, "terminal balance excludes loan debt");

        // Hook context appended.
        assertEq(m.sourceContexts[1].token, bytes32(uint256(uint160(TOKEN))), "hook context token");
        assertEq(m.sourceContexts[1].surplus, 3 ether, "hook surplus appended");
        assertEq(m.sourceContexts[1].balance, 0, "hook balance appended");
    }

    /// @notice toRemote ignores malformed successful data-hook peer accounting returns and still sends the baseline
    /// terminal snapshot.
    function test_toRemoteIgnoresMalformedDataHookPeerChainAdjustedAccounts() public {
        _setRemoteTokenMapping();

        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(1000 ether))
        );
        _mockSingleETHTerminal({ethBalance: 50 ether, ethSurplus: 30 ether});

        MalformedPeerChainAdjustedAccountsHookMock malformedHook = new MalformedPeerChainAdjustedAccountsHookMock();
        _mockCurrentRulesetDataHook(address(malformedHook));

        sucker.test_resetSendRootOverAMBCalled();
        sucker.toRemote(TOKEN);

        JBMessageRoot memory m = sucker.test_getLastSentMessage();
        assertEq(m.sourceTotalSupply, 1000 ether, "malformed hook supply should be ignored");
        assertEq(m.sourceContexts.length, 1, "malformed hook contexts should be ignored");
        assertEq(m.sourceContexts[0].surplus, 30 ether, "terminal surplus remains");
        assertEq(m.sourceContexts[0].balance, 50 ether, "terminal balance remains");
    }

    /// @notice toRemote assigns a monotonic source freshness key even when multiple roots are sent in one block.
    function test_toRemoteUsesMonotonicSnapshotFreshnessWithinSameBlock() public {
        _setRemoteTokenMapping();

        vm.deal(address(sucker), 2 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(1000 ether))
        );
        _mockSingleETHTerminal({ethBalance: 50 ether, ethSurplus: 30 ether});

        sucker.test_resetSendRootOverAMBCalled();
        sucker.toRemote(TOKEN);
        JBMessageRoot memory first = sucker.test_getLastSentMessage();

        sucker.test_insertIntoTree(2 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xCAFE)))));
        sucker.toRemote(TOKEN);
        JBMessageRoot memory second = sucker.test_getLastSentMessage();

        assertEq(first.sourceTimestamp >> 128, block.timestamp, "first freshness key includes source timestamp");
        assertEq(uint128(first.sourceTimestamp), 1, "first freshness key sequence");
        assertEq(second.sourceTimestamp >> 128, block.timestamp, "second freshness key includes source timestamp");
        assertEq(uint128(second.sourceTimestamp), 2, "second freshness key sequence");
        assertGt(second.sourceTimestamp, first.sourceTimestamp, "same-block freshness key increases");
        assertEq(block.timestamp, 100 days, "test stayed in one block timestamp");
    }

    /// @notice toRemote with no terminals produces an empty context array in the message.
    function test_toRemoteWithNoTerminals() public {
        _setRemoteTokenMapping();

        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        // terminalsOf already returns empty array from setUp.
        sucker.test_resetSendRootOverAMBCalled();
        sucker.toRemote(TOKEN);

        assertTrue(sucker.sendRootOverAMBCalled(), "sendRootOverAMB should be called");

        JBMessageRoot memory m = sucker.test_getLastSentMessage();
        assertEq(m.sourceContexts.length, 0, "no contexts with no terminals");
    }

    /// @notice toRemote with a multi-token terminal emits one raw context per token — no cross-token valuation.
    function test_toRemoteWithMultiTokenTerminalEmitsRawContexts() public {
        _setRemoteTokenMapping();

        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        address erc20Token = makeAddr("USDC");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 erc20Currency = uint32(uint160(erc20Token));

        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(TERMINAL);
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));
        vm.etch(TERMINAL, hex"00");

        JBAccountingContext[] memory contexts = new JBAccountingContext[](2);
        contexts[0] = JBAccountingContext({token: TOKEN, decimals: 18, currency: NATIVE_CURRENCY});
        contexts[1] = JBAccountingContext({token: erc20Token, decimals: 6, currency: erc20Currency});
        vm.mockCall(TERMINAL, abi.encodeCall(IJBTerminal.accountingContextsOf, (PROJECT_ID)), abi.encode(contexts));

        vm.mockCall(TERMINAL, abi.encodeCall(IJBMultiTerminal.STORE, ()), abi.encode(STORE));
        vm.etch(STORE, hex"00");

        // Per-token surplus, each requested in its own currency.
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(IJBTerminal.currentSurplusOf, (PROJECT_ID, _oneToken(TOKEN), 18, NATIVE_CURRENCY)),
            abi.encode(uint256(25 ether))
        );
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(IJBTerminal.currentSurplusOf, (PROJECT_ID, _oneToken(erc20Token), 6, erc20Currency)),
            abi.encode(uint256(4000e6))
        );

        // Per-token recorded balance.
        vm.mockCall(
            STORE,
            abi.encodeCall(IJBTerminalStore.balanceOf, (TERMINAL, PROJECT_ID, TOKEN)),
            abi.encode(uint256(10 ether))
        );
        vm.mockCall(
            STORE,
            abi.encodeCall(IJBTerminalStore.balanceOf, (TERMINAL, PROJECT_ID, erc20Token)),
            abi.encode(uint256(5000e6))
        );

        sucker.test_resetSendRootOverAMBCalled();
        sucker.toRemote(TOKEN);

        assertTrue(sucker.sendRootOverAMBCalled(), "sendRootOverAMB should be called");

        JBMessageRoot memory m = sucker.test_getLastSentMessage();
        assertEq(m.sourceContexts.length, 2, "one context per token, no collapse");

        // Native context: raw, no conversion.
        assertEq(m.sourceContexts[0].token, bytes32(uint256(uint160(TOKEN))), "native context token");
        assertEq(m.sourceContexts[0].decimals, 18, "native context decimals");
        assertEq(m.sourceContexts[0].surplus, 25 ether, "native surplus raw");
        assertEq(m.sourceContexts[0].balance, 10 ether, "native balance raw");

        // ERC20 context: raw, in its own 6 decimals.
        assertEq(m.sourceContexts[1].token, bytes32(uint256(uint160(erc20Token))), "erc20 context token");
        assertEq(m.sourceContexts[1].decimals, 6, "erc20 context decimals");
        assertEq(m.sourceContexts[1].surplus, 4000e6, "erc20 surplus raw");
        assertEq(m.sourceContexts[1].balance, 5000e6, "erc20 balance raw");
    }

    // =========================================================================
    // Group 3: accounting-only sync
    // =========================================================================

    /// @notice fromRemoteAccounting stores peer-chain accounting without touching token-local inbox roots.
    function test_fromRemoteAccountingUpdatesAccountingWithoutTouchingInbox() public {
        bytes32 inboxRoot = bytes32(uint256(0xDEAD));

        vm.prank(address(sucker));
        sucker.fromRemote(
            _root({
                nonce: 7, totalSupply: 500 ether, contexts: _singleContext({surplus: 100 ether, balance: 200 ether})
            })
        );

        JBAccountingSnapshot memory snapshot =
            _accountingSnapshot({sourceTimestamp: 8, totalSupply: 900 ether, surplus: 300 ether, balance: 400 ether});
        snapshot.sourceContexts[0].token = bytes32(uint256(uint160(TOKEN)));

        vm.prank(address(sucker));
        sucker.fromRemoteAccounting(snapshot);

        JBInboxTreeRoot memory inbox = sucker.inboxOf(TOKEN);
        assertEq(inbox.nonce, 7, "accounting sync must not alter inbox nonce");
        assertEq(inbox.root, inboxRoot, "accounting sync must not alter inbox root");
        assertEq(sucker.peerChainTotalSupply(), 900 ether, "accounting supply updated");
        assertEq(_contextFor(NATIVE_CURRENCY).surplus, 300 ether, "accounting surplus updated");
        assertEq(_contextFor(NATIVE_CURRENCY).balance, 400 ether, "accounting balance updated");
    }

    /// @notice fromRemoteAccounting ignores stale snapshots, preserving fresher root-delivered accounting.
    function test_fromRemoteAccountingDoesNotRollbackFresherRootSnapshot() public {
        vm.prank(address(sucker));
        sucker.fromRemote(
            _root({
                nonce: 5, totalSupply: 500 ether, contexts: _singleContext({surplus: 100 ether, balance: 200 ether})
            })
        );

        vm.prank(address(sucker));
        sucker.fromRemoteAccounting(
            _accountingSnapshot({sourceTimestamp: 4, totalSupply: 999 ether, surplus: 999 ether, balance: 999 ether})
        );

        assertEq(sucker.peerChainTotalSupply(), 500 ether, "stale accounting supply ignored");
        assertEq(_contextFor(NATIVE_CURRENCY).surplus, 100 ether, "stale accounting surplus ignored");
        assertEq(_contextFor(NATIVE_CURRENCY).balance, 200 ether, "stale accounting balance ignored");
    }

    /// @notice syncAccountingData sends accounting data without consulting or collecting the registry fee.
    function test_syncAccountingDataSendsChangedSnapshotWithoutToRemoteFee() public {
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(1000 ether))
        );
        _mockSingleETHTerminal({ethBalance: 50 ether, ethSurplus: 30 ether});

        vm.expectCall(address(1), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), 0);
        sucker.syncAccountingData();

        assertTrue(sucker.sendAccountingSnapshotOverAMBCalled(), "accounting message sent");
        assertEq(sucker.lastAccountingTransportPayment(), 0, "no transport payment passed");

        JBAccountingSnapshot memory snapshot = sucker.test_getLastSentAccountingSnapshot();
        assertEq(snapshot.version, 1, "message version");
        assertEq(snapshot.sourceTotalSupply, 1000 ether, "source supply");
        assertEq(snapshot.sourceContexts.length, 1, "one context");
        assertEq(snapshot.sourceContexts[0].surplus, 30 ether, "source surplus");
        assertEq(snapshot.sourceContexts[0].balance, 50 ether, "source balance");
        assertEq(snapshot.sourceTimestamp >> 128, block.timestamp, "timestamp high bits");
        assertEq(uint128(snapshot.sourceTimestamp), 1, "timestamp sequence");
    }

    /// @notice syncAccountingData can retry an unchanged accounting snapshot with a fresh source timestamp.
    function test_syncAccountingDataCanResendUnchangedAccountingData() public {
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(1000 ether))
        );
        _mockSingleETHTerminal({ethBalance: 50 ether, ethSurplus: 30 ether});

        sucker.syncAccountingData();
        sucker.syncAccountingData();

        JBAccountingSnapshot memory snapshot = sucker.test_getLastSentAccountingSnapshot();
        assertEq(snapshot.sourceTotalSupply, 1000 ether, "source supply");
        assertEq(snapshot.sourceContexts[0].surplus, 30 ether, "source surplus");
        assertEq(snapshot.sourceContexts[0].balance, 50 ether, "source balance");
        assertEq(uint128(snapshot.sourceTimestamp), 2, "timestamp sequence advanced");
    }

    /// @notice A root send does not block a later accounting-only retry of the same data.
    function test_toRemoteDoesNotBlockAccountingDataResend() public {
        _setRemoteTokenMapping();

        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(1000 ether))
        );
        _mockSingleETHTerminal({ethBalance: 50 ether, ethSurplus: 30 ether});

        sucker.toRemote(TOKEN);
        sucker.syncAccountingData();

        assertTrue(sucker.sendAccountingSnapshotOverAMBCalled(), "accounting message sent");

        JBAccountingSnapshot memory snapshot = sucker.test_getLastSentAccountingSnapshot();
        assertEq(snapshot.sourceTotalSupply, 1000 ether, "source supply");
        assertEq(snapshot.sourceContexts[0].surplus, 30 ether, "source surplus");
        assertEq(snapshot.sourceContexts[0].balance, 50 ether, "source balance");
        assertEq(uint128(snapshot.sourceTimestamp), 2, "timestamp sequence advanced");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createSucker(bytes32 salt) internal returns (PeerChainStateSucker) {
        PeerChainStateSucker singleton = new PeerChainStateSucker(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER
        );

        PeerChainStateSucker s =
            PeerChainStateSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        s.initialize(PROJECT_ID);

        return s;
    }

    /// @notice The stored peer context for a currency, reverting if none exists.
    function _contextFor(uint32 currency) internal view returns (JBPeerChainContext memory) {
        (JBPeerChainContext[] memory contexts,,) = sucker.peerChainContextsOf();
        for (uint256 i; i < contexts.length; ++i) {
            if (contexts[i].currency == currency) return contexts[i];
        }
        revert("no context for currency");
    }

    /// @notice Whether a stored peer context exists for a currency.
    function _hasContext(uint32 currency) internal view returns (bool) {
        (JBPeerChainContext[] memory contexts,,) = sucker.peerChainContextsOf();
        for (uint256 i; i < contexts.length; ++i) {
            if (contexts[i].currency == currency) return true;
        }
        return false;
    }

    /// @notice Map the native token to a remote token so the outbox accepts leaves.
    function _setRemoteTokenMapping() internal {
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );
    }

    /// @notice Build a single-element address array (matches the library's per-token surplus request).
    function _oneToken(address token) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = token;
    }

    /// @notice Build one source context keyed by the given source-local token.
    function _ctx(
        address token,
        uint8 decimals,
        uint128 surplus,
        uint128 balance
    )
        internal
        pure
        returns (JBSourceContext memory)
    {
        return JBSourceContext({
            token: bytes32(uint256(uint160(token))), decimals: decimals, surplus: surplus, balance: balance
        });
    }

    /// @notice Mock the controller's current ruleset with the given data hook.
    function _mockCurrentRulesetDataHook(address dataHook) internal {
        vm.etch(CONTROLLER, hex"00");

        JBRulesetMetadata memory metadata;
        metadata.dataHook = dataHook;
        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 0,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadataResolver.packRulesetMetadata(metadata)
        });

        vm.mockCall(
            CONTROLLER, abi.encodeCall(IJBController.currentRulesetOf, (PROJECT_ID)), abi.encode(ruleset, metadata)
        );
    }

    /// @notice Build a JBMessageRoot carrying the given contexts, using `nonce` as both the inbox nonce and the
    /// source freshness key.
    function _root(
        uint64 nonce,
        uint256 totalSupply,
        JBSourceContext[] memory contexts
    )
        internal
        pure
        returns (JBMessageRoot memory)
    {
        return JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: bytes32(uint256(0xDEAD))}),
            sourceTotalSupply: totalSupply,
            sourceContexts: contexts,
            sourceTimestamp: nonce
        });
    }

    /// @notice Build a JBMessageRoot carrying a single native context.
    function _makeMessageRoot(
        uint64 nonce,
        uint256 totalSupply,
        uint128 surplus,
        uint128 balance
    )
        internal
        pure
        returns (JBMessageRoot memory)
    {
        JBSourceContext[] memory contexts = new JBSourceContext[](1);
        contexts[0] = JBSourceContext({
            token: bytes32(uint256(uint160(TOKEN))), decimals: ETH_DECIMALS, surplus: surplus, balance: balance
        });
        return _root({nonce: nonce, totalSupply: totalSupply, contexts: contexts});
    }

    /// @notice Build an accounting-only snapshot carrying a single native context.
    function _accountingSnapshot(
        uint256 sourceTimestamp,
        uint256 totalSupply,
        uint128 surplus,
        uint128 balance
    )
        internal
        pure
        returns (JBAccountingSnapshot memory)
    {
        return JBAccountingSnapshot({
            version: 1,
            sourceTotalSupply: totalSupply,
            sourceContexts: _singleContext({surplus: surplus, balance: balance}),
            sourceTimestamp: sourceTimestamp
        });
    }

    /// @notice Mock a single native-token terminal with a known recorded balance and per-token surplus.
    function _mockSingleETHTerminal(uint256 ethBalance, uint256 ethSurplus) internal {
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(TERMINAL);
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));
        vm.etch(TERMINAL, hex"00");

        // Single native accounting context (currency is token-keyed).
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: TOKEN, decimals: 18, currency: NATIVE_CURRENCY});
        vm.mockCall(TERMINAL, abi.encodeCall(IJBTerminal.accountingContextsOf, (PROJECT_ID)), abi.encode(contexts));

        // Per-token surplus, requested in the context's own currency.
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(IJBTerminal.currentSurplusOf, (PROJECT_ID, _oneToken(TOKEN), 18, NATIVE_CURRENCY)),
            abi.encode(ethSurplus)
        );

        // Per-token recorded balance via the store.
        vm.mockCall(TERMINAL, abi.encodeCall(IJBMultiTerminal.STORE, ()), abi.encode(STORE));
        vm.etch(STORE, hex"00");
        vm.mockCall(
            STORE, abi.encodeCall(IJBTerminalStore.balanceOf, (TERMINAL, PROJECT_ID, TOKEN)), abi.encode(ethBalance)
        );
    }

    /// @notice Build a single native source context.
    function _singleContext(uint128 surplus, uint128 balance)
        internal
        pure
        returns (JBSourceContext[] memory contexts)
    {
        contexts = new JBSourceContext[](1);
        contexts[0] = JBSourceContext({
            token: bytes32(uint256(uint160(TOKEN))), decimals: ETH_DECIMALS, surplus: surplus, balance: balance
        });
    }
}
