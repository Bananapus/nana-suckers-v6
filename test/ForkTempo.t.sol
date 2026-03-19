// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
import {IJBSucker} from "../src/interfaces/IJBSucker.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
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
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";

import {MerkleLib} from "../src/utils/MerkleLib.sol";

import "forge-std/Test.sol";
import {JBCCIPSuckerDeployer} from "src/deployers/JBCCIPSuckerDeployer.sol";
import {JBCCIPSucker} from "../src/JBCCIPSucker.sol";
import {BurnMintERC677Helper} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";

import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";
import {CCIPHelper} from "../src/libraries/CCIPHelper.sol";

/// @title CCIPSuckerTempoForkedTests
/// @notice Fork tests for Tempo testnet ↔ Ethereum Sepolia CCIP lane.
/// Tempo side pays fees in LINK (transportPayment == 0).
/// Sepolia side pays fees in native ETH (transportPayment > 0).
contract CCIPSuckerTempoForkedTests is TestBaseWorkflow {
    CCIPLocalSimulatorFork ccipLocalSimulatorFork;
    BurnMintERC677Helper ccipBnM;
    BurnMintERC677Helper ccipBnMTempo;

    JBRulesetMetadata _metadata;

    JBCCIPSuckerDeployer suckerDeployerSepolia;
    JBCCIPSuckerDeployer suckerDeployerTempo;
    IJBSucker suckerSepolia;
    IJBToken projectOneToken;

    uint256 sepoliaFork;
    uint256 tempoFork;
    uint64 tempoChainSelector = CCIPHelper.TEMPO_TEST_SEL;
    uint64 ethSepoliaChainSelector = CCIPHelper.ETH_SEP_SEL;

    string ETHEREUM_SEPOLIA_RPC_URL = "ethereum_sepolia";
    string TEMPO_TESTNET_RPC_URL = "tempo_testnet";

    function initSepoliaAndUtils() public {
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
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT / 2,
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

    function launchAndConfigureSepoliaProject() public {
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

            jbController().launchProjectFor({
                owner: multisig(),
                projectUri: "whatever",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            });

            projectOneToken = jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));

            MockPriceFeed _priceFeedNativeTest = new MockPriceFeed(100 * 10 ** 18, 18);
            vm.label(address(_priceFeedNativeTest), "Mock Price Feed Native-ccipBnM");

            vm.startPrank(address(jbController()));
            IJBPrices(jbPrices()).addPriceFeedFor({
                projectId: 1,
                pricingCurrency: uint32(uint160(address(ccipBnM))),
                unitCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                feed: IJBPriceFeed(_priceFeedNativeTest)
            });
        }
    }

    function initTempoAndUtils() public {
        tempoFork = vm.createSelectFork(TEMPO_TESTNET_RPC_URL);

        Register.NetworkDetails memory tempoNetworkDetails =
            ccipLocalSimulatorFork.getNetworkDetails(CCIPHelper.TEMPO_TEST_ID);

        ccipBnMTempo = BurnMintERC677Helper(tempoNetworkDetails.ccipBnMAddress);
        vm.label(address(ccipBnMTempo), "bnmTempo");
    }

    function launchAndConfigureTempoProject() public {
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
                token: address(ccipBnMTempo), decimals: 18, currency: uint32(uint160(address(ccipBnMTempo)))
            });

            _terminalConfigurations[0] =
                JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokensToAccept});

            vm.expectCall(address(ccipBnMTempo), abi.encodeWithSelector(IERC20Metadata.decimals.selector));

            jbController().launchProjectFor({
                owner: multisig(),
                projectUri: "whatever",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            });
        }
    }

    function setUp() public override {
        // Create (and select) Sepolia fork.
        initSepoliaAndUtils();
        initMetadata();

        // Deploy JBv6 on Sepolia.
        super.setUp();

        vm.stopPrank();
        vm.startPrank(address(0x1112222));
        suckerDeployerSepolia =
            new JBCCIPSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        vm.stopPrank();

        // Sepolia → Tempo testnet.
        suckerDeployerSepolia.setChainSpecificConstants(
            CCIPHelper.TEMPO_TEST_ID,
            CCIPHelper.selectorOfChain(CCIPHelper.TEMPO_TEST_ID),
            ICCIPRouter(CCIPHelper.routerOfChain(block.chainid))
        );

        vm.startPrank(address(0x1112222));
        JBCCIPSucker singletonSepolia = new JBCCIPSucker({
            deployer: suckerDeployerSepolia,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        suckerDeployerSepolia.configureSingleton(singletonSepolia);
        suckerSepolia = suckerDeployerSepolia.createForSender(1, "salty");
        vm.label(address(suckerSepolia), "suckerSepolia");

        uint8[] memory ids = new uint8[](1);
        ids[0] = JBPermissionIds.MINT_TOKENS;
        JBPermissionsData memory perms =
            JBPermissionsData({operator: address(suckerSepolia), projectId: 1, permissionIds: ids});

        vm.startPrank(multisig());
        jbPermissions().setPermissionsFor(multisig(), perms);
        launchAndConfigureSepoliaProject();
        vm.stopPrank();

        // Init Tempo fork.
        initTempoAndUtils();
        super.setUp();

        vm.stopPrank();

        vm.startPrank(address(0x1112222));
        suckerDeployerTempo =
            new JBCCIPSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        vm.stopPrank();

        // Tempo → Sepolia.
        suckerDeployerTempo.setChainSpecificConstants(
            CCIPHelper.ETH_SEP_ID,
            CCIPHelper.selectorOfChain(CCIPHelper.ETH_SEP_ID),
            ICCIPRouter(CCIPHelper.routerOfChain(block.chainid))
        );

        vm.startPrank(address(0x1112222));
        JBCCIPSucker singletonTempo = new JBCCIPSucker({
            deployer: suckerDeployerTempo,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
        vm.stopPrank();

        suckerDeployerTempo.configureSingleton(singletonTempo);
        suckerDeployerTempo.createForSender(1, "salty");

        vm.startPrank(multisig());
        launchAndConfigureTempoProject();
        jbPermissions().setPermissionsFor(multisig(), perms);
        vm.stopPrank();

        // Mock toRemoteFee on both forks. Registry is address(0) in tests.
        vm.selectFork(sepoliaFork);
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
        vm.selectFork(tempoFork);
        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
    }

    /// @notice Test ERC20 token bridge from Sepolia → Tempo using native ETH fees.
    function test_forkSepoliaToTempo_nativeFee() external {
        address rootSender = makeAddr("rootSender");
        address user = makeAddr("him");
        uint256 amountToSend = 100;
        uint256 maxCashedOut = amountToSend / 2;

        vm.selectFork(sepoliaFork);

        ccipBnM.drip(address(user));

        JBTokenMapping memory map = JBTokenMapping({
            localToken: address(ccipBnM),
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(address(ccipBnMTempo))))
        });

        vm.prank(multisig());
        suckerSepolia.mapToken(map);

        vm.startPrank(user);
        ccipBnM.approve(address(jbMultiTerminal()), amountToSend);
        uint256 projectTokenAmount = jbMultiTerminal().pay(1, address(ccipBnM), amountToSend, user, 0, "", "");
        IERC20(address(projectOneToken)).approve(address(suckerSepolia), projectTokenAmount);
        suckerSepolia.prepare(projectTokenAmount, bytes32(uint256(uint160(user))), maxCashedOut, address(ccipBnM));
        vm.stopPrank();

        // Native ETH fee on Sepolia side.
        vm.deal(rootSender, 1 ether);
        vm.prank(rootSender);
        suckerSepolia.toRemote{value: 1 ether}(address(ccipBnM));

        // Verify: outbox cleared, fees paid, some ETH refunded.
        uint256 outboxBalance = suckerSepolia.outboxOf(address(ccipBnM)).balance;
        assertEq(outboxBalance, 0, "Outbox should be cleared");
        assert(rootSender.balance < 1 ether);
        assert(rootSender.balance > 0);

        // Route the message to the Tempo fork.
        ccipLocalSimulatorFork.switchChainAndRouteMessage(tempoFork);

        // Verify the inbox got the root.
        bytes32 inboxRoot = suckerSepolia.inboxOf(address(ccipBnMTempo)).root;
        assertNotEq(inboxRoot, bytes32(0), "Inbox root should be set");
    }
}
