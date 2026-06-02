// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

import {IOPMessenger} from "../../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../../src/interfaces/IOPStandardBridge.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../../src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBOptimismSucker} from "../../src/JBOptimismSucker.sol";
import {JBOptimismSuckerDeployer} from "../../src/deployers/JBOptimismSuckerDeployer.sol";
import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";
import {DeployerTests} from "../unit/deployer.t.sol";

contract DeployMappingBypassTest is DeployerTests {
    function test_operatorWithDeployButNoMapCanInstallInitialMappingsThroughRegistry() public {
        address operator = address(0xBEEF);

        IJBSuckerDeployer deployer = _addToRegistry(_setupRegistryAwareOptimismDeployer());

        _allowDeploying(projectId, operator);

        assertFalse(
            jbPermissions()
                .hasPermission({
                operator: operator,
                account: address(this),
                projectId: projectId,
                permissionId: JBPermissionIds.MAP_SUCKER_TOKEN,
                includeRoot: true,
                includeWildcardProjectId: true
            })
        );
        assertFalse(
            jbPermissions()
                .hasPermission({
                operator: address(registry),
                account: address(this),
                projectId: projectId,
                permissionId: JBPermissionIds.MAP_SUCKER_TOKEN,
                includeRoot: true,
                includeWildcardProjectId: true
            })
        );

        bytes32 remoteNative = bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)));
        JBTokenMapping[] memory mappings = new JBTokenMapping[](1);
        mappings[0] = JBTokenMapping({localToken: JBConstants.NATIVE_TOKEN, minGas: 300_000, remoteToken: remoteNative});

        JBSuckerDeployerConfig[] memory configurations = new JBSuckerDeployerConfig[](1);
        configurations[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: mappings});

        vm.chainId(10);
        vm.prank(operator);
        address[] memory suckers = registry.deploySuckersFor({
            projectId: projectId, salt: bytes32("deploy-mapping"), configurations: configurations
        });

        JBRemoteToken memory remote = IJBSucker(suckers[0]).remoteTokenFor(JBConstants.NATIVE_TOKEN);
        assertTrue(remote.enabled);
        assertEq(remote.addr, remoteNative);
        assertEq(remote.minGas, 300_000);
    }

    function _setupRegistryAwareOptimismDeployer() internal returns (IJBSuckerDeployer deployer) {
        JBOptimismSuckerDeployer opDeployer = new JBOptimismSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });

        opDeployer.setChainSpecificConstants(IOPMessenger(address(0x1111)), IOPStandardBridge(address(0x2222)));

        JBOptimismSucker sucker = new JBOptimismSucker({
            deployer: opDeployer,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(registry)),
            trustedForwarder: address(0)
        });

        opDeployer.configureSingleton(sucker);
        return opDeployer;
    }
}
