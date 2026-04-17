// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {JBSuckerTerminal} from "../../src/JBSuckerTerminal.sol";
import {IJBSuckerTerminal} from "../../src/interfaces/IJBSuckerTerminal.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {IWrappedNativeToken} from "../../src/interfaces/IWrappedNativeToken.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {JBProxyConfig} from "../../src/structs/JBProxyConfig.sol";
import {JBRelayCashOutClaimMessage} from "../../src/structs/JBRelayCashOutClaimMessage.sol";
import {JBRelayPayMessage} from "../../src/structs/JBRelayPayMessage.sol";

// ────────────────────────────────────────────────
// Mock ERC-20
// ────────────────────────────────────────────────

contract MockERC20Token {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ────────────────────────────────────────────────
// Mock CCIP Router
// ────────────────────────────────────────────────

contract MockWrappedNativeToken {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        (bool sent,) = msg.sender.call{value: amount}("");
        require(sent, "ETH transfer failed");
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract MockCCIPRouter {
    MockWrappedNativeToken public wrappedNative;

    // Last sent message (for test inspection)
    uint64 public lastDestChainSelector;
    bytes public lastMessageData;
    uint256 public lastTokenAmount;

    constructor(MockWrappedNativeToken _wrappedNative) {
        wrappedNative = _wrappedNative;
    }

    function getWrappedNative() external view returns (IWrappedNativeToken) {
        return IWrappedNativeToken(address(wrappedNative));
    }

    function getFee(uint64, Client.EVM2AnyMessage calldata) external pure returns (uint256) {
        return 0.01 ether;
    }

    function ccipSend(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage calldata message
    )
        external
        payable
        returns (bytes32)
    {
        lastDestChainSelector = destinationChainSelector;
        lastMessageData = message.data;
        if (message.tokenAmounts.length > 0) {
            lastTokenAmount = message.tokenAmounts[0].amount;
        }
        return keccak256(abi.encode(destinationChainSelector, message.data));
    }

    // Allow receiving ETH for fee payments
    receive() external payable {}
}

// ────────────────────────────────────────────────
// Mock Router Terminal
// ────────────────────────────────────────────────

/// @notice Simulates a router terminal that swaps an ERC-20 → ETH and pays the real project.
contract MockRouterTerminal {
    IJBTerminal public immutable REAL_TERMINAL;

    uint256 public lastProjectId;
    address public lastToken;
    uint256 public lastAmount;

    constructor(IJBTerminal _realTerminal) {
        REAL_TERMINAL = _realTerminal;
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        returns (uint256)
    {
        lastProjectId = projectId;
        lastToken = token;
        lastAmount = amount;

        // Pull the ERC-20 from the caller (simulating receiving the token to swap).
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        // Simulate swap: use pre-funded ETH to pay the real project.
        uint256 ethAmount = address(this).balance;
        return REAL_TERMINAL.pay{value: ethAmount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: ethAmount,
            beneficiary: beneficiary,
            minReturnedTokens: minReturnedTokens,
            memo: memo,
            metadata: metadata
        });
    }

    receive() external payable {}
}

// ────────────────────────────────────────────────
// Test Contract
// ────────────────────────────────────────────────

contract JBSuckerTerminalTest is Test, TestBaseWorkflow, IERC721Receiver {
    JBSuckerRegistry registry;
    JBSuckerTerminal suckerTerminal;
    uint256 realProjectId;

    // CCIP mocks
    MockWrappedNativeToken mockWETH;
    MockCCIPRouter mockRouter;
    JBSuckerTerminal remoteSuckerTerminal;
    JBSuckerTerminal homeSuckerTerminal;

    uint64 constant HOME_CHAIN_SELECTOR = 5_009_297_550_715_157_269; // Ethereum mainnet CCIP selector
    uint64 constant REMOTE_CHAIN_SELECTOR = 4_949_039_107_694_359_620; // Arbitrum CCIP selector

    function setUp() public virtual override {
        // Deploy JB infrastructure.
        super.setUp();

        // Deploy the sucker registry.
        registry = new JBSuckerRegistry(jbDirectory(), jbPermissions(), address(this), address(0));

        // Launch a real project with a native token terminal.
        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory _rulesetConfigs = new JBRulesetConfig[](1);
        _rulesetConfigs[0].mustStartAtOrAfter = 0;
        _rulesetConfigs[0].duration = 0;
        _rulesetConfigs[0].weight = 1000 * 10 ** 18;
        _rulesetConfigs[0].weightCutPercent = 0;
        _rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfigs[0].metadata = _metadata;
        _rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory _terminalConfigs = new JBTerminalConfig[](1);
        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);
        _tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        _terminalConfigs[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokensToAccept});

        realProjectId = jbController()
            .launchProjectFor({
                owner: address(this),
                projectUri: "real-project",
                rulesetConfigurations: _rulesetConfigs,
                terminalConfigurations: _terminalConfigs,
                memo: ""
            });

        // Deploy ERC-20 for the real project.
        jbController().deployERC20For(realProjectId, "RealToken", "REAL", bytes32(0));

        // Deploy the home chain sucker terminal (no CCIP — homeChainSelector will be 0 for home proxies).
        suckerTerminal = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(0)),
            remoteChainSelector: 0,
            peer: address(0),
            routerTerminal: IJBTerminal(address(0))
        });

        // Deploy CCIP mocks.
        mockWETH = new MockWrappedNativeToken();
        mockRouter = new MockCCIPRouter(mockWETH);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ────────────────────────────────────────────────
    // createProxy (home chain)
    // ────────────────────────────────────────────────

    function test_createProxy_happyPath() public {
        uint256 proxyProjectId =
            suckerTerminal.createProxy(realProjectId, 0, "ProxyToken", "PROXY", bytes32(uint256(1)));

        // Verify the proxy config was stored.
        JBProxyConfig memory config = suckerTerminal.proxyConfigOf(proxyProjectId);
        assertEq(config.realProjectId, realProjectId, "proxyConfigOf should map to real project");
        assertEq(config.homeChainSelector, 0, "homeChainSelector should be 0 for home chain");

        // Verify the reverse mapping.
        assertEq(
            suckerTerminal.proxyProjectIdOf(realProjectId, address(this)),
            proxyProjectId,
            "proxyProjectIdOf should map to proxy"
        );

        // Verify the proxy project exists (has a controller in the directory).
        assertTrue(address(jbDirectory().controllerOf(proxyProjectId)) != address(0), "proxy should have a controller");

        // Verify the proxy has the multi-terminal set.
        IJBTerminal[] memory terminals = jbDirectory().terminalsOf(proxyProjectId);
        assertEq(terminals.length, 1, "proxy should have exactly 1 terminal");
        assertEq(address(terminals[0]), address(jbMultiTerminal()), "proxy terminal should be the multi-terminal");
    }

    function test_createProxy_revertsIfNoERC20() public {
        // Launch a project WITHOUT deploying an ERC-20.
        JBRulesetConfig[] memory _rulesetConfigs = new JBRulesetConfig[](1);
        _rulesetConfigs[0].mustStartAtOrAfter = 0;
        _rulesetConfigs[0].duration = 0;
        _rulesetConfigs[0].weight = 1e18;
        _rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfigs[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        _rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 noTokenProject = jbController()
            .launchProjectFor({
                owner: address(this),
                projectUri: "",
                rulesetConfigurations: _rulesetConfigs,
                terminalConfigurations: new JBTerminalConfig[](0),
                memo: ""
            });

        vm.expectRevert(abi.encodeWithSelector(JBSuckerTerminal.JBSuckerTerminal_NoERC20.selector, noTokenProject));
        suckerTerminal.createProxy(noTokenProject, 0, "ProxyToken", "PROXY", bytes32(0));
    }

    function test_createProxy_revertsIfAlreadyExists() public {
        suckerTerminal.createProxy(realProjectId, 0, "ProxyToken", "PROXY", bytes32(uint256(1)));

        vm.expectRevert(
            abi.encodeWithSelector(JBSuckerTerminal.JBSuckerTerminal_ProxyAlreadyExists.selector, realProjectId)
        );
        suckerTerminal.createProxy(realProjectId, 0, "ProxyToken2", "PROXY2", bytes32(uint256(2)));
    }

    function test_createProxy_revertsIfNotOwner() public {
        // A random address tries to create a proxy — should revert.
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(JBSuckerTerminal.JBSuckerTerminal_Unauthorized.selector));
        suckerTerminal.createProxy(realProjectId, 0, "ProxyToken", "PROXY", bytes32(uint256(1)));
    }

    // ────────────────────────────────────────────────
    // createProxy (remote chain)
    // ────────────────────────────────────────────────

    function test_createProxy_remoteChain() public {
        // Deploy a remote sucker terminal (has CCIP router and peer).
        JBSuckerTerminal remote = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(mockRouter)),
            remoteChainSelector: HOME_CHAIN_SELECTOR,
            peer: address(suckerTerminal),
            routerTerminal: IJBTerminal(address(0))
        });

        // Create a proxy with homeChainSelector != 0 (remote chain).
        uint256 proxyProjectId =
            remote.createProxy(realProjectId, HOME_CHAIN_SELECTOR, "ProxyToken", "PROXY", bytes32(uint256(42)));

        // Verify config.
        JBProxyConfig memory config = remote.proxyConfigOf(proxyProjectId);
        assertEq(config.realProjectId, realProjectId, "should map to real project");
        assertEq(config.homeChainSelector, HOME_CHAIN_SELECTOR, "should store home chain selector");

        // Verify the proxy uses the remote sucker terminal as its terminal (not multi-terminal).
        IJBTerminal[] memory terminals = jbDirectory().terminalsOf(proxyProjectId);
        assertEq(terminals.length, 1, "proxy should have exactly 1 terminal");
        assertEq(address(terminals[0]), address(remote), "proxy terminal should be the remote sucker terminal");
    }

    // ────────────────────────────────────────────────
    // pay (home chain)
    // ────────────────────────────────────────────────────────

    function test_pay_nativeToken() public {
        // Create the proxy.
        uint256 proxyProjectId =
            suckerTerminal.createProxy(realProjectId, 0, "ProxyToken", "PROXY", bytes32(uint256(1)));

        // Pay 1 ETH through the sucker terminal.
        address beneficiary = address(0xBEEF);
        uint256 proxyTokens = suckerTerminal.pay{value: 1 ether}({
            proxyProjectId: proxyProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "test",
            metadata: ""
        });

        // Beneficiary should have received proxy tokens.
        assertGt(proxyTokens, 0, "should have received proxy tokens");

        // The proxy project's terminal should hold the real tokens.
        address realToken = address(jbTokens().tokenOf(realProjectId));
        assertTrue(realToken != address(0), "real token should exist");
    }

    function test_pay_revertsIfNotProxy() public {
        vm.expectRevert(abi.encodeWithSelector(JBSuckerTerminal.JBSuckerTerminal_NotAProxy.selector, 999));
        suckerTerminal.pay{value: 1 ether}({
            proxyProjectId: 999,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    // ────────────────────────────────────────────────
    // IJBTerminal: accounting contexts
    // ────────────────────────────────────────────────

    function test_addAccountingContextsFor() public {
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // No-op — this terminal accepts all tokens dynamically.
        suckerTerminal.addAccountingContextsFor(1, contexts);

        // accountingContextsOf always returns empty.
        JBAccountingContext[] memory stored = suckerTerminal.accountingContextsOf(1);
        assertEq(stored.length, 0, "should return empty array");

        // accountingContextForTokenOf dynamically constructs a context for any token.
        JBAccountingContext memory ctx = suckerTerminal.accountingContextForTokenOf(1, JBConstants.NATIVE_TOKEN);
        assertEq(ctx.token, JBConstants.NATIVE_TOKEN, "token should match");
        assertEq(ctx.decimals, 18, "native token should have 18 decimals");
    }

    // ────────────────────────────────────────────────
    // IJBTerminal: addToBalanceOf
    // ────────────────────────────────────────────────

    function test_addToBalanceOf_nativeToken() public {
        suckerTerminal.addToBalanceOf{value: 1 ether}(1, JBConstants.NATIVE_TOKEN, 1 ether, false, "test", "");

        // The terminal holds no surplus — balances are forwarded via CCIP.
        address[] memory tokens = new address[](1);
        tokens[0] = JBConstants.NATIVE_TOKEN;
        uint256 surplus = suckerTerminal.currentSurplusOf(1, tokens, 18, 0);
        assertEq(surplus, 0, "surplus should always be zero");
    }

    // ────────────────────────────────────────────────
    // IJBTerminal: previewPayFor reverts
    // ────────────────────────────────────────────────

    function test_previewPayFor_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(JBSuckerTerminal.JBSuckerTerminal_NotSupported.selector));
        suckerTerminal.previewPayFor(1, JBConstants.NATIVE_TOKEN, 1 ether, address(this), "");
    }

    // ────────────────────────────────────────────────
    // IJBTerminal: migrateBalanceOf reverts
    // ────────────────────────────────────────────────

    function test_migrateBalanceOf_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(JBSuckerTerminal.JBSuckerTerminal_NotSupported.selector));
        suckerTerminal.migrateBalanceOf(1, JBConstants.NATIVE_TOKEN, IJBTerminal(address(0)));
    }

    // ────────────────────────────────────────────────
    // ccipReceive
    // ────────────────────────────────────────────────

    function test_ccipReceive_revertsIfNotRouter() public {
        // Deploy a home sucker terminal with CCIP enabled.
        homeSuckerTerminal = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(mockRouter)),
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            peer: address(0xDEAD),
            routerTerminal: IJBTerminal(address(0))
        });

        Client.Any2EVMMessage memory message;
        message.sender = abi.encode(address(0xDEAD));
        message.sourceChainSelector = REMOTE_CHAIN_SELECTOR;
        message.data = "";
        message.destTokenAmounts = new Client.EVMTokenAmount[](0);

        // Should revert because msg.sender is not the CCIP router.
        vm.expectRevert(abi.encodeWithSelector(JBSuckerTerminal.JBSuckerTerminal_InvalidRouter.selector, address(this)));
        homeSuckerTerminal.ccipReceive(message);
    }

    function test_ccipReceive_revertsIfNotPeer() public {
        homeSuckerTerminal = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(mockRouter)),
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            peer: address(0xDEAD),
            routerTerminal: IJBTerminal(address(0))
        });

        Client.Any2EVMMessage memory message;
        message.sender = abi.encode(address(0xBEEF)); // Wrong peer.
        message.sourceChainSelector = REMOTE_CHAIN_SELECTOR;
        message.data = abi.encode(uint8(1), abi.encode(JBRelayPayMessage(1, address(this), "", "")));
        message.destTokenAmounts = new Client.EVMTokenAmount[](0);

        vm.prank(address(mockRouter));
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSuckerTerminal.JBSuckerTerminal_NotPeer.selector, address(0xBEEF), REMOTE_CHAIN_SELECTOR
            )
        );
        homeSuckerTerminal.ccipReceive(message);
    }

    // ────────────────────────────────────────────────
    // hasMintPermissionFor
    // ───────────────────────────────────────

    function test_hasMintPermissionFor_falseForNonSucker() public view {
        JBRuleset memory dummyRuleset;
        bool result = suckerTerminal.hasMintPermissionFor(realProjectId, dummyRuleset, address(0xDEAD));
        assertFalse(result, "non-sucker should not have mint permission");
    }

    // ────────────────────────────────────────────────
    // supportsInterface
    // ──────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(
            suckerTerminal.supportsInterface(type(IJBRulesetDataHook).interfaceId), "should support IJBRulesetDataHook"
        );
        assertTrue(suckerTerminal.supportsInterface(type(IERC165).interfaceId), "should support IERC165");
        assertTrue(suckerTerminal.supportsInterface(type(IJBTerminal).interfaceId), "should support IJBTerminal");
        assertTrue(
            suckerTerminal.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId),
            "should support IAny2EVMMessageReceiver"
        );
    }

    // ────────────────────────────────────────────────
    // cashOut
    // ────────────────────────────────────────────────

    /// @notice Helper: deploy a home sucker terminal with CCIP enabled and create a proxy + pay into it.
    function _setupCashOut()
        internal
        returns (JBSuckerTerminal homeTerminal, uint256 proxyProjectId, uint256 proxyTokens)
    {
        // Deploy a home sucker terminal WITH CCIP (so it can bridge cash out proceeds).
        homeTerminal = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(mockRouter)),
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            peer: address(0xDEAD),
            routerTerminal: IJBTerminal(address(0))
        });

        // Create a home chain proxy (homeChainSelector == 0).
        proxyProjectId = homeTerminal.createProxy(realProjectId, 0, "ProxyToken", "PROXY", bytes32(uint256(100)));

        // Pay 10 ETH → get proxy tokens.
        proxyTokens = homeTerminal.pay{value: 10 ether}({
            proxyProjectId: proxyProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "setup",
            metadata: ""
        });
    }

    function test_cashOut_happyPath() public {
        (JBSuckerTerminal homeTerminal, uint256 proxyProjectId, uint256 proxyTokens) = _setupCashOut();

        // Approve the sucker terminal to spend our proxy tokens.
        address proxyToken = address(jbTokens().tokenOf(proxyProjectId));
        IERC20(proxyToken).approve(address(homeTerminal), proxyTokens);

        // Cash out all proxy tokens.
        address payable beneficiary = payable(address(0xCAFE));
        uint256 reclaimAmount = homeTerminal.cashOut{value: 0.1 ether}({
            proxyProjectId: proxyProjectId,
            cashOutCount: proxyTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minReclaimAmount: 0,
            beneficiary: beneficiary,
            metadata: ""
        });

        // Should have reclaimed some ETH (minus fees).
        assertGt(reclaimAmount, 0, "should have reclaimed ETH");

        // The CCIP router should have received a message.
        assertEq(mockRouter.lastDestChainSelector(), REMOTE_CHAIN_SELECTOR, "CCIP dest should be remote chain");
        assertGt(mockRouter.lastTokenAmount(), 0, "CCIP should have bridged tokens");

        // Verify the CCIP message contains the correct message type and beneficiary.
        (uint8 msgType, bytes memory payload) = abi.decode(mockRouter.lastMessageData(), (uint8, bytes));
        assertEq(msgType, 2, "message type should be CASH_OUT_CLAIM (2)");
        JBRelayCashOutClaimMessage memory claimMsg = abi.decode(payload, (JBRelayCashOutClaimMessage));
        assertEq(claimMsg.beneficiary, beneficiary, "beneficiary should match");
    }

    function test_cashOut_revertsOnRemoteChainProxy() public {
        // Deploy a remote sucker terminal.
        JBSuckerTerminal remote = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(mockRouter)),
            remoteChainSelector: HOME_CHAIN_SELECTOR,
            peer: address(suckerTerminal),
            routerTerminal: IJBTerminal(address(0))
        });

        // Create a remote chain proxy (homeChainSelector != 0).
        uint256 proxyProjectId =
            remote.createProxy(realProjectId, HOME_CHAIN_SELECTOR, "ProxyToken", "PROXY", bytes32(uint256(200)));

        // Attempting to cash out on a remote chain proxy should revert.
        vm.expectRevert(abi.encodeWithSelector(JBSuckerTerminal.JBSuckerTerminal_WrongChain.selector));
        remote.cashOut{value: 0.1 ether}({
            proxyProjectId: proxyProjectId,
            cashOutCount: 1000,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minReclaimAmount: 0,
            beneficiary: payable(address(0xCAFE)),
            metadata: ""
        });
    }

    function test_cashOut_revertsIfNotAProxy() public {
        // Deploy a home sucker terminal with CCIP.
        JBSuckerTerminal homeTerminal = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(mockRouter)),
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            peer: address(0xDEAD),
            routerTerminal: IJBTerminal(address(0))
        });

        vm.expectRevert(abi.encodeWithSelector(JBSuckerTerminal.JBSuckerTerminal_NotAProxy.selector, 999));
        homeTerminal.cashOut{value: 0.1 ether}({
            proxyProjectId: 999,
            cashOutCount: 1000,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minReclaimAmount: 0,
            beneficiary: payable(address(0xCAFE)),
            metadata: ""
        });
    }

    // ────────────────────────────────────────────────
    // ccipReceive: MSG_TYPE_CASH_OUT_CLAIM
    // ────────────────────────────────────────────────

    function test_ccipReceive_cashOutClaim() public {
        // Deploy a remote sucker terminal that will receive the cash out claim.
        JBSuckerTerminal remote = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(mockRouter)),
            remoteChainSelector: HOME_CHAIN_SELECTOR,
            peer: address(0xDEAD),
            routerTerminal: IJBTerminal(address(0))
        });

        // Fund the mock WETH so the remote terminal can unwrap it.
        address payable beneficiary = payable(address(0xCAFE));
        uint256 amount = 5 ether;

        // Deposit ETH into WETH on behalf of the remote terminal (simulating CCIP delivery).
        vm.deal(address(remote), amount);
        vm.prank(address(remote));
        mockWETH.deposit{value: amount}();

        // Build the CCIP message with MSG_TYPE_CASH_OUT_CLAIM.
        Client.Any2EVMMessage memory message;
        message.sender = abi.encode(address(0xDEAD)); // peer
        message.sourceChainSelector = HOME_CHAIN_SELECTOR;
        message.data = abi.encode(
            uint8(2), // MSG_TYPE_CASH_OUT_CLAIM
            abi.encode(JBRelayCashOutClaimMessage({beneficiary: beneficiary}))
        );
        message.destTokenAmounts = new Client.EVMTokenAmount[](1);
        message.destTokenAmounts[0] = Client.EVMTokenAmount({token: address(mockWETH), amount: amount});

        uint256 beneficiaryBalanceBefore = beneficiary.balance;

        // Deliver the message as the CCIP router.
        vm.prank(address(mockRouter));
        remote.ccipReceive(message);

        // Beneficiary should have received ETH.
        assertEq(beneficiary.balance - beneficiaryBalanceBefore, amount, "beneficiary should receive ETH");
    }

    // ────────────────────────────────────────────────
    // ERC-20 Pay Remote
    // ────────────────────────────────────────────────

    function test_pay_erc20Token_remote() public {
        // Deploy a mock ERC-20.
        MockERC20Token mockUSDC = new MockERC20Token("USD Coin", "USDC");

        // Deploy a remote sucker terminal.
        JBSuckerTerminal remote = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(mockRouter)),
            remoteChainSelector: HOME_CHAIN_SELECTOR,
            peer: address(suckerTerminal),
            routerTerminal: IJBTerminal(address(0))
        });

        // Create a remote chain proxy.
        uint256 proxyProjectId =
            remote.createProxy(realProjectId, HOME_CHAIN_SELECTOR, "ProxyToken", "PROXY", bytes32(uint256(300)));

        // Mint USDC to the caller and approve the remote terminal.
        uint256 payAmount = 1000e18;
        mockUSDC.mint(address(this), payAmount);
        mockUSDC.approve(address(remote), payAmount);

        // Pay with ERC-20 (msg.value covers transport only).
        uint256 transport = 0.1 ether;
        remote.pay{value: transport}({
            proxyProjectId: proxyProjectId,
            token: address(mockUSDC),
            amount: payAmount,
            beneficiary: address(0xBEEF),
            minReturnedTokens: 0,
            memo: "erc20 pay",
            metadata: ""
        });

        // Verify CCIP message was sent.
        assertEq(mockRouter.lastDestChainSelector(), HOME_CHAIN_SELECTOR, "CCIP dest should be home chain");

        // Verify the CCIP message contains a PAY type.
        (uint8 msgType,) = abi.decode(mockRouter.lastMessageData(), (uint8, bytes));
        assertEq(msgType, 1, "message type should be PAY (1)");
    }

    // ────────────────────────────────────────────────
    // ccipReceive: PAY with ERC-20
    // ────────────────────────────────────────────────

    function test_ccipReceive_pay_erc20() public {
        // Deploy a mock ERC-20 (simulating a bridgeable token like USDC).
        MockERC20Token mockUSDC = new MockERC20Token("USD Coin", "USDC");

        // Launch a new real project that accepts USDC from the start.
        JBRulesetConfig[] memory erc20RulesetConfigs = new JBRulesetConfig[](1);
        erc20RulesetConfigs[0].mustStartAtOrAfter = 0;
        erc20RulesetConfigs[0].duration = 0;
        erc20RulesetConfigs[0].weight = 1000 * 10 ** 18;
        erc20RulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        erc20RulesetConfigs[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(mockUSDC))),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        erc20RulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        erc20RulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory erc20TerminalConfigs = new JBTerminalConfig[](1);
        JBAccountingContext[] memory usdcContext = new JBAccountingContext[](1);
        usdcContext[0] =
            JBAccountingContext({token: address(mockUSDC), decimals: 18, currency: uint32(uint160(address(mockUSDC)))});
        erc20TerminalConfigs[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: usdcContext});

        uint256 erc20ProjectId = jbController()
            .launchProjectFor({
                owner: address(this),
                projectUri: "erc20-project",
                rulesetConfigurations: erc20RulesetConfigs,
                terminalConfigurations: erc20TerminalConfigs,
                memo: ""
            });
        jbController().deployERC20For(erc20ProjectId, "ERC20Token", "ERC20T", bytes32(uint256(99)));

        // Deploy a home sucker terminal with CCIP.
        JBSuckerTerminal homeTerminal = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(mockRouter)),
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            peer: address(0xDEAD),
            routerTerminal: IJBTerminal(address(0))
        });

        // Create a home chain proxy for the ERC-20 project.
        uint256 proxyProjectId =
            homeTerminal.createProxy(erc20ProjectId, 0, "ProxyToken", "PROXY", bytes32(uint256(400)));

        // Mint USDC to the home terminal (simulating CCIP delivery).
        uint256 amount = 500e18;
        mockUSDC.mint(address(homeTerminal), amount);

        // Build the CCIP pay message with ERC-20 delivery.
        address beneficiary = address(0xBEEF);
        Client.Any2EVMMessage memory message;
        message.sender = abi.encode(address(0xDEAD));
        message.sourceChainSelector = REMOTE_CHAIN_SELECTOR;
        message.data = abi.encode(
            uint8(1), // MSG_TYPE_PAY
            abi.encode(
                JBRelayPayMessage({
                    realProjectId: erc20ProjectId, beneficiary: beneficiary, memo: "erc20", metadata: ""
                })
            )
        );
        message.destTokenAmounts = new Client.EVMTokenAmount[](1);
        message.destTokenAmounts[0] = Client.EVMTokenAmount({token: address(mockUSDC), amount: amount});

        // Deliver the message as the CCIP router.
        vm.prank(address(mockRouter));
        homeTerminal.ccipReceive(message);

        // Beneficiary should have received proxy tokens.
        address proxyToken = address(jbTokens().tokenOf(proxyProjectId));
        uint256 proxyBalance = IERC20(proxyToken).balanceOf(beneficiary);
        assertGt(proxyBalance, 0, "beneficiary should have proxy tokens");
    }

    // ────────────────────────────────────────────────
    // ccipReceive: CASH_OUT_CLAIM with ERC-20
    // ────────────────────────────────────────────────

    function test_ccipReceive_cashOutClaim_erc20() public {
        // Deploy a mock ERC-20.
        MockERC20Token mockUSDC = new MockERC20Token("USD Coin", "USDC");

        // Deploy a remote sucker terminal.
        JBSuckerTerminal remote = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(mockRouter)),
            remoteChainSelector: HOME_CHAIN_SELECTOR,
            peer: address(0xDEAD),
            routerTerminal: IJBTerminal(address(0))
        });

        // Mint USDC to the remote terminal (simulating CCIP delivery).
        address payable beneficiary = payable(address(0xCAFE));
        uint256 amount = 1000e18;
        mockUSDC.mint(address(remote), amount);

        // Build the CCIP message with MSG_TYPE_CASH_OUT_CLAIM and ERC-20 delivery.
        Client.Any2EVMMessage memory message;
        message.sender = abi.encode(address(0xDEAD));
        message.sourceChainSelector = HOME_CHAIN_SELECTOR;
        message.data = abi.encode(
            uint8(2), // MSG_TYPE_CASH_OUT_CLAIM
            abi.encode(JBRelayCashOutClaimMessage({beneficiary: beneficiary}))
        );
        message.destTokenAmounts = new Client.EVMTokenAmount[](1);
        message.destTokenAmounts[0] = Client.EVMTokenAmount({token: address(mockUSDC), amount: amount});

        // Deliver the message as the CCIP router.
        vm.prank(address(mockRouter));
        remote.ccipReceive(message);

        // Beneficiary should have received USDC (not ETH).
        assertEq(mockUSDC.balanceOf(beneficiary), amount, "beneficiary should receive USDC");
    }

    // ────────────────────────────────────────────────
    // ROUTER_TERMINAL fallback
    // ────────────────────────────────────────────────

    function test_ccipReceive_pay_routerTerminalFallback() public {
        // Deploy a mock ERC-20 that the real project does NOT accept.
        MockERC20Token mockUSDC = new MockERC20Token("USD Coin", "USDC");

        // Deploy a mock router terminal that swaps USDC → ETH (pre-funded) and pays the real project.
        MockRouterTerminal mockRouterTerm = new MockRouterTerminal(IJBTerminal(address(jbMultiTerminal())));
        vm.deal(address(mockRouterTerm), 5 ether);

        // Deploy a home sucker terminal WITH the router terminal fallback.
        JBSuckerTerminal homeTerminal = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(mockRouter)),
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            peer: address(0xDEAD),
            routerTerminal: IJBTerminal(address(mockRouterTerm))
        });

        // Create a home chain proxy for realProjectId (which only accepts native ETH).
        uint256 proxyProjectId =
            homeTerminal.createProxy(realProjectId, 0, "ProxyToken", "PROXY", bytes32(uint256(500)));

        // Mint USDC to the home terminal (simulating CCIP delivery of a token the project doesn't accept).
        uint256 amount = 100e18;
        mockUSDC.mint(address(homeTerminal), amount);

        // Build CCIP PAY message with USDC delivery for realProjectId.
        address beneficiary = address(0xBEEF);
        Client.Any2EVMMessage memory message;
        message.sender = abi.encode(address(0xDEAD));
        message.sourceChainSelector = REMOTE_CHAIN_SELECTOR;
        message.data = abi.encode(
            uint8(1), // MSG_TYPE_PAY
            abi.encode(
                JBRelayPayMessage({
                    realProjectId: realProjectId, beneficiary: beneficiary, memo: "router", metadata: ""
                })
            )
        );
        message.destTokenAmounts = new Client.EVMTokenAmount[](1);
        message.destTokenAmounts[0] = Client.EVMTokenAmount({token: address(mockUSDC), amount: amount});

        // Deliver the message as the CCIP router.
        vm.prank(address(mockRouter));
        homeTerminal.ccipReceive(message);

        // Verify the router terminal was called with the right params.
        assertEq(mockRouterTerm.lastProjectId(), realProjectId, "router should be called with real project ID");
        assertEq(mockRouterTerm.lastToken(), address(mockUSDC), "router should receive USDC");
        assertEq(mockRouterTerm.lastAmount(), amount, "router should receive full amount");

        // Beneficiary should have received proxy tokens.
        address proxyToken = address(jbTokens().tokenOf(proxyProjectId));
        uint256 proxyBalance = IERC20(proxyToken).balanceOf(beneficiary);
        assertGt(proxyBalance, 0, "beneficiary should have proxy tokens via router fallback");
    }

    function test_ccipReceive_pay_revertsNoTerminalNoRouter() public {
        // Deploy a mock ERC-20 that the real project does NOT accept.
        MockERC20Token mockUSDC = new MockERC20Token("USD Coin", "USDC");

        // Deploy a home sucker terminal WITHOUT a router terminal.
        JBSuckerTerminal homeTerminal = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(mockRouter)),
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            peer: address(0xDEAD),
            routerTerminal: IJBTerminal(address(0))
        });

        // Create a home chain proxy.
        homeTerminal.createProxy(realProjectId, 0, "ProxyToken", "PROXY", bytes32(uint256(600)));

        // Mint USDC to the terminal (simulating CCIP delivery).
        uint256 amount = 100e18;
        mockUSDC.mint(address(homeTerminal), amount);

        // Build CCIP PAY message with USDC (no terminal for this token, no router fallback).
        Client.Any2EVMMessage memory message;
        message.sender = abi.encode(address(0xDEAD));
        message.sourceChainSelector = REMOTE_CHAIN_SELECTOR;
        message.data = abi.encode(
            uint8(1), // MSG_TYPE_PAY
            abi.encode(
                JBRelayPayMessage({
                    realProjectId: realProjectId, beneficiary: address(0xBEEF), memo: "fail", metadata: ""
                })
            )
        );
        message.destTokenAmounts = new Client.EVMTokenAmount[](1);
        message.destTokenAmounts[0] = Client.EVMTokenAmount({token: address(mockUSDC), amount: amount});

        // Should revert because no terminal for USDC and no router terminal configured.
        vm.prank(address(mockRouter));
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSuckerTerminal.JBSuckerTerminal_NoTerminal.selector, realProjectId, address(mockUSDC)
            )
        );
        homeTerminal.ccipReceive(message);
    }
}
