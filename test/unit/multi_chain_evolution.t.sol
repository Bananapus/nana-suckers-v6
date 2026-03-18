// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../../src/interfaces/IJBSuckerDeployer.sol";

import "../../src/JBSucker.sol";
import "../../src/JBOptimismSucker.sol";
import "../../src/JBCCIPSucker.sol";
import "../../src/deployers/JBOptimismSuckerDeployer.sol";
import "../../src/deployers/JBCCIPSuckerDeployer.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckersPair} from "../../src/structs/JBSuckersPair.sol";
import {JBSuckerState} from "../../src/enums/JBSuckerState.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";

/// @title MultiChainEvolutionTest
/// @notice Tests that a project can start on one chain and incrementally expand to new chains over time.
///
/// Lifecycle story:
///   Phase 1: Project launches on Ethereum mainnet (no cross-chain).
///   Phase 2: Expand to Optimism — deploy OP sucker, map ETH (NATIVE_TOKEN -> NATIVE_TOKEN).
///   Phase 3: Add USDC bridging to Optimism — map USDC on the existing OP sucker.
///   Phase 4: Expand to Celo via CCIP — deploy CCIP sucker, map ETH as NATIVE_TOKEN -> celoETH (ERC-20).
///   Phase 5: Add USDC bridging to Celo — map USDC -> celoUSDC on the existing CCIP sucker.
///   Phase 6: Deprecate the OP sucker — Celo sucker continues working.
contract MultiChainEvolutionTest is Test, TestBaseWorkflow, IERC721Receiver {
    JBSuckerRegistry registry;
    uint256 projectId;

    // Mock bridge/messenger addresses for OP.
    IOPMessenger constant MOCK_OP_MESSENGER = IOPMessenger(address(0xA001));
    IOPStandardBridge constant MOCK_OP_BRIDGE = IOPStandardBridge(address(0xA002));

    // Mock CCIP router.
    address constant MOCK_CCIP_ROUTER_ADDR = address(0xA003);

    // Celo chain constants.
    uint256 constant CELO_CHAIN_ID = 42_220;
    uint64 constant CELO_CHAIN_SELECTOR = 1_311_226;

    // Token addresses representing tokens on remote chains.
    // On Celo, ETH is an ERC-20 (not native).
    address celoETH = address(0xCE10E001);
    // USDC addresses (local and remote).
    address localUSDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address opUSDC = address(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);
    address celoUSDC = address(0xef4229c8c3250C675F21BCefa42f58EfbfF6002a);

    // Deployers (set in setUp).
    JBOptimismSuckerDeployer opDeployer;
    JBCCIPSuckerDeployer ccipDeployer;

    function setUp() public override {
        super.setUp();

        vm.label(address(MOCK_OP_MESSENGER), "OP_MESSENGER");
        vm.label(address(MOCK_OP_BRIDGE), "OP_BRIDGE");
        vm.label(MOCK_CCIP_ROUTER_ADDR, "CCIP_ROUTER");

        // Etch code at mock addresses so Solidity's extcodesize checks pass.
        vm.etch(address(MOCK_OP_MESSENGER), hex"01");
        vm.etch(address(MOCK_OP_BRIDGE), hex"01");
        vm.etch(MOCK_CCIP_ROUTER_ADDR, hex"01");

        // Deploy the registry.
        registry = new JBSuckerRegistry(jbDirectory(), jbPermissions(), address(this), address(0));

        // --- Set up OP deployer ---
        opDeployer = new JBOptimismSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });
        opDeployer.setChainSpecificConstants(MOCK_OP_MESSENGER, MOCK_OP_BRIDGE);

        JBOptimismSucker opSingleton = new JBOptimismSucker({
            deployer: opDeployer,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            toRemoteFee: 0.001 ether,
            trustedForwarder: address(0)
        });
        opDeployer.configureSingleton(opSingleton);

        // --- Set up CCIP deployer ---
        ccipDeployer = new JBCCIPSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });
        ccipDeployer.setChainSpecificConstants({
            remoteChainId: CELO_CHAIN_ID,
            remoteChainSelector: CELO_CHAIN_SELECTOR,
            router: ICCIPRouter(MOCK_CCIP_ROUTER_ADDR)
        });

        JBCCIPSucker ccipSingleton = new JBCCIPSucker({
            deployer: ccipDeployer,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            toRemoteFee: 0.001 ether,
            trustedForwarder: address(0)
        });
        ccipDeployer.configureSingleton(ccipSingleton);

        // Allow both deployers in the registry.
        registry.allowSuckerDeployer(address(opDeployer));
        registry.allowSuckerDeployer(address(ccipDeployer));

        // --- Launch project ---
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
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

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = 1000 * 10 ** 18;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        projectId = jbController()
            .launchProjectFor({
                owner: address(this),
                projectUri: "myproject",
                rulesetConfigurations: rulesetConfigs,
                terminalConfigurations: terminalConfigs,
                memo: ""
            });
    }

    // =========================================================================
    // Full lifecycle: project starts on one chain, evolves to many
    // =========================================================================

    // Storage vars for lifecycle test (avoids stack-too-deep).
    IJBSucker _opSucker;
    IJBSucker _celoSucker;

    function test_lifecycle_projectExpandsAcrossChainsOverTime() public {
        // ---------------------------------------------------------------
        // Phase 1: Project exists only on Ethereum mainnet.
        //          No suckers deployed yet.
        // ---------------------------------------------------------------

        assertEq(registry.suckersOf(projectId).length, 0, "Phase 1: no suckers yet");

        // Grant the registry MAP_SUCKER_TOKEN permission so deploySuckersFor can call mapTokens.
        _grantMapPermission(address(registry));

        // ---------------------------------------------------------------
        // Phase 2: Expand to Optimism.
        //          Deploy OP sucker. Map NATIVE_TOKEN -> NATIVE_TOKEN
        //          (both chains have ETH as native).
        // ---------------------------------------------------------------
        {
            JBTokenMapping[] memory opMappings = new JBTokenMapping[](1);
            opMappings[0] = JBTokenMapping({
                localToken: JBConstants.NATIVE_TOKEN,
                minGas: 200_000,
                remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
            });

            JBSuckerDeployerConfig[] memory opConfig = new JBSuckerDeployerConfig[](1);
            opConfig[0] =
                JBSuckerDeployerConfig({deployer: IJBSuckerDeployer(address(opDeployer)), mappings: opMappings});

            _opSucker = IJBSucker(registry.deploySuckersFor(projectId, bytes32("op_salt"), opConfig)[0]);
        }

        assertEq(registry.suckersOf(projectId).length, 1, "Phase 2: one sucker (OP)");
        assertTrue(registry.isSuckerOf(projectId, address(_opSucker)), "Phase 2: OP sucker registered");

        JBRemoteToken memory opNative = _opSucker.remoteTokenFor(JBConstants.NATIVE_TOKEN);
        assertTrue(opNative.enabled, "Phase 2: native mapping enabled on OP");
        assertEq(
            opNative.addr, bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))), "Phase 2: native maps to native on OP"
        );

        // ---------------------------------------------------------------
        // Phase 3: Add USDC bridging to Optimism.
        //          Call mapToken on the existing OP sucker.
        // ---------------------------------------------------------------

        _opSucker.mapToken(
            JBTokenMapping({
                localToken: localUSDC, minGas: 200_000, remoteToken: bytes32(uint256(uint160(opUSDC)))
            })
        );

        assertTrue(_opSucker.remoteTokenFor(localUSDC).enabled, "Phase 3: USDC enabled on OP");
        assertEq(
            _opSucker.remoteTokenFor(localUSDC).addr, bytes32(uint256(uint160(opUSDC))), "Phase 3: USDC maps to opUSDC"
        );
        assertTrue(_opSucker.remoteTokenFor(JBConstants.NATIVE_TOKEN).enabled, "Phase 3: native still works");

        // ---------------------------------------------------------------
        // Phase 4: Expand to Celo via CCIP.
        //          Deploy CCIP sucker. Map NATIVE_TOKEN -> celoETH (ERC-20).
        //
        //          THIS IS THE KEY CROSS-CHAIN NATIVE TOKEN INTEROP CASE:
        //          On Ethereum, ETH is the native token (NATIVE_TOKEN).
        //          On Celo, ETH is an ERC-20 (celoETH address).
        //          The CCIP sucker allows this mapping because it wraps
        //          native ETH -> WETH for CCIP transport, and the receiving
        //          side processes celoETH as an ERC-20 (no unwrap).
        // ---------------------------------------------------------------
        {
            JBTokenMapping[] memory celoMappings = new JBTokenMapping[](1);
            celoMappings[0] = JBTokenMapping({
                localToken: JBConstants.NATIVE_TOKEN,
                minGas: 200_000,
                remoteToken: bytes32(uint256(uint160(celoETH))) // ERC-20 on Celo, NOT NATIVE_TOKEN
            });

            JBSuckerDeployerConfig[] memory celoConfig = new JBSuckerDeployerConfig[](1);
            celoConfig[0] =
                JBSuckerDeployerConfig({deployer: IJBSuckerDeployer(address(ccipDeployer)), mappings: celoMappings});

            _celoSucker = IJBSucker(registry.deploySuckersFor(projectId, bytes32("celo_salt"), celoConfig)[0]);
        }

        assertEq(registry.suckersOf(projectId).length, 2, "Phase 4: two suckers (OP + Celo)");
        assertTrue(registry.isSuckerOf(projectId, address(_celoSucker)), "Phase 4: Celo sucker registered");
        assertTrue(registry.isSuckerOf(projectId, address(_opSucker)), "Phase 4: OP sucker still registered");

        JBRemoteToken memory celoNative = _celoSucker.remoteTokenFor(JBConstants.NATIVE_TOKEN);
        assertTrue(celoNative.enabled, "Phase 4: native mapping enabled on Celo");
        assertEq(
            celoNative.addr, bytes32(uint256(uint160(celoETH))), "Phase 4: native maps to celoETH (ERC-20) on Celo"
        );
        assertEq(registry.suckerPairsOf(projectId).length, 2, "Phase 4: two sucker pairs");

        // ---------------------------------------------------------------
        // Phase 5: Add USDC bridging to Celo.
        //          Call mapToken on the existing CCIP sucker.
        // ---------------------------------------------------------------

        _celoSucker.mapToken(
            JBTokenMapping({
                localToken: localUSDC,
                minGas: 200_000,
                remoteToken: bytes32(uint256(uint160(celoUSDC)))
            })
        );

        assertTrue(_celoSucker.remoteTokenFor(localUSDC).enabled, "Phase 5: USDC enabled on Celo");
        assertEq(
            _celoSucker.remoteTokenFor(localUSDC).addr,
            bytes32(uint256(uint160(celoUSDC))),
            "Phase 5: USDC maps to celoUSDC"
        );

        // OP sucker is completely independent — its mappings unchanged.
        assertEq(
            _opSucker.remoteTokenFor(JBConstants.NATIVE_TOKEN).addr,
            bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            "Phase 5: OP native mapping unchanged"
        );
        assertEq(
            _opSucker.remoteTokenFor(localUSDC).addr,
            bytes32(uint256(uint160(opUSDC))),
            "Phase 5: OP USDC mapping unchanged"
        );

        // ---------------------------------------------------------------
        // Phase 6: Deprecate the OP sucker.
        //          The Celo sucker continues working.
        // ---------------------------------------------------------------

        uint40 deprecationTime = uint40(block.timestamp + 14 days);
        JBOptimismSucker(payable(address(_opSucker))).setDeprecation(deprecationTime);
        vm.warp(deprecationTime);

        assertEq(uint8(_opSucker.state()), uint8(JBSuckerState.DEPRECATED), "Phase 6: OP sucker deprecated");

        registry.removeDeprecatedSucker(projectId, address(_opSucker));
        assertEq(registry.suckersOf(projectId).length, 1, "Phase 6: only Celo sucker remains");

        assertEq(uint8(_celoSucker.state()), uint8(JBSuckerState.ENABLED), "Phase 6: Celo still enabled");
        assertTrue(
            _celoSucker.remoteTokenFor(JBConstants.NATIVE_TOKEN).enabled, "Phase 6: Celo native mapping still works"
        );
        assertEq(
            _celoSucker.remoteTokenFor(JBConstants.NATIVE_TOKEN).addr,
            bytes32(uint256(uint160(celoETH))),
            "Phase 6: Celo native still maps to celoETH"
        );
    }

    // =========================================================================
    // Focused: deploy suckers to multiple chains in one transaction
    // =========================================================================

    function test_canDeployToMultipleChainsAtOnce() public {
        _grantMapPermission(address(registry));

        // Deploy to both OP and Celo in a single deploySuckersFor call.
        JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](2);

        JBTokenMapping[] memory opMappings = new JBTokenMapping[](1);
        opMappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        JBTokenMapping[] memory celoMappings = new JBTokenMapping[](1);
        celoMappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(celoETH)))
        });

        configs[0] = JBSuckerDeployerConfig({deployer: IJBSuckerDeployer(address(opDeployer)), mappings: opMappings});
        configs[1] =
            JBSuckerDeployerConfig({deployer: IJBSuckerDeployer(address(ccipDeployer)), mappings: celoMappings});

        address[] memory suckers = registry.deploySuckersFor(projectId, bytes32("both"), configs);

        assertEq(suckers.length, 2, "Should deploy 2 suckers");
        assertEq(registry.suckersOf(projectId).length, 2, "Registry should track 2 suckers");

        // Verify each sucker has its own independent mapping.
        IJBSucker opSucker = IJBSucker(suckers[0]);
        IJBSucker celoSucker = IJBSucker(suckers[1]);

        assertEq(
            opSucker.remoteTokenFor(JBConstants.NATIVE_TOKEN).addr,
            bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            "OP: native -> native"
        );
        assertEq(
            celoSucker.remoteTokenFor(JBConstants.NATIVE_TOKEN).addr,
            bytes32(uint256(uint160(celoETH))),
            "Celo: native -> celoETH (ERC-20)"
        );
    }

    // =========================================================================
    // Focused: add tokens incrementally to an existing sucker
    // =========================================================================

    function test_canMapTokensIncrementallyToExistingSucker() public {
        _grantMapPermission(address(registry));

        // Deploy CCIP sucker with just native mapping.
        JBTokenMapping[] memory initialMappings = new JBTokenMapping[](1);
        initialMappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(celoETH)))
        });

        JBSuckerDeployerConfig[] memory config = new JBSuckerDeployerConfig[](1);
        config[0] =
            JBSuckerDeployerConfig({deployer: IJBSuckerDeployer(address(ccipDeployer)), mappings: initialMappings});

        address[] memory suckers = registry.deploySuckersFor(projectId, bytes32("incr"), config);
        IJBSucker sucker = IJBSucker(suckers[0]);

        // Initially: only native mapped.
        assertTrue(sucker.remoteTokenFor(JBConstants.NATIVE_TOKEN).enabled, "Native should be mapped");
        assertFalse(sucker.remoteTokenFor(localUSDC).enabled, "USDC should NOT be mapped yet");

        // Later: project owner adds USDC.
        sucker.mapToken(
            JBTokenMapping({
                localToken: localUSDC,
                minGas: 200_000,
                remoteToken: bytes32(uint256(uint160(celoUSDC)))
            })
        );

        // Now both are mapped.
        assertTrue(sucker.remoteTokenFor(JBConstants.NATIVE_TOKEN).enabled, "Native still mapped");
        assertTrue(sucker.remoteTokenFor(localUSDC).enabled, "USDC now mapped");
        assertEq(sucker.remoteTokenFor(localUSDC).addr, bytes32(uint256(uint160(celoUSDC))), "USDC maps to celoUSDC");
    }

    // =========================================================================
    // Focused: modifications to one sucker don't affect another
    // =========================================================================

    function test_suckerMappingsAreIndependent() public {
        _grantMapPermission(address(registry));

        // Deploy two suckers.
        JBTokenMapping[] memory nativeMappings = new JBTokenMapping[](1);
        nativeMappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        JBSuckerDeployerConfig[] memory opConfig = new JBSuckerDeployerConfig[](1);
        opConfig[0] =
            JBSuckerDeployerConfig({deployer: IJBSuckerDeployer(address(opDeployer)), mappings: nativeMappings});

        JBTokenMapping[] memory celoNativeMappings = new JBTokenMapping[](1);
        celoNativeMappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(celoETH)))
        });

        JBSuckerDeployerConfig[] memory celoConfig = new JBSuckerDeployerConfig[](1);
        celoConfig[0] =
            JBSuckerDeployerConfig({deployer: IJBSuckerDeployer(address(ccipDeployer)), mappings: celoNativeMappings});

        address[] memory opSuckers = registry.deploySuckersFor(projectId, bytes32("ind_op"), opConfig);
        address[] memory celoSuckers = registry.deploySuckersFor(projectId, bytes32("ind_celo"), celoConfig);

        IJBSucker opSucker = IJBSucker(opSuckers[0]);
        IJBSucker celoSucker = IJBSucker(celoSuckers[0]);

        // Map USDC only on the Celo sucker.
        celoSucker.mapToken(
            JBTokenMapping({
                localToken: localUSDC,
                minGas: 200_000,
                remoteToken: bytes32(uint256(uint160(celoUSDC)))
            })
        );

        // OP sucker should NOT have USDC mapped.
        assertFalse(opSucker.remoteTokenFor(localUSDC).enabled, "OP sucker should NOT have USDC");

        // Celo sucker should have USDC mapped.
        assertTrue(celoSucker.remoteTokenFor(localUSDC).enabled, "Celo sucker should have USDC");

        // Disable native on OP sucker.
        opSucker.mapToken(
            JBTokenMapping({
                localToken: JBConstants.NATIVE_TOKEN, minGas: 200_000, remoteToken: bytes32(0)
            })
        );

        // OP native disabled, Celo native unaffected.
        assertFalse(opSucker.remoteTokenFor(JBConstants.NATIVE_TOKEN).enabled, "OP native disabled");
        assertTrue(celoSucker.remoteTokenFor(JBConstants.NATIVE_TOKEN).enabled, "Celo native still enabled");
    }

    // =========================================================================
    // Focused: CCIP sucker accepts NATIVE -> ERC20, OP sucker rejects it
    // =========================================================================

    function test_nativeToERC20_acceptedOnCCIP_rejectedOnOP() public {
        _grantMapPermission(address(registry));

        // Deploy both suckers with just a placeholder native->native mapping.
        JBTokenMapping[] memory nativeMappings = new JBTokenMapping[](1);
        nativeMappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        JBSuckerDeployerConfig[] memory opConfig = new JBSuckerDeployerConfig[](1);
        opConfig[0] =
            JBSuckerDeployerConfig({deployer: IJBSuckerDeployer(address(opDeployer)), mappings: nativeMappings});
        address[] memory opSuckers = registry.deploySuckersFor(projectId, bytes32("natv_op"), opConfig);

        // CCIP sucker: deploy with NATIVE -> celoETH (ERC-20). Should succeed.
        JBTokenMapping[] memory celoEthMappings = new JBTokenMapping[](1);
        celoEthMappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(celoETH)))
        });

        JBSuckerDeployerConfig[] memory celoConfig = new JBSuckerDeployerConfig[](1);
        celoConfig[0] =
            JBSuckerDeployerConfig({deployer: IJBSuckerDeployer(address(ccipDeployer)), mappings: celoEthMappings});

        // This should succeed — CCIP allows NATIVE -> ERC-20.
        address[] memory celoSuckers = registry.deploySuckersFor(projectId, bytes32("natv_celo"), celoConfig);
        assertEq(
            IJBSucker(celoSuckers[0]).remoteTokenFor(JBConstants.NATIVE_TOKEN).addr,
            bytes32(uint256(uint160(celoETH))),
            "CCIP: NATIVE -> celoETH accepted"
        );

        // OP sucker: try to map NATIVE -> celoETH (ERC-20). Should REVERT.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSucker.JBSucker_InvalidNativeRemoteAddress.selector, bytes32(uint256(uint160(celoETH)))
            )
        );
        IJBSucker(opSuckers[0])
            .mapToken(
                JBTokenMapping({
                    localToken: JBConstants.NATIVE_TOKEN,
                    minGas: 200_000,
                    remoteToken: bytes32(uint256(uint160(celoETH)))
                        })
            );
    }

    // =========================================================================
    // Focused: can replace a deprecated sucker with a new one
    // =========================================================================

    function test_canReplaceSuckerAfterDeprecation() public {
        _grantMapPermission(address(registry));

        // Deploy initial OP sucker.
        JBTokenMapping[] memory mappings = new JBTokenMapping[](1);
        mappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        JBSuckerDeployerConfig[] memory config = new JBSuckerDeployerConfig[](1);
        config[0] = JBSuckerDeployerConfig({deployer: IJBSuckerDeployer(address(opDeployer)), mappings: mappings});

        address[] memory firstDeploy = registry.deploySuckersFor(projectId, bytes32("v1"), config);
        address oldSucker = firstDeploy[0];
        assertEq(registry.suckersOf(projectId).length, 1);

        // Deprecate it.
        uint40 deprecationTime = uint40(block.timestamp + 14 days);
        JBOptimismSucker(payable(oldSucker)).setDeprecation(deprecationTime);
        vm.warp(deprecationTime);
        assertEq(uint8(IJBSucker(oldSucker).state()), uint8(JBSuckerState.DEPRECATED));

        // Remove from registry.
        registry.removeDeprecatedSucker(projectId, oldSucker);
        assertEq(registry.suckersOf(projectId).length, 0, "Old sucker removed");

        // Deploy a replacement sucker with a new salt.
        address[] memory secondDeploy = registry.deploySuckersFor(projectId, bytes32("v2"), config);
        address newSucker = secondDeploy[0];

        assertEq(registry.suckersOf(projectId).length, 1, "New sucker deployed");
        assertTrue(registry.isSuckerOf(projectId, newSucker), "New sucker registered");
        assertFalse(registry.isSuckerOf(projectId, oldSucker), "Old sucker no longer registered");
        assertTrue(newSucker != oldSucker, "New sucker has different address");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _grantMapPermission(address operator) internal {
        uint8[] memory permissions = new uint8[](1);
        permissions[0] = JBPermissionIds.MAP_SUCKER_TOKEN;

        jbPermissions()
            .setPermissionsFor(
                address(this),
                JBPermissionsData({operator: operator, projectId: uint56(projectId), permissionIds: permissions})
            );
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
