// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IJBSucker} from "../src/interfaces/IJBSucker.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

import {JBLayer} from "../src/enums/JBLayer.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {JBTokenMapping} from "../src/structs/JBTokenMapping.sol";
import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
import {JBArbitrumSuckerDeployer} from "src/deployers/JBArbitrumSuckerDeployer.sol";
import {JBArbitrumSucker} from "../src/JBArbitrumSucker.sol";
import {IArbGatewayRouter} from "../src/interfaces/IArbGatewayRouter.sol";
import {ARBAddresses} from "../src/libraries/ARBAddresses.sol";

/// @notice Fork tests for the Arbitrum-native bridge sucker deployer.
/// @dev Verifies that:
///   - L1 (Ethereum) deployer configures with both inbox and gateway router
///   - L2 (Arbitrum) deployer configures with only gateway router (inbox = address(0))
///   - Both deployers produce suckers with correct immutables from real on-chain contracts
contract ForkArbitrumDeployerTest is TestBaseWorkflow, IERC721Receiver {
    JBRulesetMetadata _metadata;

    // L1 state (created during setUp on ethereum fork).
    JBArbitrumSuckerDeployer deployerL1;
    IJBSucker suckerL1;

    // L2 state (created during setUp on arbitrum fork).
    JBArbitrumSuckerDeployer deployerL2;
    IJBSucker suckerL2;

    uint256 l1Fork;
    uint256 l2Fork;

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

        // ── L1 (Ethereum mainnet)
        l1Fork = vm.createSelectFork("ethereum");
        vm.rollFork(block.number - 5);
        super.setUp();
        vm.stopPrank();

        deployerL1 = new JBArbitrumSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });

        deployerL1.setChainSpecificConstants(
            JBLayer.L1, IInbox(ARBAddresses.L1_ETH_INBOX), IArbGatewayRouter(ARBAddresses.L1_GATEWAY_ROUTER)
        );

        JBArbitrumSucker singletonL1 = new JBArbitrumSucker({
            deployer: deployerL1,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });

        deployerL1.configureSingleton(singletonL1);
        _launchProject();
        suckerL1 = deployerL1.createForSender(1, "arb-l1");

        // ── L2 (Arbitrum mainnet)
        l2Fork = vm.createSelectFork("arbitrum");
        vm.rollFork(block.number - 5);
        super.setUp();
        vm.stopPrank();

        deployerL2 = new JBArbitrumSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });

        // L2: inbox is legitimately address(0).
        deployerL2.setChainSpecificConstants(
            JBLayer.L2, IInbox(address(0)), IArbGatewayRouter(ARBAddresses.L2_GATEWAY_ROUTER)
        );

        JBArbitrumSucker singletonL2 = new JBArbitrumSucker({
            deployer: deployerL2,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });

        deployerL2.configureSingleton(singletonL2);
        _launchProject();
        suckerL2 = deployerL2.createForSender(1, "arb-l2");

        // Mock the registry's toRemoteFee() on both forks (registry is address(0) in tests).
        vm.selectFork(l1Fork);
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
        vm.selectFork(l2Fork);
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
    }

    /// @notice L1 deployer and sucker have correct configuration with real Arbitrum inbox and gateway router.
    function test_l1DeployerAndSucker() external {
        vm.selectFork(l1Fork);

        // Deployer state.
        assertEq(uint256(deployerL1.arbLayer()), uint256(JBLayer.L1));
        assertEq(address(deployerL1.arbInbox()), ARBAddresses.L1_ETH_INBOX);
        assertEq(address(deployerL1.arbGatewayRouter()), ARBAddresses.L1_GATEWAY_ROUTER);

        // Sucker immutables match deployer.
        assertEq(suckerL1.projectId(), 1);
        assertEq(uint256(JBArbitrumSucker(payable(address(suckerL1))).LAYER()), uint256(JBLayer.L1));
        assertEq(address(JBArbitrumSucker(payable(address(suckerL1))).ARBINBOX()), ARBAddresses.L1_ETH_INBOX);
        assertEq(address(JBArbitrumSucker(payable(address(suckerL1))).GATEWAYROUTER()), ARBAddresses.L1_GATEWAY_ROUTER);
    }

    /// @notice L2 deployer and sucker have correct configuration — inbox is address(0).
    function test_l2DeployerAndSucker() external {
        vm.selectFork(l2Fork);

        // Deployer state.
        assertEq(uint256(deployerL2.arbLayer()), uint256(JBLayer.L2));
        assertEq(address(deployerL2.arbInbox()), address(0));
        assertEq(address(deployerL2.arbGatewayRouter()), ARBAddresses.L2_GATEWAY_ROUTER);

        // Sucker immutables match deployer.
        assertEq(suckerL2.projectId(), 1);
        assertEq(uint256(JBArbitrumSucker(payable(address(suckerL2))).LAYER()), uint256(JBLayer.L2));
        assertEq(address(JBArbitrumSucker(payable(address(suckerL2))).ARBINBOX()), address(0));
        assertEq(address(JBArbitrumSucker(payable(address(suckerL2))).GATEWAYROUTER()), ARBAddresses.L2_GATEWAY_ROUTER);
    }

    /// @notice Launch a minimal project for sucker creation.
    function _launchProject() internal {
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: new JBCurrencyAmount[](0),
            surplusAllowances: new JBCurrencyAmount[](0)
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
            owner: address(this),
            projectUri: "arb-fork-test",
            rulesetConfigurations: _rulesetConfigurations,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice Fork test for Arbitrum native ETH transfer via the Arbitrum native bridge (L1 → L2).
///
/// Tests the full send-side flow against real mainnet Arbitrum inbox:
///   - Pay into L1 terminal, receive project tokens
///   - Prepare cash out via sucker (builds merkle tree)
///   - toRemote{value: transportPayment}() creates a retryable ticket through the real inbox
///   - Outbox is cleared, inbox accepts the message
///
/// Arbitrum L1 → L2 requires `msg.value` for retryable ticket gas (unlike OP Stack).
contract ForkArbitrumNativeTransferTest is TestBaseWorkflow {
    JBRulesetMetadata _metadata;

    JBArbitrumSuckerDeployer deployerL1;
    IJBSucker suckerL1;
    IJBToken projectToken;

    uint256 l1Fork;

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

        // ── L1 (Ethereum mainnet)
        l1Fork = vm.createSelectFork("ethereum");
        vm.rollFork(block.number - 5);
        super.setUp();
        vm.stopPrank();

        vm.startPrank(address(0x1112222));
        deployerL1 = new JBArbitrumSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        deployerL1.setChainSpecificConstants(
            JBLayer.L1, IInbox(ARBAddresses.L1_ETH_INBOX), IArbGatewayRouter(ARBAddresses.L1_GATEWAY_ROUTER)
        );

        vm.startPrank(address(0x1112222));
        JBArbitrumSucker singletonL1 = new JBArbitrumSucker({
            deployer: deployerL1,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        deployerL1.configureSingleton(singletonL1);
        suckerL1 = deployerL1.createForSender(1, "arb-native");
        vm.label(address(suckerL1), "suckerL1");

        // Grant sucker mint permission.
        uint8[] memory ids = new uint8[](1);
        ids[0] = JBPermissionIds.MINT_TOKENS;
        JBPermissionsData memory permsL1 =
            JBPermissionsData({operator: address(suckerL1), projectId: 1, permissionIds: ids});

        vm.startPrank(multisig());
        jbPermissions().setPermissionsFor(multisig(), permsL1);
        _launchProject();
        projectToken = jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));
        vm.stopPrank();

        // Mock the registry's toRemoteFee() (registry is address(0) in tests).
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
    }

    /// @notice Launch a project that accepts native ETH with surplus allowance.
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
            projectUri: "arb-native-fork-test",
            rulesetConfigurations: _rulesetConfigurations,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });
    }

    /// @notice Test native ETH transfer from L1 → Arbitrum L2 via the real Arbitrum inbox.
    ///
    /// Arbitrum L1 → L2 uses retryable tickets which require `msg.value` for gas:
    ///   - `maxSubmissionCost` + `MESSENGER_BASE_GAS_LIMIT * maxFeePerGas` for the message
    ///   - The actual bridged ETH amount is sent as `nativeValue` in the retryable ticket
    function test_l1NativeTransfer() external {
        address user = makeAddr("user");
        uint256 amountToSend = 0.05 ether;
        uint256 maxCashedOut = amountToSend / 2;

        vm.selectFork(l1Fork);
        vm.deal(user, amountToSend + 1 ether); // Extra ETH for transport payment.

        // Map native token.
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
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

        // Record logs to verify inbox interaction.
        vm.recordLogs();

        // Send to L2 with transport payment for retryable ticket gas.
        suckerL1.toRemote{value: 1 ether}(JBConstants.NATIVE_TOKEN);
        vm.stopPrank();

        // Verify outbox cleared on L1.
        assertEq(suckerL1.outboxOf(JBConstants.NATIVE_TOKEN).balance, 0, "Outbox should be cleared");

        // Verify the Arbitrum inbox accepted our retryable ticket.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundInboxEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == ARBAddresses.L1_ETH_INBOX) {
                foundInboxEvent = true;
                break;
            }
        }
        assertTrue(foundInboxEvent, "Arbitrum inbox should have emitted events");
    }
}
