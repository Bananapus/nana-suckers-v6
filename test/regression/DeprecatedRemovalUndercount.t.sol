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
import {JBChainAccounting} from "../../src/structs/JBChainAccounting.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBSourceContext} from "../../src/structs/JBSourceContext.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";
import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";

contract RegressionDeprecatedLiveSucker is JBSucker {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function peerChainId() public pure override returns (uint256) {
        return 10;
    }

    /// @notice Inject a peer-chain total supply by storing a single accounting record for this sucker's peer chain
    /// through the real receive path, so the registry's aggregate views read it back per chain.
    /// @param supply The total supply to record for the peer chain.
    function test_setPeerChainTotalSupply(uint256 supply) external {
        JBChainAccounting[] memory accounts = new JBChainAccounting[](1);
        accounts[0] = JBChainAccounting({
            chainId: peerChainId(), totalSupply: supply, contexts: new JBSourceContext[](0), timestamp: 1
        });

        JBMessageRoot memory root = JBMessageRoot({
            version: MESSAGE_VERSION,
            token: bytes32(0),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: 0, root: bytes32(0)}),
            accounts: accounts
        });

        this.fromRemote(root);
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

contract RegressionDeprecatedLiveDeployer is IJBSuckerDeployer {
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

contract RegressionDeprecatedRemovalUndercountTest is Test {
    address internal constant DIRECTORY = address(0xD1);
    address internal constant PERMISSIONS = address(0xD2);
    address internal constant PROJECTS = address(0xD3);
    address internal constant TOKENS = address(0xD4);

    /// @dev This test only reads total supply (never valued), so any non-zero prices address suffices.
    address internal constant PRICES = address(0xD5);
    uint256 internal constant PROJECT_ID = 1;

    JBSuckerRegistry internal registry;
    RegressionDeprecatedLiveSucker internal sucker;
    RegressionDeprecatedLiveDeployer internal deployer;

    function setUp() public {
        vm.warp(100 days);

        vm.mockCall(DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(PROJECTS));
        vm.mockCall(PROJECTS, abi.encodeWithSelector(IERC721.ownerOf.selector, PROJECT_ID), abi.encode(address(this)));

        registry = new JBSuckerRegistry(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBPrices(PRICES), address(this), address(0)
        );
        RegressionDeprecatedLiveSucker singleton =
            new RegressionDeprecatedLiveSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS));
        sucker = RegressionDeprecatedLiveSucker(
            // forge-lint: disable-next-line(unsafe-typecast)
            payable(address(
                    LibClone.cloneDeterministic(address(singleton), keccak256(bytes("regression-deprecated-live")))
                ))
        );
        sucker.initialize(PROJECT_ID);
        deployer = new RegressionDeprecatedLiveDeployer(IJBSucker(address(sucker)));

        registry.allowSuckerDeployer(address(deployer));

        JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](1);
        configs[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: new JBTokenMapping[](0)});
        // forge-lint: disable-next-line(unsafe-typecast)
        registry.deploySuckersFor(PROJECT_ID, keccak256(bytes("regression-deprecated")), configs);
    }

    /// @dev Deprecated suckers are now included in aggregate views. This test verifies
    /// that `removeDeprecatedSucker` does NOT hide supply from `remoteTotalSupplyOf`.
    function test_removeDeprecatedSuckerPreservesRemoteSupplyInRegistryViews() external {
        sucker.test_setPeerChainTotalSupply(1000e18);
        sucker.test_setDeprecatedAfter(block.timestamp - 1);

        uint256 supplyBeforeRemoval = registry.remoteTotalSupplyOf(PROJECT_ID);
        assertEq(supplyBeforeRemoval, 1000e18, "active deprecated sucker contributes remote supply");

        registry.removeDeprecatedSucker({projectId: PROJECT_ID, sucker: address(sucker)});

        // Deprecated sucker supply remains visible after removal from active listings.
        uint256 supplyAfterRemoval = registry.remoteTotalSupplyOf(PROJECT_ID);
        assertEq(supplyAfterRemoval, 1000e18, "deprecated sucker supply remains visible after removal");

        uint256 localSupply = 100e18;
        assertEq(localSupply + supplyAfterRemoval, 1100e18, "cross-chain consumer sees full supply even after removal");
    }

    /// @notice `allSuckersOf` must return every sucker ever registered for a project — including
    /// deprecated entries that `suckersOf` filters out. Consumers like
    /// `JBReferralSplitHook.burnUnbridgeableCreditFor` rely on this to detect "has any sucker
    /// ever peered to chain X?" so they don't permaburn credit that's still bridgeable through
    /// a deprecated-but-not-yet-replaced sucker.
    function test_allSuckersOf_includesDeprecatedAfterRemoval() external {
        // Before deprecation, both views see the sucker.
        address[] memory activeBefore = registry.suckersOf(PROJECT_ID);
        address[] memory allBefore = registry.allSuckersOf(PROJECT_ID);
        assertEq(activeBefore.length, 1, "active set sees the sucker pre-deprecation");
        assertEq(allBefore.length, 1, "full set sees the sucker pre-deprecation");
        assertEq(activeBefore[0], address(sucker));
        assertEq(allBefore[0], address(sucker));

        // Deprecate and remove from active listings.
        sucker.test_setDeprecatedAfter(block.timestamp - 1);
        registry.removeDeprecatedSucker({projectId: PROJECT_ID, sucker: address(sucker)});

        // After removal, `suckersOf` filters it out — but `allSuckersOf` MUST still report it,
        // otherwise downstream "is this chain bridgeable?" checks return a false negative.
        address[] memory activeAfter = registry.suckersOf(PROJECT_ID);
        address[] memory allAfter = registry.allSuckersOf(PROJECT_ID);
        assertEq(activeAfter.length, 0, "suckersOf filters out the removed entry");
        assertEq(allAfter.length, 1, "allSuckersOf still includes the removed entry");
        assertEq(allAfter[0], address(sucker), "removed sucker still reachable via allSuckersOf");
    }
}
