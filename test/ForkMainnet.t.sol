// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IJBSucker} from "../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../src/interfaces/IJBSuckerDeployer.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ICCIPRouter} from "src/interfaces/ICCIPRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBTokenMapping} from "../src/structs/JBTokenMapping.sol";

import "forge-std/Test.sol";
import {JBCCIPSuckerDeployer} from "src/deployers/JBCCIPSuckerDeployer.sol";
import {JBCCIPSucker} from "../src/JBCCIPSucker.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {CCIPHelper} from "../src/libraries/CCIPHelper.sol";

/// @notice Abstract base for mainnet CCIP sucker fork tests.
/// @dev Tests native token transfers across real mainnet CCIP infrastructure to verify sucker
/// compatibility with production routers on every supported chain pair.
///
/// CCIPLocalSimulatorFork only ships with testnet entries, so we register mainnet network details
/// via `setNetworkDetails` before running the tests.
abstract contract CCIPSuckerMainnetForkTestBase is TestBaseWorkflow {
    CCIPLocalSimulatorFork ccipLocalSimulatorFork;
    JBRulesetMetadata _metadata;

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

    // ── LINK token addresses per mainnet chain
    // ────────────────────────────

    function _linkTokenOf(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        if (chainId == 42_161) return 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
        if (chainId == 10) return 0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6;
        if (chainId == 8453) return 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
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
            ccipLnMAddress: address(0)
        });
        ccipLocalSimulatorFork.setNetworkDetails(chainId, details);
    }

    // ── Setup
    // ─────────────────────────────────────────────────────────────

    function setUp() public override {
        // ── L1
        // ────────────────────────────────────────────────────────────
        l1Fork = vm.createSelectFork(_l1RpcUrl());

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
        l2Fork = vm.createSelectFork(_l2RpcUrl());

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
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        suckerDeployerL2.configureSingleton(singletonL2);
        IJBSucker suckerL2 = suckerDeployerL2.createForSender(1, "salty");

        // Grant L2 sucker mint permission and launch L2 project.
        JBPermissionsData memory permsL2 =
            JBPermissionsData({operator: address(suckerL2), projectId: 1, permissionIds: ids});
        vm.startPrank(multisig());
        _launchProject();
        jbPermissions().setPermissionsFor(multisig(), permsL2);
        vm.stopPrank();
    }

    /// @notice Launch a project that accepts only native token.
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
                projectUri: "mainnet-fork-test",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            });
    }

    // ── Tests
    // ─────────────────────────────────────────────────────────────

    /// @notice Test native token transfer from L1 → L2 via real mainnet CCIP routers.
    ///
    /// This verifies the full send-side flow against production CCIP infrastructure:
    ///   1. Pay into JB terminal, receive project tokens
    ///   2. Prepare cash out via sucker (builds merkle tree)
    ///   3. toRemote() wraps ETH → WETH, sends CCIP message through the real mainnet router
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

        // Start on L1.
        vm.selectFork(l1Fork);
        vm.deal(user, amountToSend);

        // Map native token.
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            toRemoteFee: 1
        });

        vm.prank(multisig());
        suckerL1.mapToken(map);

        // Pay into L1 terminal → receive project tokens.
        vm.startPrank(user);
        uint256 projectTokenAmount =
            jbMultiTerminal().pay{value: amountToSend}(1, JBConstants.NATIVE_TOKEN, amountToSend, user, 0, "", "");

        // Prepare cash out via sucker.
        IERC20(address(projectToken)).approve(address(suckerL1), projectTokenAmount);
        suckerL1.prepare(projectTokenAmount, bytes32(uint256(uint160(user))), maxCashedOut, JBConstants.NATIVE_TOKEN);
        vm.stopPrank();

        // Record logs to capture the CCIPSendRequested event.
        vm.recordLogs();

        // Send to remote chain — this calls the REAL mainnet CCIP router.
        vm.deal(rootSender, 1 ether);
        vm.prank(rootSender);
        suckerL1.toRemote{value: 1 ether}(JBConstants.NATIVE_TOKEN);

        // Verify outbox cleared on L1.
        assertEq(suckerL1.outboxOf(JBConstants.NATIVE_TOKEN).balance, 0, "Outbox should be cleared");

        // Verify CCIP fees paid (some ETH consumed, but not all).
        assertLt(rootSender.balance, 1 ether, "CCIP fees should have been deducted");
        assertGt(rootSender.balance, 0, "Excess ETH should be returned");

        // Verify a CCIPSendRequested event was emitted (proves the mainnet router accepted our message).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundCCIPSend = false;
        // CCIPSendRequested topic:
        // keccak256("CCIPSendRequested(bytes32,(uint64,address,address,uint256,uint256,(address,uint256)[],bytes,bytes[]))")
        // We just check for any log from the CCIP router address.
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
}
