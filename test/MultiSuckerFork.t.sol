// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {JBSucker} from "../src/JBSucker.sol";
import {JBSuckerRegistry} from "../src/JBSuckerRegistry.sol";
import {IJBSucker} from "../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";
import {JBDenominatedAmount} from "../src/structs/JBDenominatedAmount.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";
import {JBInboxTreeRoot} from "../src/structs/JBInboxTreeRoot.sol";
import {JBRemoteToken} from "../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../src/structs/JBTokenMapping.sol";
import {JBSuckerDeployerConfig} from "../src/structs/JBSuckerDeployerConfig.sol";

/// @notice Mock sucker with controllable peer chain ID and state. Allows direct `fromRemote()` calls
/// by overriding `_isRemotePeer` to return true.
contract MultiSuckerMock is JBSucker {
    uint256 internal _peerChain;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        IJBSuckerRegistry registry
    )
        JBSucker(directory, permissions, address(1), tokens, 1, registry, address(0))
    {}

    function setPeerChainId(uint256 chainId) external {
        _peerChain = chainId;
    }

    function peerChainId() external view override returns (uint256) {
        return _peerChain;
    }

    /// @dev Allow direct deprecation for testing.
    function setDeprecatedAfter(uint256 timestamp) external {
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

/// @notice Mock deployer that returns pre-created suckers in order.
contract MultiSuckerMockDeployer is IJBSuckerDeployer {
    IJBSucker[] internal _suckers;
    uint256 internal _index;

    function addSucker(IJBSucker sucker) external {
        _suckers.push(sucker);
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
        for (uint256 i; i < _suckers.length; i++) {
            if (addr == address(_suckers[i])) return true;
        }
        return false;
    }

    function createForSender(uint256, bytes32, bytes32) external returns (IJBSucker) {
        IJBSucker sucker = _suckers[_index];
        _index++;
        return sucker;
    }
}

/// @title MultiSuckerForkTest
/// @notice Fork tests for multiple suckers on the same chain pair.
///
/// Covers:
///  1. Duplicate active sucker for same peer chain is blocked by registry
///  2. Full deprecation → replacement lifecycle with real state delivery via `fromRemote()`
///  3. Registry aggregate views prefer the active sucker for each peer chain
///  4. Deprecated sucker with higher state — active replacement still wins
///  5. Multi-chain suckers sum across different chains (no spurious dedup)
///  6. Stale snapshot nonce on same sucker does NOT roll back state
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract MultiSuckerForkTest -vvv
contract MultiSuckerForkTest is Test {
    address internal constant DIRECTORY = address(0xD1);
    address internal constant PERMISSIONS = address(0xD2);
    address internal constant PROJECTS = address(0xD3);
    address internal constant TOKENS = address(0xD4);

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant OPTIMISM = 10;

    uint32 internal ETH_CURRENCY = uint32(uint160(JBConstants.NATIVE_TOKEN));

    JBSuckerRegistry internal registry;
    MultiSuckerMock internal singleton;
    MultiSuckerMockDeployer internal deployer;

    function setUp() public {
        // Fork Ethereum mainnet for realistic block context.
        vm.createSelectFork("ethereum", 21_700_000);
        vm.warp(100 days);

        // Mock JB infrastructure interfaces.
        vm.mockCall(DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(PROJECTS));
        vm.mockCall(PROJECTS, abi.encodeWithSelector(IERC721.ownerOf.selector, PROJECT_ID), abi.encode(address(this)));

        // Deploy real registry.
        registry = new JBSuckerRegistry(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), address(this), address(0));

        // Create mock sucker singleton.
        singleton = new MultiSuckerMock(
            IJBDirectory(DIRECTORY),
            IJBPermissions(PERMISSIONS),
            IJBTokens(TOKENS),
            IJBSuckerRegistry(address(registry))
        );

        // Create and allowlist mock deployer.
        deployer = new MultiSuckerMockDeployer();
        registry.allowSuckerDeployer(address(deployer));
    }

    // ── Helpers
    // ──────────────────────────────────────────────────────────────

    /// @dev Clone a mock sucker, initialize it for PROJECT_ID, and set its peer chain.
    function _createMockSucker(bytes32 salt, uint256 peerChain) internal returns (MultiSuckerMock sucker) {
        sucker = MultiSuckerMock(payable(LibClone.cloneDeterministic(address(singleton), salt)));
        sucker.initialize(PROJECT_ID);
        sucker.setPeerChainId(peerChain);
    }

    /// @dev Deploy a single sucker through the registry.
    function _deployViaRegistry(MultiSuckerMock sucker) internal {
        deployer.addSucker(IJBSucker(address(sucker)));
        JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](1);
        configs[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: new JBTokenMapping[](0)});
        registry.deploySuckersFor({
            projectId: PROJECT_ID, salt: bytes32(uint256(block.timestamp)), configurations: configs
        });
    }

    /// @dev Build a JBMessageRoot with the given state values.
    function _buildStateMessage(
        uint64 sourceTimestamp,
        uint256 totalSupply,
        uint256 surplus,
        uint256 balance
    )
        internal
        view
        returns (JBMessageRoot memory)
    {
        return JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: sourceTimestamp, root: bytes32(0)}),
            sourceTotalSupply: totalSupply,
            sourceCurrency: ETH_CURRENCY,
            sourceDecimals: 18,
            sourceSurplus: surplus,
            sourceBalance: balance,
            sourceTimestamp: sourceTimestamp
        });
    }

    /// @dev Deliver state to a sucker via `fromRemote()`.
    function _deliverState(
        MultiSuckerMock sucker,
        uint64 sourceTimestamp,
        uint256 totalSupply,
        uint256 surplus,
        uint256 balance
    )
        internal
    {
        JBMessageRoot memory root = _buildStateMessage(sourceTimestamp, totalSupply, surplus, balance);
        sucker.fromRemote(root);
    }

    /// @dev Deprecate a sucker (set deprecatedAfter in the past) and remove it from the registry.
    function _deprecateAndRemove(MultiSuckerMock sucker) internal {
        sucker.setDeprecatedAfter(block.timestamp - 1);
        registry.removeDeprecatedSucker({projectId: PROJECT_ID, sucker: address(sucker)});
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 1: Duplicate active sucker for same peer chain is blocked
    // ═══════════════════════════════════════════════════════════════════

    function test_duplicatePeerChainBlocked() external {
        MultiSuckerMock sucker1 = _createMockSucker("dup-a", ARBITRUM);
        MultiSuckerMock sucker2 = _createMockSucker("dup-b", ARBITRUM);

        // Deploy first sucker for Arbitrum — should succeed.
        _deployViaRegistry(sucker1);

        // Deploy second sucker for Arbitrum — should revert.
        deployer.addSucker(IJBSucker(address(sucker2)));
        JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](1);
        configs[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: new JBTokenMapping[](0)});

        vm.expectRevert(
            abi.encodeWithSelector(JBSuckerRegistry.JBSuckerRegistry_DuplicatePeerChain.selector, PROJECT_ID, ARBITRUM)
        );
        registry.deploySuckersFor({projectId: PROJECT_ID, salt: bytes32("dup-salt"), configurations: configs});
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 2: Deprecation → replacement lifecycle with state delivery
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Deploy sucker1, deliver state, deprecate it, deploy sucker2, deliver state.
    /// Verify aggregate views use per-chain MAX (not sum) during the migration window.
    function test_deprecateAndReplace_aggregateViewsUseMax() external {
        MultiSuckerMock sucker1 = _createMockSucker("replace-a", ARBITRUM);
        _deployViaRegistry(sucker1);

        // Deliver state to sucker1: totalSupply=1000e18, surplus=500e18, balance=2000e18.
        _deliverState(sucker1, 1, 1000e18, 500e18, 2000e18);

        // Verify sucker1 stored the state.
        assertEq(sucker1.peerChainTotalSupply(), 1000e18, "sucker1 should store total supply");

        // Verify registry aggregate views before deprecation.
        assertEq(registry.remoteTotalSupplyOf(PROJECT_ID), 1000e18, "registry total supply before deprecation");
        assertEq(registry.remoteBalanceOf(PROJECT_ID, 18, ETH_CURRENCY), 2000e18, "registry balance before deprecation");
        assertEq(registry.remoteSurplusOf(PROJECT_ID, 18, ETH_CURRENCY), 500e18, "registry surplus before deprecation");

        // Deprecate sucker1 and remove from active listing.
        _deprecateAndRemove(sucker1);

        // Deploy sucker2 for same chain (now allowed since sucker1 is DEPRECATED).
        MultiSuckerMock sucker2 = _createMockSucker("replace-b", ARBITRUM);
        _deployViaRegistry(sucker2);

        // Deliver HIGHER state to sucker2.
        _deliverState(sucker2, 1, 1200e18, 600e18, 2500e18);

        // Registry should return MAX(sucker1, sucker2) per value.
        // sucker2 has higher values, so MAX = sucker2's values.
        assertEq(
            registry.remoteTotalSupplyOf(PROJECT_ID), 1200e18, "registry total supply should be MAX(1000, 1200) = 1200"
        );
        assertEq(
            registry.remoteBalanceOf(PROJECT_ID, 18, ETH_CURRENCY),
            2500e18,
            "registry balance should be MAX(2000, 2500) = 2500"
        );
        assertEq(
            registry.remoteSurplusOf(PROJECT_ID, 18, ETH_CURRENCY),
            600e18,
            "registry surplus should be MAX(500, 600) = 600"
        );

        // Verify deprecated sucker is still included in aggregate (not hidden).
        assertTrue(registry.isSuckerOf(PROJECT_ID, address(sucker1)), "deprecated sucker should still be recognized");

        // Verify deprecated sucker is excluded from active listing.
        address[] memory active = registry.suckersOf(PROJECT_ID);
        assertEq(active.length, 1, "only active sucker should appear in suckersOf");
        assertEq(active[0], address(sucker2), "active listing should show sucker2");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 3: Deprecated sucker has HIGHER state — active replacement wins
    // ═══════════════════════════════════════════════════════════════════

    /// @notice When the deprecated sucker has higher state values than the active replacement,
    /// the registry should still prefer the active sucker for that peer chain.
    function test_deprecatedHigherState_activeReplacementWins() external {
        MultiSuckerMock sucker1 = _createMockSucker("higher-a", ARBITRUM);
        _deployViaRegistry(sucker1);

        // Deliver HIGH state to sucker1.
        _deliverState(sucker1, 1, 5000e18, 3000e18, 10_000e18);

        // Deprecate sucker1.
        _deprecateAndRemove(sucker1);

        // Deploy sucker2 with LOWER state.
        MultiSuckerMock sucker2 = _createMockSucker("higher-b", ARBITRUM);
        _deployViaRegistry(sucker2);
        _deliverState(sucker2, 1, 2000e18, 1000e18, 4000e18);

        // Registry should ignore stale deprecated values once an active replacement exists for that peer chain.
        assertEq(
            registry.remoteTotalSupplyOf(PROJECT_ID),
            2000e18,
            "active replacement should own the peer-chain total supply"
        );
        assertEq(
            registry.remoteBalanceOf(PROJECT_ID, 18, ETH_CURRENCY),
            4000e18,
            "active replacement should own the peer-chain balance"
        );
        assertEq(
            registry.remoteSurplusOf(PROJECT_ID, 18, ETH_CURRENCY),
            1000e18,
            "active replacement should own the peer-chain surplus"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 4: Multi-chain suckers sum across different chains
    // ═══════════════════════════════════════════════════════════════════

    /// @notice When suckers target different chains, their values should SUM (not MAX).
    function test_multiChainSuckersSum() external {
        // Deploy sucker for Arbitrum.
        MultiSuckerMock suckerArb = _createMockSucker("multi-arb", ARBITRUM);
        _deployViaRegistry(suckerArb);
        _deliverState(suckerArb, 1, 1000e18, 500e18, 2000e18);

        // Deploy sucker for Optimism.
        MultiSuckerMock suckerOp = _createMockSucker("multi-op", OPTIMISM);
        _deployViaRegistry(suckerOp);
        _deliverState(suckerOp, 1, 300e18, 200e18, 800e18);

        // Registry should SUM across different chains.
        assertEq(
            registry.remoteTotalSupplyOf(PROJECT_ID),
            1300e18,
            "different chains should SUM total supply: 1000 + 300 = 1300"
        );
        assertEq(
            registry.remoteBalanceOf(PROJECT_ID, 18, ETH_CURRENCY),
            2800e18,
            "different chains should SUM balance: 2000 + 800 = 2800"
        );
        assertEq(
            registry.remoteSurplusOf(PROJECT_ID, 18, ETH_CURRENCY),
            700e18,
            "different chains should SUM surplus: 500 + 200 = 700"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 5: Multi-chain with deprecation — dedup per chain, sum across
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Two chains (Arb + OP). Deprecate Arb sucker, replace it. OP sucker unchanged.
    /// Aggregate should be: active Arb replacement + OP value.
    function test_multiChainWithDeprecation_dedupPerChainSumAcross() external {
        // Deploy suckers for both chains.
        MultiSuckerMock suckerArb1 = _createMockSucker("mc-arb1", ARBITRUM);
        _deployViaRegistry(suckerArb1);
        _deliverState(suckerArb1, 1, 1000e18, 500e18, 2000e18);

        MultiSuckerMock suckerOp = _createMockSucker("mc-op", OPTIMISM);
        _deployViaRegistry(suckerOp);
        _deliverState(suckerOp, 1, 300e18, 200e18, 800e18);

        // Verify initial sum.
        assertEq(registry.remoteTotalSupplyOf(PROJECT_ID), 1300e18, "initial sum: 1000 + 300");

        // Deprecate Arb sucker and replace with lower state.
        _deprecateAndRemove(suckerArb1);
        MultiSuckerMock suckerArb2 = _createMockSucker("mc-arb2", ARBITRUM);
        _deployViaRegistry(suckerArb2);
        _deliverState(suckerArb2, 1, 800e18, 400e18, 1500e18);

        // Arb dedup: active replacement 800. OP: 300. Total: 1100.
        assertEq(
            registry.remoteTotalSupplyOf(PROJECT_ID), 1100e18, "dedup per chain + sum across: active 800 + 300 = 1100"
        );
        assertEq(registry.remoteBalanceOf(PROJECT_ID, 18, ETH_CURRENCY), 2300e18, "balance: active 1500 + 800 = 2300");
        assertEq(registry.remoteSurplusOf(PROJECT_ID, 18, ETH_CURRENCY), 600e18, "surplus: active 400 + 200 = 600");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 6: Stale snapshot nonce does NOT roll back state
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Deliver state with nonce=2, then try nonce=1 — state should NOT roll back.
    function test_staleSnapshotNonce_doesNotRollBack() external {
        MultiSuckerMock sucker = _createMockSucker("stale-a", ARBITRUM);
        _deployViaRegistry(sucker);

        // Deliver fresh state with nonce=2.
        _deliverState(sucker, 2, 5000e18, 3000e18, 10_000e18);
        assertEq(sucker.peerChainTotalSupply(), 5000e18, "nonce=2 state should be stored");

        // Deliver stale state with nonce=1 (lower values).
        _deliverState(sucker, 1, 1000e18, 500e18, 2000e18);

        // State should NOT have rolled back.
        assertEq(sucker.peerChainTotalSupply(), 5000e18, "stale nonce=1 should NOT overwrite nonce=2 state");
        assertEq(
            registry.remoteTotalSupplyOf(PROJECT_ID), 5000e18, "registry should reflect nonce=2 state (not rolled back)"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 7: Fresh snapshot nonce DOES update state
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Deliver state with nonce=1, then nonce=2 with lower values — state SHOULD update.
    function test_freshSnapshotNonce_updatesState() external {
        MultiSuckerMock sucker = _createMockSucker("fresh-a", ARBITRUM);
        _deployViaRegistry(sucker);

        // Deliver initial state.
        _deliverState(sucker, 1, 5000e18, 3000e18, 10_000e18);
        assertEq(sucker.peerChainTotalSupply(), 5000e18);

        // Deliver newer state with lower values.
        _deliverState(sucker, 2, 2000e18, 1000e18, 4000e18);

        // State SHOULD update to the newer (lower) values.
        assertEq(sucker.peerChainTotalSupply(), 2000e18, "nonce=2 should overwrite nonce=1 even with lower values");
        assertEq(
            registry.remoteBalanceOf(PROJECT_ID, 18, ETH_CURRENCY), 4000e18, "registry should reflect updated balance"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 8: After deprecation, deploying replacement for same chain works
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Verify the full lifecycle: deploy → deprecate → remove → deploy replacement.
    function test_deprecateRemoveDeploy_fullLifecycle() external {
        // Step 1: Deploy sucker1 for Arbitrum.
        MultiSuckerMock sucker1 = _createMockSucker("lifecycle-a", ARBITRUM);
        _deployViaRegistry(sucker1);
        _deliverState(sucker1, 1, 1000e18, 500e18, 2000e18);

        address[] memory activeBefore = registry.suckersOf(PROJECT_ID);
        assertEq(activeBefore.length, 1, "1 active sucker before deprecation");

        // Step 2: Cannot deploy sucker2 for same chain while sucker1 is active.
        MultiSuckerMock sucker2 = _createMockSucker("lifecycle-b", ARBITRUM);
        deployer.addSucker(IJBSucker(address(sucker2)));
        JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](1);
        configs[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: new JBTokenMapping[](0)});

        vm.expectRevert(
            abi.encodeWithSelector(JBSuckerRegistry.JBSuckerRegistry_DuplicatePeerChain.selector, PROJECT_ID, ARBITRUM)
        );
        registry.deploySuckersFor({projectId: PROJECT_ID, salt: bytes32("blocked"), configurations: configs});

        // Step 3: Deprecate sucker1.
        _deprecateAndRemove(sucker1);

        // Step 4: Now deploy sucker2 for same chain — should succeed.
        _deployViaRegistry(sucker2);
        _deliverState(sucker2, 1, 1500e18, 700e18, 3000e18);

        // Verify lifecycle result.
        address[] memory activeAfter = registry.suckersOf(PROJECT_ID);
        assertEq(activeAfter.length, 1, "1 active sucker after replacement");
        assertEq(activeAfter[0], address(sucker2), "active sucker should be sucker2");

        // Both suckers recognized by isSuckerOf.
        assertTrue(registry.isSuckerOf(PROJECT_ID, address(sucker1)), "deprecated sucker1 still recognized");
        assertTrue(registry.isSuckerOf(PROJECT_ID, address(sucker2)), "active sucker2 recognized");

        // Aggregate views: MAX(1000, 1500) = 1500.
        assertEq(registry.remoteTotalSupplyOf(PROJECT_ID), 1500e18, "total supply should be MAX of both suckers");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 9: Zero state from active replacement hides deprecated state
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Deploy sucker1 with state, deprecate, deploy sucker2 with NO state delivered yet.
    /// The active replacement should own the peer-chain aggregate even before it has delivered state.
    function test_newSuckerZeroState_activeReplacementWins() external {
        MultiSuckerMock sucker1 = _createMockSucker("zero-a", ARBITRUM);
        _deployViaRegistry(sucker1);
        _deliverState(sucker1, 1, 1000e18, 500e18, 2000e18);

        _deprecateAndRemove(sucker1);

        // Deploy sucker2 but DON'T deliver any state (all zeros).
        MultiSuckerMock sucker2 = _createMockSucker("zero-b", ARBITRUM);
        _deployViaRegistry(sucker2);

        // Registry should ignore stale deprecated values once an active replacement exists for that peer chain.
        assertEq(registry.remoteTotalSupplyOf(PROJECT_ID), 0, "active zero state should own total supply");
        assertEq(registry.remoteBalanceOf(PROJECT_ID, 18, ETH_CURRENCY), 0, "active zero state should own balance");
    }
}
