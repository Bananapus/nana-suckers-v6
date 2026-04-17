// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IJBSucker} from "../src/interfaces/IJBSucker.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ICCIPRouter} from "src/interfaces/ICCIPRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBTokenMapping} from "../src/structs/JBTokenMapping.sol";
import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {JBInboxTreeRoot} from "../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";
import {JBClaim} from "../src/structs/JBClaim.sol";
import {JBLeaf} from "../src/structs/JBLeaf.sol";
import {JBSucker} from "../src/JBSucker.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
import {JBCCIPSuckerDeployer} from "src/deployers/JBCCIPSuckerDeployer.sol";
import {JBCCIPSucker} from "../src/JBCCIPSucker.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {CCIPHelper} from "../src/libraries/CCIPHelper.sol";

/// @dev Captured leaf data from InsertToOutboxTree event.
struct LeafData {
    bytes32 beneficiary;
    uint256 index;
    bytes32 root;
    uint256 projectTokenCount;
    uint256 terminalTokenAmount;
    bytes32 hashed;
}

/// @notice Abstract base for mainnet CCIP sucker claim fork tests.
/// @dev Tests the full round-trip: pay → prepare → toRemote (L1) → manual ccipReceive → claim (L2).
/// Uses the dual-fork pattern from ForkMainnet.t.sol (real CCIP router on send side) combined with
/// the manual ccipReceive pattern from ForkSwapMainnet.t.sol (prank as router on receive side).
abstract contract CCIPSuckerClaimForkTestBase is TestBaseWorkflow {
    CCIPLocalSimulatorFork ccipLocalSimulatorFork;
    JBRulesetMetadata _metadata;

    JBCCIPSuckerDeployer suckerDeployerL1;
    JBCCIPSuckerDeployer suckerDeployerL2;
    IJBSucker suckerL1;
    IJBToken projectToken;

    uint256 l1Fork;
    uint256 l2Fork;

    // ── Chain-specific overrides
    // ──────────────────────────────────────────────

    function _l1RpcUrl() internal pure virtual returns (string memory);
    function _l2RpcUrl() internal pure virtual returns (string memory);
    function _l1ChainId() internal pure virtual returns (uint256);
    function _l2ChainId() internal pure virtual returns (uint256);
    function _l1ForkBlock() internal pure virtual returns (uint256);
    function _l2ForkBlock() internal pure virtual returns (uint256);

    // ── Token overrides (defaults: native token on both sides)
    // ────────────────────────────────

    function _terminalToken() internal view virtual returns (address) {
        return JBConstants.NATIVE_TOKEN;
    }

    function _remoteTerminalToken() internal view virtual returns (bytes32) {
        return bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)));
    }

    /// @dev Whether CCIP fees are paid in native ETH (true) or LINK from the sucker's balance (false).
    function _ccipFeesInNative() internal pure virtual returns (bool) {
        return true;
    }

    // ── LINK token addresses per mainnet chain
    // ────────────────────────────────

    function _linkTokenOf(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        if (chainId == 42_161) return 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
        if (chainId == 10) return 0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6;
        if (chainId == 8453) return 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
        if (chainId == 4217) return 0x15C03488B29e27d62BAf10E30b0c474bf60E0264;
        revert("Unsupported chain for LINK token");
    }

    // ── Register mainnet network details
    // ──────────────────────────────────

    function _registerMainnetDetails(uint256 chainId) internal {
        Register.NetworkDetails memory details = Register.NetworkDetails({
            chainSelector: CCIPHelper.selectorOfChain(chainId),
            routerAddress: CCIPHelper.routerOfChain(chainId),
            linkAddress: _linkTokenOf(chainId),
            wrappedNativeAddress: CCIPHelper.wethOfChain(chainId),
            ccipBnMAddress: address(0),
            ccipLnMAddress: address(0),
            rmnProxyAddress: address(0),
            registryModuleOwnerCustomAddress: address(0),
            tokenAdminRegistryAddress: address(0)
        });
        ccipLocalSimulatorFork.setNetworkDetails(chainId, details);
    }

    /// @dev Deploy mock ERC20 at the terminal token address if it has no code on the current fork.
    function _ensureTerminalTokenExists() internal {
        address token = _terminalToken();
        if (token != JBConstants.NATIVE_TOKEN && token.code.length == 0) {
            vm.etch(token, CCIPHelper.wethOfChain(block.chainid).code);
        }
    }

    // ── Setup
    // ─────────────────────────────────────────────────────────────

    function setUp() public override {
        // ── L1
        // ────────────────────────────────────────────────────────────
        l1Fork = vm.createSelectFork(_l1RpcUrl(), _l1ForkBlock());
        _ensureTerminalTokenExists();

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        // Register mainnet network details (CCIPLocalSimulatorFork only ships with testnets).
        _registerMainnetDetails(_l1ChainId());
        _registerMainnetDetails(_l2ChainId());

        _metadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT / 2,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        // Deploy full JB infrastructure on L1.
        super.setUp();
        vm.stopPrank();

        // Deploy sucker deployer on L1 (points to L2 as remote).
        vm.startPrank(address(0x1112222));
        suckerDeployerL1 =
            new JBCCIPSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        vm.stopPrank();

        suckerDeployerL1.setChainSpecificConstants(
            _l2ChainId(), CCIPHelper.selectorOfChain(_l2ChainId()), ICCIPRouter(CCIPHelper.routerOfChain(block.chainid))
        );

        vm.startPrank(address(0x1112222));
        JBCCIPSucker singletonL1 = new JBCCIPSucker({
            deployer: suckerDeployerL1,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        suckerDeployerL1.configureSingleton(singletonL1);
        suckerL1 = suckerDeployerL1.createForSender(1, "salty");
        vm.label(address(suckerL1), "suckerL1");

        // Grant sucker mint permission on L1.
        uint8[] memory ids = new uint8[](1);
        ids[0] = JBPermissionIds.MINT_TOKENS;
        JBPermissionsData memory permsL1 =
            JBPermissionsData({operator: address(suckerL1), projectId: 1, permissionIds: ids});

        vm.startPrank(multisig());
        jbPermissions().setPermissionsFor(multisig(), permsL1);
        _launchProject();
        projectToken = jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));
        vm.stopPrank();

        // ── L2
        // ────────────────────────────────────────────────────────────
        l2Fork = vm.createSelectFork(_l2RpcUrl(), _l2ForkBlock());
        _ensureTerminalTokenExists();

        // Deploy full JB infrastructure on L2.
        super.setUp();
        vm.stopPrank();

        vm.startPrank(address(0x1112222));
        suckerDeployerL2 =
            new JBCCIPSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        vm.stopPrank();

        suckerDeployerL2.setChainSpecificConstants(
            _l1ChainId(), CCIPHelper.selectorOfChain(_l1ChainId()), ICCIPRouter(CCIPHelper.routerOfChain(block.chainid))
        );

        vm.startPrank(address(0x1112222));
        JBCCIPSucker singletonL2 = new JBCCIPSucker({
            deployer: suckerDeployerL2,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        suckerDeployerL2.configureSingleton(singletonL2);
        IJBSucker suckerL2 = suckerDeployerL2.createForSender(1, "salty");

        // Grant L2 sucker mint permission, launch L2 project, deploy ERC20.
        JBPermissionsData memory permsL2 =
            JBPermissionsData({operator: address(suckerL2), projectId: 1, permissionIds: ids});
        vm.startPrank(multisig());
        _launchProject();
        jbPermissions().setPermissionsFor(multisig(), permsL2);
        jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));
        vm.stopPrank();

        // Mock the registry's toRemoteFee() on both forks (registry is address(0) in tests).
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
        vm.selectFork(l1Fork);
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
    }

    /// @notice Launch a project that accepts `_terminalToken()`.
    function _launchProject() internal {
        address token = _terminalToken();

        // Ensure baseCurrency matches the terminal token so no price feed is needed.
        _metadata.baseCurrency = uint32(uint160(token));

        JBCurrencyAmount[] memory _surplusAllowances = new JBCurrencyAmount[](1);
        _surplusAllowances[0] = JBCurrencyAmount({amount: 5 * 10 ** 18, currency: uint32(uint160(token))});

        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: token,
            payoutLimits: new JBCurrencyAmount[](0),
            surplusAllowances: _surplusAllowances
        });

        JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
        _rulesetConfigurations[0].mustStartAtOrAfter = 0;
        _rulesetConfigurations[0].duration = 0;
        _rulesetConfigurations[0].weight = 1000 * 10 ** 18;
        _rulesetConfigurations[0].weightCutPercent = 0;
        _rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfigurations[0].metadata = _metadata;
        _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);
        _tokensToAccept[0] = JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});

        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        _terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokensToAccept});

        jbController()
            .launchProjectFor({
                owner: multisig(),
                projectUri: "claim-fork-test",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            });
    }

    // ── Helpers
    // ─────────────────────────────────────────────────────────────

    /// @notice Builds a 32-element proof of all zero hashes for a single-leaf tree (index 0).
    function _zeroProof() internal pure returns (bytes32[32] memory proof) {
        proof[0] = hex"0000000000000000000000000000000000000000000000000000000000000000";
        proof[1] = hex"ad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5";
        proof[2] = hex"b4c11951957c6f8f642c4af61cd6b24640fec6dc7fc607ee8206a99e92410d30";
        proof[3] = hex"21ddb9a356815c3fac1026b6dec5df3124afbadb485c9ba5a3e3398a04b7ba85";
        proof[4] = hex"e58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344";
        proof[5] = hex"0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d";
        proof[6] = hex"887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968";
        proof[7] = hex"ffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83";
        proof[8] = hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af";
        proof[9] = hex"cefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0";
        proof[10] = hex"f9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5";
        proof[11] = hex"f8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892";
        proof[12] = hex"3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c";
        proof[13] = hex"c1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb";
        proof[14] = hex"5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc";
        proof[15] = hex"da7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2";
        proof[16] = hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f";
        proof[17] = hex"e1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a";
        proof[18] = hex"5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0";
        proof[19] = hex"b46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0";
        proof[20] = hex"c65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2";
        proof[21] = hex"f4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9";
        proof[22] = hex"5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377";
        proof[23] = hex"4df84f40ae0c8229d0d6069e5c8f39a7c299677a09d367fc7b05e3bc380ee652";
        proof[24] = hex"cdc72595f74c7b1043d0e1ffbab734648c838dfb0527d971b602bc216c9619ef";
        proof[25] = hex"0abf5ac974a1ed57f4050aa510dd9c74f508277b39d7973bb2dfccc5eeb0618d";
        proof[26] = hex"b8cd74046ff337f0a7bf2c8e03e10f642c1886798d71806ab1e888d9e5ee87d0";
        proof[27] = hex"838c5655cb21c6cb83313b5a631175dff4963772cce9108188b34ac87c81c41e";
        proof[28] = hex"662ee4dd2dd7b2bc707961b1e646c4047669dcb6584f0d8d770daf5d7e7deb2e";
        proof[29] = hex"388ab20e2573d171a88108e79d820e98f26c0b84aa8b2f4aa4968dbb818ea322";
        proof[30] = hex"93237c50ba75ee485f4c22adf2f741400bdf8d6a9cc7df7ecae576221665d735";
        proof[31] = hex"8448818bb4ae4562849e949e17ac16e0be16688e156b5cf15e098c627c0056a9";
    }

    /// @notice Builds a `Client.Any2EVMMessage` for manual ccipReceive delivery on L2.
    function _buildCCIPMessage(JBMessageRoot memory messageRoot) internal view returns (Client.Any2EVMMessage memory) {
        return Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: CCIPHelper.selectorOfChain(_l1ChainId()),
            sender: abi.encode(address(suckerL1)),
            data: abi.encode(uint8(0), abi.encode(messageRoot)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    /// @notice Extract leaf data from InsertToOutboxTree events in a log array.
    function _extractLeaf(Vm.Log[] memory logs, uint256 leafIndex) internal pure returns (LeafData memory leaf) {
        bytes32 eventSig =
            keccak256("InsertToOutboxTree(bytes32,address,bytes32,uint256,bytes32,uint256,uint256,address)");

        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != eventSig) continue;

            uint256 decodedIndex;
            (leaf.hashed, decodedIndex, leaf.root, leaf.projectTokenCount, leaf.terminalTokenAmount,) =
                abi.decode(logs[i].data, (bytes32, uint256, bytes32, uint256, uint256, address));

            if (decodedIndex == leafIndex) {
                leaf.beneficiary = logs[i].topics[1];
                leaf.index = decodedIndex;
                return leaf;
            }
        }
        revert("InsertToOutboxTree event not found for leafIndex");
    }

    /// @notice Extract root and nonce from a RootToRemote event.
    function _extractRootToRemote(Vm.Log[] memory logs) internal pure returns (bytes32 root, uint64 nonce) {
        bytes32 eventSig = keccak256("RootToRemote(bytes32,address,uint256,uint64,address)");

        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != eventSig) continue;
            root = logs[i].topics[1];
            (, nonce,) = abi.decode(logs[i].data, (uint256, uint64, address));
            return (root, nonce);
        }
        revert("RootToRemote event not found");
    }

    /// @notice Have user pay and prepare. Returns captured leaf data.
    function _mapPayAndPrepare(address user, uint256 amountToSend) internal returns (LeafData memory leaf) {
        address token = _terminalToken();

        // Fund user with terminal token.
        if (token == JBConstants.NATIVE_TOKEN) {
            vm.deal(user, amountToSend);
        } else {
            deal(token, user, amountToSend);
        }

        // Pay into L1 terminal → receive project tokens.
        vm.startPrank(user);
        uint256 projectTokenAmount;
        if (token == JBConstants.NATIVE_TOKEN) {
            projectTokenAmount = jbMultiTerminal().pay{value: amountToSend}(1, token, amountToSend, user, 0, "", "");
        } else {
            IERC20(token).approve(address(jbMultiTerminal()), amountToSend);
            projectTokenAmount = jbMultiTerminal().pay(1, token, amountToSend, user, 0, "", "");
        }

        // Prepare: burns project tokens, cashes out terminal token, inserts leaf into outbox tree.
        IERC20(address(projectToken)).approve(address(suckerL1), projectTokenAmount);
        vm.recordLogs();
        suckerL1.prepare(projectTokenAmount, bytes32(uint256(uint160(user))), 0, token);
        vm.stopPrank();

        // Capture leaf from InsertToOutboxTree event.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        leaf = _extractLeaf(logs, suckerL1.outboxOf(token).tree.count - 1);
    }

    /// @notice Send toRemote and return the root + nonce from RootToRemote event.
    function _sendToRemote() internal returns (bytes32 sentRoot, uint64 sentNonce) {
        address token = _terminalToken();
        vm.recordLogs();
        address rootSender = makeAddr("rootSender");

        if (_ccipFeesInNative()) {
            // Native ETH fee path.
            uint256 ccipFeeAmount = 1 ether;
            vm.deal(rootSender, ccipFeeAmount);
            vm.prank(rootSender);
            suckerL1.toRemote{value: ccipFeeAmount}(token);
        } else {
            // LINK fee path: pre-fund sucker with LINK, call toRemote with msg.value = 0.
            address linkToken = _linkTokenOf(block.chainid);
            deal(linkToken, address(suckerL1), IERC20(linkToken).balanceOf(address(suckerL1)) + 100 ether);
            vm.prank(rootSender);
            suckerL1.toRemote(token);
        }

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (sentRoot, sentNonce) = _extractRootToRemote(logs);
    }

    /// @notice Deliver a root to L2 via manual ccipReceive and fund the sucker with terminal token.
    function _deliverToL2(bytes32 root, uint64 nonce, uint256 totalAmount) internal {
        address token = _terminalToken();

        // Fund sucker with terminal token (simulates CCIP delivery).
        if (token == JBConstants.NATIVE_TOKEN) {
            vm.deal(address(suckerL1), totalAmount);
        } else {
            deal(token, address(suckerL1), totalAmount);
        }

        JBMessageRoot memory messageRoot = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(token))),
            amount: totalAmount,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: root}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 18,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        vm.prank(CCIPHelper.routerOfChain(_l2ChainId()));
        JBCCIPSucker(payable(address(suckerL1))).ccipReceive(_buildCCIPMessage(messageRoot));
    }

    /// @notice Map terminal token for bridging on the current fork.
    function _mapTerminalToken() internal {
        // Cache before vm.prank — _terminalToken() may trigger a DELEGATECALL to the CCIPHelper
        // library (linkOfChain is `public pure`), which would consume the prank.
        address token = _terminalToken();
        bytes32 remoteToken = _remoteTerminalToken();
        vm.prank(multisig());
        suckerL1.mapToken(JBTokenMapping({localToken: token, minGas: 200_000, remoteToken: remoteToken}));
    }

    /// @notice Full single-leaf setup: L1 map+pay+prepare+toRemote, then deliver to L2.
    function _fullSingleLeafSetup(address user)
        internal
        returns (LeafData memory leaf, bytes32 sentRoot, uint64 sentNonce)
    {
        vm.selectFork(l1Fork);
        _mapTerminalToken();
        leaf = _mapPayAndPrepare(user, 0.05 ether);
        (sentRoot, sentNonce) = _sendToRemote();
        vm.selectFork(l2Fork);
        _deliverToL2(sentRoot, sentNonce, leaf.terminalTokenAmount);
    }

    // ── Tests: happy path
    // ─────────────────────────────────────────────────────────────

    /// @notice Full end-to-end single-leaf: pay → prepare → toRemote (L1) → ccipReceive → claim (L2).
    function test_roundTripNativeClaim() external {
        address user = makeAddr("user");

        // ── L1: Pay + Prepare + ToRemote ──
        vm.selectFork(l1Fork);
        address token = _terminalToken();
        _mapTerminalToken();

        LeafData memory leaf = _mapPayAndPrepare(user, 0.05 ether);

        assertEq(leaf.index, 0, "First leaf should be at index 0");
        assertGt(leaf.projectTokenCount, 0, "Project token count should be > 0");
        assertGt(leaf.terminalTokenAmount, 0, "Terminal token amount should be > 0");

        // toRemote: sends via real CCIP router.
        (bytes32 sentRoot, uint64 sentNonce) = _sendToRemote();
        assertEq(suckerL1.outboxOf(token).balance, 0, "Outbox should be cleared");
        assertEq(sentRoot, leaf.root, "Root from toRemote should match InsertToOutboxTree");

        // ── Switch to L2: ccipReceive + claim ──
        vm.selectFork(l2Fork);
        token = _terminalToken(); // Refresh for L2 fork (may be different address).
        _deliverToL2(sentRoot, sentNonce, leaf.terminalTokenAmount);

        // Verify inbox root is set.
        assertEq(suckerL1.inboxOf(token).root, sentRoot, "Inbox root should match sent root");

        // Verify user has 0 tokens before claim.
        assertEq(jbTokens().totalBalanceOf(user, 1), 0, "User should have 0 tokens before claim");

        // Claim with zero-hash proof (single-leaf tree).
        JBClaim memory claimData = JBClaim({
            token: token,
            leaf: JBLeaf({
                index: leaf.index,
                beneficiary: leaf.beneficiary,
                projectTokenCount: leaf.projectTokenCount,
                terminalTokenAmount: leaf.terminalTokenAmount
            }),
            proof: _zeroProof()
        });
        suckerL1.claim(claimData);

        assertEq(
            jbTokens().totalBalanceOf(user, 1),
            leaf.projectTokenCount,
            "User should have received exact project token count from claim"
        );

        // Double-claim should revert.
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, token, leaf.index));
        suckerL1.claim(claimData);
    }

    /// @notice Two users prepare on L1, both claim on L2 with correct merkle proofs.
    function test_roundTripNativeClaim_twoLeaves() external {
        address userA = makeAddr("userA");
        address userB = makeAddr("userB");
        uint256 amountToSend = 0.05 ether;

        // ── L1: Both users pay, then prepare ──
        vm.selectFork(l1Fork);
        address token = _terminalToken();
        _mapTerminalToken();

        // Both users pay first (so surplus is established), then prepare.
        if (token == JBConstants.NATIVE_TOKEN) {
            vm.deal(userA, amountToSend);
            vm.deal(userB, amountToSend);
        } else {
            deal(token, userA, amountToSend);
            deal(token, userB, amountToSend);
        }

        uint256 ptAmountA;
        uint256 ptAmountB;
        if (token == JBConstants.NATIVE_TOKEN) {
            vm.prank(userA);
            ptAmountA = jbMultiTerminal().pay{value: amountToSend}(1, token, amountToSend, userA, 0, "", "");
            vm.prank(userB);
            ptAmountB = jbMultiTerminal().pay{value: amountToSend}(1, token, amountToSend, userB, 0, "", "");
        } else {
            vm.startPrank(userA);
            IERC20(token).approve(address(jbMultiTerminal()), amountToSend);
            ptAmountA = jbMultiTerminal().pay(1, token, amountToSend, userA, 0, "", "");
            vm.stopPrank();
            vm.startPrank(userB);
            IERC20(token).approve(address(jbMultiTerminal()), amountToSend);
            ptAmountB = jbMultiTerminal().pay(1, token, amountToSend, userB, 0, "", "");
            vm.stopPrank();
        }

        // Record logs across both prepares.
        vm.recordLogs();

        vm.startPrank(userA);
        IERC20(address(projectToken)).approve(address(suckerL1), ptAmountA);
        suckerL1.prepare(ptAmountA, bytes32(uint256(uint160(userA))), 0, token);
        vm.stopPrank();

        vm.startPrank(userB);
        IERC20(address(projectToken)).approve(address(suckerL1), ptAmountB);
        suckerL1.prepare(ptAmountB, bytes32(uint256(uint160(userB))), 0, token);
        vm.stopPrank();

        Vm.Log[] memory prepareLogs = vm.getRecordedLogs();
        LeafData memory leafA = _extractLeaf(prepareLogs, 0);
        LeafData memory leafB = _extractLeaf(prepareLogs, 1);

        // toRemote: sends 2-leaf root via real CCIP router.
        (bytes32 sentRoot, uint64 sentNonce) = _sendToRemote();

        // ── Switch to L2: deliver + both users claim ──
        vm.selectFork(l2Fork);
        token = _terminalToken(); // Refresh for L2 fork.
        _deliverToL2(sentRoot, sentNonce, leafA.terminalTokenAmount + leafB.terminalTokenAmount);

        assertNotEq(suckerL1.inboxOf(token).root, bytes32(0), "Inbox root should be set");

        // User A claims with proof: [hashedB, Z_1, Z_2, ..., Z_31].
        {
            bytes32[32] memory proofA = _zeroProof();
            proofA[0] = leafB.hashed;

            suckerL1.claim(
                JBClaim({
                    token: token,
                    leaf: JBLeaf({
                        index: leafA.index,
                        beneficiary: leafA.beneficiary,
                        projectTokenCount: leafA.projectTokenCount,
                        terminalTokenAmount: leafA.terminalTokenAmount
                    }),
                    proof: proofA
                })
            );
            assertEq(jbTokens().totalBalanceOf(userA, 1), leafA.projectTokenCount, "User A should have received tokens");
        }

        // User B claims with proof: [hashedA, Z_1, Z_2, ..., Z_31].
        {
            bytes32[32] memory proofB = _zeroProof();
            proofB[0] = leafA.hashed;

            suckerL1.claim(
                JBClaim({
                    token: token,
                    leaf: JBLeaf({
                        index: leafB.index,
                        beneficiary: leafB.beneficiary,
                        projectTokenCount: leafB.projectTokenCount,
                        terminalTokenAmount: leafB.terminalTokenAmount
                    }),
                    proof: proofB
                })
            );
            assertEq(jbTokens().totalBalanceOf(userB, 1), leafB.projectTokenCount, "User B should have received tokens");
        }

        // Double-claims revert.
        {
            bytes32[32] memory proofA = _zeroProof();
            proofA[0] = leafB.hashed;

            vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, token, leafA.index));
            suckerL1.claim(
                JBClaim({
                    token: token,
                    leaf: JBLeaf({
                        index: leafA.index,
                        beneficiary: leafA.beneficiary,
                        projectTokenCount: leafA.projectTokenCount,
                        terminalTokenAmount: leafA.terminalTokenAmount
                    }),
                    proof: proofA
                })
            );
        }
    }

    // ── Tests: edge cases
    // ─────────────────────────────────────────────────────────────

    /// @notice Claim with a tampered proof element reverts.
    function test_claimRevertsWithInvalidProof() external {
        address user = makeAddr("user");
        (LeafData memory leaf,,) = _fullSingleLeafSetup(user);
        address token = _terminalToken();

        bytes32[32] memory badProof = _zeroProof();
        badProof[15] = bytes32(uint256(0xdead)); // Corrupt a middle element.

        vm.expectPartialRevert(JBSucker.JBSucker_InvalidProof.selector);
        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leaf.index,
                    beneficiary: leaf.beneficiary,
                    projectTokenCount: leaf.projectTokenCount,
                    terminalTokenAmount: leaf.terminalTokenAmount
                }),
                proof: badProof
            })
        );
    }

    /// @notice Claim with correct proof but tampered leaf amount reverts (leaf hash mismatch).
    function test_claimRevertsWithTamperedLeafAmount() external {
        address user = makeAddr("user");
        (LeafData memory leaf,,) = _fullSingleLeafSetup(user);
        address token = _terminalToken();

        vm.expectPartialRevert(JBSucker.JBSucker_InvalidProof.selector);
        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leaf.index,
                    beneficiary: leaf.beneficiary,
                    projectTokenCount: leaf.projectTokenCount + 1, // Tampered.
                    terminalTokenAmount: leaf.terminalTokenAmount
                }),
                proof: _zeroProof()
            })
        );
    }

    /// @notice Claim with correct proof but wrong beneficiary reverts.
    function test_claimRevertsWithWrongBeneficiary() external {
        address user = makeAddr("user");
        (LeafData memory leaf,,) = _fullSingleLeafSetup(user);
        address token = _terminalToken();

        vm.expectPartialRevert(JBSucker.JBSucker_InvalidProof.selector);
        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leaf.index,
                    beneficiary: bytes32(uint256(uint160(makeAddr("attacker")))), // Wrong beneficiary.
                    projectTokenCount: leaf.projectTokenCount,
                    terminalTokenAmount: leaf.terminalTokenAmount
                }),
                proof: _zeroProof()
            })
        );
    }

    /// @notice Claim at wrong index (1 instead of 0) in a single-leaf tree reverts.
    function test_claimRevertsAtWrongIndex() external {
        address user = makeAddr("user");
        (LeafData memory leaf,,) = _fullSingleLeafSetup(user);
        address token = _terminalToken();

        vm.expectPartialRevert(JBSucker.JBSucker_InvalidProof.selector);
        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: 1, // Wrong index — leaf was at index 0.
                    beneficiary: leaf.beneficiary,
                    projectTokenCount: leaf.projectTokenCount,
                    terminalTokenAmount: leaf.terminalTokenAmount
                }),
                proof: _zeroProof()
            })
        );
    }

    /// @notice Claim before ccipReceive delivers inbox root reverts (inbox root is zero).
    function test_claimRevertsBeforeDelivery() external {
        address user = makeAddr("user");

        // L1: prepare only (no delivery to L2).
        vm.selectFork(l1Fork);
        _mapTerminalToken();
        LeafData memory leaf = _mapPayAndPrepare(user, 0.05 ether);

        // Switch to L2 without calling ccipReceive — inbox root stays bytes32(0).
        vm.selectFork(l2Fork);
        address token = _terminalToken();

        assertEq(suckerL1.inboxOf(token).root, bytes32(0), "Inbox root should be zero");

        vm.expectPartialRevert(JBSucker.JBSucker_InvalidProof.selector);
        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leaf.index,
                    beneficiary: leaf.beneficiary,
                    projectTokenCount: leaf.projectTokenCount,
                    terminalTokenAmount: leaf.terminalTokenAmount
                }),
                proof: _zeroProof()
            })
        );
    }

    /// @notice In a two-leaf tree, using the other user's proof reverts.
    function test_twoLeaves_claimRevertsWithSwappedProofs() external {
        address userA = makeAddr("userA");
        address userB = makeAddr("userB");
        uint256 amountToSend = 0.05 ether;

        vm.selectFork(l1Fork);
        address token = _terminalToken();
        _mapTerminalToken();

        if (token == JBConstants.NATIVE_TOKEN) {
            vm.deal(userA, amountToSend);
            vm.deal(userB, amountToSend);
        } else {
            deal(token, userA, amountToSend);
            deal(token, userB, amountToSend);
        }

        uint256 ptA;
        uint256 ptB;
        if (token == JBConstants.NATIVE_TOKEN) {
            vm.prank(userA);
            ptA = jbMultiTerminal().pay{value: amountToSend}(1, token, amountToSend, userA, 0, "", "");
            vm.prank(userB);
            ptB = jbMultiTerminal().pay{value: amountToSend}(1, token, amountToSend, userB, 0, "", "");
        } else {
            vm.startPrank(userA);
            IERC20(token).approve(address(jbMultiTerminal()), amountToSend);
            ptA = jbMultiTerminal().pay(1, token, amountToSend, userA, 0, "", "");
            vm.stopPrank();
            vm.startPrank(userB);
            IERC20(token).approve(address(jbMultiTerminal()), amountToSend);
            ptB = jbMultiTerminal().pay(1, token, amountToSend, userB, 0, "", "");
            vm.stopPrank();
        }

        vm.recordLogs();

        vm.startPrank(userA);
        IERC20(address(projectToken)).approve(address(suckerL1), ptA);
        suckerL1.prepare(ptA, bytes32(uint256(uint160(userA))), 0, token);
        vm.stopPrank();

        vm.startPrank(userB);
        IERC20(address(projectToken)).approve(address(suckerL1), ptB);
        suckerL1.prepare(ptB, bytes32(uint256(uint160(userB))), 0, token);
        vm.stopPrank();

        Vm.Log[] memory prepareLogs = vm.getRecordedLogs();
        LeafData memory leafA = _extractLeaf(prepareLogs, 0);
        LeafData memory leafB = _extractLeaf(prepareLogs, 1);

        (bytes32 sentRoot, uint64 sentNonce) = _sendToRemote();

        vm.selectFork(l2Fork);
        token = _terminalToken(); // Refresh for L2 fork.
        _deliverToL2(sentRoot, sentNonce, leafA.terminalTokenAmount + leafB.terminalTokenAmount);

        // User A tries to claim at index 0 with user B's proof [hashA, Z_1, ...].
        // The correct proof for index 0 is [hashB, Z_1, ...].
        bytes32[32] memory wrongProof = _zeroProof();
        wrongProof[0] = leafA.hashed; // User B's proof has hashA at [0], wrong for leaf A.

        vm.expectPartialRevert(JBSucker.JBSucker_InvalidProof.selector);
        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leafA.index,
                    beneficiary: leafA.beneficiary,
                    projectTokenCount: leafA.projectTokenCount,
                    terminalTokenAmount: leafA.terminalTokenAmount
                }),
                proof: wrongProof
            })
        );
    }

    /// @notice A second ccipReceive with a stale (non-increasing) nonce does not update the inbox root.
    function test_staleNonceDoesNotUpdateInboxRoot() external {
        address user = makeAddr("user");
        (LeafData memory leaf, bytes32 sentRoot, uint64 sentNonce) = _fullSingleLeafSetup(user);
        address token = _terminalToken();

        // Verify inbox root was set by _fullSingleLeafSetup.
        assertEq(suckerL1.inboxOf(token).root, sentRoot, "Inbox root should be set");

        // Try to deliver a different root with the same nonce.
        bytes32 fakeRoot = bytes32(uint256(0xbeef));
        JBMessageRoot memory staleMessage = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(token))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: sentNonce, root: fakeRoot}), // Same nonce, different root.
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 18,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 2
        });

        vm.prank(CCIPHelper.routerOfChain(_l2ChainId()));
        JBCCIPSucker(payable(address(suckerL1))).ccipReceive(_buildCCIPMessage(staleMessage));

        // Inbox root should be unchanged — stale nonce was rejected.
        assertEq(suckerL1.inboxOf(token).root, sentRoot, "Inbox root should NOT be updated by stale nonce");
        assertNotEq(suckerL1.inboxOf(token).root, fakeRoot, "Fake root should NOT have been accepted");

        // Original claim should still work.
        suckerL1.claim(
            JBClaim({
                token: token,
                leaf: JBLeaf({
                    index: leaf.index,
                    beneficiary: leaf.beneficiary,
                    projectTokenCount: leaf.projectTokenCount,
                    terminalTokenAmount: leaf.terminalTokenAmount
                }),
                proof: _zeroProof()
            })
        );
        assertEq(
            jbTokens().totalBalanceOf(user, 1),
            leaf.projectTokenCount,
            "Claim should still work after stale nonce rejection"
        );
    }
}

// ─── Concrete chain pair tests
// ────────────────────────────────────────────────

// ── Pinned fork blocks (matching v6 repo convention)
// ──────────────────────────────────────────────────────
uint256 constant CLAIM_ETH_FORK_BLOCK = 21_700_000;
uint256 constant CLAIM_ARB_FORK_BLOCK = 300_000_000;
// ETH→Tempo CCIP lane + LINK token pool allowlist activated around block 24,744,000.
uint256 constant CLAIM_ETH_TEMPO_FORK_BLOCK = 24_745_000;
uint256 constant CLAIM_TEMPO_FORK_BLOCK = 15_168_000;

/// @notice Ethereum mainnet → Arbitrum mainnet claim round-trip.
contract EthArbClaimForkTest is CCIPSuckerClaimForkTestBase {
    function _l1RpcUrl() internal pure override returns (string memory) {
        return "ethereum";
    }

    function _l2RpcUrl() internal pure override returns (string memory) {
        return "arbitrum";
    }

    function _l1ChainId() internal pure override returns (uint256) {
        return 1;
    }

    function _l2ChainId() internal pure override returns (uint256) {
        return 42_161;
    }

    function _l1ForkBlock() internal pure override returns (uint256) {
        return CLAIM_ETH_FORK_BLOCK;
    }

    function _l2ForkBlock() internal pure override returns (uint256) {
        return CLAIM_ARB_FORK_BLOCK;
    }
}

/// @notice Ethereum mainnet → Tempo mainnet claim round-trip.
/// Both projects accept LINK (the only CCIP-supported token on the ETH↔Tempo lane).
contract EthTempoClaimForkTest is CCIPSuckerClaimForkTestBase {
    function _l1RpcUrl() internal pure override returns (string memory) {
        return "ethereum";
    }

    function _l2RpcUrl() internal pure override returns (string memory) {
        return "tempo";
    }

    function _l1ChainId() internal pure override returns (uint256) {
        return 1;
    }

    function _l2ChainId() internal pure override returns (uint256) {
        return 4217;
    }

    function _l1ForkBlock() internal pure override returns (uint256) {
        return CLAIM_ETH_TEMPO_FORK_BLOCK;
    }

    function _l2ForkBlock() internal pure override returns (uint256) {
        return CLAIM_TEMPO_FORK_BLOCK;
    }

    function _terminalToken() internal view override returns (address) {
        return CCIPHelper.linkOfChain(block.chainid);
    }

    function _remoteTerminalToken() internal view override returns (bytes32) {
        uint256 remoteChain = block.chainid == _l1ChainId() ? _l2ChainId() : _l1ChainId();
        return bytes32(uint256(uint160(CCIPHelper.linkOfChain(remoteChain))));
    }

    function _ccipFeesInNative() internal pure override returns (bool) {
        // ETH side pays native ETH for CCIP fees.
        return true;
    }
}

/// @notice Tempo mainnet → Ethereum mainnet claim round-trip.
/// Both projects accept LINK (the only CCIP-supported token on the Tempo↔ETH lane).
contract TempoEthClaimForkTest is CCIPSuckerClaimForkTestBase {
    function _l1RpcUrl() internal pure override returns (string memory) {
        return "tempo";
    }

    function _l2RpcUrl() internal pure override returns (string memory) {
        return "ethereum";
    }

    function _l1ChainId() internal pure override returns (uint256) {
        return 4217;
    }

    function _l2ChainId() internal pure override returns (uint256) {
        return 1;
    }

    function _l1ForkBlock() internal pure override returns (uint256) {
        return CLAIM_TEMPO_FORK_BLOCK;
    }

    function _l2ForkBlock() internal pure override returns (uint256) {
        return CLAIM_ETH_TEMPO_FORK_BLOCK;
    }

    function _terminalToken() internal view override returns (address) {
        return CCIPHelper.linkOfChain(block.chainid);
    }

    function _remoteTerminalToken() internal view override returns (bytes32) {
        uint256 remoteChain = block.chainid == _l1ChainId() ? _l2ChainId() : _l1ChainId();
        return bytes32(uint256(uint160(CCIPHelper.linkOfChain(remoteChain))));
    }

    function _ccipFeesInNative() internal pure override returns (bool) {
        // Tempo has no native token (CALLVALUE=0), CCIP fees paid in LINK.
        return false;
    }
}
