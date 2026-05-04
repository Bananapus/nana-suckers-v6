// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {SuckerForkHelpers} from "./helpers/SuckerForkHelpers.sol";
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
uint256 constant SWAP_TEMPO_FORK_BLOCK = 15_168_000;

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
abstract contract SwapCCIPSuckerForkTestBase is SuckerForkHelpers {
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

    // ── Overrides with defaults (preserve existing ETH mainnet behavior)
    // ──────────────────────────────────────────────
    function _l1RpcUrl() internal pure virtual returns (string memory) {
        return "ethereum";
    }

    function _l1ChainId() internal pure virtual returns (uint256) {
        return 1;
    }

    function _weth() internal pure virtual returns (address) {
        return MAINNET_WETH;
    }

    function _v3Factory() internal pure virtual returns (address) {
        return address(MAINNET_V3_FACTORY);
    }

    /// @dev Whether CCIP fees are paid in native ETH (true) or LINK from the sucker's balance (false).
    function _ccipFeesInNative() internal pure virtual returns (bool) {
        return true;
    }

    // ── Setup
    // ──────────────────────────────────────────────────────────────────

    function setUp() public override {
        l1Fork = vm.createSelectFork(_l1RpcUrl(), _l1ForkBlock());
        _ensureTerminalTokenExists();

        _initMetadata();

        super.setUp();
        vm.stopPrank();

        // Deploy swap sucker deployer.
        vm.startPrank(address(0x1112222));
        suckerDeployer =
            new JBSwapCCIPSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        vm.stopPrank();

        suckerDeployer.setChainSpecificConstants(
            _remoteChainId(),
            CCIPHelper.selectorOfChain(_remoteChainId()),
            ICCIPRouter(CCIPHelper.routerOfChain(block.chainid))
        );

        suckerDeployer.setSwapConstants({
            _bridgeToken: IERC20(_bridgeToken()),
            _poolManager: IPoolManager(address(0)),
            _v3Factory: IUniswapV3Factory(_v3Factory()),
            _univ4Hook: address(0),
            _weth: _weth()
        });

        vm.startPrank(address(0x1112222));
        JBSwapCCIPSucker singleton = new JBSwapCCIPSucker({
            deployer: suckerDeployer,
            directory: jbDirectory(),
            tokens: jbTokens(),
            permissions: jbPermissions(),
            prices: address(jbPrices()),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        suckerDeployer.configureSingleton(singleton);
        suckerL1 = suckerDeployer.createForSender(1, "salty", bytes32(0));
        vm.label(address(suckerL1), "swapSuckerL1");

        uint8[] memory ids = new uint8[](1);
        ids[0] = JBPermissionIds.MINT_TOKENS;
        JBPermissionsData memory perms =
            JBPermissionsData({operator: address(suckerL1), projectId: 1, permissionIds: ids});

        vm.startPrank(multisig());
        jbPermissions().setPermissionsFor(multisig(), perms);
        _launchProject();
        projectToken = jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));
        vm.stopPrank();

        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
    }

    // ── Tests
    // ──────────────────────────────────────────────────────────────────

    /// @notice Verify swap sucker immutables are correctly wired through the deployer → singleton → clone chain.
    function test_immutables() public view {
        JBSwapCCIPSucker swapSucker = JBSwapCCIPSucker(payable(address(suckerL1)));
        assertEq(address(swapSucker.BRIDGE_TOKEN()), _bridgeToken(), "BRIDGE_TOKEN mismatch");
        assertEq(address(swapSucker.V3_FACTORY()), _v3Factory(), "V3_FACTORY mismatch");
        assertEq(address(swapSucker.WETH()), _weth(), "WETH mismatch");
        assertEq(address(swapSucker.POOL_MANAGER()), address(0), "No V4 pool manager");
        assertEq(address(swapSucker.CCIP_ROUTER()), CCIPHelper.routerOfChain(_l1ChainId()), "CCIP router mismatch");
        assertEq(swapSucker.REMOTE_CHAIN_ID(), _remoteChainId(), "Remote chain ID mismatch");
        assertEq(
            swapSucker.REMOTE_CHAIN_SELECTOR(),
            CCIPHelper.selectorOfChain(_remoteChainId()),
            "Remote chain selector mismatch"
        );
    }

    /// @notice Full send-side flow: pay terminal token → prepare → toRemote.
    ///
    /// The swap sucker:
    ///   1. Cashes out terminal token from the terminal (via prepare)
    ///   2. Swaps terminal token → bridge token (if different) via Uniswap V3
    ///   3. Sends bridge token via CCIP through the real mainnet router
    function test_swapNativeTransfer() external {
        address rootSender = makeAddr("rootSender");
        address user = makeAddr("user");
        uint256 amountToSend = 0.05 ether;
        uint256 maxCashedOut = amountToSend / 2;
        address token = _terminalToken();

        vm.selectFork(l1Fork);

        // Fund user with terminal token.
        if (token == JBConstants.NATIVE_TOKEN) {
            vm.deal(user, amountToSend);
        } else {
            deal(token, user, amountToSend);
        }

        // Map terminal token with 600k minGas (required for swap sucker's ccipReceive gas budget).
        JBTokenMapping memory map = JBTokenMapping({
            localToken: token, minGas: 600_000, remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        vm.prank(multisig());
        suckerL1.mapToken(map);

        // Pay into terminal → receive project tokens.
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
        suckerL1.prepare(projectTokenAmount, bytes32(uint256(uint160(user))), maxCashedOut, token);
        vm.stopPrank();

        // Record logs to capture CCIP router events.
        vm.recordLogs();

        if (_ccipFeesInNative()) {
            // Native ETH fee path: send ETH for CCIP fees via msg.value.
            uint256 ccipFeeAmount = 1 ether;
            vm.deal(rootSender, ccipFeeAmount);
            vm.prank(rootSender);
            suckerL1.toRemote{value: ccipFeeAmount}(token);

            // Verify CCIP fees paid (some native consumed, but not all).
            assertLt(rootSender.balance, ccipFeeAmount, "CCIP fees should have been deducted");
            assertGt(rootSender.balance, 0, "Excess native should be returned");
        } else {
            // LINK fee path: caller provides LINK inline — approve + transferFrom.
            address linkToken = CCIPHelper.linkOfChain(block.chainid);
            uint256 linkForFees = 100 ether;
            deal(linkToken, rootSender, linkForFees);
            uint256 senderLinkBefore = IERC20(linkToken).balanceOf(rootSender);
            vm.prank(rootSender);
            IERC20(linkToken).approve({spender: address(suckerL1), value: linkForFees});
            vm.prank(rootSender);
            suckerL1.toRemote(token);

            // Verify LINK was consumed from the caller for CCIP fees.
            assertLt(
                IERC20(linkToken).balanceOf(rootSender),
                senderLinkBefore,
                "LINK should have been consumed from caller for CCIP fees"
            );
        }

        // Verify outbox cleared.
        assertEq(suckerL1.outboxOf(token).balance, 0, "Outbox should be cleared");

        // Verify CCIP router or sucker emitted events (router delegates to OnRamp, so check both).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address expectedRouter = CCIPHelper.routerOfChain(_l1ChainId());
        bool foundCCIPEvent;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == expectedRouter || logs[i].emitter == address(suckerL1)) {
                foundCCIPEvent = true;
                break;
            }
        }
        assertTrue(foundCCIPEvent, "CCIP router/sucker should have emitted events");

        // Verify sucker has no leftover bridge token (all sent via CCIP).
        // When CCIP fees are paid in LINK and LINK is the bridge token, the sucker retains
        // leftover LINK from the fee pre-funding — so we only assert zero for the native fee path.
        if (_ccipFeesInNative() || _bridgeToken() != CCIPHelper.linkOfChain(block.chainid)) {
            assertEq(IERC20(_bridgeToken()).balanceOf(address(suckerL1)), 0, "No bridge token should remain in sucker");
        }
    }

    /// @notice Simulate receiving a CCIP message from the remote chain carrying bridge token.
    ///
    /// The swap sucker:
    ///   1. Receives bridge token via ccipReceive (simulated OffRamp delivery)
    ///   2. Swaps bridge token → terminal token via Uniswap V3 (if different)
    ///   3. Stores conversion rate (leafTotal: bridge amount, localTotal: terminal token received)
    ///   4. Records inbox merkle root for future claims
    ///
    /// When terminal token == bridge token (e.g. Tempo with LINK), no swap occurs — the bridge
    /// token IS the terminal token, so it is stored directly.
    function test_swapReceiveFromRemote() external {
        // Use a reasonable amount for the bridge token (varies by decimals).
        uint256 bridgeAmount = 1000 * 10 ** _bridgeTokenDecimals();
        address token = _terminalToken();
        bool swapExpected = token != _bridgeToken();

        vm.selectFork(l1Fork);

        // Map terminal token so the sucker recognizes it.
        JBTokenMapping memory map = JBTokenMapping({
            localToken: token, minGas: 600_000, remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });
        vm.prank(multisig());
        suckerL1.mapToken(map);

        // Fund sucker with bridge token (simulates CCIP OffRamp token delivery before ccipReceive).
        deal(_bridgeToken(), address(suckerL1), bridgeAmount);

        // Build CCIP message: root targets terminal token, bridge token delivered.
        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(token))),
            amount: bridgeAmount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xdead))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 18,
            sourceSurplus: 0,
            sourceBalance: 0,
            sourceTimestamp: 1
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

        // Prank as the real CCIP router.
        vm.prank(CCIPHelper.routerOfChain(_l1ChainId()));
        JBSwapCCIPSucker(payable(address(suckerL1))).ccipReceive(ccipMsg);

        if (swapExpected) {
            // Verify: swap happened — sucker now holds terminal token from bridge token swap.
            uint256 ethReceived = address(suckerL1).balance;
            assertGt(ethReceived, 0, "Sucker should hold ETH from bridge->ETH swap");
            assertGt(ethReceived, 0.001 ether, "ETH amount should be reasonable");
            // Verify: bridge token fully consumed by the swap.
            assertEq(IERC20(_bridgeToken()).balanceOf(address(suckerL1)), 0, "All bridge token should be swapped");
        } else {
            // No swap: bridge token == terminal token. Sucker holds bridge token as terminal balance.
            assertEq(
                IERC20(_bridgeToken()).balanceOf(address(suckerL1)),
                bridgeAmount,
                "Bridge token should remain (no swap when terminal == bridge)"
            );
        }

        // Verify: inbox root was set for future claims.
        assertNotEq(suckerL1.inboxOf(token).root, bytes32(0), "Inbox root should be set after ccipReceive");
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

/// @notice Tempo mainnet → Ethereum mainnet (chain ID 1).
/// On Tempo, the project accepts LINK directly (= bridge token, no swap needed).
/// V3_FACTORY = address(0) is safe because no swap is ever attempted.
/// CCIP fees are paid in Tempo's native USD token.
contract TempoEthSwapForkTest is SwapCCIPSuckerForkTestBase {
    function _l1RpcUrl() internal pure override returns (string memory) {
        return "tempo";
    }

    function _l1ChainId() internal pure override returns (uint256) {
        return 4217;
    }

    function _l1ForkBlock() internal pure override returns (uint256) {
        return SWAP_TEMPO_FORK_BLOCK;
    }

    function _remoteChainId() internal pure override returns (uint256) {
        return 1;
    }

    function _bridgeToken() internal pure override returns (address) {
        // LINK on Tempo.
        return 0x15C03488B29e27d62BAf10E30b0c474bf60E0264;
    }

    function _bridgeTokenDecimals() internal pure override returns (uint8) {
        return 18;
    }

    function _weth() internal pure override returns (address) {
        return CCIPHelper.TEMPO_WETH;
    }

    function _v3Factory() internal pure override returns (address) {
        return address(0); // No Uniswap on Tempo.
    }

    function _terminalToken() internal pure override returns (address) {
        // LINK on Tempo = bridge token (no swap needed).
        return 0x15C03488B29e27d62BAf10E30b0c474bf60E0264;
    }

    function _ccipFeesInNative() internal pure override returns (bool) {
        // Tempo has no native token (CALLVALUE=0), CCIP fees paid in LINK.
        return false;
    }
}
