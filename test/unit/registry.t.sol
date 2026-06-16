// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBOptimismSucker.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/deployers/JBOptimismSuckerDeployer.sol";

import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {JBSuckerRegistry} from "./../../src/JBSuckerRegistry.sol";

contract RegistryUnitTest is Test {
    /// @dev Valuation never runs in this deploy-only test, so any non-zero prices address suffices.
    address internal constant PRICES = address(0xA4);

    JBDirectory internal directory;
    JBPermissions internal permissions;
    JBProjects internal projects;
    JBSuckerRegistry internal registry;

    function setUp() public {
        projects = new JBProjects(msg.sender, address(0), address(0));
        permissions = new JBPermissions(address(0));
        directory = new JBDirectory(permissions, projects, address(100));
        registry = new JBSuckerRegistry({
            directory: directory,
            permissions: permissions,
            prices: IJBPrices(PRICES),
            initialOwner: address(this),
            trustedForwarder: address(0)
        });
    }

    function testAllowTokenMappingsRequiresMatchingArrayLengths() public {
        address[] memory localTokens = new address[](1);
        uint256[] memory remoteChainIds = new uint256[](1);
        bytes32[] memory remoteTokens = new bytes32[](2);

        vm.expectRevert(
            abi.encodeWithSelector(JBSuckerRegistry.JBSuckerRegistry_TokenMappingLengthMismatch.selector, 1, 1, 2)
        );
        registry.allowTokenMappings({
            localTokens: localTokens, remoteChainIds: remoteChainIds, remoteTokens: remoteTokens
        });
    }

    function testDeployNoProjectCheck() public {
        new JBSuckerRegistry({
            directory: directory,
            permissions: permissions,
            prices: IJBPrices(PRICES),
            initialOwner: address(100),
            trustedForwarder: address(0)
        });
    }

    function testDifferentAddressTokenMappingRequiresApproval() public {
        address localToken = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        uint256 remoteChainId = 42_161;
        bytes32 remoteToken = bytes32(uint256(uint160(address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831))));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBSuckerRegistry.JBSuckerRegistry_TokenMappingNotAllowed.selector,
                localToken,
                remoteChainId,
                remoteToken
            )
        );
        registry.requireTokenMappingAllowed({
            localToken: localToken, remoteChainId: remoteChainId, remoteToken: remoteToken
        });

        registry.allowTokenMapping({localToken: localToken, remoteChainId: remoteChainId, remoteToken: remoteToken});
        registry.requireTokenMappingAllowed({
            localToken: localToken, remoteChainId: remoteChainId, remoteToken: remoteToken
        });
    }

    function testNativeTokenMappingRequiresApproval() public {
        uint256 remoteChainId = 10;
        bytes32 remoteToken = bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBSuckerRegistry.JBSuckerRegistry_TokenMappingNotAllowed.selector,
                JBConstants.NATIVE_TOKEN,
                remoteChainId,
                remoteToken
            )
        );
        registry.requireTokenMappingAllowed({
            localToken: JBConstants.NATIVE_TOKEN, remoteChainId: remoteChainId, remoteToken: remoteToken
        });

        registry.allowTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN, remoteChainId: remoteChainId, remoteToken: remoteToken
        });
        registry.requireTokenMappingAllowed({
            localToken: JBConstants.NATIVE_TOKEN, remoteChainId: remoteChainId, remoteToken: remoteToken
        });
    }

    function testRemoveTokenMappingBlocksFutureUse() public {
        address localToken = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        uint256 remoteChainId = 42_161;
        bytes32 remoteToken = bytes32(uint256(uint160(address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831))));

        registry.allowTokenMapping({localToken: localToken, remoteChainId: remoteChainId, remoteToken: remoteToken});
        registry.removeTokenMapping({localToken: localToken, remoteChainId: remoteChainId, remoteToken: remoteToken});

        vm.expectRevert(
            abi.encodeWithSelector(
                JBSuckerRegistry.JBSuckerRegistry_TokenMappingNotAllowed.selector,
                localToken,
                remoteChainId,
                remoteToken
            )
        );
        registry.requireTokenMappingAllowed({
            localToken: localToken, remoteChainId: remoteChainId, remoteToken: remoteToken
        });
    }

    function testSameAddressNonNativeTokenMappingDoesNotRequireApproval() public view {
        address localToken = address(0xBEEF);
        bytes32 remoteToken = bytes32(uint256(uint160(localToken)));

        registry.requireTokenMappingAllowed({localToken: localToken, remoteChainId: 42_161, remoteToken: remoteToken});
    }

    function testTokenMappingApprovalIsScopedToRemoteChain() public {
        address localToken = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        bytes32 remoteToken = bytes32(uint256(uint160(address(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85))));

        registry.allowTokenMapping({localToken: localToken, remoteChainId: 10, remoteToken: remoteToken});

        registry.requireTokenMappingAllowed({localToken: localToken, remoteChainId: 10, remoteToken: remoteToken});
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSuckerRegistry.JBSuckerRegistry_TokenMappingNotAllowed.selector,
                localToken,
                uint256(42_161),
                remoteToken
            )
        );
        registry.requireTokenMappingAllowed({localToken: localToken, remoteChainId: 42_161, remoteToken: remoteToken});
    }

    function testTokenMappingBatchesAllowAndRemovePairs() public {
        address[] memory localTokens = new address[](2);
        localTokens[0] = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        localTokens[1] = JBConstants.NATIVE_TOKEN;

        uint256[] memory remoteChainIds = new uint256[](2);
        remoteChainIds[0] = 42_161;
        remoteChainIds[1] = 10;

        bytes32[] memory remoteTokens = new bytes32[](2);
        remoteTokens[0] = bytes32(uint256(uint160(address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831))));
        remoteTokens[1] = bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)));

        registry.allowTokenMappings({
            localTokens: localTokens, remoteChainIds: remoteChainIds, remoteTokens: remoteTokens
        });

        assertTrue(registry.tokenMappingIsAllowed(localTokens[0], remoteChainIds[0], remoteTokens[0]));
        assertTrue(registry.tokenMappingIsAllowed(localTokens[1], remoteChainIds[1], remoteTokens[1]));
        registry.requireTokenMappingAllowed({
            localToken: localTokens[0], remoteChainId: remoteChainIds[0], remoteToken: remoteTokens[0]
        });
        registry.requireTokenMappingAllowed({
            localToken: localTokens[1], remoteChainId: remoteChainIds[1], remoteToken: remoteTokens[1]
        });

        registry.removeTokenMappings({
            localTokens: localTokens, remoteChainIds: remoteChainIds, remoteTokens: remoteTokens
        });

        assertFalse(registry.tokenMappingIsAllowed(localTokens[0], remoteChainIds[0], remoteTokens[0]));
        assertFalse(registry.tokenMappingIsAllowed(localTokens[1], remoteChainIds[1], remoteTokens[1]));
    }

    function testZeroRemoteTokenDoesNotRequireApproval() public view {
        registry.requireTokenMappingAllowed({
            localToken: JBConstants.NATIVE_TOKEN, remoteChainId: 10, remoteToken: bytes32(0)
        });
    }
}
