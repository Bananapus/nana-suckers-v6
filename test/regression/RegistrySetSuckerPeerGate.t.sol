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
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
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

/// @notice Regression test for the explicit-peer permission gate in `JBSuckerRegistry.deploySuckersFor`.
/// @dev Before the fix, any caller with `DEPLOY_SUCKERS` could pass an arbitrary `configuration.peer`. That peer
/// gets to deliver outbox roots and mint project tokens via the new sucker, so an ops automation operator with
/// the narrower deploy permission could quietly register an attacker-controlled peer. The fix requires the
/// stricter `SET_SUCKER_PEER` permission whenever `peer` is nonzero; only `bytes32(0)` keeps the sucker's
/// deterministic same-address peer behavior.
contract RegistrySetSuckerPeerGateTest is Test, TestBaseWorkflow, IERC721Receiver {
    address internal constant MESSENGER = address(0x1001);

    JBSuckerRegistry internal registry;
    JBOptimismSuckerDeployer internal deployer;

    address internal projectOwner;
    address internal opsOperator;
    address internal peerManagerOperator;
    uint256 internal projectId;

    function setUp() public override {
        vm.chainId(10);
        super.setUp();

        projectOwner = address(this);
        opsOperator = makeAddr("opsOperator");
        peerManagerOperator = makeAddr("peerManagerOperator");

        registry = new JBSuckerRegistry({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            prices: jbPrices(),
            initialOwner: address(this),
            trustedForwarder: address(0)
        });

        deployer = new JBOptimismSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });
        deployer.setChainSpecificConstants({
            messenger: IOPMessenger(MESSENGER), bridge: IOPStandardBridge(address(0x1002))
        });

        JBOptimismSucker singleton = new JBOptimismSucker({
            deployer: deployer,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: registry,
            trustedForwarder: address(0)
        });
        deployer.configureSingleton(singleton);

        registry.allowSuckerDeployer(address(deployer));
        registry.allowTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            remoteChainId: 1,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        projectId = _launchProject();

        // ops operator: only DEPLOY_SUCKERS + MAP_SUCKER_TOKEN (no SET_SUCKER_PEER).
        _grantOperator({
            operator: opsOperator, ids: _ids({a: JBPermissionIds.DEPLOY_SUCKERS, b: JBPermissionIds.MAP_SUCKER_TOKEN})
        });

        // peer-manager operator: DEPLOY_SUCKERS + MAP_SUCKER_TOKEN + SET_SUCKER_PEER.
        uint8[] memory peerIds = new uint8[](3);
        peerIds[0] = JBPermissionIds.DEPLOY_SUCKERS;
        peerIds[1] = JBPermissionIds.MAP_SUCKER_TOKEN;
        peerIds[2] = JBPermissionIds.SET_SUCKER_PEER;
        _grantOperator({operator: peerManagerOperator, ids: peerIds});
    }

    /// @notice Operator with only `DEPLOY_SUCKERS` cannot register a non-symmetric explicit peer.
    /// @dev Before the fix, this call would succeed and a malicious operator could plant a bogus peer that has
    /// authority to deliver outbox roots and mint project tokens. The gate now checks `SET_SUCKER_PEER` against
    /// the project owner, not the caller.
    function test_explicitPeer_revertsWhenOperatorLacksSetSuckerPeer() external {
        bytes32 attackerPeer = bytes32(uint256(uint160(makeAddr("attackerPeer"))));
        JBSuckerDeployerConfig[] memory configs = _configsWithPeer(attackerPeer);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                projectOwner,
                opsOperator,
                projectId,
                JBPermissionIds.SET_SUCKER_PEER
            )
        );
        vm.prank(opsOperator);
        registry.deploySuckersFor({projectId: projectId, salt: keccak256("ops-explicit"), configurations: configs});
    }

    /// @notice Operator with both `DEPLOY_SUCKERS` and `SET_SUCKER_PEER` can register a non-symmetric explicit
    /// peer. The gate authorizes; the rest of the deploy path runs to completion.
    function test_explicitPeer_succeedsWhenOperatorHasSetSuckerPeer() external {
        bytes32 explicitPeer = bytes32(uint256(uint160(makeAddr("explicitPeer"))));
        JBSuckerDeployerConfig[] memory configs = _configsWithPeer(explicitPeer);

        vm.prank(peerManagerOperator);
        address[] memory suckers =
            registry.deploySuckersFor({projectId: projectId, salt: keccak256("peer-mgr"), configurations: configs});

        assertEq(suckers.length, 1);
        assertEq(IJBSucker(suckers[0]).peer(), explicitPeer, "peer should equal the explicit override");
    }

    /// @notice Symmetric default (peer == bytes32(0)) is unaffected: the narrower `DEPLOY_SUCKERS` is enough.
    /// @dev This pins the boundary condition. The gate is for non-symmetric peers only.
    function test_defaultPeer_doesNotRequireSetSuckerPeer() external {
        JBSuckerDeployerConfig[] memory configs = _configsWithPeer(bytes32(0));

        vm.prank(opsOperator);
        address[] memory suckers =
            registry.deploySuckersFor({projectId: projectId, salt: keccak256("ops-default"), configurations: configs});

        assertEq(suckers.length, 1);
        // The deployer fills the default peer with the deterministic self-address; assert it isn't zero.
        assertNotEq(IJBSucker(suckers[0]).peer(), bytes32(0), "default peer should resolve to a real address");
    }

    /// @notice The registry address is still an explicit peer override; only `bytes32(0)` means default.
    function test_explicitPeerEqualToRegistry_revertsWhenOperatorLacksSetSuckerPeer() external {
        // The registry is not the sucker clone. If this nonzero value were exempt, an ops operator could install it
        // as the remote message authority without the permission intended for peer selection.
        bytes32 registryPeer = bytes32(uint256(uint160(address(registry))));
        JBSuckerDeployerConfig[] memory configs = _configsWithPeer(registryPeer);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                projectOwner,
                opsOperator,
                projectId,
                JBPermissionIds.SET_SUCKER_PEER
            )
        );
        vm.prank(opsOperator);
        registry.deploySuckersFor({projectId: projectId, salt: keccak256("ops-registry"), configurations: configs});
    }

    /// @notice A peer manager can still intentionally set the registry address if that is truly desired.
    function test_explicitPeerEqualToRegistry_succeedsWhenOperatorHasSetSuckerPeer() external {
        // This confirms the change is authorization-only: nonzero peers are still supported once explicitly approved.
        bytes32 registryPeer = bytes32(uint256(uint160(address(registry))));
        JBSuckerDeployerConfig[] memory configs = _configsWithPeer(registryPeer);

        vm.prank(peerManagerOperator);
        address[] memory suckers = registry.deploySuckersFor({
            projectId: projectId, salt: keccak256("peer-mgr-registry"), configurations: configs
        });

        assertEq(suckers.length, 1);
        assertEq(IJBSucker(suckers[0]).peer(), registryPeer, "approved explicit peer should be stored");
    }

    function _configsWithPeer(bytes32 peer) internal view returns (JBSuckerDeployerConfig[] memory configs) {
        JBTokenMapping[] memory mappings = new JBTokenMapping[](1);
        mappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 300_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        configs = new JBSuckerDeployerConfig[](1);
        configs[0] =
            JBSuckerDeployerConfig({deployer: IJBSuckerDeployer(address(deployer)), peer: peer, mappings: mappings});
    }

    function _ids(uint8 a, uint8 b) internal pure returns (uint8[] memory ids) {
        ids = new uint8[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _grantOperator(address operator, uint8[] memory ids) internal {
        jbPermissions()
            .setPermissionsFor({
            account: projectOwner,
            // forge-lint: disable-next-line(unsafe-typecast)
            permissionsData: JBPermissionsData({operator: operator, projectId: uint64(projectId), permissionIds: ids})
        });
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
            scopeCashOutsToLocalBalances: true,
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
            owner: projectOwner,
            projectUri: "registry-set-sucker-peer-gate",
            rulesetConfigurations: rulesets,
            terminalConfigurations: terminals,
            memo: ""
        });
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
