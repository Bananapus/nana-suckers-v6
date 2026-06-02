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
import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
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
    uint32 internal immutable _currency;
    uint8 internal immutable _decimals;

    constructor(uint256 supply, uint128 surplus, uint128 balance, address token, uint32 currency, uint8 decimals) {
        _supply = supply;
        _surplus = surplus;
        _balance = balance;
        _token = token;
        _currency = currency;
        _decimals = decimals;
    }

    function peerChainAdjustedAccountsOf(uint256)
        external
        view
        returns (uint256 supply, JBSourceContext[] memory contexts)
    {
        contexts = new JBSourceContext[](1);
        contexts[0] = JBSourceContext({
            token: bytes32(uint256(uint160(_token))),
            currency: _currency,
            decimals: _decimals,
            surplus: _surplus,
            balance: _balance
        });
        return (_supply, contexts);
    }
}

/// @title PeerChainStateTest
/// @notice Tests for peer chain state tracking: fromRemote stores each remote accounting context under the local
/// token it resolves to, the per-token par-read views, and the per-context snapshot propagation via toRemote.
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

    /// @dev An accounting context's currency is token-keyed: `uint32(uint160(token))`, not a standard currency id.
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
    // Group 1: fromRemote stores peer chain state per context
    // =========================================================================

    /// @notice fromRemote with a single native context stores the supply and the context's raw surplus/balance.
    function test_fromRemoteStoresPeerChainState() public {
        JBMessageRoot memory root = _makeMessageRoot({nonce: 1, totalSupply: 500 ether, surplus: 100 ether, balance: 200 ether});

        // Call fromRemote as the peer (address(sucker) since peer() returns _toBytes32(address(this))).
        vm.prank(address(sucker));
        sucker.fromRemote(root);

        assertEq(sucker.peerChainTotalSupply(), 500 ether, "peerChainTotalSupply should be stored");

        // Read the native context at par (same token, same decimals).
        JBDenominatedAmount memory storedBalance = sucker.peerChainBalanceOf(TOKEN, ETH_DECIMALS);
        assertEq(storedBalance.value, 200 ether, "balance value should be stored");
        assertEq(storedBalance.currency, NATIVE_CURRENCY, "balance currency should be the context currency");
        assertEq(storedBalance.decimals, ETH_DECIMALS, "balance decimals should match request");

        JBDenominatedAmount memory storedSurplus = sucker.peerChainSurplusOf(TOKEN, ETH_DECIMALS);
        assertEq(storedSurplus.value, 100 ether, "surplus value should be stored");
        assertEq(storedSurplus.currency, NATIVE_CURRENCY, "surplus currency should be the context currency");
        assertEq(storedSurplus.decimals, ETH_DECIMALS, "surplus decimals should match request");
    }

    /// @notice fromRemote with a non-increasing source freshness key does NOT update shared state.
    function test_fromRemoteOnlyUpdatesOnHigherFreshnessKey() public {
        JBMessageRoot memory root1 = _makeMessageRoot({nonce: 5, totalSupply: 500 ether, surplus: 100 ether, balance: 200 ether});
        vm.prank(address(sucker));
        sucker.fromRemote(root1);

        // Same freshness key — should NOT update.
        JBMessageRoot memory root2 = _makeMessageRoot({nonce: 5, totalSupply: 999 ether, surplus: 999 ether, balance: 999 ether});
        vm.prank(address(sucker));
        sucker.fromRemote(root2);

        assertEq(sucker.peerChainTotalSupply(), 500 ether, "supply should not update on same freshness key");
        assertEq(sucker.peerChainBalanceOf(TOKEN, ETH_DECIMALS).value, 200 ether, "balance should not update");
        assertEq(sucker.peerChainSurplusOf(TOKEN, ETH_DECIMALS).value, 100 ether, "surplus should not update");
    }

    /// @notice fromRemote with a higher source freshness key updates shared state.
    function test_fromRemoteUpdatesOnNewFreshnessKey() public {
        JBMessageRoot memory root1 = _makeMessageRoot({nonce: 1, totalSupply: 500 ether, surplus: 100 ether, balance: 200 ether});
        vm.prank(address(sucker));
        sucker.fromRemote(root1);

        JBMessageRoot memory root2 = _makeMessageRoot({nonce: 2, totalSupply: 750 ether, surplus: 300 ether, balance: 400 ether});
        vm.prank(address(sucker));
        sucker.fromRemote(root2);

        assertEq(sucker.peerChainTotalSupply(), 750 ether, "supply should update on newer freshness key");
        assertEq(sucker.peerChainBalanceOf(TOKEN, ETH_DECIMALS).value, 400 ether, "balance should update");
        assertEq(sucker.peerChainSurplusOf(TOKEN, ETH_DECIMALS).value, 300 ether, "surplus should update");
    }

    /// @notice fromRemote stores each context under the local token it resolves to; each reads back at par.
    function test_fromRemoteStoresEachContextPerToken() public {
        address usdc = makeAddr("USDC");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 usdcCurrency = uint32(uint160(usdc));

        JBSourceContext[] memory contexts = new JBSourceContext[](2);
        contexts[0] = _ctx({token: TOKEN, currency: NATIVE_CURRENCY, decimals: 18, surplus: 100 ether, balance: 200 ether});
        contexts[1] = _ctx({token: usdc, currency: usdcCurrency, decimals: 6, surplus: 5000e6, balance: 9000e6});

        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 1, totalSupply: 500 ether, contexts: contexts}));

        // Native context read at par.
        assertEq(sucker.peerChainSurplusOf(TOKEN, 18).value, 100 ether, "native surplus at par");
        assertEq(sucker.peerChainBalanceOf(TOKEN, 18).value, 200 ether, "native balance at par");

        // USDC context read at par in its own 6 decimals.
        JBDenominatedAmount memory usdcSurplus = sucker.peerChainSurplusOf(usdc, 6);
        assertEq(usdcSurplus.value, 5000e6, "usdc surplus at par");
        assertEq(usdcSurplus.currency, usdcCurrency, "usdc currency echoed");
        assertEq(usdcSurplus.decimals, 6, "usdc decimals echoed");
        assertEq(sucker.peerChainBalanceOf(usdc, 6).value, 9000e6, "usdc balance at par");
    }

    /// @notice fromRemote sums contexts within the same snapshot that resolve to the same local token.
    function test_fromRemoteSameTokenContextsAccumulate() public {
        JBSourceContext[] memory contexts = new JBSourceContext[](2);
        contexts[0] = _ctx({token: TOKEN, currency: NATIVE_CURRENCY, decimals: 18, surplus: 100 ether, balance: 200 ether});
        contexts[1] = _ctx({token: TOKEN, currency: NATIVE_CURRENCY, decimals: 18, surplus: 30 ether, balance: 50 ether});

        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 1, totalSupply: 500 ether, contexts: contexts}));

        assertEq(sucker.peerChainSurplusOf(TOKEN, 18).value, 130 ether, "same-token surplus accumulates");
        assertEq(sucker.peerChainBalanceOf(TOKEN, 18).value, 250 ether, "same-token balance accumulates");
    }

    /// @notice A context that drops out of a fresher snapshot reads as absent (zero) without explicit clearing.
    function test_fromRemoteContextAbsentInFresherSnapshotReadsZero() public {
        address usdc = makeAddr("USDC");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 usdcCurrency = uint32(uint160(usdc));

        // Snapshot 1 carries both native and USDC contexts.
        JBSourceContext[] memory first = new JBSourceContext[](2);
        first[0] = _ctx({token: TOKEN, currency: NATIVE_CURRENCY, decimals: 18, surplus: 100 ether, balance: 200 ether});
        first[1] = _ctx({token: usdc, currency: usdcCurrency, decimals: 6, surplus: 5000e6, balance: 9000e6});
        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 1, totalSupply: 500 ether, contexts: first}));

        // Snapshot 2 carries only the native context — USDC dropped out.
        JBSourceContext[] memory second = new JBSourceContext[](1);
        second[0] = _ctx({token: TOKEN, currency: NATIVE_CURRENCY, decimals: 18, surplus: 120 ether, balance: 220 ether});
        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 2, totalSupply: 600 ether, contexts: second}));

        // Native context reflects the fresher snapshot.
        assertEq(sucker.peerChainSurplusOf(TOKEN, 18).value, 120 ether, "native reflects fresher snapshot");
        // USDC context is stale (older epoch) and reads zero.
        assertEq(sucker.peerChainSurplusOf(usdc, 6).value, 0, "dropped context reads zero");
        assertEq(sucker.peerChainBalanceOf(usdc, 6).value, 0, "dropped context balance reads zero");
    }

    // =========================================================================
    // Group 2: per-token par-read views
    // =========================================================================

    /// @notice peerChainBalanceOf reads the stored context at par when decimals match.
    function test_peerChainBalanceOfSameToken() public {
        vm.prank(address(sucker));
        sucker.fromRemote(_makeMessageRoot({nonce: 1, totalSupply: 100 ether, surplus: 50 ether, balance: 10 ether}));

        JBDenominatedAmount memory result = sucker.peerChainBalanceOf(TOKEN, 18);
        assertEq(result.value, 10 ether, "same token same decimals returns exact value");
        assertEq(result.currency, NATIVE_CURRENCY, "returned currency is the context currency");
        assertEq(result.decimals, 18, "returned decimals match request");
    }

    /// @notice peerChainSurplusOf reads the stored context at par when decimals match.
    function test_peerChainSurplusOfSameToken() public {
        vm.prank(address(sucker));
        sucker.fromRemote(_makeMessageRoot({nonce: 1, totalSupply: 100 ether, surplus: 50 ether, balance: 10 ether}));

        assertEq(sucker.peerChainSurplusOf(TOKEN, 18).value, 50 ether, "same token same decimals returns exact surplus");
    }

    /// @notice peerChainBalanceOf returns zero when nothing is stored for the token.
    function test_peerChainBalanceOfZeroValue() public view {
        assertEq(sucker.peerChainBalanceOf(TOKEN, 18).value, 0, "zero stored returns zero");
    }

    /// @notice peerChainBalanceOf for a token with no stored context returns zero — surplus held in a different asset
    /// is never folded into an unrelated token.
    function test_peerChainBalanceOfDifferentTokenReturnsZero() public {
        vm.prank(address(sucker));
        sucker.fromRemote(_makeMessageRoot({nonce: 1, totalSupply: 100 ether, surplus: 50 ether, balance: 10 ether}));

        address unrelated = makeAddr("UNRELATED");
        assertEq(sucker.peerChainBalanceOf(unrelated, 18).value, 0, "unrelated token reads zero");
        assertEq(sucker.peerChainSurplusOf(unrelated, 18).value, 0, "unrelated token surplus reads zero");
    }

    /// @notice peerChainBalanceOf adjusts only the decimals when the requested precision differs from the context's.
    function test_peerChainBalanceOfDecimalsAdjust() public {
        address usdc = makeAddr("USDC");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 usdcCurrency = uint32(uint160(usdc));

        JBSourceContext[] memory contexts = new JBSourceContext[](1);
        contexts[0] = _ctx({token: usdc, currency: usdcCurrency, decimals: 6, surplus: 5000e6, balance: 9000e6});
        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 1, totalSupply: 0, contexts: contexts}));

        // Stored at 6 decimals; requested at 18 (->) scaled up by 10^12, no price conversion.
        assertEq(sucker.peerChainSurplusOf(usdc, 18).value, 5000 ether, "6->18 decimals scales surplus at par");
        assertEq(sucker.peerChainBalanceOf(usdc, 18).value, 9000 ether, "6->18 decimals scales balance at par");
    }

    /// @notice Fuzz: a stored context reads back at par across every decimal pair — only the decimals are adjusted,
    /// never a price. Sweeps decimal combinations to catch any hardcoded precision assumption.
    function testFuzz_peerChainReadsAtParAcrossDecimals(uint8 srcDecimals, uint8 dstDecimals, uint128 amount) public {
        srcDecimals = uint8(bound(srcDecimals, 0, 24));
        dstDecimals = uint8(bound(dstDecimals, 0, 24));

        address token = makeAddr("FUZZ_TOKEN");
        JBSourceContext[] memory contexts = new JBSourceContext[](1);
        contexts[0] = _ctx({token: token, currency: 1, decimals: srcDecimals, surplus: amount, balance: amount});
        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 1, totalSupply: 0, contexts: contexts}));

        // Expected is a pure decimal rescale of the raw amount (division rounds down, the bias-low direction).
        uint256 expected;
        if (dstDecimals >= srcDecimals) {
            expected = uint256(amount) * 10 ** (uint256(dstDecimals) - srcDecimals);
        } else {
            expected = uint256(amount) / 10 ** (uint256(srcDecimals) - dstDecimals);
        }

        assertEq(sucker.peerChainSurplusOf(token, dstDecimals).value, expected, "surplus folds at par, decimals only");
        assertEq(sucker.peerChainBalanceOf(token, dstDecimals).value, expected, "balance folds at par, decimals only");
    }

    /// @notice Fuzz: a zero-amount context reads back as zero for any decimal pair.
    function testFuzz_peerChainZeroAmountReadsZero(uint8 srcDecimals, uint8 dstDecimals) public {
        srcDecimals = uint8(bound(srcDecimals, 0, 24));
        dstDecimals = uint8(bound(dstDecimals, 0, 24));

        address token = makeAddr("FUZZ_ZERO");
        JBSourceContext[] memory contexts = new JBSourceContext[](1);
        contexts[0] = _ctx({token: token, currency: 1, decimals: srcDecimals, surplus: 0, balance: 0});
        vm.prank(address(sucker));
        sucker.fromRemote(_root({nonce: 1, totalSupply: 0, contexts: contexts}));

        assertEq(sucker.peerChainSurplusOf(token, dstDecimals).value, 0, "zero input yields zero surplus");
        assertEq(sucker.peerChainBalanceOf(token, dstDecimals).value, 0, "zero input yields zero balance");
    }

    // =========================================================================
    // Group 3: per-context snapshot propagation via toRemote
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
        assertEq(m.sourceContexts[0].currency, NATIVE_CURRENCY, "context currency is token-keyed");
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
            supply: 12 ether,
            surplus: 3 ether,
            balance: 0,
            token: TOKEN,
            currency: NATIVE_CURRENCY,
            decimals: 18
        });
        vm.etch(CONTROLLER, hex"00");
        JBRulesetMetadata memory metadata;
        metadata.dataHook = address(accountingHook);
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
            STORE, abi.encodeCall(IJBTerminalStore.balanceOf, (TERMINAL, PROJECT_ID, TOKEN)), abi.encode(uint256(10 ether))
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
        uint32 currency,
        uint8 decimals,
        uint128 surplus,
        uint128 balance
    )
        internal
        pure
        returns (JBSourceContext memory)
    {
        return JBSourceContext({
            token: bytes32(uint256(uint160(token))),
            currency: currency,
            decimals: decimals,
            surplus: surplus,
            balance: balance
        });
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
            token: bytes32(uint256(uint160(TOKEN))),
            currency: NATIVE_CURRENCY,
            decimals: ETH_DECIMALS,
            surplus: surplus,
            balance: balance
        });
        return _root({nonce: nonce, totalSupply: totalSupply, contexts: contexts});
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
}
