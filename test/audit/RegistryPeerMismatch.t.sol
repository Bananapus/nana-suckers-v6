// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {JBOptimismSucker} from "../../src/JBOptimismSucker.sol";
import {JBOptimismSuckerDeployer} from "../../src/deployers/JBOptimismSuckerDeployer.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IOPMessenger} from "../../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../../src/interfaces/IOPStandardBridge.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";
import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";

contract RegistryPeerMismatchTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    bytes32 internal constant SALT = keccak256("same-user-salt");

    address internal constant OWNER = address(0xBEEF);
    address internal constant DIRECTORY = address(0xD1);
    address internal constant PERMISSIONS = address(0xD2);
    address internal constant TOKENS = address(0xD3);
    address internal constant PROJECTS = address(0xD4);
    address internal constant MESSENGER = address(0xD5);
    address internal constant BRIDGE = address(0xD6);

    JBSuckerRegistry internal registryA;
    JBSuckerRegistry internal registryB;

    function setUp() public {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(IJBProjects(PROJECTS)));
        vm.mockCall(
            PROJECTS, abi.encodeWithSelector(bytes4(keccak256("ownerOf(uint256)")), PROJECT_ID), abi.encode(OWNER)
        );
    }

    function test_registryDeployPathBreaksDefaultPeerSymmetry() public {
        registryA = new JBSuckerRegistry(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), OWNER, address(0));
        registryB = new JBSuckerRegistry(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), OWNER, address(0));

        JBOptimismSuckerDeployer deployerA = _deployOptimismDeployer(registryA);
        JBOptimismSuckerDeployer deployerB = _deployOptimismDeployer(registryB);

        JBSuckerDeployerConfig[] memory configsA = _configFor(deployerA);
        JBSuckerDeployerConfig[] memory configsB = _configFor(deployerB);

        vm.prank(OWNER);
        address suckerA = registryA.deploySuckersFor(PROJECT_ID, SALT, configsA)[0];

        vm.prank(OWNER);
        address suckerB = registryB.deploySuckersFor(PROJECT_ID, SALT, configsB)[0];

        assertTrue(suckerA != suckerB, "same sender+salt should diverge because registry address salts the clone");
        assertEq(IJBSucker(suckerA).peer(), bytes32(uint256(uint160(suckerA))), "default peer is self address");
        assertEq(IJBSucker(suckerB).peer(), bytes32(uint256(uint160(suckerB))), "default peer is self address");

        vm.mockCall(MESSENGER, abi.encodeWithSelector(IOPMessenger.xDomainMessageSender.selector), abi.encode(suckerA));

        vm.prank(MESSENGER);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("JBSucker_NotPeer(bytes32)")), bytes32(uint256(uint160(MESSENGER))))
        );
        JBOptimismSucker(payable(suckerB))
            .fromRemote(
                JBMessageRoot({
                version: 1,
                token: bytes32(0),
                amount: 0,
                remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(1))}),
                sourceTotalSupply: 0,
                sourceCurrency: 0,
                sourceDecimals: 0,
                sourceSurplus: 0,
                sourceBalance: 0,
                sourceTimestamp: 1
            })
            );
    }

    function _deployOptimismDeployer(JBSuckerRegistry registry) internal returns (JBOptimismSuckerDeployer deployer) {
        deployer = new JBOptimismSuckerDeployer(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), OWNER, address(0)
        );
        vm.prank(OWNER);
        deployer.setChainSpecificConstants(IOPMessenger(MESSENGER), IOPStandardBridge(BRIDGE));

        JBOptimismSucker singleton = new JBOptimismSucker(
            deployer, IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), 1, registry, address(0)
        );
        vm.prank(OWNER);
        deployer.configureSingleton(singleton);

        vm.prank(OWNER);
        registry.allowSuckerDeployer(address(deployer));
    }

    function _configFor(JBOptimismSuckerDeployer deployer)
        internal
        pure
        returns (JBSuckerDeployerConfig[] memory configs)
    {
        configs = new JBSuckerDeployerConfig[](1);
        configs[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: new JBTokenMapping[](0)});
    }
}
