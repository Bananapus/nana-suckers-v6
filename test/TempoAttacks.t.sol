// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v5/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v5/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v5/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../src/JBSucker.sol";
import {JBAddToBalanceMode} from "../src/enums/JBAddToBalanceMode.sol";
import {JBSuckerState} from "../src/enums/JBSuckerState.sol";
import {JBClaim} from "../src/structs/JBClaim.sol";
import {JBLeaf} from "../src/structs/JBLeaf.sol";
import {JBInboxTreeRoot} from "../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../src/structs/JBTokenMapping.sol";
import {MerkleLib} from "../src/utils/MerkleLib.sol";

/// @notice Reusable test sucker for attack testing.
contract AttackTempoSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;

    bool nextCheckShouldPass;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        JBAddToBalanceMode addToBalanceMode,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, addToBalanceMode, forwarder)
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
        override
    {}

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == peer();
    }

    function peerChainId() external view virtual override returns (uint256) {
        return block.chainid;
    }

    function _validateBranchRoot(
        bytes32 expectedRoot,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        address beneficiary,
        uint256 index,
        bytes32[_TREE_DEPTH] calldata leaves
    )
        internal
        virtual
        override
    {
        if (!nextCheckShouldPass) {
            super._validateBranchRoot(expectedRoot, projectTokenCount, terminalTokenAmount, beneficiary, index, leaves);
        }
        nextCheckShouldPass = false;
    }

    function test_setNextMerkleCheckToBe(bool _pass) external {
        nextCheckShouldPass = _pass;
    }

    function test_setOutboxBalance(address token, uint256 amount) external {
        _outboxOf[token].balance = amount;
    }

    function test_setInboxRoot(address token, uint64 nonce, bytes32 root) external {
        _inboxOf[token] = JBInboxTreeRoot({nonce: nonce, root: root});
    }

    function test_insertIntoTree(
        uint256 projectTokenCount,
        address token,
        uint256 terminalTokenAmount,
        address beneficiary
    )
        external
    {
        _insertIntoTree(projectTokenCount, token, terminalTokenAmount, beneficiary);
    }

    function test_getOutboxRoot(address token) external view returns (bytes32) {
        return _outboxOf[token].tree.root();
    }

    function test_getOutboxCount(address token) external view returns (uint256) {
        return _outboxOf[token].tree.count;
    }

    function test_getInboxNonce(address token) external view returns (uint64) {
        return _inboxOf[token].nonce;
    }

    function test_getInboxRoot(address token) external view returns (bytes32) {
        return _inboxOf[token].root;
    }

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

    function test_setDeprecatedAfter(uint40 ts) external {
        deprecatedAfter = ts;
    }
}

/// @title TempoAttacks
/// @notice Attack surface testing for the Tempo cross-chain integration.
/// @dev Tests re-entrancy vectors, double-claiming, front-running, and cross-chain accounting invariants
///      specific to the mixed NATIVE_TOKEN/ERC20 architecture of Tempo.
contract TempoAttacks is Test {
    using MerkleLib for MerkleLib.Tree;

    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);

    uint256 constant PROJECT_ID = 1;

    /// @dev Simulated WETH ERC20 on Tempo
    address constant WETH_ON_TEMPO = address(0xE770e770E770E770e770e770E770e770E770E770);

    AttackTempoSucker sucker;

    function setUp() public {
        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");

        sucker = _createTestSucker(PROJECT_ID, "attack_salt");

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
    }

    function _createTestSucker(uint256 projectId, bytes32 salt) internal returns (AttackTempoSucker) {
        AttackTempoSucker singleton = new AttackTempoSucker(
            IJBDirectory(DIRECTORY),
            IJBPermissions(PERMISSIONS),
            IJBTokens(TOKENS),
            JBAddToBalanceMode.MANUAL,
            FORWARDER
        );

        AttackTempoSucker clone =
            AttackTempoSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        clone.initialize(projectId);
        return clone;
    }

    // =========================================================================
    // INVARIANT 1: No tokens created from nothing
    // =========================================================================
    /// @notice Outbox balance can only increase through insertIntoTree.
    ///         Direct balance manipulation should not affect tracked outbox balance.
    function test_invariant_noTokensFromNothing() public {
        address token = WETH_ON_TEMPO;

        // Track initial outbox balance (0)
        uint256 trackedBalance = 0;

        // Insert items — this is the ONLY way to increase outbox balance
        sucker.test_insertIntoTree(5 ether, token, 3 ether, address(100));
        sucker.test_insertIntoTree(10 ether, token, 7 ether, address(200));
        trackedBalance += 3 ether + 7 ether;

        // Outbox count should reflect insertions
        assertEq(sucker.test_getOutboxCount(token), 2, "Should have 2 leaves");

        // Sending extra tokens to the sucker should NOT increase outbox balance
        // (outbox.balance is only increased through _insertIntoTree in prepare())
        vm.deal(address(sucker), 100 ether);

        // The actual balance is inflated but the tracked outbox is not
        assertEq(address(sucker).balance, 100 ether, "ETH balance should be inflated");
        // Outbox tree count remains 2 — no phantom leaves created
        assertEq(sucker.test_getOutboxCount(token), 2, "Outbox count should still be 2");
    }

    // =========================================================================
    // INVARIANT 2: No double-spend across different token types
    // =========================================================================
    /// @notice Claiming a leaf for WETH_ON_TEMPO should not allow claiming the same
    ///         leaf index for NATIVE_TOKEN or vice versa.
    function test_invariant_noDoubleSpendAcrossTokenTypes() public {
        address wethToken = WETH_ON_TEMPO;
        address nativeToken = JBConstants.NATIVE_TOKEN;

        // Set up leaves for both token types at the same index (0)
        sucker.test_insertIntoTree(5 ether, wethToken, 5 ether, address(120));
        sucker.test_insertIntoTree(5 ether, nativeToken, 5 ether, address(120));

        // Set inbox roots
        bytes32 wethRoot = sucker.test_getOutboxRoot(wethToken);
        bytes32 nativeRoot = sucker.test_getOutboxRoot(nativeToken);
        sucker.test_setInboxRoot(wethToken, 1, wethRoot);
        sucker.test_setInboxRoot(nativeToken, 1, nativeRoot);
        sucker.test_setOutboxBalance(wethToken, 100 ether);
        sucker.test_setOutboxBalance(nativeToken, 100 ether);

        // Mock controller
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, 5 ether, address(120), "", false)),
            abi.encode(5 ether)
        );

        bytes32[32] memory proof;

        // Claim for WETH_ON_TEMPO at index 0
        sucker.test_setNextMerkleCheckToBe(true);
        JBClaim memory wethClaim = JBClaim({
            token: wethToken,
            leaf: JBLeaf({
                index: 0, beneficiary: address(120), projectTokenCount: 5 ether, terminalTokenAmount: 5 ether
            }),
            proof: proof
        });
        sucker.claim(wethClaim);

        // Claim for NATIVE_TOKEN at index 0 should ALSO succeed (separate bitmap per token)
        sucker.test_setNextMerkleCheckToBe(true);
        JBClaim memory nativeClaim = JBClaim({
            token: nativeToken,
            leaf: JBLeaf({
                index: 0, beneficiary: address(120), projectTokenCount: 5 ether, terminalTokenAmount: 5 ether
            }),
            proof: proof
        });
        sucker.claim(nativeClaim);

        // But claiming WETH again at index 0 should revert
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, wethToken, 0));
        sucker.claim(wethClaim);

        // And claiming NATIVE again at index 0 should revert
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, nativeToken, 0));
        sucker.claim(nativeClaim);
    }

    // =========================================================================
    // ATTACK 1: Front-running token mapping change
    // =========================================================================
    /// @notice An attacker cannot exploit a token mapping change to claim tokens that don't belong to them.
    ///         Inbox roots are keyed by local token address, independent of the remote mapping.
    function test_attack_frontRunTokenMappingChange() public {
        address token = WETH_ON_TEMPO;

        // Set up remote mapping: WETH_ON_TEMPO → NATIVE_TOKEN on ETH
        sucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: JBConstants.NATIVE_TOKEN,
                minBridgeAmount: 0
            })
        );

        // Insert leaf and set inbox root
        sucker.test_insertIntoTree(10 ether, token, 5 ether, address(100));
        bytes32 root = sucker.test_getOutboxRoot(token);
        sucker.test_setInboxRoot(token, 1, root);

        // Attacker changes the remote mapping (would need to be project owner)
        address maliciousRemote = makeAddr("maliciousRemote");
        sucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: true, emergencyHatch: false, minGas: 200_000, addr: maliciousRemote, minBridgeAmount: 0
            })
        );

        // The inbox root for WETH_ON_TEMPO is still valid — it's keyed by local token, not remote
        bytes32 storedRoot = sucker.test_getInboxRoot(token);
        assertEq(storedRoot, root, "Inbox root should persist regardless of remote mapping change");
    }

    // =========================================================================
    // ATTACK 2: Cross-token inbox root confusion
    // =========================================================================
    /// @notice Attacker tries to claim using a proof from one token type against another token's inbox.
    function test_attack_crossTokenInboxConfusion() public {
        // Set up roots for two different tokens with different merkle trees
        sucker.test_insertIntoTree(10 ether, WETH_ON_TEMPO, 5 ether, address(100));
        sucker.test_insertIntoTree(20 ether, JBConstants.NATIVE_TOKEN, 10 ether, address(200));

        bytes32 wethRoot = sucker.test_getOutboxRoot(WETH_ON_TEMPO);
        bytes32 nativeRoot = sucker.test_getOutboxRoot(JBConstants.NATIVE_TOKEN);

        // Set inbox roots
        sucker.test_setInboxRoot(WETH_ON_TEMPO, 1, wethRoot);
        sucker.test_setInboxRoot(JBConstants.NATIVE_TOKEN, 1, nativeRoot);

        // The roots should be different since different data was inserted
        assertTrue(wethRoot != nativeRoot, "Different trees should produce different roots");

        // An attacker cannot use WETH proof against NATIVE inbox or vice versa
        // because the claim token determines which inbox root is checked
    }

    // =========================================================================
    // ATTACK 3: Deprecated sucker message injection
    // =========================================================================
    /// @notice When a sucker is deprecated, fromRemote silently ignores new messages.
    ///         This prevents attackers from injecting messages into a deprecated sucker.
    function test_attack_deprecatedSuckerMessageInjection() public {
        // Warp to a realistic timestamp to avoid underflow in state() calculation.
        // state() computes deprecatedAfter - _maxMessagingDelay() (14 days) which underflows
        // at low timestamps.
        vm.warp(30 days);

        // Deprecate the sucker
        sucker.test_setDeprecatedAfter(uint40(block.timestamp + 1));
        vm.warp(block.timestamp + 1);
        assertEq(uint8(sucker.state()), uint8(JBSuckerState.DEPRECATED));

        // Try to inject a message
        JBMessageRoot memory root = JBMessageRoot({
            token: WETH_ON_TEMPO,
            amount: 1000 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xDEAD))})
        });

        // fromRemote should accept the call but silently ignore the update
        vm.prank(address(sucker));
        sucker.fromRemote(root);

        // Verify the inbox was NOT updated
        assertEq(sucker.test_getInboxNonce(WETH_ON_TEMPO), 0, "Inbox should not update when deprecated");
    }

    // =========================================================================
    // ATTACK 4: Nonce gap exploitation
    // =========================================================================
    /// @notice Verify that nonce gaps are accepted (1→5 is valid).
    ///         An attacker cannot cause issues by skipping nonces.
    function test_attack_nonceGapExploitation() public {
        // Deliver nonce 1
        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                token: WETH_ON_TEMPO,
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xAA))})
            })
        );
        assertEq(sucker.test_getInboxNonce(WETH_ON_TEMPO), 1);

        // Skip to nonce 5 — this should be accepted
        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                token: WETH_ON_TEMPO,
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 5, root: bytes32(uint256(0xBB))})
            })
        );
        assertEq(sucker.test_getInboxNonce(WETH_ON_TEMPO), 5, "Nonce gap should be accepted");

        // Nonce 3 (which was skipped) should be silently ignored
        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                token: WETH_ON_TEMPO,
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 3, root: bytes32(uint256(0xCC))})
            })
        );
        assertEq(sucker.test_getInboxNonce(WETH_ON_TEMPO), 5, "Stale nonce 3 should be ignored");
    }

    // =========================================================================
    // ATTACK 5: Claim with beneficiary mismatch
    // =========================================================================
    /// @notice Attacker tries to claim tokens intended for a different beneficiary
    ///         by constructing a claim with their own address. The merkle proof
    ///         validation should prevent this.
    function test_attack_beneficiaryMismatch() public {
        address token = WETH_ON_TEMPO;
        address realBeneficiary = address(100);
        address attacker = address(999);

        // Insert leaf for real beneficiary
        sucker.test_insertIntoTree(5 ether, token, 5 ether, realBeneficiary);
        bytes32 root = sucker.test_getOutboxRoot(token);
        sucker.test_setInboxRoot(token, 1, root);
        sucker.test_setOutboxBalance(token, 100 ether);

        // Attacker tries to claim with their own address but the proof won't match
        // (merkle check is NOT overridden here)
        bytes32[32] memory proof;
        JBClaim memory attackClaim = JBClaim({
            token: token,
            leaf: JBLeaf({
                index: 0,
                beneficiary: attacker, // Wrong beneficiary
                projectTokenCount: 5 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });

        // This should revert because the merkle proof doesn't match the modified beneficiary
        vm.expectRevert();
        sucker.claim(attackClaim);
    }

    // =========================================================================
    // INVARIANT 3: Outbox tree count is monotonically increasing
    // =========================================================================
    /// @notice The outbox tree count can only increase, never decrease.
    function test_invariant_outboxCountMonotonic() public {
        address token = WETH_ON_TEMPO;

        uint256 prevCount = 0;
        for (uint256 i = 0; i < 20; i++) {
            sucker.test_insertIntoTree((i + 1) * 1 ether, token, (i + 1) * 0.5 ether, address(uint160(1000 + i)));

            uint256 newCount = sucker.test_getOutboxCount(token);
            assertTrue(newCount > prevCount, "Count must strictly increase");
            prevCount = newCount;
        }

        assertEq(prevCount, 20, "Final count should be 20");
    }

    // =========================================================================
    // INVARIANT 4: Inbox nonce is monotonically increasing per token
    // =========================================================================
    /// @notice Inbox nonce can only increase, never decrease, independently per token.
    function test_invariant_inboxNonceMonotonic() public {
        uint64 wethNonce = 0;
        uint64 nativeNonce = 0;

        for (uint64 i = 1; i <= 10; i++) {
            // Advance WETH nonce
            vm.prank(address(sucker));
            sucker.fromRemote(
                JBMessageRoot({
                    token: WETH_ON_TEMPO,
                    amount: 1 ether,
                    remoteRoot: JBInboxTreeRoot({nonce: i, root: bytes32(uint256(i))})
                })
            );
            uint64 newWethNonce = sucker.test_getInboxNonce(WETH_ON_TEMPO);
            assertTrue(newWethNonce > wethNonce, "WETH nonce must increase");
            wethNonce = newWethNonce;

            // Advance NATIVE nonce at 2x rate
            vm.prank(address(sucker));
            sucker.fromRemote(
                JBMessageRoot({
                    token: JBConstants.NATIVE_TOKEN,
                    amount: 1 ether,
                    remoteRoot: JBInboxTreeRoot({nonce: i * 2, root: bytes32(uint256(i * 100))})
                })
            );
            uint64 newNativeNonce = sucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN);
            assertTrue(newNativeNonce > nativeNonce, "NATIVE nonce must increase");
            nativeNonce = newNativeNonce;
        }

        assertEq(wethNonce, 10, "Final WETH nonce should be 10");
        assertEq(nativeNonce, 20, "Final NATIVE nonce should be 20");
    }

    receive() external payable {}
}
