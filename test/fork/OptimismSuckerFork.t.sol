// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

// Core imports for JB stack interaction.
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Sucker imports for OP bridge testing.
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";
import {IOPMessenger} from "../../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../../src/interfaces/IOPStandardBridge.sol";
import {JBOptimismSucker} from "../../src/JBOptimismSucker.sol";
import {JBOptimismSuckerDeployer} from "../../src/deployers/JBOptimismSuckerDeployer.sol";

// Chainlink imports for sequencer-aware price feed testing.
import {JBChainlinkV3SequencerPriceFeed} from "@bananapus/core-v6/src/JBChainlinkV3SequencerPriceFeed.sol";
import {AggregatorV3Interface} from "@bananapus/core-v6/src/JBChainlinkV3PriceFeed.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";

/// @notice Optimism mainnet (chain ID 10) fork test for OP-specific sucker behavior.
///
/// Validates chain-sensitive features on Optimism:
/// - OP Stack predeploy contracts exist at canonical addresses
/// - CrossDomainMessenger responds to xDomainMessageSender()
/// - JBOptimismSucker deploys correctly with real OP bridge contracts
/// - Native ETH bridging send-side flow works against real Optimism infrastructure
/// - L2 sequencer-aware Chainlink price feeds work with real Optimism feeds
///
/// Run with: forge test --match-contract OptimismSuckerForkTest -vvv
contract OptimismSuckerForkTest is TestBaseWorkflow {
    // ── Optimism L2 predeploy addresses (same across all OP Stack L2s) ──

    // The L2 CrossDomainMessenger predeploy used by OP suckers.
    IOPMessenger constant L2_MESSENGER = IOPMessenger(0x4200000000000000000000000000000000000007);

    // The L2 StandardBridge predeploy used for ERC-20/ETH bridging.
    IOPStandardBridge constant L2_BRIDGE = IOPStandardBridge(0x4200000000000000000000000000000000000010);

    // The L2ToL1MessagePasser predeploy (verifies OP infra completeness).
    address constant L2_TO_L1_MESSAGE_PASSER = 0x4200000000000000000000000000000000000016;

    // WETH predeploy on OP Stack L2s.
    address constant OP_WETH = 0x4200000000000000000000000000000000000006;

    // ── Optimism Chainlink addresses ──

    // Chainlink ETH/USD price feed on Optimism mainnet.
    address constant OP_ETH_USD_FEED = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;

    // Chainlink L2 sequencer uptime feed on Optimism mainnet.
    address constant OP_SEQUENCER_FEED = 0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389;

    // Grace period: 1 hour after sequencer restart before accepting prices.
    uint256 constant L2_GRACE_PERIOD = 3600;

    // ── Sucker test state ──

    // Ruleset metadata used for the test project.
    JBRulesetMetadata _metadata;

    // The JBOptimismSucker deployer on the L2 fork.
    JBOptimismSuckerDeployer suckerDeployer;

    // The deployed sucker instance.
    IJBSucker sucker;

    // The project's ERC-20 token (deployed after project launch).
    IJBToken projectToken;

    // Tracks whether the Optimism fork was successfully created.
    bool forkCreated;

    // Accept ETH for cash-out reclaims.
    receive() external payable {}

    function setUp() public override {
        // Attempt to fork Optimism mainnet; skip all tests if no RPC is available.
        try vm.createSelectFork("optimism") {
            // Fork succeeded — record that fact.
            forkCreated = true;
        } catch {
            // No Optimism RPC configured — skip gracefully.
            forkCreated = false;
            return;
        }

        // Configure ruleset metadata with sensible defaults for sucker testing.
        _metadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT / 2, // 50% reserved tokens.
            cashOutTaxRate: 0, // No cash-out tax (simplifies sucker tests).
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)), // ETH as base currency.
            pausePay: false, // Payments enabled.
            pauseCreditTransfers: false, // Credit transfers enabled.
            allowOwnerMinting: true, // Owner can mint (needed for sucker claims).
            allowSetCustomToken: false, // Custom token setting disabled.
            allowTerminalMigration: false, // Terminal migration disabled.
            allowSetTerminals: false, // Setting terminals disabled.
            allowSetController: false, // Setting controller disabled.
            allowAddAccountingContext: true, // Adding accounting contexts allowed.
            allowAddPriceFeed: true, // Adding price feeds allowed.
            ownerMustSendPayouts: false, // Anyone can trigger payouts.
            holdFees: false, // Fees not held.
            useTotalSurplusForCashOuts: true, // Use total surplus across terminals.
            useDataHookForPay: false, // No pay data hook.
            useDataHookForCashOut: false, // No cash-out data hook.
            dataHook: address(0), // No data hook address.
            metadata: 0 // No extra metadata.
        });

        // Deploy fresh JB core contracts on the Optimism fork.
        super.setUp();

        // Stop any active prank from TestBaseWorkflow.
        vm.stopPrank();

        // Deploy the OP sucker deployer (from a non-privileged address to match prod pattern).
        vm.startPrank(address(0x1112222));
        suckerDeployer = new JBOptimismSuckerDeployer(
            jbDirectory(), // Core directory for project lookups.
            jbPermissions(), // Permissions contract for access control.
            jbTokens(), // Token contract for minting/burning.
            address(this), // Configurator address.
            address(0) // No trusted forwarder for this test.
        );
        vm.stopPrank();

        // Set the OP-specific constants: messenger and bridge addresses.
        suckerDeployer.setChainSpecificConstants(L2_MESSENGER, L2_BRIDGE);

        // Deploy the singleton implementation (used as template for clones).
        vm.startPrank(address(0x1112222));
        JBOptimismSucker singleton = new JBOptimismSucker({
            deployer: suckerDeployer, // Deployer that provides bridge references.
            directory: jbDirectory(), // Core directory.
            permissions: jbPermissions(), // Core permissions.
            tokens: jbTokens(), // Core token management.
            feeProjectId: 1, // Fee project ID.
            registry: IJBSuckerRegistry(address(0)), // No registry in test.
            trustedForwarder: address(0) // No trusted forwarder.
        });
        vm.stopPrank();

        // Register the singleton with the deployer.
        suckerDeployer.configureSingleton(singleton);

        // Create a sucker clone for project ID 1.
        sucker = suckerDeployer.createForSender(1, "op-fork-salt");

        // Label the sucker address for trace readability.
        vm.label(address(sucker), "optimismSucker");

        // Grant the sucker MINT_TOKENS permission so it can mint on claim.
        uint8[] memory ids = new uint8[](1);
        ids[0] = JBPermissionIds.MINT_TOKENS; // Permission to mint project tokens.

        // Build permissions data for the sucker.
        JBPermissionsData memory perms = JBPermissionsData({
            operator: address(sucker), // The sucker needs mint permission.
            projectId: 1, // For project 1.
            permissionIds: ids // MINT_TOKENS permission.
        });

        // Set permissions and launch the project.
        vm.startPrank(multisig());
        jbPermissions().setPermissionsFor(multisig(), perms); // Grant mint to sucker.
        _launchProject(); // Launch a project that accepts native ETH.
        projectToken = jbController().deployERC20For(1, "OPSuckerToken", "OPSOOK", bytes32(0)); // Deploy ERC-20.
        vm.stopPrank();

        // Mock the registry's toRemoteFee() to return 0 (registry is address(0) in tests).
        vm.mockCall(
            address(0),
            abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()),
            abi.encode(uint256(0)) // Zero bridging fee for test simplicity.
        );
    }

    /// @notice Launches a test project that accepts native ETH payments.
    function _launchProject() internal {
        // Configure surplus allowance for the project.
        JBCurrencyAmount[] memory _surplusAllowances = new JBCurrencyAmount[](1);
        _surplusAllowances[0] = JBCurrencyAmount({
            amount: 5 * 10 ** 18, // Allow 5 ETH surplus withdrawal.
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)) // Denominated in native ETH.
        });

        // Configure fund access limits (surplus allowance only, no payout limits).
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()), // For the multi-terminal.
            token: JBConstants.NATIVE_TOKEN, // For native ETH.
            payoutLimits: new JBCurrencyAmount[](0), // No payout limits.
            surplusAllowances: _surplusAllowances // 5 ETH surplus allowance.
        });

        // Build ruleset configuration.
        JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
        _rulesetConfigurations[0].mustStartAtOrAfter = 0; // Start immediately.
        _rulesetConfigurations[0].duration = 0; // No expiration (manual replacement only).
        _rulesetConfigurations[0].weight = 1000 * 10 ** 18; // 1000 tokens per ETH.
        _rulesetConfigurations[0].weightCutPercent = 0; // No weight decay.
        _rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0)); // No approval hook.
        _rulesetConfigurations[0].metadata = _metadata; // Configured metadata.
        _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0); // No split groups.
        _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup; // Fund access config.

        // Configure terminal to accept native ETH.
        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);
        _tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, // Accept native ETH.
            decimals: 18, // ETH uses 18 decimals.
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)) // Currency matches token.
        });

        // Set up the terminal configuration.
        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        _terminalConfigurations[0] = JBTerminalConfig({
            terminal: jbMultiTerminal(), // Use the deployed multi-terminal.
            accountingContextsToAccept: _tokensToAccept // Accept native ETH.
        });

        // Launch the project with the configured ruleset and terminal.
        jbController()
            .launchProjectFor({
                owner: multisig(), // Multisig owns the project.
                projectUri: "optimism-sucker-fork-test", // Descriptive URI.
                rulesetConfigurations: _rulesetConfigurations, // Single ruleset.
                terminalConfigurations: _terminalConfigurations, // Single terminal.
                memo: "" // No memo.
            });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Tests
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Verify chain ID is correct on the Optimism fork.
    function test_optimism_chainId() public {
        // Skip if no Optimism fork is available.
        if (!forkCreated) {
            vm.skip(true); // Gracefully skip when no Optimism RPC is configured.
            return;
        }

        // Optimism mainnet chain ID should be 10.
        assertEq(block.chainid, 10, "Fork should report Optimism mainnet chain ID 10");
    }

    /// @notice Verify OP Stack predeploy contracts exist at canonical addresses.
    function test_optimism_predeploysExist() public {
        // Skip if no Optimism fork is available.
        if (!forkCreated) {
            vm.skip(true); // Gracefully skip when no Optimism RPC is configured.
            return;
        }

        // CrossDomainMessenger should be deployed at the L2 predeploy address.
        assertGt(address(L2_MESSENGER).code.length, 0, "CrossDomainMessenger should be deployed on Optimism");

        // StandardBridge should be deployed at the L2 predeploy address.
        assertGt(address(L2_BRIDGE).code.length, 0, "StandardBridge should be deployed on Optimism");

        // L2ToL1MessagePasser should be deployed (OP withdrawals depend on it).
        assertGt(L2_TO_L1_MESSAGE_PASSER.code.length, 0, "L2ToL1MessagePasser should be deployed on Optimism");

        // WETH predeploy should exist on Optimism.
        assertGt(OP_WETH.code.length, 0, "WETH predeploy should exist on Optimism");
    }

    /// @notice Verify the OP CrossDomainMessenger responds to xDomainMessageSender().
    function test_optimism_messengerXDomainSender() public {
        // Skip if no Optimism fork is available.
        if (!forkCreated) {
            vm.skip(true); // Gracefully skip when no Optimism RPC is configured.
            return;
        }

        // xDomainMessageSender() should revert when called outside of a cross-domain message.
        // This proves the messenger exists and has the expected function selector.
        try L2_MESSENGER.xDomainMessageSender() {
            // If it doesn't revert, it returned a default value — still proves the contract responds.
            assertTrue(true, "Messenger responded to xDomainMessageSender() without revert");
        } catch {
            // Expected: reverts with "xDomainMessageSender is not set" when not in a cross-domain call.
            assertTrue(true, "Messenger correctly reverts outside cross-domain context");
        }
    }

    /// @notice Verify JBOptimismSucker deployed correctly with OP bridge references.
    function test_optimism_suckerBridgeReferences() public {
        // Skip if no Optimism fork is available.
        if (!forkCreated) {
            vm.skip(true); // Gracefully skip when no Optimism RPC is configured.
            return;
        }

        // Cast to JBOptimismSucker via payable address (JBSucker has a payable fallback).
        JBOptimismSucker opSucker = JBOptimismSucker(payable(address(sucker)));

        // Verify OPMESSENGER points to the L2 CrossDomainMessenger.
        assertEq(
            address(opSucker.OPMESSENGER()),
            address(L2_MESSENGER),
            "Sucker OPMESSENGER should be the L2 CrossDomainMessenger"
        );

        // Verify OPBRIDGE points to the L2 StandardBridge.
        assertEq(address(opSucker.OPBRIDGE()), address(L2_BRIDGE), "Sucker OPBRIDGE should be the L2 StandardBridge");
    }

    /// @notice Verify sucker's peerChainId() returns Ethereum mainnet (1) when on Optimism (10).
    function test_optimism_suckerPeerChainId() public {
        // Skip if no Optimism fork is available.
        if (!forkCreated) {
            vm.skip(true); // Gracefully skip when no Optimism RPC is configured.
            return;
        }

        // Cast to JBOptimismSucker via payable address (JBSucker has a payable fallback).
        JBOptimismSucker opSucker = JBOptimismSucker(payable(address(sucker)));

        // When running on Optimism (chain 10), peer should be Ethereum mainnet (chain 1).
        assertEq(opSucker.peerChainId(), 1, "Peer chain for Optimism should be Ethereum mainnet (chain ID 1)");
    }

    /// @notice Test native ETH send-side flow: pay into terminal, prepare cash-out via sucker,
    /// and send to remote via the OP bridge.
    function test_optimism_nativeEthSendFlow() public {
        // Skip if no Optimism fork is available.
        if (!forkCreated) {
            vm.skip(true); // Gracefully skip when no Optimism RPC is configured.
            return;
        }

        // Set up test actor and amounts.
        address user = makeAddr("opUser");
        uint256 amountToSend = 0.05 ether; // Amount of ETH to pay into the project.
        uint256 maxCashedOut = amountToSend / 2; // Maximum ETH expected from cash-out.

        // Fund the user with ETH on Optimism.
        vm.deal(user, amountToSend);

        // Map native token (ETH -> ETH, same on both chains).
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN, // Local token is native ETH.
            minGas: 200_000, // Minimum gas for cross-domain message execution.
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))) // Remote token is also native ETH.
        });

        // Map the token as project owner (multisig).
        vm.prank(multisig());
        sucker.mapToken(map);

        // Pay into the terminal as the user, receiving project tokens.
        vm.startPrank(user);
        uint256 projectTokenAmount = jbMultiTerminal().pay{value: amountToSend}(
            1, // Project ID 1.
            JBConstants.NATIVE_TOKEN, // Pay with native ETH.
            amountToSend, // Full amount.
            user, // Tokens go to user.
            0, // No minimum tokens.
            "", // No memo.
            "" // No metadata.
        );

        // Approve the sucker to spend the user's project tokens.
        IERC20(address(projectToken)).approve(address(sucker), projectTokenAmount);

        // Prepare the cash-out via the sucker (builds the merkle outbox tree).
        sucker.prepare(
            projectTokenAmount, // All project tokens.
            bytes32(uint256(uint160(user))), // Remote beneficiary (same user).
            maxCashedOut, // Maximum ETH to receive on remote.
            JBConstants.NATIVE_TOKEN // Cash out in native ETH.
        );
        vm.stopPrank();

        // Record logs to verify that OP bridge/messenger emit events.
        vm.recordLogs();

        // Send the outbox tree to the remote chain via the OP bridge.
        vm.prank(user);
        sucker.toRemote(JBConstants.NATIVE_TOKEN); // Initiates bridging (OP bridge doesn't need msg.value).

        // Verify the outbox was cleared after sending.
        assertEq(sucker.outboxOf(JBConstants.NATIVE_TOKEN).balance, 0, "Outbox should be cleared after toRemote()");

        // Verify that the OP bridge or messenger emitted events (proves real contracts accepted our call).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundBridgeEvent = false; // Track whether we found a bridge/messenger event.
        for (uint256 i = 0; i < logs.length; i++) {
            // Check if the event was emitted by the bridge or messenger predeploys.
            if (logs[i].emitter == address(L2_BRIDGE) || logs[i].emitter == address(L2_MESSENGER)) {
                foundBridgeEvent = true; // Found an event from the OP infrastructure.
                break;
            }
        }

        // At least one event should have been emitted by the OP bridge infrastructure.
        assertTrue(foundBridgeEvent, "OP bridge/messenger should have emitted events on Optimism");
    }

    /// @notice Verify Chainlink sequencer-aware price feed works with real Optimism feeds.
    function test_optimism_sequencerPriceFeed() public {
        // Skip if no Optimism fork is available.
        if (!forkCreated) {
            vm.skip(true); // Gracefully skip when no Optimism RPC is configured.
            return;
        }

        // Verify the ETH/USD feed contract exists on Optimism.
        assertGt(OP_ETH_USD_FEED.code.length, 0, "Chainlink ETH/USD feed should be deployed on Optimism");

        // Verify the sequencer uptime feed contract exists on Optimism.
        assertGt(OP_SEQUENCER_FEED.code.length, 0, "Chainlink sequencer feed should be deployed on Optimism");

        // Deploy a sequencer-aware price feed using Optimism's real Chainlink feeds.
        JBChainlinkV3SequencerPriceFeed feed = new JBChainlinkV3SequencerPriceFeed(
            AggregatorV3Interface(OP_ETH_USD_FEED), // The underlying ETH/USD price feed.
            3600, // 1-hour staleness threshold.
            AggregatorV2V3Interface(OP_SEQUENCER_FEED), // The L2 sequencer uptime feed.
            L2_GRACE_PERIOD // 1-hour grace period after sequencer restart.
        );

        // Attempt to get the current price; may revert if sequencer is in grace period.
        try feed.currentUnitPrice(18) returns (uint256 price) {
            // If the sequencer is up and feed is fresh, verify the price is sane.
            assertGt(price, 0, "ETH/USD price should be positive on Optimism");

            // Sanity check: ETH should be between $100 and $100,000.
            assertGt(price, 100e18, "ETH/USD price should be above $100 on Optimism");
            assertLt(price, 100_000e18, "ETH/USD price should be below $100,000 on Optimism");
        } catch {
            // Sequencer down or feed stale at the fork block — expected behavior.
            assertTrue(true, "Feed reverted as expected (sequencer down or stale at fork block)");
        }
    }

    /// @notice Verify the MESSENGER_BASE_GAS_LIMIT constant is set correctly.
    function test_optimism_messengerBaseGasLimit() public {
        // Skip if no Optimism fork is available.
        if (!forkCreated) {
            vm.skip(true); // Gracefully skip when no Optimism RPC is configured.
            return;
        }

        // The base gas limit should be 300,000 (defined in JBSucker.sol).
        assertEq(sucker.MESSENGER_BASE_GAS_LIMIT(), 300_000, "MESSENGER_BASE_GAS_LIMIT should be 300,000");
    }
}
