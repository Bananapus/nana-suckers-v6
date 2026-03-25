// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IJBSucker} from "../src/interfaces/IJBSucker.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBTokenMapping} from "../src/structs/JBTokenMapping.sol";

import {IOPMessenger} from "../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../src/interfaces/IOPStandardBridge.sol";
import {IWrappedNativeToken} from "../src/interfaces/IWrappedNativeToken.sol";

import "forge-std/Test.sol";
import {JBCeloSuckerDeployer} from "src/deployers/JBCeloSuckerDeployer.sol";
import {JBCeloSucker} from "../src/JBCeloSucker.sol";
import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";

/// @notice Fork test for `JBCeloSucker` — OP Stack sucker for Celo (custom gas token chain).
///
/// Celo uses CELO as its native gas token, not ETH. ETH exists on Celo only as an ERC-20 (WETH).
/// This test verifies that:
///   - Native ETH on L1 is wrapped to WETH and bridged as ERC-20 via the OP bridge (not as msg.value).
///   - WETH on Celo is bridged as ERC-20 back to L1.
///
/// Two directions are tested:
///   - test_nativeToWeth: Send native ETH from Ethereum → Celo (maps NATIVE_TOKEN → Celo WETH).
///   - test_wethToNative: Send WETH ERC-20 from Celo → Ethereum (maps Celo WETH → NATIVE_TOKEN).
contract ForkCeloTest is TestBaseWorkflow {
    JBRulesetMetadata _metadata;

    // ── L1 (Ethereum) side
    JBCeloSuckerDeployer suckerDeployerL1;
    IJBSucker suckerL1;
    IJBToken projectToken;

    // ── L2 (Celo) side
    JBCeloSuckerDeployer suckerDeployerL2;
    IJBSucker suckerL2;

    uint256 l1Fork;
    uint256 l2Fork;

    /// @notice WETH on Celo (Celo native bridge). ETH's ERC-20 representation on Celo.
    address constant CELO_WETH = 0xD221812de1BD094f35587EE8E174B07B6167D9Af;

    // ── Real bridge addresses
    // L1 (Ethereum mainnet) — Celo's OP Stack bridge contracts on L1
    IOPMessenger constant L1_MESSENGER = IOPMessenger(0x1AC1181fc4e4F877963680587AEAa2C90D7EbB95);
    IOPStandardBridge constant L1_BRIDGE = IOPStandardBridge(0x9C4955b92F34148dbcfDCD82e9c9eCe5CF2badfe);
    IWrappedNativeToken constant L1_WETH = IWrappedNativeToken(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // L2 (Celo mainnet) — OP predeploys
    IOPMessenger constant L2_MESSENGER = IOPMessenger(0x4200000000000000000000000000000000000007);
    IOPStandardBridge constant L2_BRIDGE = IOPStandardBridge(0x4200000000000000000000000000000000000010);

    // ── Setup
    // ─────────────────────────────────────────────────────────

    function setUp() public override {
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

        // ── L1 (Ethereum)
        // ────────────────────────────────────────────────────────────
        l1Fork = vm.createSelectFork("ethereum");

        // Deploy full JB infrastructure on L1.
        super.setUp();
        vm.stopPrank();

        // Deploy Celo sucker deployer on L1 (points to Celo as remote).
        vm.startPrank(address(0x1112222));
        suckerDeployerL1 =
            new JBCeloSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        vm.stopPrank();

        suckerDeployerL1.setChainSpecificConstants(L1_MESSENGER, L1_BRIDGE, L1_WETH);

        vm.startPrank(address(0x1112222));
        JBCeloSucker singletonL1 = new JBCeloSucker({
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
        _launchNativeProject();
        projectToken = jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));
        vm.stopPrank();

        // ── L2 (Celo)
        // ────────────────────────────────────────────────────────────
        l2Fork = vm.createSelectFork("celo");

        // Deploy full JB infrastructure on Celo.
        super.setUp();
        vm.stopPrank();

        vm.startPrank(address(0x1112222));
        suckerDeployerL2 =
            new JBCeloSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        vm.stopPrank();

        suckerDeployerL2.setChainSpecificConstants(L2_MESSENGER, L2_BRIDGE, IWrappedNativeToken(CELO_WETH));

        vm.startPrank(address(0x1112222));
        JBCeloSucker singletonL2 = new JBCeloSucker({
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
        suckerL2 = suckerDeployerL2.createForSender(1, "salty");
        vm.label(address(suckerL2), "suckerL2");

        // Grant L2 sucker mint permission and launch L2 project.
        JBPermissionsData memory permsL2 =
            JBPermissionsData({operator: address(suckerL2), projectId: 1, permissionIds: ids});

        vm.startPrank(multisig());
        jbPermissions().setPermissionsFor(multisig(), permsL2);
        _launchWethProject();
        vm.stopPrank();

        // Mock the registry's toRemoteFee() on both forks (registry is address(0) in tests).
        vm.selectFork(l1Fork);
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
        vm.selectFork(l2Fork);
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
    }

    /// @notice Launch a project on L1 that accepts native ETH.
    function _launchNativeProject() internal {
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
                projectUri: "celo-fork-test-native",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            });
    }

    /// @notice Launch a project on Celo that accepts WETH (ETH as ERC-20).
    function _launchWethProject() internal {
        // Override baseCurrency to match the WETH token so no price feed conversion is needed.
        JBRulesetMetadata memory celoMetadata = _metadata;
        celoMetadata.baseCurrency = uint32(uint160(CELO_WETH));

        JBCurrencyAmount[] memory _surplusAllowances = new JBCurrencyAmount[](1);
        _surplusAllowances[0] = JBCurrencyAmount({amount: 5 * 10 ** 18, currency: uint32(uint160(CELO_WETH))});

        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: CELO_WETH,
            payoutLimits: new JBCurrencyAmount[](0),
            surplusAllowances: _surplusAllowances
        });

        JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
        _rulesetConfigurations[0].mustStartAtOrAfter = 0;
        _rulesetConfigurations[0].duration = 0;
        _rulesetConfigurations[0].weight = 1000 * 10 ** 18;
        _rulesetConfigurations[0].weightCutPercent = 0;
        _rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfigurations[0].metadata = celoMetadata;
        _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);
        _tokensToAccept[0] = JBAccountingContext({token: CELO_WETH, decimals: 18, currency: uint32(uint160(CELO_WETH))});

        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        _terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokensToAccept});

        jbController()
            .launchProjectFor({
                owner: multisig(),
                projectUri: "celo-fork-test-weth",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            });
    }

    // ── Tests
    // ─────────────────────────────────────────────────────────

    /// @notice Test native ETH transfer from Ethereum → Celo via OP bridge.
    ///
    /// On Celo, ETH is an ERC-20 (WETH), so the token mapping uses NATIVE_TOKEN → CELO_WETH.
    /// The sucker wraps native ETH → WETH and bridges it as ERC-20 via OPBRIDGE.bridgeERC20To().
    /// The messenger message is sent with nativeValue = 0 (Celo's native is CELO, not ETH).
    function test_nativeToWeth() external {
        address user = makeAddr("user");
        uint256 amountToSend = 0.05 ether;
        uint256 maxCashedOut = amountToSend / 2;

        // Start on L1.
        vm.selectFork(l1Fork);
        vm.deal(user, amountToSend);

        // Map native ETH → Celo WETH (ERC-20 on remote).
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN, minGas: 200_000, remoteToken: bytes32(uint256(uint160(CELO_WETH)))
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

        // Record logs to verify bridging behavior.
        vm.recordLogs();

        // Send to Celo — should wrap ETH → WETH and bridge as ERC-20.
        vm.prank(user);
        suckerL1.toRemote(JBConstants.NATIVE_TOKEN);

        // Verify outbox cleared on L1.
        assertEq(suckerL1.outboxOf(JBConstants.NATIVE_TOKEN).balance, 0, "Outbox should be cleared");

        // Verify that the OP bridge received the bridgeERC20To call (events from bridge/messenger).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundBridgeEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(L1_BRIDGE) || logs[i].emitter == address(L1_MESSENGER)) {
                foundBridgeEvent = true;
                break;
            }
        }
        assertTrue(foundBridgeEvent, "OP bridge/messenger should have emitted events");
    }

    /// @notice Test WETH (ERC-20) transfer from Celo → Ethereum via OP bridge.
    ///
    /// On Celo, the project accepts WETH as its terminal token. The sucker maps
    /// CELO_WETH (local ERC-20) → L1 WETH (remote ERC-20). The OP bridge validates
    /// that the remote token matches the Optimism Mintable ERC20's configured remote.
    function test_wethToNative() external {
        address user = makeAddr("user");
        uint256 amountToSend = 0.05 ether;
        uint256 maxCashedOut = amountToSend / 2;

        // Start on Celo.
        vm.selectFork(l2Fork);

        // Give user WETH on Celo.
        deal(CELO_WETH, user, amountToSend);

        // Map Celo WETH → L1 WETH. The OP bridge's L2StandardBridge validates that the
        // remoteToken matches the Optimism Mintable ERC20's REMOTE_TOKEN() — must be L1 WETH.
        JBTokenMapping memory map = JBTokenMapping({
            localToken: CELO_WETH, minGas: 200_000, remoteToken: bytes32(uint256(uint160(address(L1_WETH))))
        });

        vm.prank(multisig());
        suckerL2.mapToken(map);

        // Deploy an ERC20 for the Celo project BEFORE paying so tokens mint as ERC20 (not credits).
        vm.prank(multisig());
        IJBToken celoProjectToken = jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));

        // Pay WETH into terminal → receive project tokens (as ERC20).
        vm.startPrank(user);
        IERC20(CELO_WETH).approve(address(jbMultiTerminal()), amountToSend);
        uint256 projectTokenAmount = jbMultiTerminal().pay(1, CELO_WETH, amountToSend, user, 0, "", "");

        // Prepare cash out via sucker.
        IERC20(address(celoProjectToken)).approve(address(suckerL2), projectTokenAmount);
        suckerL2.prepare(projectTokenAmount, bytes32(uint256(uint160(user))), maxCashedOut, CELO_WETH);
        vm.stopPrank();

        // Record logs to verify bridging behavior.
        vm.recordLogs();

        // Send to L1 — bridges WETH as ERC-20 directly.
        vm.prank(user);
        suckerL2.toRemote(CELO_WETH);

        // Verify outbox cleared.
        assertEq(suckerL2.outboxOf(CELO_WETH).balance, 0, "Outbox should be cleared");

        // Verify that the OP bridge received the bridgeERC20To call.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundBridgeEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(L2_BRIDGE) || logs[i].emitter == address(L2_MESSENGER)) {
                foundBridgeEvent = true;
                break;
            }
        }
        assertTrue(foundBridgeEvent, "OP bridge/messenger should have emitted events");
    }
}
