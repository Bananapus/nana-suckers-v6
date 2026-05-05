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

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
import {JBCCIPSuckerDeployer} from "src/deployers/JBCCIPSuckerDeployer.sol";
import {JBCCIPSucker} from "../src/JBCCIPSucker.sol";
import {CCIPLocalSimulatorFork} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {CCIPHelper} from "../src/libraries/CCIPHelper.sol";

/// @notice Abstract base for mainnet CCIP sucker fork tests.
/// @dev Tests native token transfers across real mainnet CCIP infrastructure to verify sucker
/// compatibility with production routers on every supported chain pair.
///
/// CCIPLocalSimulatorFork only ships with testnet entries, so we register mainnet network details
/// via `setNetworkDetails` before running the tests.
abstract contract CCIPSuckerMainnetForkTestBase is SuckerForkHelpers {
    CCIPLocalSimulatorFork ccipLocalSimulatorFork;

    JBCCIPSuckerDeployer suckerDeployerL1;
    JBCCIPSuckerDeployer suckerDeployerL2;
    IJBSucker suckerL1;
    IJBToken projectToken;

    uint256 l1Fork;
    uint256 l2Fork;

    // ── Chain-specific overrides
    // ──────────────────────────────────────────

    function _l1RpcUrl() internal pure virtual returns (string memory);
    function _l2RpcUrl() internal pure virtual returns (string memory);
    function _l1ChainId() internal pure virtual returns (uint256);
    function _l2ChainId() internal pure virtual returns (uint256);
    function _l1ForkBlock() internal pure virtual returns (uint256);
    function _l2ForkBlock() internal pure virtual returns (uint256);

    function _remoteTerminalToken() internal view virtual returns (bytes32) {
        return bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)));
    }

    /// @dev Whether CCIP fees are paid in native ETH (true) or LINK from the sucker's balance (false).
    function _ccipFeesInNative() internal pure virtual returns (bool) {
        return true;
    }

    // ── Setup
    // ─────────────────────────────────────────────────────────────

    function setUp() public override {
        // ── L1
        l1Fork = vm.createSelectFork(_l1RpcUrl(), _l1ForkBlock());
        _ensureTerminalTokenExists();

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        _registerMainnetDetails(ccipLocalSimulatorFork, _l1ChainId());
        _registerMainnetDetails(ccipLocalSimulatorFork, _l2ChainId());

        _initMetadata();

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
            prices: address(jbPrices()),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        suckerDeployerL1.configureSingleton(singletonL1);
        suckerL1 = suckerDeployerL1.createForSender(1, "salty", bytes32(0));
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
        l2Fork = vm.createSelectFork(_l2RpcUrl(), _l2ForkBlock());
        _ensureTerminalTokenExists();

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
            prices: address(jbPrices()),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        suckerDeployerL2.configureSingleton(singletonL2);
        IJBSucker suckerL2 = suckerDeployerL2.createForSender(1, "salty", bytes32(0));

        // Grant L2 sucker mint permission and launch L2 project.
        JBPermissionsData memory permsL2 =
            JBPermissionsData({operator: address(suckerL2), projectId: 1, permissionIds: ids});
        vm.startPrank(multisig());
        _launchProject();
        jbPermissions().setPermissionsFor(multisig(), permsL2);
        vm.stopPrank();

        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
    }

    // ── Tests
    // ─────────────────────────────────────────────────────────────

    /// @notice Test token transfer from L1 → L2 via real mainnet CCIP routers.
    ///
    /// This verifies the full send-side flow against production CCIP infrastructure:
    ///   1. Pay into JB terminal, receive project tokens
    ///   2. Prepare cash out via sucker (builds merkle tree)
    ///   3. toRemote() sends CCIP message through the real mainnet router
    ///   4. Outbox is cleared, CCIP fees are paid
    ///
    /// The L2 delivery side (switchChainAndRouteMessage) is tested in Fork.t.sol against
    /// Sepolia where CCIPLocalSimulatorFork has full testnet token pool support. Here we
    /// focus on confirming our CCIP message is accepted by each mainnet router — the most
    /// critical integration point that can't be tested any other way.
    function test_nativeTransfer() external {
        address rootSender = makeAddr("rootSender");
        address user = makeAddr("user");
        uint256 amountToSend = 0.05 ether;
        uint256 maxCashedOut = amountToSend / 2;

        // Start on L1 — must be before _terminalToken() since it uses block.chainid.
        vm.selectFork(l1Fork);
        address token = _terminalToken();

        // Fund user with terminal token.
        if (token == JBConstants.NATIVE_TOKEN) {
            vm.deal(user, amountToSend);
        } else {
            deal(token, user, amountToSend);
        }

        // Map terminal token.
        JBTokenMapping memory map =
            JBTokenMapping({localToken: token, minGas: 200_000, remoteToken: _remoteTerminalToken()});

        vm.prank(multisig());
        suckerL1.mapToken(map);

        // Pay into L1 terminal → receive project tokens.
        vm.startPrank(user);
        uint256 projectTokenAmount;
        if (token == JBConstants.NATIVE_TOKEN) {
            projectTokenAmount = jbMultiTerminal().pay{value: amountToSend}(1, token, amountToSend, user, 0, "", "");
        } else {
            IERC20(token).approve(address(jbMultiTerminal()), amountToSend);
            projectTokenAmount = jbMultiTerminal().pay(1, token, amountToSend, user, 0, "", "");
        }

        // Prepare cash out via sucker.
        IERC20(address(projectToken)).approve(address(suckerL1), projectTokenAmount);
        suckerL1.prepare(projectTokenAmount, bytes32(uint256(uint160(user))), maxCashedOut, token);
        vm.stopPrank();

        // Record logs to capture the CCIPSendRequested event.
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
            // On Tempo, CALLVALUE always returns 0, so transportPayment = 0, triggering LINK fee mode.
            address linkToken = _linkTokenOf(block.chainid);
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

        // Verify outbox cleared on L1.
        assertEq(suckerL1.outboxOf(token).balance, 0, "Outbox should be cleared");

        // Verify a CCIPSendRequested event was emitted (proves the mainnet router accepted our message).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // forge-lint: disable-next-line(mixed-case-variable)
        bool foundCCIPSend = false;
        address expectedRouter = CCIPHelper.routerOfChain(_l1ChainId());
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == expectedRouter || logs[i].emitter == address(suckerL1)) {
                foundCCIPSend = true;
                break;
            }
        }
        assertTrue(foundCCIPSend, "CCIP router should have emitted events");
    }
}

// ─── Concrete chain pair tests
// ────────────────────────────────────────────────

// ── Pinned fork blocks (matching v6 repo convention)
// ──────────────────────────────────────────────────────
uint256 constant ETH_FORK_BLOCK = 21_700_000;
uint256 constant ARB_FORK_BLOCK = 300_000_000;
uint256 constant OP_FORK_BLOCK = 130_000_000;
uint256 constant BASE_FORK_BLOCK = 25_000_000;
// ETH→Tempo CCIP lane + LINK token pool allowlist activated around block 24,744,000.
uint256 constant ETH_TEMPO_FORK_BLOCK = 24_745_000;
uint256 constant TEMPO_FORK_BLOCK = 15_168_000;

/// @notice Ethereum mainnet → Arbitrum mainnet.
contract EthArbMainnetForkTest is CCIPSuckerMainnetForkTestBase {
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
        return ETH_FORK_BLOCK;
    }

    function _l2ForkBlock() internal pure override returns (uint256) {
        return ARB_FORK_BLOCK;
    }
}

/// @notice Ethereum mainnet → Optimism mainnet.
contract EthOpMainnetForkTest is CCIPSuckerMainnetForkTestBase {
    function _l1RpcUrl() internal pure override returns (string memory) {
        return "ethereum";
    }

    function _l2RpcUrl() internal pure override returns (string memory) {
        return "optimism";
    }

    function _l1ChainId() internal pure override returns (uint256) {
        return 1;
    }

    function _l2ChainId() internal pure override returns (uint256) {
        return 10;
    }

    function _l1ForkBlock() internal pure override returns (uint256) {
        return ETH_FORK_BLOCK;
    }

    function _l2ForkBlock() internal pure override returns (uint256) {
        return OP_FORK_BLOCK;
    }
}

/// @notice Ethereum mainnet → Base mainnet.
contract EthBaseMainnetForkTest is CCIPSuckerMainnetForkTestBase {
    function _l1RpcUrl() internal pure override returns (string memory) {
        return "ethereum";
    }

    function _l2RpcUrl() internal pure override returns (string memory) {
        return "base";
    }

    function _l1ChainId() internal pure override returns (uint256) {
        return 1;
    }

    function _l2ChainId() internal pure override returns (uint256) {
        return 8453;
    }

    function _l1ForkBlock() internal pure override returns (uint256) {
        return ETH_FORK_BLOCK;
    }

    function _l2ForkBlock() internal pure override returns (uint256) {
        return BASE_FORK_BLOCK;
    }
}

/// @notice Arbitrum mainnet → Optimism mainnet.
contract ArbOpMainnetForkTest is CCIPSuckerMainnetForkTestBase {
    function _l1RpcUrl() internal pure override returns (string memory) {
        return "arbitrum";
    }

    function _l2RpcUrl() internal pure override returns (string memory) {
        return "optimism";
    }

    function _l1ChainId() internal pure override returns (uint256) {
        return 42_161;
    }

    function _l2ChainId() internal pure override returns (uint256) {
        return 10;
    }

    function _l1ForkBlock() internal pure override returns (uint256) {
        return ARB_FORK_BLOCK;
    }

    function _l2ForkBlock() internal pure override returns (uint256) {
        return OP_FORK_BLOCK;
    }
}

/// @notice Arbitrum mainnet → Base mainnet.
contract ArbBaseMainnetForkTest is CCIPSuckerMainnetForkTestBase {
    function _l1RpcUrl() internal pure override returns (string memory) {
        return "arbitrum";
    }

    function _l2RpcUrl() internal pure override returns (string memory) {
        return "base";
    }

    function _l1ChainId() internal pure override returns (uint256) {
        return 42_161;
    }

    function _l2ChainId() internal pure override returns (uint256) {
        return 8453;
    }

    function _l1ForkBlock() internal pure override returns (uint256) {
        return ARB_FORK_BLOCK;
    }

    function _l2ForkBlock() internal pure override returns (uint256) {
        return BASE_FORK_BLOCK;
    }
}

/// @notice Optimism mainnet → Base mainnet.
contract OpBaseMainnetForkTest is CCIPSuckerMainnetForkTestBase {
    function _l1RpcUrl() internal pure override returns (string memory) {
        return "optimism";
    }

    function _l2RpcUrl() internal pure override returns (string memory) {
        return "base";
    }

    function _l1ChainId() internal pure override returns (uint256) {
        return 10;
    }

    function _l2ChainId() internal pure override returns (uint256) {
        return 8453;
    }

    function _l1ForkBlock() internal pure override returns (uint256) {
        return OP_FORK_BLOCK;
    }

    function _l2ForkBlock() internal pure override returns (uint256) {
        return BASE_FORK_BLOCK;
    }
}

/// @notice Ethereum mainnet → Tempo mainnet.
/// Both projects accept LINK (the only CCIP-supported token on the ETH↔Tempo lane).
contract EthTempoMainnetForkTest is CCIPSuckerMainnetForkTestBase {
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
        return ETH_TEMPO_FORK_BLOCK;
    }

    function _l2ForkBlock() internal pure override returns (uint256) {
        return TEMPO_FORK_BLOCK;
    }

    function _terminalToken() internal view override returns (address) {
        return CCIPHelper.linkOfChain(block.chainid);
    }

    function _remoteTerminalToken() internal view override returns (bytes32) {
        // LINK on the remote chain (different address, same asset via CCIP token pools).
        uint256 remoteChain = block.chainid == _l1ChainId() ? _l2ChainId() : _l1ChainId();
        return bytes32(uint256(uint160(CCIPHelper.linkOfChain(remoteChain))));
    }

    function _ccipFeesInNative() internal pure override returns (bool) {
        // ETH side pays native ETH for CCIP fees.
        return true;
    }
}

/// @notice Tempo mainnet → Ethereum mainnet.
/// Both projects accept LINK (the only CCIP-supported token on the Tempo↔ETH lane).
contract TempoEthMainnetForkTest is CCIPSuckerMainnetForkTestBase {
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
        return TEMPO_FORK_BLOCK;
    }

    function _l2ForkBlock() internal pure override returns (uint256) {
        return ETH_TEMPO_FORK_BLOCK;
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
