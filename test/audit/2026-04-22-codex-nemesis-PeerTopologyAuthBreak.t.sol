// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {JBOptimismSucker} from "../../src/JBOptimismSucker.sol";
import {JBSucker} from "../../src/JBSucker.sol";
import {JBOptimismSuckerDeployer} from "../../src/deployers/JBOptimismSuckerDeployer.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {IOPMessenger} from "../../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../../src/interfaces/IOPStandardBridge.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";

contract PeerTopologyAuthBreakTest is Test {
    address internal constant DIRECTORY_A = address(0x1001);
    address internal constant DIRECTORY_B = address(0x1002);
    address internal constant PERMISSIONS = address(0x2001);
    address internal constant TOKENS = address(0x3001);
    address internal constant PROJECTS = address(0x4001);
    address internal constant REGISTRY = address(0x5001);
    address internal constant MESSENGER = address(0x6001);
    address internal constant BRIDGE = address(0x7001);
    address internal constant USER = address(0x8001);

    JBOptimismSuckerDeployer internal deployerA;
    JBOptimismSuckerDeployer internal deployerB;

    function setUp() public {
        vm.mockCall(DIRECTORY_A, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(DIRECTORY_B, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));

        deployerA = new JBOptimismSuckerDeployer({
            directory: IJBDirectory(DIRECTORY_A),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            configurator: address(this),
            trustedForwarder: address(0)
        });
        deployerB = new JBOptimismSuckerDeployer({
            directory: IJBDirectory(DIRECTORY_B),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            configurator: address(this),
            trustedForwarder: address(0)
        });

        deployerA.setChainSpecificConstants({
            messenger: IOPMessenger(MESSENGER),
            bridge: IOPStandardBridge(BRIDGE)
        });
        deployerB.setChainSpecificConstants({
            messenger: IOPMessenger(MESSENGER),
            bridge: IOPStandardBridge(BRIDGE)
        });

        JBOptimismSucker singletonA = new JBOptimismSucker({
            deployer: deployerA,
            directory: IJBDirectory(DIRECTORY_A),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(REGISTRY),
            trustedForwarder: address(0)
        });
        JBOptimismSucker singletonB = new JBOptimismSucker({
            deployer: deployerB,
            directory: IJBDirectory(DIRECTORY_B),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(REGISTRY),
            trustedForwarder: address(0)
        });

        deployerA.configureSingleton(singletonA);
        deployerB.configureSingleton(singletonB);
    }

    function test_sameSaltDifferentDeploymentTopology_breaksDefaultPeerAuthentication() public {
        bytes32 salt = keccak256("NEMESIS_PEER_BREAK");

        vm.startPrank(USER);
        IJBSucker suckerA = deployerA.createForSender({localProjectId: 1, salt: salt});
        IJBSucker suckerB = deployerB.createForSender({localProjectId: 1, salt: salt});
        vm.stopPrank();

        assertTrue(address(suckerA) != address(suckerB), "different deployment topologies should yield different clones");
        assertEq(JBOptimismSucker(payable(address(suckerA))).peer(), bytes32(uint256(uint160(address(suckerA)))));
        assertEq(JBOptimismSucker(payable(address(suckerB))).peer(), bytes32(uint256(uint160(address(suckerB)))));

        vm.mockCall(MESSENGER, abi.encodeWithSignature("xDomainMessageSender()"), abi.encode(address(suckerB)));

        JBMessageRoot memory root = JBMessageRoot({
            version: JBSucker(payable(address(suckerA))).MESSAGE_VERSION(),
            token: bytes32(uint256(uint160(address(0xBEEF)))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: keccak256("root")}),
            sourceTotalSupply: 0,
            sourceCurrency: 1,
            sourceDecimals: 18,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        vm.expectRevert();
        vm.prank(MESSENGER);
        JBOptimismSucker(payable(address(suckerA))).fromRemote(root);
    }
}
