// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBSucker.sol";

import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @notice Test harness sucker that exposes internals for peer chain state tests.
contract PeerChainStateSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    /// @notice The last JBMessageRoot passed to _sendRootOverAMB.
    JBMessageRoot private _lastSentMessage;

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
        _lastSentMessage = message;
        sendRootOverAMBCalled = true;
    }

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == _toAddress(peer());
    }

    function peerChainId() external view virtual override returns (uint256) {
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
        _insertIntoTree(projectTokenCount, token, terminalTokenAmount, beneficiary);
    }

    function test_resetSendRootOverAMBCalled() external {
        sendRootOverAMBCalled = false;
    }

    function test_getLastSentMessage() external view returns (JBMessageRoot memory) {
        return _lastSentMessage;
    }
}

/// @title PeerChainStateTest
/// @notice Tests for peer chain state tracking: fromRemote storage, peerChainBalanceOf/SurplusOf views,
/// and buildETHAggregate message propagation via toRemote/sendRoot.
contract PeerChainStateTest is Test {
    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);
    address constant TERMINAL = address(1200);
    address constant STORE = address(1300);
    address constant PRICES = address(1400);

    uint256 constant PROJECT_ID = 1;
    address constant TOKEN = address(0x000000000000000000000000000000000000EEEe);

    /// @dev ETH currency = JBCurrencyIds.ETH = 1
    uint256 constant ETH_CURRENCY = 1;
    uint8 constant ETH_DECIMALS = 18;

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
        vm.label(PRICES, "MOCK_PRICES");

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
    // Group 1: fromRemote stores peer chain state
    // =========================================================================

    /// @notice fromRemote with populated fields stores peerChainTotalSupply, _peerChainBalance, _peerChainSurplus.
    function test_fromRemoteStoresPeerChainState() public {
        JBMessageRoot memory root = _makeMessageRoot({
            nonce: 1,
            totalSupply: 500 ether,
            surplus: 100 ether,
            balance: 200 ether,
            currency: uint256(uint32(ETH_CURRENCY)),
            decimals: ETH_DECIMALS
        });

        // Call fromRemote as the peer (address(sucker) since peer() returns _toBytes32(address(this))).
        vm.prank(address(sucker));
        sucker.fromRemote(root);

        // Verify peerChainTotalSupply.
        assertEq(sucker.peerChainTotalSupply(), 500 ether, "peerChainTotalSupply should be stored");

        // Verify balance via public view (query in same currency/decimals as stored).
        JBDenominatedAmount memory storedBalance = sucker.peerChainBalanceOf(ETH_DECIMALS, ETH_CURRENCY);
        assertEq(storedBalance.value, 200 ether, "balance value should be stored");
        assertEq(storedBalance.currency, uint32(ETH_CURRENCY), "balance currency should be stored");
        assertEq(storedBalance.decimals, ETH_DECIMALS, "balance decimals should be stored");

        // Verify surplus via public view.
        JBDenominatedAmount memory storedSurplus = sucker.peerChainSurplusOf(ETH_DECIMALS, ETH_CURRENCY);
        assertEq(storedSurplus.value, 100 ether, "surplus value should be stored");
        assertEq(storedSurplus.currency, uint32(ETH_CURRENCY), "surplus currency should be stored");
        assertEq(storedSurplus.decimals, ETH_DECIMALS, "surplus decimals should be stored");
    }

    /// @notice fromRemote with same nonce as current inbox does NOT update state.
    function test_fromRemoteOnlyUpdatesOnHigherNonce() public {
        // First call with nonce 5.
        JBMessageRoot memory root1 = _makeMessageRoot({
            nonce: 5,
            totalSupply: 500 ether,
            surplus: 100 ether,
            balance: 200 ether,
            currency: uint256(uint32(ETH_CURRENCY)),
            decimals: ETH_DECIMALS
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root1);

        // Second call with same nonce 5 — should NOT update.
        JBMessageRoot memory root2 = _makeMessageRoot({
            nonce: 5,
            totalSupply: 999 ether,
            surplus: 999 ether,
            balance: 999 ether,
            currency: uint256(uint32(ETH_CURRENCY)),
            decimals: ETH_DECIMALS
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root2);

        // State should still reflect root1 values.
        assertEq(sucker.peerChainTotalSupply(), 500 ether, "supply should not update on same nonce");

        JBDenominatedAmount memory storedBalance = sucker.peerChainBalanceOf(ETH_DECIMALS, ETH_CURRENCY);
        assertEq(storedBalance.value, 200 ether, "balance should not update on same nonce");

        JBDenominatedAmount memory storedSurplus = sucker.peerChainSurplusOf(ETH_DECIMALS, ETH_CURRENCY);
        assertEq(storedSurplus.value, 100 ether, "surplus should not update on same nonce");
    }

    /// @notice fromRemote with higher nonce updates state.
    function test_fromRemoteUpdatesOnNewNonce() public {
        // First call with nonce 1.
        JBMessageRoot memory root1 = _makeMessageRoot({
            nonce: 1,
            totalSupply: 500 ether,
            surplus: 100 ether,
            balance: 200 ether,
            currency: uint256(uint32(ETH_CURRENCY)),
            decimals: ETH_DECIMALS
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root1);

        // Second call with nonce 2 — should update.
        JBMessageRoot memory root2 = _makeMessageRoot({
            nonce: 2,
            totalSupply: 750 ether,
            surplus: 300 ether,
            balance: 400 ether,
            currency: uint256(uint32(ETH_CURRENCY)),
            decimals: ETH_DECIMALS
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root2);

        // State should reflect root2 values.
        assertEq(sucker.peerChainTotalSupply(), 750 ether, "supply should update on new nonce");

        JBDenominatedAmount memory storedBalance = sucker.peerChainBalanceOf(ETH_DECIMALS, ETH_CURRENCY);
        assertEq(storedBalance.value, 400 ether, "balance should update on new nonce");

        JBDenominatedAmount memory storedSurplus = sucker.peerChainSurplusOf(ETH_DECIMALS, ETH_CURRENCY);
        assertEq(storedSurplus.value, 300 ether, "surplus should update on new nonce");
    }

    // =========================================================================
    // Group 2: peerChainBalanceOf / peerChainSurplusOf views
    // =========================================================================

    /// @notice peerChainBalanceOf with same currency returns decimal-adjusted value.
    function test_peerChainBalanceOfSameCurrency() public {
        // Store balance via fromRemote (18 decimals ETH, currency = JBCurrencyIds.ETH = 1).
        JBMessageRoot memory root = _makeMessageRoot({
            nonce: 1,
            totalSupply: 100 ether,
            surplus: 50 ether,
            balance: 10 ether,
            currency: uint256(uint32(ETH_CURRENCY)),
            decimals: ETH_DECIMALS
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root);

        // Query balance in ETH currency (JBCurrencyIds.ETH = 1) at 18 decimals — should return exact value.
        JBDenominatedAmount memory result = sucker.peerChainBalanceOf(18, ETH_CURRENCY);
        assertEq(result.value, 10 ether, "same currency same decimals should return exact value");
        assertEq(result.currency, uint32(ETH_CURRENCY), "returned currency should match requested");
        assertEq(result.decimals, 18, "returned decimals should match requested");
    }

    /// @notice peerChainSurplusOf with same currency returns decimal-adjusted value.
    function test_peerChainSurplusOfSameCurrency() public {
        JBMessageRoot memory root = _makeMessageRoot({
            nonce: 1,
            totalSupply: 100 ether,
            surplus: 50 ether,
            balance: 10 ether,
            currency: uint256(uint32(ETH_CURRENCY)),
            decimals: ETH_DECIMALS
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root);

        JBDenominatedAmount memory result = sucker.peerChainSurplusOf(18, ETH_CURRENCY);
        assertEq(result.value, 50 ether, "same currency same decimals should return exact surplus");
    }

    /// @notice peerChainBalanceOf returns zero when no balance stored.
    function test_peerChainBalanceOfZeroValue() public view {
        JBDenominatedAmount memory result = sucker.peerChainBalanceOf(18, ETH_CURRENCY);
        assertEq(result.value, 0, "zero stored should return zero");
    }

    /// @notice peerChainBalanceOf with different currency uses price feed for conversion.
    function test_peerChainBalanceOfDifferentCurrency() public {
        // Store balance of 10 ETH via fromRemote.
        JBMessageRoot memory root = _makeMessageRoot({
            nonce: 1,
            totalSupply: 100 ether,
            surplus: 50 ether,
            balance: 10 ether,
            currency: uint256(uint32(ETH_CURRENCY)),
            decimals: ETH_DECIMALS
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root);

        // Set up terminal mocks for price conversion.
        _mockSingleETHTerminal({ethBalance: 5 ether, ethSurplus: 3 ether});

        // Mock price: 1 ETH = 2000 USD (pricingCurrency = ETH, unitCurrency = USD).
        // convertPeerValue calls: pricePerUnitOf(projectId, sourceCurrency=ETH, unitCurrency=USD, decimals=18)
        uint32 usdCurrency = 2;
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, uint32(ETH_CURRENCY), usdCurrency, 18)),
            abi.encode(uint256(2000e18))
        );

        // Query balance in USD at 18 decimals.
        // convertPeerValue: mulDiv(10e18, 2000e18, 10^18) = 10 * 2000 * 1e18 = 20000e18
        JBDenominatedAmount memory result = sucker.peerChainBalanceOf(18, uint256(usdCurrency));
        assertEq(result.value, 20_000 ether, "10 ETH at 2000 USD/ETH should return 20000 USD");
        assertEq(result.currency, usdCurrency, "returned currency should be USD");
    }

    // =========================================================================
    // Group 3: buildETHAggregate via toRemote / _sendRoot
    // =========================================================================

    /// @notice toRemote sends ETH aggregate (surplus, balance, currency, decimals) in the message.
    function test_toRemoteSendsETHAggregateInMessage() public {
        // Set up token mapping.
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );

        // Insert a leaf so the outbox is non-empty.
        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        // Mock total supply.
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(1000 ether))
        );

        // Set up terminal mocks with known surplus/balance.
        _mockSingleETHTerminal({ethBalance: 50 ether, ethSurplus: 30 ether});

        sucker.test_resetSendRootOverAMBCalled();
        sucker.toRemote(TOKEN);

        assertTrue(sucker.sendRootOverAMBCalled(), "sendRootOverAMB should be called");

        // Inspect the captured message.
        JBMessageRoot memory m = sucker.test_getLastSentMessage();

        assertEq(m.version, 1, "message version should be 1");
        assertEq(m.sourceTotalSupply, 1000 ether, "sourceTotalSupply should match mock");
        assertEq(m.sourceCurrency, ETH_CURRENCY, "sourceCurrency should be ETH");
        assertEq(m.sourceDecimals, ETH_DECIMALS, "sourceDecimals should be 18");
        assertEq(m.sourceSurplus, 30 ether, "sourceSurplus should match mock");
        assertEq(m.sourceBalance, 50 ether, "sourceBalance should match mock");
    }

    /// @notice toRemote with no terminals produces surplus=0, balance=0 in message.
    function test_toRemoteWithNoTerminals() public {
        // Set up token mapping.
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );

        // Insert a leaf so the outbox is non-empty.
        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        // terminalsOf already returns empty array from setUp.
        sucker.test_resetSendRootOverAMBCalled();
        sucker.toRemote(TOKEN);

        assertTrue(sucker.sendRootOverAMBCalled(), "sendRootOverAMB should be called");

        JBMessageRoot memory m = sucker.test_getLastSentMessage();

        assertEq(m.sourceSurplus, 0, "surplus should be 0 with no terminals");
        assertEq(m.sourceBalance, 0, "balance should be 0 with no terminals");
        assertEq(m.sourceCurrency, ETH_CURRENCY, "currency should still be ETH");
        assertEq(m.sourceDecimals, ETH_DECIMALS, "decimals should still be 18");
    }

    /// @notice toRemote with a multi-token terminal aggregates ETH + ERC20 balance via price conversion.
    function test_toRemoteWithMultiTokenTerminal() public {
        // Set up token mapping.
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );

        // Insert a leaf so the outbox is non-empty.
        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        // Set up a terminal with both ETH and an ERC20 token.
        address erc20Token = makeAddr("USDC");
        uint32 erc20Currency = uint32(uint160(erc20Token));

        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(TERMINAL);
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));

        // Mock surplus (aggregated by first terminal).
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(
                IJBTerminal.currentSurplusOf, (PROJECT_ID, new address[](0), ETH_DECIMALS, uint32(ETH_CURRENCY))
            ),
            abi.encode(uint256(25 ether))
        );

        // Mock STORE and PRICES.
        vm.mockCall(TERMINAL, abi.encodeCall(IJBMultiTerminal.STORE, ()), abi.encode(STORE));
        vm.mockCall(STORE, abi.encodeCall(IJBTerminalStore.PRICES, ()), abi.encode(PRICES));
        vm.etch(PRICES, hex"00");

        // Set up two accounting contexts: ETH (18 decimals) + ERC20 (6 decimals).
        uint32 nativeTokenCurrency = uint32(uint160(TOKEN));
        JBAccountingContext[] memory contexts = new JBAccountingContext[](2);
        contexts[0] = JBAccountingContext({token: TOKEN, decimals: 18, currency: nativeTokenCurrency});
        contexts[1] = JBAccountingContext({token: erc20Token, decimals: 6, currency: erc20Currency});
        vm.mockCall(TERMINAL, abi.encodeCall(IJBTerminal.accountingContextsOf, (PROJECT_ID)), abi.encode(contexts));

        // Mock balances: 10 ETH + 5000 USDC (6 decimals).
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

        // Mock price: native token → ETH (1:1 identity since it IS ETH).
        // buildETHAggregate compares uint32(uint160(token)) vs JBCurrencyIds.ETH — these differ,
        // so it falls through to the price feed path for all tokens including native ETH.
        vm.mockCall(
            PRICES,
            abi.encodeCall(
                IJBPrices.pricePerUnitOf, (PROJECT_ID, nativeTokenCurrency, uint32(ETH_CURRENCY), ETH_DECIMALS)
            ),
            abi.encode(uint256(1e18))
        );

        // Mock price: 1 USDC = 0.0005 ETH (at 18 decimals).
        vm.mockCall(
            PRICES,
            abi.encodeCall(IJBPrices.pricePerUnitOf, (PROJECT_ID, erc20Currency, uint32(ETH_CURRENCY), ETH_DECIMALS)),
            abi.encode(uint256(0.0005 ether))
        );

        sucker.test_resetSendRootOverAMBCalled();
        sucker.toRemote(TOKEN);

        assertTrue(sucker.sendRootOverAMBCalled(), "sendRootOverAMB should be called");

        JBMessageRoot memory m = sucker.test_getLastSentMessage();

        assertEq(m.sourceSurplus, 25 ether, "surplus should be the aggregated ETH surplus");

        // Expected balance: 10 ETH + mulDiv(5000e6, 0.0005e18, 10^6) = 10e18 + 2.5e18 = 12.5e18
        assertEq(m.sourceBalance, 12.5 ether, "balance should aggregate ETH + ERC20 converted to ETH");
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

    /// @notice Build a JBMessageRoot with the given parameters.
    function _makeMessageRoot(
        uint64 nonce,
        uint256 totalSupply,
        uint256 surplus,
        uint256 balance,
        uint256 currency,
        uint8 decimals
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
            sourceCurrency: currency,
            sourceDecimals: decimals,
            sourceSurplus: surplus,
            sourceBalance: balance,
            snapshotNonce: nonce
        });
    }

    /// @notice Mock a single ETH terminal with known balance and surplus.
    function _mockSingleETHTerminal(uint256 ethBalance, uint256 ethSurplus) internal {
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(TERMINAL);
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));

        // Mock surplus.
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(
                IJBTerminal.currentSurplusOf, (PROJECT_ID, new address[](0), ETH_DECIMALS, uint32(ETH_CURRENCY))
            ),
            abi.encode(ethSurplus)
        );

        // Mock STORE and PRICES.
        vm.mockCall(TERMINAL, abi.encodeCall(IJBMultiTerminal.STORE, ()), abi.encode(STORE));
        vm.mockCall(STORE, abi.encodeCall(IJBTerminalStore.PRICES, ()), abi.encode(PRICES));

        // Etch minimal bytecode at mock addresses so Solidity's try-statement extcodesize checks pass.
        vm.etch(PRICES, hex"00");

        // Single ETH accounting context.
        // Note: accounting context currency = uint32(uint160(TOKEN)) which differs from JBCurrencyIds.ETH.
        uint32 nativeTokenCurrency = uint32(uint160(TOKEN));
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: TOKEN, decimals: 18, currency: nativeTokenCurrency});
        vm.mockCall(TERMINAL, abi.encodeCall(IJBTerminal.accountingContextsOf, (PROJECT_ID)), abi.encode(contexts));

        // Mock ETH balance.
        vm.mockCall(
            STORE, abi.encodeCall(IJBTerminalStore.balanceOf, (TERMINAL, PROJECT_ID, TOKEN)), abi.encode(ethBalance)
        );

        // Mock price feed: native token currency → ETH currency (identity conversion, 1:1 at 18 decimals).
        // buildETHAggregate compares uint32(uint160(token)) against JBCurrencyIds.ETH — these differ for native
        // token, so it falls through to the price feed path.
        vm.mockCall(
            PRICES,
            abi.encodeCall(
                IJBPrices.pricePerUnitOf, (PROJECT_ID, nativeTokenCurrency, uint32(ETH_CURRENCY), ETH_DECIMALS)
            ),
            abi.encode(uint256(1e18))
        );
    }
}
