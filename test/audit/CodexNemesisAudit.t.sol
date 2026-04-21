// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v5/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v5/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {JBOptimismSucker} from "../../src/JBOptimismSucker.sol";
import {JBArbitrumSucker} from "../../src/JBArbitrumSucker.sol";
import {JBOptimismSuckerDeployer} from "../../src/deployers/JBOptimismSuckerDeployer.sol";
import {JBArbitrumSuckerDeployer} from "../../src/deployers/JBArbitrumSuckerDeployer.sol";
import {JBAddToBalanceMode} from "../../src/enums/JBAddToBalanceMode.sol";
import {JBLayer} from "../../src/enums/JBLayer.sol";
import {IOPMessenger} from "../../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../../src/interfaces/IOPStandardBridge.sol";
import {IArbGatewayRouter} from "../../src/interfaces/IArbGatewayRouter.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";

contract CodexNemesisAuditTest is Test {
    address internal constant DIRECTORY = address(0x600);
    address internal constant PERMISSIONS = address(0x700);
    address internal constant TOKENS = address(0x800);
    address internal constant PROJECTS = address(0x900);
    address internal constant FORWARDER = address(0xA00);

    function test_mapToken_retains_unexpected_msg_value() external {
        TestSucker singleton = new TestSucker(
            IJBDirectory(DIRECTORY),
            IJBPermissions(PERMISSIONS),
            IJBTokens(TOKENS),
            JBAddToBalanceMode.MANUAL,
            FORWARDER
        );

        TestSucker sucker = TestSucker(payable(LibClone.clone(address(singleton))));
        sucker.initialize(1);

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(PROJECTS, abi.encodeWithSignature("ownerOf(uint256)", 1), abi.encode(address(this)));

        JBTokenMapping memory map = JBTokenMapping({
            localToken: address(0xBEEF), minGas: 200_000, remoteToken: address(0xCAFE), minBridgeAmount: 1
        });

        sucker.mapToken{value: 1 ether}(map);

        assertEq(address(sucker).balance, 1 ether, "mapping payment stays trapped on the sucker");
        assertEq(
            sucker.amountToAddToBalanceOf(JBConstants.NATIVE_TOKEN),
            1 ether,
            "stray ETH becomes add-to-balance inventory instead of refunding the caller"
        );
    }

    function test_op_deployer_accepts_partial_transport_configuration() external {
        JBOptimismSuckerDeployer deployer = new JBOptimismSuckerDeployer({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            configurator: address(this),
            trusted_forwarder: FORWARDER
        });

        deployer.setChainSpecificConstants(IOPMessenger(address(0x1111)), IOPStandardBridge(address(0)));

        JBOptimismSucker singleton = new JBOptimismSucker({
            deployer: deployer,
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            addToBalanceMode: JBAddToBalanceMode.ON_CLAIM,
            trusted_forwarder: FORWARDER
        });

        deployer.configureSingleton(singleton);

        assertEq(address(deployer.opMessenger()), address(0x1111), "messenger is set");
        assertEq(address(deployer.opBridge()), address(0), "bridge stays unset");
        assertEq(address(singleton.OPBRIDGE()), address(0), "singleton inherits the broken zero bridge");
    }

    function test_arb_l1_deployer_accepts_missing_inbox() external {
        JBArbitrumSuckerDeployer deployer = new JBArbitrumSuckerDeployer({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            configurator: address(this),
            trusted_forwarder: FORWARDER
        });

        deployer.setChainSpecificConstants(JBLayer.L1, IInbox(address(0)), IArbGatewayRouter(address(0x2222)));

        JBArbitrumSucker singleton = new JBArbitrumSucker({
            deployer: deployer,
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            addToBalanceMode: JBAddToBalanceMode.ON_CLAIM,
            trusted_forwarder: FORWARDER
        });

        deployer.configureSingleton(singleton);

        assertEq(uint256(deployer.arbLayer()), uint256(JBLayer.L1), "configured as L1");
        assertEq(address(deployer.arbInbox()), address(0), "L1 deployer still accepts a missing inbox");
        assertEq(address(singleton.ARBINBOX()), address(0), "singleton inherits the broken zero inbox");
    }
}

contract TestSucker is JBSucker {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        JBAddToBalanceMode addToBalanceMode,
        address trustedForwarder
    )
        JBSucker(directory, permissions, tokens, addToBalanceMode, trustedForwarder)
    {}

    function _sendRootOverAMB(
        uint256,
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBMessageRoot memory
    )
        internal
        pure
        override
    {}

    function _isRemotePeer(address) internal pure override returns (bool) {
        return false;
    }

    function peerChainId() external view override returns (uint256) {
        return block.chainid;
    }
}
