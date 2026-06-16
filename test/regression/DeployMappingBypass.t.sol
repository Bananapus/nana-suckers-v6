// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

import {JBOptimismSucker} from "../../src/JBOptimismSucker.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {JBOptimismSuckerDeployer} from "../../src/deployers/JBOptimismSuckerDeployer.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../../src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {IOPMessenger} from "../../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../../src/interfaces/IOPStandardBridge.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";
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
        registry.allowTokenMapping({localToken: JBConstants.NATIVE_TOKEN, remoteChainId: 1, remoteToken: remoteNative});

        JBTokenMapping[] memory mappings = new JBTokenMapping[](1);
        mappings[0] = JBTokenMapping({localToken: JBConstants.NATIVE_TOKEN, minGas: 300_000, remoteToken: remoteNative});

        JBSuckerDeployerConfig[] memory configurations = new JBSuckerDeployerConfig[](1);
        configurations[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: mappings});

        vm.chainId(10);
        vm.prank(operator);
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 salt = bytes32("deploy-mapping");
        address[] memory suckers =
            registry.deploySuckersFor({projectId: projectId, salt: salt, configurations: configurations});

        JBRemoteToken memory remote = IJBSucker(suckers[0]).remoteTokenFor(JBConstants.NATIVE_TOKEN);
        assertTrue(remote.enabled);
        assertEq(remote.addr, remoteNative);
        assertEq(remote.minGas, 300_000);
    }

    function test_operatorWithDeployCannotInstallUnapprovedNativeMappingThroughRegistry() public {
        address operator = address(0xBEEF);

        IJBSuckerDeployer deployer = _addToRegistry(_setupRegistryAwareOptimismDeployer());

        _allowDeploying(projectId, operator);

        bytes32 remoteNative = bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)));
        registry.removeTokenMapping(JBConstants.NATIVE_TOKEN, 1, remoteNative);

        JBTokenMapping[] memory mappings = new JBTokenMapping[](1);
        mappings[0] = JBTokenMapping({localToken: JBConstants.NATIVE_TOKEN, minGas: 300_000, remoteToken: remoteNative});

        JBSuckerDeployerConfig[] memory configurations = new JBSuckerDeployerConfig[](1);
        configurations[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: mappings});

        vm.chainId(10);
        vm.prank(operator);
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 salt = bytes32("blocked-native");
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSuckerRegistry.JBSuckerRegistry_TokenMappingNotAllowed.selector,
                JBConstants.NATIVE_TOKEN,
                uint256(1),
                remoteNative
            )
        );
        registry.deploySuckersFor({projectId: projectId, salt: salt, configurations: configurations});
    }

    function test_projectOwnerCanMapDifferentAddressTokenOnlyAfterRegistryApproval() public {
        IJBSuckerDeployer deployer = _addToRegistry(_setupRegistryAwareOptimismDeployer());
        vm.chainId(10);
        IJBSucker sucker = _deployThroughRegistry({
            deployer: deployer, _projectId: projectId, salt: keccak256("post-deploy-token-pair")
        });

        address localToken = makeAddr("localToken");
        bytes32 remoteToken = bytes32(uint256(uint160(makeAddr("remoteToken"))));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBSuckerRegistry.JBSuckerRegistry_TokenMappingNotAllowed.selector, localToken, uint256(1), remoteToken
            )
        );
        sucker.mapToken(JBTokenMapping({localToken: localToken, minGas: 300_000, remoteToken: remoteToken}));

        registry.allowTokenMapping({localToken: localToken, remoteChainId: 1, remoteToken: remoteToken});
        sucker.mapToken(JBTokenMapping({localToken: localToken, minGas: 300_000, remoteToken: remoteToken}));

        JBRemoteToken memory remote = sucker.remoteTokenFor(localToken);
        assertTrue(remote.enabled);
        assertEq(remote.addr, remoteToken);
    }

    function test_projectOwnerCanMapSameAddressNonNativeTokenWithoutRegistryApproval() public {
        IJBSuckerDeployer deployer = _addToRegistry(_setupRegistryAwareOptimismDeployer());
        vm.chainId(10);
        IJBSucker sucker = _deployThroughRegistry({
            deployer: deployer, _projectId: projectId, salt: keccak256("same-address-token-pair")
        });

        address token = makeAddr("sameAddressToken");
        bytes32 remoteToken = bytes32(uint256(uint160(token)));

        sucker.mapToken(JBTokenMapping({localToken: token, minGas: 300_000, remoteToken: remoteToken}));

        JBRemoteToken memory remote = sucker.remoteTokenFor(token);
        assertTrue(remote.enabled);
        assertEq(remote.addr, remoteToken);
    }

    function test_tokenMappingApprovalIsScopedToRemoteChain() public {
        IJBSuckerDeployer deployer = _addToRegistry(_setupRegistryAwareOptimismDeployer());
        vm.chainId(1);
        IJBSucker sucker = _deployThroughRegistry({
            deployer: deployer, _projectId: projectId, salt: keccak256("route-scoped-token-pair")
        });

        address mainnetUsdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        bytes32 optimismUsdc = bytes32(uint256(uint160(address(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85))));

        registry.allowTokenMapping({localToken: mainnetUsdc, remoteChainId: 42_161, remoteToken: optimismUsdc});

        vm.expectRevert(
            abi.encodeWithSelector(
                JBSuckerRegistry.JBSuckerRegistry_TokenMappingNotAllowed.selector,
                mainnetUsdc,
                uint256(10),
                optimismUsdc
            )
        );
        sucker.mapToken(JBTokenMapping({localToken: mainnetUsdc, minGas: 300_000, remoteToken: optimismUsdc}));

        registry.allowTokenMapping({localToken: mainnetUsdc, remoteChainId: 10, remoteToken: optimismUsdc});
        sucker.mapToken(JBTokenMapping({localToken: mainnetUsdc, minGas: 300_000, remoteToken: optimismUsdc}));
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
