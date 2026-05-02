// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "@bananapus/core-v6/src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../../src/interfaces/IJBSuckerDeployer.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {JBOptimismSucker} from "../../src/JBOptimismSucker.sol";
import {JBOptimismSuckerDeployer} from "../../src/deployers/JBOptimismSuckerDeployer.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";
import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";
import {IOPMessenger} from "../../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../../src/interfaces/IOPStandardBridge.sol";

contract CodexPeerDeterminismTest is Test, TestBaseWorkflow, IERC721Receiver {
    JBSuckerRegistry internal registryA;
    JBSuckerRegistry internal registryB;
    JBOptimismSuckerDeployer internal deployer;
    uint256 internal projectId;

    function setUp() public override {
        super.setUp();

        registryA = new JBSuckerRegistry(jbDirectory(), jbPermissions(), address(this), address(0));
        registryB = new JBSuckerRegistry(jbDirectory(), jbPermissions(), address(this), address(0));

        deployer = new JBOptimismSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });
        deployer.setChainSpecificConstants(IOPMessenger(address(0x1001)), IOPStandardBridge(address(0x1002)));

        JBOptimismSucker singleton = new JBOptimismSucker({
            deployer: deployer,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: registryA,
            trustedForwarder: address(0)
        });
        deployer.configureSingleton(singleton);

        registryA.allowSuckerDeployer(address(deployer));
        registryB.allowSuckerDeployer(address(deployer));

        projectId = _launchProject();
        _grantRegistryPermissions(address(registryA));
        _grantRegistryPermissions(address(registryB));
    }

    function test_registryAddressChangesCloneAddressAndBreaksDefaultPeerAssumption() external {
        bytes32 salt = keccak256("same-user-salt");

        IJBSucker suckerA = _deployViaRegistry(registryA, salt);
        IJBSucker suckerB = _deployViaRegistry(registryB, salt);

        assertNotEq(address(suckerA), address(suckerB), "registry-dependent deployment should not match");
        assertEq(suckerA.peer(), bytes32(uint256(uint160(address(suckerA)))));
        assertEq(suckerB.peer(), bytes32(uint256(uint160(address(suckerB)))));
        assertTrue(suckerA.peer() != bytes32(uint256(uint160(address(suckerB)))));
        assertTrue(suckerB.peer() != bytes32(uint256(uint160(address(suckerA)))));
    }

    function _deployViaRegistry(JBSuckerRegistry registry, bytes32 salt) internal returns (IJBSucker sucker) {
        JBTokenMapping[] memory mappings = new JBTokenMapping[](1);
        mappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 300_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](1);
        configs[0] = JBSuckerDeployerConfig({
            deployer: IJBSuckerDeployer(address(deployer)), peer: bytes32(0), mappings: mappings
        });

        sucker = IJBSucker(registry.deploySuckersFor(projectId, salt, configs)[0]);
    }

    function _grantRegistryPermissions(address operator) internal {
        uint8[] memory permissionIds = new uint8[](2);
        permissionIds[0] = JBPermissionIds.DEPLOY_SUCKERS;
        permissionIds[1] = JBPermissionIds.MAP_SUCKER_TOKEN;

        jbPermissions()
            .setPermissionsFor(
                address(this),
                JBPermissionsData({operator: operator, projectId: uint64(projectId), permissionIds: permissionIds})
            );
    }

    function _launchProject() internal returns (uint256) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
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

        JBCurrencyAmount[] memory surplusAllowances = new JBCurrencyAmount[](1);
        surplusAllowances[0] = JBCurrencyAmount({amount: 5 ether, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        JBFundAccessLimitGroup[] memory fundAccess = new JBFundAccessLimitGroup[](1);
        fundAccess[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: new JBCurrencyAmount[](0),
            surplusAllowances: surplusAllowances
        });

        JBRulesetConfig[] memory rulesets = new JBRulesetConfig[](1);
        rulesets[0].mustStartAtOrAfter = 0;
        rulesets[0].duration = 0;
        rulesets[0].weight = 1000 * 10 ** 18;
        rulesets[0].weightCutPercent = 0;
        rulesets[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesets[0].metadata = metadata;
        rulesets[0].splitGroups = new JBSplitGroup[](0);
        rulesets[0].fundAccessLimitGroups = fundAccess;

        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](1);
        terminals[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContexts});

        return jbController()
            .launchProjectFor({
            owner: address(this),
            projectUri: "peer-determinism",
            rulesetConfigurations: rulesets,
            terminalConfigurations: terminals,
            memo: ""
        });
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
