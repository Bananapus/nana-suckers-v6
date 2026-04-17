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
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
import {JBSwapCCIPSuckerDeployer} from "src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {JBSwapCCIPSucker} from "../src/JBSwapCCIPSucker.sol";
import {CCIPHelper} from "../src/libraries/CCIPHelper.sol";
import {JBInboxTreeRoot} from "../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";

// ── Pinned fork blocks
uint256 constant SWAP_ETH_FORK_BLOCK = 21_700_000;
// ETH→Tempo CCIP lane + LINK token pool allowlist activated around block 24,744,000.
uint256 constant SWAP_ETH_TEMPO_FORK_BLOCK = 24_745_000;

// ── Token addresses on Ethereum mainnet
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
IUniswapV3Factory constant MAINNET_V3_FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

/// @notice Abstract base for mainnet fork tests of `JBSwapCCIPSucker`.
///
/// Tests the full prepare → toRemote flow on Ethereum mainnet where:
///   - Project accepts native ETH as its terminal token
///   - Swap sucker swaps ETH → bridge token via real Uniswap V3 pools
///   - CCIP sends the bridge token to the remote chain through the real mainnet router
///
/// Also tests the receive side: simulating a CCIP message arriving with the bridge token,
/// verifying the swap sucker swaps it back to ETH via real Uniswap V3 and stores correct
/// conversion rates for claim scaling.
///
/// The bridge token varies per route (USDC for Arbitrum, LINK for Tempo) since CCIP token
/// pool allowlists differ by destination chain.
abstract contract SwapCCIPSuckerForkTestBase is TestBaseWorkflow {
    JBRulesetMetadata _metadata;

    JBSwapCCIPSuckerDeployer suckerDeployer;
    IJBSucker suckerL1;
    IJBToken projectToken;

    uint256 l1Fork;

    // ── Chain-specific overrides
    // ──────────────────────────────────────────────
    function _l1ForkBlock() internal pure virtual returns (uint256);
    function _remoteChainId() internal pure virtual returns (uint256);
    function _bridgeToken() internal pure virtual returns (address);
    function _bridgeTokenDecimals() internal pure virtual returns (uint8);

    // ── Setup
    // ──────────────────────────────────────────────────────────────────

    function setUp() public override {
        l1Fork = vm.createSelectFork("ethereum", _l1ForkBlock());

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

        // Deploy full JB infrastructure on ETH mainnet.
        super.setUp();
        vm.stopPrank();

        // Deploy swap sucker deployer.
        vm.startPrank(address(0x1112222));
        suckerDeployer =
            new JBSwapCCIPSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        vm.stopPrank();

        // Configure CCIP constants (remote = target chain).
        suckerDeployer.setChainSpecificConstants(
            _remoteChainId(),
            CCIPHelper.selectorOfChain(_remoteChainId()),
            ICCIPRouter(CCIPHelper.routerOfChain(block.chainid))
        );

        // Configure swap constants: bridge token, real V3 factory, real WETH.
        suckerDeployer.setSwapConstants({
            _bridgeToken: IERC20(_bridgeToken()),
            _poolManager: IPoolManager(address(0)),
            _v3Factory: MAINNET_V3_FACTORY,
            _univ4Hook: address(0),
            _weth: MAINNET_WETH
        });

        // Deploy singleton and configure.
        vm.startPrank(address(0x1112222));
        JBSwapCCIPSucker singleton = new JBSwapCCIPSucker({
            deployer: suckerDeployer,
            directory: jbDirectory(),
            tokens: jbTokens(),
            permissions: jbPermissions(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        suckerDeployer.configureSingleton(singleton);
        suckerL1 = suckerDeployer.createForSender(1, "salty");
        vm.label(address(suckerL1), "swapSuckerL1");

        // Grant sucker mint permission.
        uint8[] memory ids = new uint8[](1);
        ids[0] = JBPermissionIds.MINT_TOKENS;
        JBPermissionsData memory perms =
            JBPermissionsData({operator: address(suckerL1), projectId: 1, permissionIds: ids});

        vm.startPrank(multisig());
        jbPermissions().setPermissionsFor(multisig(), perms);
        _launchProject();
        projectToken = jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));
        vm.stopPrank();

        // Mock the registry's toRemoteFee() (registry is address(0) in tests).
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
    }

    /// @notice Launch a project that accepts only native ETH.
    function _launchProject() internal {
        JBCurrencyAmount[] memory _surplusAllowances = new JBCurrencyAmount[](1);
        _surplusAllowances[0] =
            JBCurrencyAmount({amount: 5 * 10 ** 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: JBConstants.NATIVE_TOKEN,
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
        _tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        _terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokensToAccept});

        jbController()
            .launchProjectFor({
                owner: multisig(),
                projectUri: "swap-fork-test",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            });
    }

    // ── Tests
    // ──────────────────────────────────────────────────────────────────

    /// @notice Verify swap sucker immutables are correctly wired through the deployer → singleton → clone chain.
    function test_immutables() public view {
        JBSwapCCIPSucker swapSucker = JBSwapCCIPSucker(payable(address(suckerL1)));
        assertEq(address(swapSucker.BRIDGE_TOKEN()), _bridgeToken(), "BRIDGE_TOKEN mismatch");
        assertEq(address(swapSucker.V3_FACTORY()), address(MAINNET_V3_FACTORY), "V3_FACTORY should be mainnet");
        assertEq(address(swapSucker.WETH()), MAINNET_WETH, "WETH should be mainnet WETH");
        assertEq(address(swapSucker.POOL_MANAGER()), address(0), "No V4 pool manager");
        assertEq(address(swapSucker.CCIP_ROUTER()), CCIPHelper.routerOfChain(1), "CCIP router should be ETH mainnet");
        assertEq(swapSucker.REMOTE_CHAIN_ID(), _remoteChainId(), "Remote chain ID mismatch");
        assertEq(
            swapSucker.REMOTE_CHAIN_SELECTOR(),
            CCIPHelper.selectorOfChain(_remoteChainId()),
            "Remote chain selector mismatch"
        );
    }

    /// @notice Full send-side flow: pay ETH → prepare → toRemote.
    ///
    /// The swap sucker:
    ///   1. Cashes out ETH from the terminal (via prepare)
    ///   2. Swaps ETH → bridge token via real Uniswap V3 pool on mainnet
    ///   3. Sends bridge token via CCIP through the real mainnet router
    function test_swapNativeTransfer() external {
        address rootSender = makeAddr("rootSender");
        address user = makeAddr("user");
        uint256 amountToSend = 0.05 ether;
        uint256 maxCashedOut = amountToSend / 2;

        vm.selectFork(l1Fork);
        vm.deal(user, amountToSend);

        // Map native ETH with 600k minGas (required for swap sucker's ccipReceive gas budget).
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 600_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        vm.prank(multisig());
        suckerL1.mapToken(map);

        // Pay ETH into terminal → receive project tokens.
        vm.startPrank(user);
        uint256 projectTokenAmount =
            jbMultiTerminal().pay{value: amountToSend}(1, JBConstants.NATIVE_TOKEN, amountToSend, user, 0, "", "");

        // Prepare: burns project tokens, cashes out ETH, inserts leaf into outbox tree.
        IERC20(address(projectToken)).approve(address(suckerL1), projectTokenAmount);
        suckerL1.prepare(projectTokenAmount, bytes32(uint256(uint160(user))), maxCashedOut, JBConstants.NATIVE_TOKEN);
        vm.stopPrank();

        // Record logs to capture CCIP router events.
        vm.recordLogs();

        // toRemote: swap ETH → bridge token via real Uniswap V3, send via real CCIP router.
        vm.deal(rootSender, 1 ether);
        vm.prank(rootSender);
        suckerL1.toRemote{value: 1 ether}(JBConstants.NATIVE_TOKEN);

        // Verify outbox cleared.
        assertEq(suckerL1.outboxOf(JBConstants.NATIVE_TOKEN).balance, 0, "Outbox should be cleared");

        // Verify CCIP fees paid (some ETH consumed, but not all).
        assertLt(rootSender.balance, 1 ether, "CCIP fees should have been deducted");
        assertGt(rootSender.balance, 0, "Excess ETH should be returned");

        // Verify CCIP router or sucker emitted events (router delegates to OnRamp, so check both).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address expectedRouter = CCIPHelper.routerOfChain(1);
        bool foundCCIPEvent;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == expectedRouter || logs[i].emitter == address(suckerL1)) {
                foundCCIPEvent = true;
                break;
            }
        }
        assertTrue(foundCCIPEvent, "CCIP router/sucker should have emitted events");

        // Verify sucker has no leftover bridge token or ETH (all swapped and sent).
        assertEq(IERC20(_bridgeToken()).balanceOf(address(suckerL1)), 0, "No bridge token should remain in sucker");
        assertEq(address(suckerL1).balance, 0, "No ETH should remain in sucker");
    }

    /// @notice Simulate receiving a CCIP message from the remote chain carrying bridge token.
    ///
    /// The swap sucker:
    ///   1. Receives bridge token via ccipReceive (simulated OffRamp delivery)
    ///   2. Swaps bridge token → ETH via real Uniswap V3 pool on mainnet
    ///   3. Stores conversion rate (leafTotal: bridge amount, localTotal: ETH received)
    ///   4. Records inbox merkle root for future claims
    function test_swapReceiveFromRemote() external {
        // Use a reasonable amount for the bridge token (varies by decimals).
        uint256 bridgeAmount = 1000 * 10 ** _bridgeTokenDecimals();

        vm.selectFork(l1Fork);

        // Map native token so the sucker recognizes it.
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 600_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });
        vm.prank(multisig());
        suckerL1.mapToken(map);

        // Fund sucker with bridge token (simulates CCIP OffRamp token delivery before ccipReceive).
        deal(_bridgeToken(), address(suckerL1), bridgeAmount);

        // Build CCIP message: root targets NATIVE_TOKEN (ETH), bridge token delivered.
        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: bridgeAmount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xdead))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 18,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        Client.EVMTokenAmount[] memory destTokenAmounts = new Client.EVMTokenAmount[](1);
        destTokenAmounts[0] = Client.EVMTokenAmount({token: _bridgeToken(), amount: bridgeAmount});

        Client.Any2EVMMessage memory ccipMsg = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: CCIPHelper.selectorOfChain(_remoteChainId()),
            sender: abi.encode(address(suckerL1)), // peer() defaults to address(this)
            data: abi.encode(uint8(0), abi.encode(root, uint256(0), uint256(1))), // type 0 = ROOT, range [0,1)
            destTokenAmounts: destTokenAmounts
        });

        uint256 ethBefore = address(suckerL1).balance;

        // Prank as the real mainnet CCIP router.
        vm.prank(CCIPHelper.routerOfChain(1));
        JBSwapCCIPSucker(payable(address(suckerL1))).ccipReceive(ccipMsg);

        // Verify: swap happened — sucker now holds ETH from bridge token → ETH swap.
        uint256 ethReceived = address(suckerL1).balance - ethBefore;
        assertGt(ethReceived, 0, "Sucker should hold ETH from bridge->ETH swap");
        // Conservative: 1000 units of any reasonable token > 0.001 ETH.
        assertGt(ethReceived, 0.001 ether, "ETH amount should be reasonable");

        // Verify: bridge token fully consumed by the swap.
        assertEq(IERC20(_bridgeToken()).balanceOf(address(suckerL1)), 0, "All bridge token should be swapped");

        // Verify: inbox root was set for future claims.
        assertNotEq(
            suckerL1.inboxOf(JBConstants.NATIVE_TOKEN).root, bytes32(0), "Inbox root should be set after ccipReceive"
        );
    }
}

// ─── Concrete chain pair tests
// ────────────────────────────────────────────────

/// @notice Ethereum mainnet → Tempo (chain ID 4217).
/// The primary production route: ETH-backed project on mainnet, stablecoin-backed on Tempo.
/// Uses LINK as bridge token — the only CCIP-supported token on the ETH→Tempo lane.
/// Exercises the full swap pipeline (ETH → LINK via Uniswap V3 → CCIP to Tempo).
contract EthTempoSwapForkTest is SwapCCIPSuckerForkTestBase {
    function _l1ForkBlock() internal pure override returns (uint256) {
        return SWAP_ETH_TEMPO_FORK_BLOCK;
    }

    function _remoteChainId() internal pure override returns (uint256) {
        return 4217;
    }

    function _bridgeToken() internal pure override returns (address) {
        return LINK;
    }

    function _bridgeTokenDecimals() internal pure override returns (uint8) {
        return 18;
    }
}

/// @notice Ethereum mainnet → Arbitrum (chain ID 42161).
/// Validates swap sucker on established CCIP lane with USDC bridge token support.
/// Exercises the full swap pipeline (ETH → USDC via Uniswap V3 → CCIP to Arbitrum).
contract EthArbSwapForkTest is SwapCCIPSuckerForkTestBase {
    function _l1ForkBlock() internal pure override returns (uint256) {
        return SWAP_ETH_FORK_BLOCK;
    }

    function _remoteChainId() internal pure override returns (uint256) {
        return 42_161;
    }

    function _bridgeToken() internal pure override returns (address) {
        return USDC;
    }

    function _bridgeTokenDecimals() internal pure override returns (uint8) {
        return 6;
    }
}
