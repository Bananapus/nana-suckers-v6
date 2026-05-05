// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../../src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";
import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";

contract CodexNemesisDeprecatedLiveSucker is JBSucker {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        JBSucker(directory, permissions, IJBPrices(address(1)), tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function peerChainId() external pure override returns (uint256) {
        return 10;
    }

    function test_setPeerChainTotalSupply(uint256 supply) external {
        peerChainTotalSupply = supply;
    }

    function test_setDeprecatedAfter(uint256 timestamp) external {
        deprecatedAfter = timestamp;
    }

    function _isRemotePeer(address) internal pure override returns (bool) {
        return true;
    }

    function _sendRootOverAMB(
        uint256,
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBMessageRoot memory
    )
        internal
        override
    {}
}

contract CodexNemesisDeprecatedLiveDeployer is IJBSuckerDeployer {
    IJBSucker public immutable sucker;

    constructor(IJBSucker _sucker) {
        sucker = _sucker;
    }

    function DIRECTORY() external pure returns (IJBDirectory) {
        return IJBDirectory(address(0));
    }

    function LAYER_SPECIFIC_CONFIGURATOR() external pure returns (address) {
        return address(0);
    }

    function TOKENS() external pure returns (IJBTokens) {
        return IJBTokens(address(0));
    }

    function isSucker(address addr) external view returns (bool) {
        return addr == address(sucker);
    }

    function createForSender(uint256, bytes32, bytes32) external view returns (IJBSucker) {
        return sucker;
    }
}

contract CodexNemesisDeprecatedRemovalUndercountTest is Test {
    address internal constant DIRECTORY = address(0xD1);
    address internal constant PERMISSIONS = address(0xD2);
    address internal constant PROJECTS = address(0xD3);
    address internal constant TOKENS = address(0xD4);
    uint256 internal constant PROJECT_ID = 1;

    JBSuckerRegistry internal registry;
    CodexNemesisDeprecatedLiveSucker internal sucker;
    CodexNemesisDeprecatedLiveDeployer internal deployer;

    function setUp() public {
        vm.warp(100 days);

        vm.mockCall(DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(PROJECTS));
        vm.mockCall(PROJECTS, abi.encodeWithSelector(IERC721.ownerOf.selector, PROJECT_ID), abi.encode(address(this)));

        registry = new JBSuckerRegistry(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), address(this), address(0));
        CodexNemesisDeprecatedLiveSucker singleton = new CodexNemesisDeprecatedLiveSucker(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS)
        );
        sucker = CodexNemesisDeprecatedLiveSucker(
            payable(address(LibClone.cloneDeterministic(address(singleton), bytes32("nemesis-deprecated-live"))))
        );
        sucker.initialize(PROJECT_ID);
        deployer = new CodexNemesisDeprecatedLiveDeployer(IJBSucker(address(sucker)));

        registry.allowSuckerDeployer(address(deployer));

        JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](1);
        configs[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: new JBTokenMapping[](0)});
        registry.deploySuckersFor(PROJECT_ID, bytes32("nemesis-deprecated"), configs);
    }

    /// @dev Deprecated suckers are now included in aggregate views. This test verifies
    /// that `removeDeprecatedSucker` does NOT hide supply from `remoteTotalSupplyOf`.
    function test_removeDeprecatedSuckerPreservesRemoteSupplyInRegistryViews() external {
        sucker.test_setPeerChainTotalSupply(1000e18);
        sucker.test_setDeprecatedAfter(block.timestamp - 1);

        uint256 supplyBeforeRemoval = registry.remoteTotalSupplyOf(PROJECT_ID);
        assertEq(supplyBeforeRemoval, 1000e18, "active deprecated sucker contributes remote supply");

        registry.removeDeprecatedSucker({projectId: PROJECT_ID, sucker: address(sucker)});

        // After the fix, the deprecated sucker's supply is still visible.
        uint256 supplyAfterRemoval = registry.remoteTotalSupplyOf(PROJECT_ID);
        assertEq(supplyAfterRemoval, 1000e18, "deprecated sucker supply remains visible after removal");

        uint256 localSupply = 100e18;
        assertEq(localSupply + supplyAfterRemoval, 1100e18, "cross-chain consumer sees full supply even after removal");
    }
}
