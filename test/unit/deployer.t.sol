// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBSucker.sol";
import {IJBSuckerDeployer} from "../../src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/deployers/JBOptimismSuckerDeployer.sol";
import {JBOptimismSucker} from "../../src/JBOptimismSucker.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/deployers/JBBaseSuckerDeployer.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/deployers/JBCCIPSuckerDeployer.sol";
import {JBCCIPSucker} from "../../src/JBCCIPSucker.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/deployers/JBArbitrumSuckerDeployer.sol";
import {JBArbitrumSucker} from "../../src/JBArbitrumSucker.sol";

import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";

import {JBOptimismSuckerDeployer} from "../../src/deployers/JBOptimismSuckerDeployer.sol";
import {JBSuckerRegistry} from "./../../src/JBSuckerRegistry.sol";

contract DeployerTests is Test, TestBaseWorkflow, IERC721Receiver {
    JBSuckerRegistry registry;
    uint256 projectId;

    //*********************************************************************//
    // --------------------------- Setup --------------------------------- //
    //*********************************************************************//

    function setUp() public override {
        // Deploy JB.
        super.setUp();

        // Deploy the registry.
        registry = new JBSuckerRegistry(jbDirectory(), jbPermissions(), address(this), address(0));

        // Setup: terminal / project
        // Package up the limits for the given terminal.
        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
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

        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);

        // Specify a payout limit.
        JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](0);

        // Specify a surplus allowance.
        JBCurrencyAmount[] memory _surplusAllowances = new JBCurrencyAmount[](1);
        _surplusAllowances[0] =
            JBCurrencyAmount({amount: 5 * 10 ** 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: _payoutLimits,
            surplusAllowances: _surplusAllowances
        });

        // Package up the ruleset configuration.
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
        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);

        _tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        _terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokensToAccept});

        // Create a first project to collect fees.
        projectId = jbController()
            .launchProjectFor({
            owner: address(this),
            projectUri: "whatever",
            rulesetConfigurations: _rulesetConfigurations,
            terminalConfigurations: _terminalConfigurations, // Set terminals to receive fees.
            memo: ""
        });

        // Setup an erc20 for the project
        jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));
    }

    function _setupOptimismDeployer(
        IOPMessenger _opMessenger,
        IOPStandardBridge _opBridge
    )
        internal
        returns (IJBSuckerDeployer deployer)
    {
        vm.assume(address(_opMessenger) != address(0));
        vm.assume(address(_opBridge) != address(0));

        // forge-lint: disable-next-line(mixed-case-variable)
        JBOptimismSuckerDeployer OPDeployer = new JBOptimismSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });

        deployer = OPDeployer;
        OPDeployer.setChainSpecificConstants(_opMessenger, _opBridge);

        // Deploy the singleton.
        JBOptimismSucker sucker = new JBOptimismSucker({
            deployer: OPDeployer,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            prices: address(jbPrices()),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });

        // Set the singleton.
        OPDeployer.configureSingleton(sucker);

        assertEq(address(OPDeployer.opMessenger()), address(_opMessenger));
        assertEq(address(OPDeployer.opBridge()), address(_opBridge));
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function _setupCCIPDeployer(
        uint256 _remoteChainId,
        uint64 _remoteChainSelector,
        ICCIPRouter _ccipRouter
    )
        internal
        returns (IJBSuckerDeployer deployer)
    {
        // forge-lint: disable-next-line(mixed-case-variable)
        JBCCIPSuckerDeployer CCIPDeployer = new JBCCIPSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });

        deployer = CCIPDeployer;
        CCIPDeployer.setChainSpecificConstants({
            remoteChainId: _remoteChainId, remoteChainSelector: _remoteChainSelector, router: _ccipRouter
        });

        // Deploy the singleton.
        JBCCIPSucker sucker = new JBCCIPSucker({
            deployer: CCIPDeployer,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            prices: address(jbPrices()),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });

        // Set the singleton.
        CCIPDeployer.configureSingleton(sucker);

        assertEq(CCIPDeployer.ccipRemoteChainId(), _remoteChainId);
        assertEq(CCIPDeployer.ccipRemoteChainSelector(), _remoteChainSelector);
        assertEq(address(CCIPDeployer.ccipRouter()), address(_ccipRouter));
    }

    function _setupArbitrumDeployer(
        JBLayer _layer,
        IInbox _inbox,
        IArbGatewayRouter _gatewayRouter
    )
        internal
        returns (IJBSuckerDeployer deployer)
    {
        // forge-lint: disable-next-line(mixed-case-variable)
        JBArbitrumSuckerDeployer ARBDeployer = new JBArbitrumSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });

        deployer = ARBDeployer;
        ARBDeployer.setChainSpecificConstants(_layer, _inbox, _gatewayRouter);

        // Deploy the singleton.
        JBArbitrumSucker sucker = new JBArbitrumSucker({
            deployer: ARBDeployer,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            prices: address(jbPrices()),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });

        // Set the singleton.
        ARBDeployer.configureSingleton(sucker);

        assertEq(uint256(ARBDeployer.arbLayer()), uint256(_layer));
        assertEq(address(ARBDeployer.arbInbox()), address(_inbox));
        assertEq(address(ARBDeployer.arbGatewayRouter()), address(_gatewayRouter));
    }

    //*********************************************************************//
    // ------------------------ Variations ------------------------------- //
    //*********************************************************************//

    function testOPDeployer(IOPMessenger _opMessenger, IOPStandardBridge _opBridge) public {
        IJBSuckerDeployer deployer = _setupOptimismDeployer(_opMessenger, _opBridge);
        IJBSucker sucker = _deployDirectly(deployer, projectId, bytes32(0));
        _assertValidSucker(sucker, projectId);
        _assertOptimismSucker(deployer, sucker);
    }

    function testOPDeployerThroughRegistry(IOPMessenger _opMessenger, IOPStandardBridge _opBridge) public {
        IJBSuckerDeployer deployer = _addToRegistry(_setupOptimismDeployer(_opMessenger, _opBridge));
        _allowMapping(projectId, address(registry));
        IJBSucker sucker = _deployThroughRegistry(deployer, projectId, bytes32(0));
        _assertRegistered(_assertValidSucker(sucker, projectId));
        _assertOptimismSucker(deployer, sucker);
    }

    function testCCIPDeployer(uint256 _remoteChainId, uint64 _remoteChainSelector, ICCIPRouter _ccipRouter) public {
        // Ensure that the id/selector are set.
        vm.assume(_remoteChainSelector != 0);
        vm.assume(_remoteChainId != 0);

        // Ensure that its not a precompile.
        vm.assume(uint160(address(_ccipRouter)) > 100);

        // Exclude deployed contracts to prevent vm.etch from overwriting them.
        _assumeNotDeployed(address(_ccipRouter));

        // We have a sanity check that requires code to be at the router address.
        vm.etch(address(_ccipRouter), "0x1");

        IJBSuckerDeployer deployer = _setupCCIPDeployer(_remoteChainId, _remoteChainSelector, _ccipRouter);
        IJBSucker sucker = _deployDirectly(deployer, projectId, bytes32(0));
        _assertValidSucker(sucker, projectId);
        _assertCCIPSucker(deployer, sucker);
    }

    function testCCIPDeployerThroughRegistry(
        uint256 _remoteChainId,
        uint64 _remoteChainSelector,
        ICCIPRouter _ccipRouter
    )
        public
    {
        // Ensure that the id/selector are set.
        vm.assume(_remoteChainSelector != 0);
        vm.assume(_remoteChainId != 0);

        // Ensure that its not a precompile.
        vm.assume(uint160(address(_ccipRouter)) > 100);

        // Exclude deployed contracts to prevent vm.etch from overwriting them.
        _assumeNotDeployed(address(_ccipRouter));

        // We have a sanity check that requires code to be at the router address.
        vm.etch(address(_ccipRouter), "0x1");

        _allowMapping(projectId, address(registry));
        IJBSuckerDeployer deployer =
            _addToRegistry(_setupCCIPDeployer(_remoteChainId, _remoteChainSelector, _ccipRouter));
        IJBSucker sucker = _deployThroughRegistry(deployer, projectId, bytes32(0));
        _assertRegistered(_assertValidSucker(sucker, projectId));
        _assertCCIPSucker(deployer, sucker);
    }

    function testArbDeployer(bool _layer, IInbox _inbox, IArbGatewayRouter _gatewayRouter) public {
        // Gateway router always required; inbox required on L1 only.
        vm.assume(_gatewayRouter != IArbGatewayRouter(address(0)));
        if (_layer) vm.assume(_inbox != IInbox(address(0)));

        IJBSuckerDeployer deployer = _setupArbitrumDeployer(_layer ? JBLayer.L1 : JBLayer.L2, _inbox, _gatewayRouter);
        IJBSucker sucker = _deployDirectly(deployer, projectId, bytes32(0));
        _assertValidSucker(sucker, projectId);
        _assertArbSucker(deployer, sucker);
    }

    function testArbDeployerThroughRegistry(bool _layer, IInbox _inbox, IArbGatewayRouter _gatewayRouter) public {
        // Gateway router always required; inbox required on L1 only.
        vm.assume(_gatewayRouter != IArbGatewayRouter(address(0)));
        if (_layer) vm.assume(_inbox != IInbox(address(0)));

        _allowMapping(projectId, address(registry));
        IJBSuckerDeployer deployer =
            _addToRegistry(_setupArbitrumDeployer(_layer ? JBLayer.L1 : JBLayer.L2, _inbox, _gatewayRouter));
        IJBSucker sucker = _deployThroughRegistry(deployer, projectId, bytes32(0));
        _assertRegistered(_assertValidSucker(sucker, projectId));
        _assertArbSucker(deployer, sucker);
    }

    /// @notice L2 deployment with inbox=address(0) should succeed — inbox is only needed on L1.
    function testArbDeployerL2WithZeroInbox(IArbGatewayRouter _gatewayRouter) public {
        vm.assume(_gatewayRouter != IArbGatewayRouter(address(0)));

        IJBSuckerDeployer deployer = _setupArbitrumDeployer(JBLayer.L2, IInbox(address(0)), _gatewayRouter);
        IJBSucker sucker = _deployDirectly(deployer, projectId, bytes32(0));
        _assertValidSucker(sucker, projectId);
        _assertArbSucker(deployer, sucker);
    }

    /// @notice L1 deployment must revert when inbox is address(0).
    function testArbDeployerL1RevertsWithZeroInbox(IArbGatewayRouter _gatewayRouter) public {
        vm.assume(_gatewayRouter != IArbGatewayRouter(address(0)));

        // forge-lint: disable-next-line(mixed-case-variable)
        JBArbitrumSuckerDeployer ARBDeployer = new JBArbitrumSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });

        vm.expectRevert(JBSuckerDeployer.JBSuckerDeployer_InvalidLayerSpecificConfiguration.selector);
        ARBDeployer.setChainSpecificConstants(JBLayer.L1, IInbox(address(0)), _gatewayRouter);
    }

    /// @notice L2 deployment must revert when gateway router is address(0).
    function testArbDeployerL2RevertsWithZeroGateway() public {
        // forge-lint: disable-next-line(mixed-case-variable)
        JBArbitrumSuckerDeployer ARBDeployer = new JBArbitrumSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });

        vm.expectRevert(JBSuckerDeployer.JBSuckerDeployer_InvalidLayerSpecificConfiguration.selector);
        ARBDeployer.setChainSpecificConstants(JBLayer.L2, IInbox(address(0)), IArbGatewayRouter(address(0)));
    }

    //*********************************************************************//
    // ------------------------ Utilities ------------------------------- //
    //*********************************************************************//

    function _addToRegistry(IJBSuckerDeployer deployer) internal returns (IJBSuckerDeployer) {
        registry.allowSuckerDeployer(address(deployer));

        // lets us chain calls.
        return deployer;
    }

    function _allowMapping(uint256 _projectId, address beneficiary) internal {
        uint8[] memory permissions = new uint8[](1);
        permissions[0] = JBPermissionIds.MAP_SUCKER_TOKEN;

        jbPermissions()
            .setPermissionsFor(
                address(this),
                // forge-lint: disable-next-line(unsafe-typecast)
                JBPermissionsData({operator: beneficiary, projectId: uint56(_projectId), permissionIds: permissions})
            );
    }

    function _allowDeploying(uint256 _projectId, address beneficiary) internal {
        uint8[] memory permissions = new uint8[](1);
        permissions[0] = JBPermissionIds.DEPLOY_SUCKERS;

        jbPermissions()
            .setPermissionsFor(
                address(this),
                // forge-lint: disable-next-line(unsafe-typecast)
                JBPermissionsData({operator: beneficiary, projectId: uint56(_projectId), permissionIds: permissions})
            );
    }

    function _deployDirectly(IJBSuckerDeployer deployer, uint256 _projectId, bytes32 salt)
        internal
        returns (IJBSucker)
    {
        return deployer.createForSender(_projectId, salt, bytes32(0));
    }

    function _deployThroughRegistry(
        IJBSuckerDeployer deployer,
        uint256 _projectId,
        bytes32 salt
    )
        internal
        returns (IJBSucker)
    {
        JBTokenMapping[] memory mappings = new JBTokenMapping[](1);
        mappings[0] = JBTokenMapping({
            localToken: address(JBConstants.NATIVE_TOKEN),
            minGas: 300_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        JBSuckerDeployerConfig[] memory configurations = new JBSuckerDeployerConfig[](1);
        configurations[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: mappings});

        return IJBSucker(registry.deploySuckersFor(_projectId, salt, configurations)[0]);
    }

    /// @notice Exclude addresses of contracts deployed during setUp to prevent vm.etch from overwriting them.
    function _assumeNotDeployed(address addr) internal view {
        vm.assume(addr != address(jbPermissions()));
        vm.assume(addr != address(jbDirectory()));
        vm.assume(addr != address(jbProjects()));
        vm.assume(addr != address(jbController()));
        vm.assume(addr != address(jbMultiTerminal()));
        vm.assume(addr != address(jbTokens()));
        vm.assume(addr != address(jbSplits()));
        vm.assume(addr != address(jbRulesets()));
        vm.assume(addr != address(jbTerminalStore()));
        vm.assume(addr != address(registry));
    }

    //*********************************************************************//
    // -------------------------- Asserts -------------------------------- //
    //*********************************************************************//

    function _assertValidSucker(IJBSucker sucker, uint256 _projectId) internal view returns (IJBSucker) {
        assertEq(sucker.projectId(), _projectId);
        assertEq(address(sucker.DIRECTORY()), address(jbDirectory()));
        assertEq(address(sucker.TOKENS()), address(jbTokens()));
        assertEq(sucker.peer(), bytes32(uint256(uint160(address(sucker)))));
        assertEq(uint8(sucker.state()), uint8(JBSuckerState.ENABLED));

        return sucker;
    }

    function _assertRegistered(IJBSucker sucker) internal view returns (IJBSucker) {
        uint256 _projectId = sucker.projectId();
        assert(registry.isSuckerOf(_projectId, address(sucker)));
        assertEq(address(registry.suckersOf(_projectId)[0]), address(sucker));
        return sucker;
    }

    function _assertOptimismSucker(IJBSuckerDeployer deployer, IJBSucker sucker) internal view returns (IJBSucker) {
        assertEq(
            address(JBOptimismSuckerDeployer(address(deployer)).opMessenger()),
            address(JBOptimismSucker(payable(address(sucker))).OPMESSENGER())
        );
        assertEq(
            address(JBOptimismSuckerDeployer(address(deployer)).opBridge()),
            address(JBOptimismSucker(payable(address(sucker))).OPBRIDGE())
        );

        return sucker;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function _assertCCIPSucker(IJBSuckerDeployer deployer, IJBSucker sucker) internal view returns (IJBSucker) {
        assertEq(
            address(JBCCIPSuckerDeployer(address(deployer)).ccipRouter()),
            address(JBCCIPSucker(payable(address(sucker))).CCIP_ROUTER())
        );

        assertEq(
            JBCCIPSuckerDeployer(address(deployer)).ccipRemoteChainId(),
            JBCCIPSucker(payable(address(sucker))).REMOTE_CHAIN_ID()
        );

        assertEq(
            JBCCIPSuckerDeployer(address(deployer)).ccipRemoteChainSelector(),
            JBCCIPSucker(payable(address(sucker))).REMOTE_CHAIN_SELECTOR()
        );
        return sucker;
    }

    function _assertArbSucker(IJBSuckerDeployer deployer, IJBSucker sucker) internal view returns (IJBSucker) {
        assertEq(
            uint256(JBArbitrumSuckerDeployer(address(deployer)).arbLayer()),
            uint256(JBArbitrumSucker(payable(address(sucker))).LAYER())
        );
        assertEq(
            address(JBArbitrumSuckerDeployer(address(deployer)).arbInbox()),
            address(JBArbitrumSucker(payable(address(sucker))).ARBINBOX())
        );
        assertEq(
            address(JBArbitrumSuckerDeployer(address(deployer)).arbGatewayRouter()),
            address(JBArbitrumSucker(payable(address(sucker))).GATEWAYROUTER())
        );
        return sucker;
    }

    /// @notice Deploying two suckers with the same peer chain ID should revert.
    function testDuplicatePeerChainReverts(ICCIPRouter _ccipRouter) public {
        vm.assume(uint160(address(_ccipRouter)) > 100);
        _assumeNotDeployed(address(_ccipRouter));
        vm.etch(address(_ccipRouter), "0x1");

        uint256 remoteChainId = 10;
        uint64 remoteSelector = 1;

        _allowMapping(projectId, address(registry));

        // Deploy the first sucker targeting chain 10.
        IJBSuckerDeployer deployer1 = _addToRegistry(_setupCCIPDeployer(remoteChainId, remoteSelector, _ccipRouter));
        _deployThroughRegistry(deployer1, projectId, bytes32("salt1"));

        // Deploy a second sucker also targeting chain 10 — should revert.
        IJBSuckerDeployer deployer2 = _addToRegistry(_setupCCIPDeployer(remoteChainId, remoteSelector + 1, _ccipRouter));

        JBTokenMapping[] memory mappings2 = new JBTokenMapping[](1);
        mappings2[0] = JBTokenMapping({
            localToken: address(JBConstants.NATIVE_TOKEN),
            minGas: 300_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });
        JBSuckerDeployerConfig[] memory configs2 = new JBSuckerDeployerConfig[](1);
        configs2[0] = JBSuckerDeployerConfig({deployer: deployer2, peer: bytes32(0), mappings: mappings2});

        vm.expectRevert(
            abi.encodeWithSelector(
                JBSuckerRegistry.JBSuckerRegistry_DuplicatePeerChain.selector, projectId, remoteChainId
            )
        );
        registry.deploySuckersFor(projectId, bytes32("salt2"), configs2);
    }

    /// @notice After deprecating and removing a sucker, a new sucker to the same peer chain should succeed.
    function testDuplicatePeerChainAllowedAfterDeprecation(ICCIPRouter _ccipRouter) public {
        vm.assume(uint160(address(_ccipRouter)) > 100);
        _assumeNotDeployed(address(_ccipRouter));
        vm.etch(address(_ccipRouter), "0x1");

        uint256 remoteChainId = 10;
        uint64 remoteSelector = 1;

        _allowMapping(projectId, address(registry));

        // Deploy the first sucker.
        IJBSuckerDeployer deployer = _addToRegistry(_setupCCIPDeployer(remoteChainId, remoteSelector, _ccipRouter));
        IJBSucker sucker = _deployThroughRegistry(deployer, projectId, bytes32("salt1"));
        assertTrue(registry.isSuckerOf(projectId, address(sucker)));

        // Deprecate and remove it.
        JBSucker(payable(address(sucker))).setDeprecation(uint40(block.timestamp + 14 days + 1));
        vm.warp(block.timestamp + 14 days + 1);
        registry.removeDeprecatedSucker(projectId, address(sucker));

        // Deploy a replacement to the same peer chain — should succeed.
        IJBSuckerDeployer deployer2 = _addToRegistry(_setupCCIPDeployer(remoteChainId, remoteSelector + 1, _ccipRouter));
        IJBSucker sucker2 = _deployThroughRegistry(deployer2, projectId, bytes32("salt2"));
        assertTrue(registry.isSuckerOf(projectId, address(sucker2)));
    }

    // ------------------------------------------------------------------
    // Remote aggregate view tests
    // ------------------------------------------------------------------

    /// @notice remoteTotalSupplyOf sums peerChainTotalSupply across active suckers.
    function testRemoteTotalSupplyOf(ICCIPRouter _ccipRouter) public {
        vm.assume(uint160(address(_ccipRouter)) > 100);
        _assumeNotDeployed(address(_ccipRouter));
        vm.etch(address(_ccipRouter), "0x1");

        _allowMapping(projectId, address(registry));

        // Deploy two suckers to different chains.
        IJBSuckerDeployer deployer1 = _addToRegistry(_setupCCIPDeployer(10, 1, _ccipRouter));
        IJBSucker sucker1 = _deployThroughRegistry(deployer1, projectId, bytes32("salt1"));

        IJBSuckerDeployer deployer2 = _addToRegistry(_setupCCIPDeployer(42_161, 2, _ccipRouter));
        IJBSucker sucker2 = _deployThroughRegistry(deployer2, projectId, bytes32("salt2"));

        // Mock peerChainTotalSupply on each sucker.
        vm.mockCall(address(sucker1), abi.encodeCall(IJBSucker.peerChainTotalSupply, ()), abi.encode(100e18));
        vm.mockCall(address(sucker2), abi.encodeCall(IJBSucker.peerChainTotalSupply, ()), abi.encode(250e18));

        assertEq(registry.remoteTotalSupplyOf(projectId), 350e18);
    }

    /// @notice remoteBalanceOf sums peerChainBalanceOf across active suckers.
    function testRemoteBalanceOf(ICCIPRouter _ccipRouter) public {
        vm.assume(uint160(address(_ccipRouter)) > 100);
        _assumeNotDeployed(address(_ccipRouter));
        vm.etch(address(_ccipRouter), "0x1");

        _allowMapping(projectId, address(registry));

        IJBSuckerDeployer deployer1 = _addToRegistry(_setupCCIPDeployer(10, 1, _ccipRouter));
        IJBSucker sucker1 = _deployThroughRegistry(deployer1, projectId, bytes32("salt1"));

        IJBSuckerDeployer deployer2 = _addToRegistry(_setupCCIPDeployer(42_161, 2, _ccipRouter));
        IJBSucker sucker2 = _deployThroughRegistry(deployer2, projectId, bytes32("salt2"));

        uint256 ethCurrency = uint256(uint160(JBConstants.NATIVE_TOKEN));

        // Mock peerChainBalanceOf on each sucker.
        vm.mockCall(
            address(sucker1),
            abi.encodeCall(IJBSucker.peerChainBalanceOf, (18, ethCurrency)),
            abi.encode(JBDenominatedAmount({value: 5e18, currency: uint32(ethCurrency), decimals: 18}))
        );
        vm.mockCall(
            address(sucker2),
            abi.encodeCall(IJBSucker.peerChainBalanceOf, (18, ethCurrency)),
            abi.encode(JBDenominatedAmount({value: 3e18, currency: uint32(ethCurrency), decimals: 18}))
        );

        assertEq(registry.remoteBalanceOf(projectId, 18, ethCurrency), 8e18);
    }

    /// @notice remoteSurplusOf sums peerChainSurplusOf across active suckers.
    function testRemoteSurplusOf(ICCIPRouter _ccipRouter) public {
        vm.assume(uint160(address(_ccipRouter)) > 100);
        _assumeNotDeployed(address(_ccipRouter));
        vm.etch(address(_ccipRouter), "0x1");

        _allowMapping(projectId, address(registry));

        IJBSuckerDeployer deployer1 = _addToRegistry(_setupCCIPDeployer(10, 1, _ccipRouter));
        IJBSucker sucker1 = _deployThroughRegistry(deployer1, projectId, bytes32("salt1"));

        IJBSuckerDeployer deployer2 = _addToRegistry(_setupCCIPDeployer(42_161, 2, _ccipRouter));
        IJBSucker sucker2 = _deployThroughRegistry(deployer2, projectId, bytes32("salt2"));

        uint256 ethCurrency = uint256(uint160(JBConstants.NATIVE_TOKEN));

        // Mock peerChainSurplusOf on each sucker.
        vm.mockCall(
            address(sucker1),
            abi.encodeCall(IJBSucker.peerChainSurplusOf, (18, ethCurrency)),
            abi.encode(JBDenominatedAmount({value: 10e18, currency: uint32(ethCurrency), decimals: 18}))
        );
        vm.mockCall(
            address(sucker2),
            abi.encodeCall(IJBSucker.peerChainSurplusOf, (18, ethCurrency)),
            abi.encode(JBDenominatedAmount({value: 7e18, currency: uint32(ethCurrency), decimals: 18}))
        );

        assertEq(registry.remoteSurplusOf(projectId, 18, ethCurrency), 17e18);
    }

    /// @notice Remote views return 0 for a project with no suckers.
    function testRemoteViewsZeroWithNoSuckers() public view {
        assertEq(registry.remoteTotalSupplyOf(projectId), 0);
        assertEq(registry.remoteBalanceOf(projectId, 18, uint256(uint160(JBConstants.NATIVE_TOKEN))), 0);
        assertEq(registry.remoteSurplusOf(projectId, 18, uint256(uint160(JBConstants.NATIVE_TOKEN))), 0);
    }

    /// @notice Deprecated suckers are included in aggregate views so their supply
    /// is not hidden from downstream consumers during migration windows.
    function testRemoteViewsIncludeDeprecatedSuckers(ICCIPRouter _ccipRouter) public {
        vm.assume(uint160(address(_ccipRouter)) > 100);
        _assumeNotDeployed(address(_ccipRouter));
        vm.etch(address(_ccipRouter), "0x1");

        _allowMapping(projectId, address(registry));

        IJBSuckerDeployer deployer1 = _addToRegistry(_setupCCIPDeployer(10, 1, _ccipRouter));
        IJBSucker sucker1 = _deployThroughRegistry(deployer1, projectId, bytes32("salt1"));

        // Mock peerChainTotalSupply.
        vm.mockCall(address(sucker1), abi.encodeCall(IJBSucker.peerChainTotalSupply, ()), abi.encode(100e18));

        // Before deprecation: 100e18.
        assertEq(registry.remoteTotalSupplyOf(projectId), 100e18);

        // Deprecate and remove.
        JBSucker(payable(address(sucker1))).setDeprecation(uint40(block.timestamp + 14 days + 1));
        vm.warp(block.timestamp + 14 days + 1);
        registry.removeDeprecatedSucker(projectId, address(sucker1));

        // After deprecation: supply is still visible (deprecated sucker inclusion fix).
        assertEq(registry.remoteTotalSupplyOf(projectId), 100e18);
    }

    /// @notice Remote views silently skip suckers that revert.
    function testRemoteViewsSkipRevertingSuckers(ICCIPRouter _ccipRouter) public {
        vm.assume(uint160(address(_ccipRouter)) > 100);
        _assumeNotDeployed(address(_ccipRouter));
        vm.etch(address(_ccipRouter), "0x1");

        _allowMapping(projectId, address(registry));

        // Deploy two suckers.
        IJBSuckerDeployer deployer1 = _addToRegistry(_setupCCIPDeployer(10, 1, _ccipRouter));
        IJBSucker sucker1 = _deployThroughRegistry(deployer1, projectId, bytes32("salt1"));

        IJBSuckerDeployer deployer2 = _addToRegistry(_setupCCIPDeployer(42_161, 2, _ccipRouter));
        IJBSucker sucker2 = _deployThroughRegistry(deployer2, projectId, bytes32("salt2"));

        // sucker1 returns 100e18, sucker2 reverts.
        vm.mockCall(address(sucker1), abi.encodeCall(IJBSucker.peerChainTotalSupply, ()), abi.encode(100e18));
        vm.mockCallRevert(address(sucker2), abi.encodeCall(IJBSucker.peerChainTotalSupply, ()), "boom");

        // Should still return 100e18 (sucker2's revert is silently skipped).
        assertEq(registry.remoteTotalSupplyOf(projectId), 100e18);
    }

    /// @notice This function is called when we create a JB project.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
