// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
import {IJBSucker} from "../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../src/interfaces/IJBSuckerDeployer.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ICCIPRouter} from "src/interfaces/ICCIPRouter.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {JBTokenMapping} from "../src/structs/JBTokenMapping.sol";
import {JBRemoteToken} from "../src/structs/JBRemoteToken.sol";
import {JBOutboxTree} from "../src/structs/JBOutboxTree.sol";
import {JBInboxTreeRoot} from "../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";
import {JBClaim} from "../src/structs/JBClaim.sol";
import {JBLeaf} from "../src/structs/JBLeaf.sol";

import {MerkleLib} from "../src/utils/MerkleLib.sol";

import "forge-std/Test.sol";
import {JBCCIPSuckerDeployer} from "src/deployers/JBCCIPSuckerDeployer.sol";
import {JBCCIPSucker} from "../src/JBCCIPSucker.sol";
import {BurnMintERC677Helper} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";

import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";
import {CCIPHelper} from "../src/libraries/CCIPHelper.sol";
import {JBSucker} from "../src/JBSucker.sol";

/// @notice Fork test that exercises the full prepare -> toRemote -> CCIP deliver -> claim flow
/// on Sepolia <-> Arbitrum Sepolia, verifying merkle proof verification and double-claim prevention.
contract CCIPSuckerForkClaimTests is TestBaseWorkflow {
    // CCIP Local Simulator Contracts
    CCIPLocalSimulatorFork ccipLocalSimulatorFork;
    BurnMintERC677Helper ccipBnM;
    BurnMintERC677Helper ccipBnMArbSepolia;

    // Re-used parameters for project/ruleset/sucker setups
    JBRulesetMetadata _metadata;

    // Sucker and token
    JBCCIPSuckerDeployer suckerDeployer;
    JBCCIPSuckerDeployer suckerDeployer2;
    IJBSucker suckerL1;
    IJBToken projectOneToken;

    // Chain ids and selectors
    uint256 sepoliaFork;
    uint256 arbSepoliaFork;
    uint64 arbSepoliaChainSelector = 3_478_487_238_524_512_106;
    uint64 ethSepoliaChainSelector = 16_015_286_601_757_825_753;

    // RPCs -- named endpoints from foundry.toml [rpc_endpoints].
    string ETHEREUM_SEPOLIA_RPC_URL = "ethereum_sepolia";
    string ARBITRUM_SEPOLIA_RPC_URL = "arbitrum_sepolia";

    //*********************************************************************//
    // ----------------------------- Events ------------------------------ //
    //*********************************************************************//

    /// @dev Mirror of IJBSucker.InsertToOutboxTree so we can capture it with vm.expectEmit / recordLogs.
    event InsertToOutboxTree(
        bytes32 indexed beneficiary,
        address indexed token,
        bytes32 hashed,
        uint256 index,
        bytes32 root,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        address caller
    );

    //*********************************************************************//
    // ---------------------------- Setup parts -------------------------- //
    //*********************************************************************//

    function initL1AndUtils() public {
        // Setup starts on sepolia fork
        sepoliaFork = vm.createSelectFork(ETHEREUM_SEPOLIA_RPC_URL);

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));
        Register.NetworkDetails memory sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        ccipBnM = BurnMintERC677Helper(sepoliaNetworkDetails.ccipBnMAddress);
        vm.label(address(ccipBnM), "bnmEthSep");
        vm.makePersistent(address(ccipBnM));
    }

    function initMetadata() public {
        _metadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT / 2, //50%
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(JBConstants.NATIVE_TOKEN))),
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
    }

    function launchAndConfigureL1Project() public {
        // Package up the limits for the given terminal.
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        {
            JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](0);

            JBCurrencyAmount[] memory _surplusAllowances = new JBCurrencyAmount[](1);
            _surplusAllowances[0] =
                JBCurrencyAmount({amount: 5 * 10 ** 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

            _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
                terminal: address(jbMultiTerminal()),
                token: JBConstants.NATIVE_TOKEN,
                payoutLimits: _payoutLimits,
                surplusAllowances: _surplusAllowances
            });
        }

        {
            JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            _rulesetConfigurations[0].duration = 0;
            _rulesetConfigurations[0].weight = 1000 * 10 ** 18;
            _rulesetConfigurations[0].weightCutPercent = 0;
            _rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

            JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
            JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](2);

            _tokensToAccept[0] = JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });

            _tokensToAccept[1] = JBAccountingContext({
                token: address(ccipBnM), decimals: 18, currency: uint32(uint160(address(ccipBnM)))
            });

            _terminalConfigurations[0] =
                JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokensToAccept});

            vm.expectCall(address(ccipBnM), abi.encodeWithSelector(IERC20Metadata.decimals.selector));

            // Create a first project to collect fees.
            jbController()
                .launchProjectFor({
                    owner: multisig(),
                    projectUri: "whatever",
                    rulesetConfigurations: _rulesetConfigurations,
                    terminalConfigurations: _terminalConfigurations,
                    memo: ""
                });

            // Setup an erc20 for the project
            projectOneToken = jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));

            // Add a price-feed to reconcile pays and cash outs with our test token
            MockPriceFeed _priceFeedNativeTest = new MockPriceFeed(100 * 10 ** 18, 18);
            vm.label(address(_priceFeedNativeTest), "Mock Price Feed Native-ccipBnM");

            vm.startPrank(address(jbController()));
            IJBPrices(jbPrices())
                .addPriceFeedFor({
                    projectId: 1,
                    pricingCurrency: uint32(uint160(address(ccipBnM))),
                    unitCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                    feed: IJBPriceFeed(_priceFeedNativeTest)
                });
        }
    }

    function initL2AndUtils() public {
        // Create and select our L2 fork
        arbSepoliaFork = vm.createSelectFork(ARBITRUM_SEPOLIA_RPC_URL);

        Register.NetworkDetails memory arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(421_614);

        ccipBnMArbSepolia = BurnMintERC677Helper(arbSepoliaNetworkDetails.ccipBnMAddress);
        vm.label(address(ccipBnMArbSepolia), "bnmArbSep");
    }

    function launchAndConfigureL2Project() public {
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        {
            JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            _rulesetConfigurations[0].duration = 0;
            _rulesetConfigurations[0].weight = 1000 * 10 ** 18;
            _rulesetConfigurations[0].weightCutPercent = 0;
            _rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

            JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
            JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](2);

            _tokensToAccept[0] = JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });

            _tokensToAccept[1] = JBAccountingContext({
                token: address(ccipBnMArbSepolia), decimals: 18, currency: uint32(uint160(address(ccipBnMArbSepolia)))
            });

            _terminalConfigurations[0] =
                JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokensToAccept});

            vm.expectCall(address(ccipBnMArbSepolia), abi.encodeWithSelector(IERC20Metadata.decimals.selector));

            // Create a first project to collect fees.
            jbController()
                .launchProjectFor({
                    owner: multisig(),
                    projectUri: "whatever",
                    rulesetConfigurations: _rulesetConfigurations,
                    terminalConfigurations: _terminalConfigurations,
                    memo: ""
                });
        }
    }

    //*********************************************************************//
    // ------------------------------- Setup ----------------------------- //
    //*********************************************************************//

    function setUp() public override {
        // Create (and select) Sepolia fork and make simulator helper contracts persistent.
        initL1AndUtils();

        // Set metadata for the test projects to use.
        initMetadata();

        // Run setup on our first fork (sepolia) so we have a JBV4 setup (deploys v4 contracts).
        super.setUp();

        vm.stopPrank();
        vm.startPrank(address(0x1112222));
        suckerDeployer = new JBCCIPSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        vm.stopPrank();

        // Set the remote chain as arb-sep
        suckerDeployer.setChainSpecificConstants(
            421_614, CCIPHelper.selectorOfChain(421_614), ICCIPRouter(CCIPHelper.routerOfChain(block.chainid))
        );

        // Deploy the singleton and configure it.
        vm.startPrank(address(0x1112222));
        JBCCIPSucker singleton = new JBCCIPSucker({
            deployer: suckerDeployer,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        suckerDeployer.configureSingleton(singleton);

        // Deploy our first sucker (on sepolia, the current fork, or "L1").
        suckerL1 = suckerDeployer.createForSender(1, "salty");
        vm.label(address(suckerL1), "suckerL1");

        // Allow the sucker to mint
        uint8[] memory ids = new uint8[](1);
        ids[0] = JBPermissionIds.MINT_TOKENS;

        JBPermissionsData memory perms =
            JBPermissionsData({operator: address(suckerL1), projectId: 1, permissionIds: ids});

        // Allow our L1 sucker to mint.
        vm.startPrank(multisig());
        jbPermissions().setPermissionsFor(multisig(), perms);

        // Launch and configure our project on L1.
        launchAndConfigureL1Project();

        vm.stopPrank();

        // Init our L2 fork and CCIP Local simulator utils for L2.
        initL2AndUtils();

        // Setup JBV4 on our forked L2 (arb-sep).
        super.setUp();

        vm.stopPrank();

        vm.startPrank(address(0x1112222));
        suckerDeployer2 =
            new JBCCIPSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        vm.stopPrank();

        suckerDeployer2.setChainSpecificConstants(
            11_155_111, CCIPHelper.selectorOfChain(11_155_111), ICCIPRouter(CCIPHelper.routerOfChain(block.chainid))
        );

        // Deploy the singleton and configure it.
        vm.startPrank(address(0x1112222));
        JBCCIPSucker singleton2 = new JBCCIPSucker({
            deployer: suckerDeployer2,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        suckerDeployer2.configureSingleton(singleton2);

        // Deploy the sucker on L2.
        suckerDeployer2.createForSender(1, "salty");

        // Launch our project on L2.
        vm.startPrank(multisig());
        launchAndConfigureL2Project();

        // Allow the L2 sucker to mint (reuse same perms struct, operator is the same address via CREATE2 salt).
        jbPermissions().setPermissionsFor(multisig(), perms);

        vm.stopPrank();

        // Mock the registry's toRemoteFee() on both forks (registry is address(0) in tests).
        vm.selectFork(sepoliaFork);
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
        vm.selectFork(arbSepoliaFork);
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
    }

    //*********************************************************************//
    // ----------------------- Helper: zero-hash proof ------------------- //
    //*********************************************************************//

    /// @notice Builds a 32-element proof of all zero hashes for a single-leaf tree (index 0).
    /// @dev For a tree with one leaf at index 0, every sibling on the path to the root is the
    ///      zero hash at that level: Z_0, Z_1, ..., Z_31.
    function _zeroProof() internal pure returns (bytes32[32] memory proof) {
        proof[0] = hex"0000000000000000000000000000000000000000000000000000000000000000"; // Z_0
        proof[1] = hex"ad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5"; // Z_1
        proof[2] = hex"b4c11951957c6f8f642c4af61cd6b24640fec6dc7fc607ee8206a99e92410d30"; // Z_2
        proof[3] = hex"21ddb9a356815c3fac1026b6dec5df3124afbadb485c9ba5a3e3398a04b7ba85"; // Z_3
        proof[4] = hex"e58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344"; // Z_4
        proof[5] = hex"0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d"; // Z_5
        proof[6] = hex"887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968"; // Z_6
        proof[7] = hex"ffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83"; // Z_7
        proof[8] = hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af"; // Z_8
        proof[9] = hex"cefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0"; // Z_9
        proof[10] = hex"f9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5"; // Z_10
        proof[11] = hex"f8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892"; // Z_11
        proof[12] = hex"3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c"; // Z_12
        proof[13] = hex"c1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb"; // Z_13
        proof[14] = hex"5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc"; // Z_14
        proof[15] = hex"da7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2"; // Z_15
        proof[16] = hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f"; // Z_16
        proof[17] = hex"e1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a"; // Z_17
        proof[18] = hex"5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0"; // Z_18
        proof[19] = hex"b46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0"; // Z_19
        proof[20] = hex"c65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2"; // Z_20
        proof[21] = hex"f4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9"; // Z_21
        proof[22] = hex"5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377"; // Z_22
        proof[23] = hex"4df84f40ae0c8229d0d6069e5c8f39a7c299677a09d367fc7b05e3bc380ee652"; // Z_23
        proof[24] = hex"cdc72595f74c7b1043d0e1ffbab734648c838dfb0527d971b602bc216c9619ef"; // Z_24
        proof[25] = hex"0abf5ac974a1ed57f4050aa510dd9c74f508277b39d7973bb2dfccc5eeb0618d"; // Z_25
        proof[26] = hex"b8cd74046ff337f0a7bf2c8e03e10f642c1886798d71806ab1e888d9e5ee87d0"; // Z_26
        proof[27] = hex"838c5655cb21c6cb83313b5a631175dff4963772cce9108188b34ac87c81c41e"; // Z_27
        proof[28] = hex"662ee4dd2dd7b2bc707961b1e646c4047669dcb6584f0d8d770daf5d7e7deb2e"; // Z_28
        proof[29] = hex"388ab20e2573d171a88108e79d820e98f26c0b84aa8b2f4aa4968dbb818ea322"; // Z_29
        proof[30] = hex"93237c50ba75ee485f4c22adf2f741400bdf8d6a9cc7df7ecae576221665d735"; // Z_30
        proof[31] = hex"8448818bb4ae4562849e949e17ac16e0be16688e156b5cf15e098c627c0056a9"; // Z_31
    }

    //*********************************************************************//
    // ------------------------------- Tests ----------------------------- //
    //*********************************************************************//

    /// @notice Full end-to-end: prepare on L1 -> toRemote via CCIP -> claim on L2 -> double-claim reverts.
    function test_forkClaimNative() external {
        // -- Actors and parameters --
        address user = makeAddr("him");

        // State captured across scoped blocks
        uint256 capturedProjectTokenCount;
        uint256 capturedTerminalTokenAmount;
        uint256 capturedIndex;
        bytes32 capturedBeneficiary;

        // ----------------------------------------------------------------
        // Step 1: Prepare on L1 — pay the project, then prepare to bridge
        // ----------------------------------------------------------------
        {
            vm.selectFork(sepoliaFork);

            uint256 amountToSend = 0.05 ether;
            uint256 maxCashedOut = amountToSend / 2;

            vm.deal(user, amountToSend);

            // Map the native token for bridging
            JBTokenMapping memory map = JBTokenMapping({
                localToken: JBConstants.NATIVE_TOKEN,
                minGas: 200_000,
                remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
            });

            vm.prank(multisig());
            suckerL1.mapToken(map);

            // User pays the project and receives project tokens
            vm.startPrank(user);
            uint256 projectTokenAmount =
                jbMultiTerminal().pay{value: amountToSend}(1, JBConstants.NATIVE_TOKEN, amountToSend, user, 0, "", "");

            // Approve the sucker to use the project tokens
            IERC20(address(projectOneToken)).approve(address(suckerL1), projectTokenAmount);

            // Record logs to capture InsertToOutboxTree event
            vm.recordLogs();

            // Prepare: cashes out project tokens for native tokens, inserts leaf into outbox tree
            suckerL1.prepare(
                projectTokenAmount, bytes32(uint256(uint160(user))), maxCashedOut, JBConstants.NATIVE_TOKEN
            );
            vm.stopPrank();
        }

        // ----------------------------------------------------------------
        // Step 2: Extract leaf values from the InsertToOutboxTree event
        // ----------------------------------------------------------------
        {
            Vm.Log[] memory logs = vm.getRecordedLogs();

            bytes32 eventSig =
                keccak256("InsertToOutboxTree(bytes32,address,bytes32,uint256,bytes32,uint256,uint256,address)");

            bool found;

            for (uint256 i; i < logs.length; i++) {
                if (logs[i].topics[0] == eventSig) {
                    capturedBeneficiary = logs[i].topics[1];

                    (, // hashed
                        capturedIndex,, // root
                        capturedProjectTokenCount,
                        capturedTerminalTokenAmount,
                        // caller
                    ) = abi.decode(logs[i].data, (bytes32, uint256, bytes32, uint256, uint256, address));

                    found = true;
                    break;
                }
            }
            assertTrue(found, "InsertToOutboxTree event not found");
            assertEq(capturedIndex, 0, "First leaf should be at index 0");
            assertEq(capturedBeneficiary, bytes32(uint256(uint160(user))), "Beneficiary mismatch");
            assertGt(capturedProjectTokenCount, 0, "Project token count should be > 0");
            assertGt(capturedTerminalTokenAmount, 0, "Terminal token amount should be > 0");
        }

        // ----------------------------------------------------------------
        // Step 3: Send over CCIP (toRemote) and deliver to L2
        // ----------------------------------------------------------------
        {
            address rootSender = makeAddr("rootSender");
            vm.deal(rootSender, 1 ether);

            vm.prank(rootSender);
            suckerL1.toRemote{value: 1 ether}(JBConstants.NATIVE_TOKEN);

            // Verify outbox is cleared
            assertEq(
                suckerL1.outboxOf(JBConstants.NATIVE_TOKEN).balance, 0, "Outbox balance should be 0 after toRemote"
            );

            // CCIP local simulator delivers the message to L2
            ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);

            // We are now on L2 (arbSepoliaFork). suckerL1 is at the same address due to CREATE2.
            // Verify inbox root was set
            assertNotEq(
                suckerL1.inboxOf(JBConstants.NATIVE_TOKEN).root,
                bytes32(0),
                "Inbox root should be set after CCIP delivery"
            );

            // Verify native value was delivered
            assertEq(address(suckerL1).balance, capturedTerminalTokenAmount, "Sucker should hold the bridged ETH");
        }

        // ----------------------------------------------------------------
        // Step 4: Claim on L2 — beneficiary receives minted project tokens
        // ----------------------------------------------------------------
        {
            // Check user's project token balance before claim (should be 0 on L2)
            assertEq(jbTokens().totalBalanceOf(user, 1), 0, "User should have 0 project tokens on L2 before claim");

            // For a single-leaf tree (index 0), the merkle proof siblings are all zero hashes
            JBClaim memory claimData = JBClaim({
                token: JBConstants.NATIVE_TOKEN,
                leaf: JBLeaf({
                    index: capturedIndex,
                    beneficiary: capturedBeneficiary,
                    projectTokenCount: capturedProjectTokenCount,
                    terminalTokenAmount: capturedTerminalTokenAmount
                }),
                proof: _zeroProof()
            });

            // Execute the claim
            suckerL1.claim(claimData);

            // Verify: beneficiary received the minted project tokens
            assertEq(
                jbTokens().totalBalanceOf(user, 1),
                capturedProjectTokenCount,
                "User should have received the exact project token count from the claim"
            );

            // ----------------------------------------------------------------
            // Step 5: Double-claim reverts
            // ----------------------------------------------------------------
            vm.expectRevert(
                abi.encodeWithSelector(
                    JBSucker.JBSucker_LeafAlreadyExecuted.selector, JBConstants.NATIVE_TOKEN, capturedIndex
                )
            );
            suckerL1.claim(claimData);
        }
    }
}
