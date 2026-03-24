// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerRegistry} from "../src/JBSuckerRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../src/JBSucker.sol";

import {JBSuckerState} from "../src/enums/JBSuckerState.sol";
import {JBClaim} from "../src/structs/JBClaim.sol";
import {JBLeaf} from "../src/structs/JBLeaf.sol";
import {JBInboxTreeRoot} from "../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";
import {JBOutboxTree} from "../src/structs/JBOutboxTree.sol";
import {JBRemoteToken} from "../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../src/structs/JBTokenMapping.sol";
import {MerkleLib} from "../src/utils/MerkleLib.sol";

/// @notice Extended test sucker with additional helpers for deep attack testing.
contract DeepAttackSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    bool nextCheckShouldPass;
    bool public sendRootOverAMBReverted;
    bool public shouldRevertAMB;
    uint256 public lastAMBAmount;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        IJBSuckerRegistry registry,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, 1, registry, forwarder)
    {}

    function _sendRootOverAMB(
        uint256,
        uint256,
        address,
        uint256 amount,
        JBRemoteToken memory,
        JBMessageRoot memory
    )
        internal
        override
    {
        lastAMBAmount = amount;
        if (shouldRevertAMB) {
            sendRootOverAMBReverted = true;
            revert("AMB reverted");
        }
    }

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == _toAddress(peer());
    }

    function peerChainId() external view virtual override returns (uint256) {
        return block.chainid;
    }

    function _validateBranchRoot(
        bytes32 expectedRoot,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
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

    // ========================= Test helpers =========================

    function test_setNextMerkleCheckToBe(bool _pass) external {
        nextCheckShouldPass = _pass;
    }

    function test_setShouldRevertAMB(bool _revert) external {
        shouldRevertAMB = _revert;
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
        bytes32 beneficiary
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

    function test_getOutboxNonce(address token) external view returns (uint64) {
        return _outboxOf[token].nonce;
    }

    function test_getOutboxBalance(address token) external view returns (uint256) {
        return _outboxOf[token].balance;
    }

    function test_getNumberOfClaimsSent(address token) external view returns (uint256) {
        return _outboxOf[token].numberOfClaimsSent;
    }

    function test_setNumberOfClaimsSent(address token, uint256 count) external {
        _outboxOf[token].numberOfClaimsSent = count;
    }

    function test_getInboxRoot(address token) external view returns (bytes32) {
        return _inboxOf[token].root;
    }

    function test_getInboxNonce(address token) external view returns (uint64) {
        return _inboxOf[token].nonce;
    }

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

    function test_getRemoteToken(address localToken) external view returns (JBRemoteToken memory) {
        return _remoteTokenFor[localToken];
    }

    function test_isExecuted(address token, uint256 index) external view returns (bool) {
        return _executedFor[token].get(index);
    }

    function test_isEmergencyExecuted(address terminalToken, uint256 index) external view returns (bool) {
        address emergencyExitAddress = address(bytes20(keccak256(abi.encode(terminalToken))));
        return _executedFor[emergencyExitAddress].get(index);
    }

    function test_setDeprecatedAfter(uint256 timestamp) external {
        deprecatedAfter = timestamp;
    }
}

/// @title SuckerDeepAttacks
/// @notice Comprehensive adversarial security tests for JBSucker covering nonce handling,
///         double-spend vectors, deprecation state machine, emergency exit edge cases,
///         token mapping, merkle proof forgery, and balance manipulation.
contract SuckerDeepAttacks is Test {
    using MerkleLib for MerkleLib.Tree;

    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);
    address constant TERMINAL = address(1200);
    address constant MOCK_REGISTRY = address(1300);

    uint256 constant PROJECT_ID = 1;
    address constant TOKEN = address(0x000000000000000000000000000000000000EEEe); // JBConstants.NATIVE_TOKEN

    DeepAttackSucker sucker;

    function setUp() public {
        // Warp to a reasonable timestamp so deprecation math doesn't underflow.
        vm.warp(100 days);

        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");
        vm.label(TOKENS, "MOCK_TOKENS");
        vm.label(CONTROLLER, "MOCK_CONTROLLER");
        vm.label(TERMINAL, "MOCK_TERMINAL");
        vm.label(MOCK_REGISTRY, "MOCK_REGISTRY");

        sucker = _createTestSucker(PROJECT_ID, "deep_attack_salt");

        // Mock directory
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, TOKEN)), abi.encode(TERMINAL)
        );
        // Mock terminal.addToBalanceOf to accept any call (including payable for native token).
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());
        // Mock terminal.pay so the toRemote fee payment try-catch doesn't revert on ABI decode of empty return data.
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(0)));
    }

    function _createTestSucker(uint256 projectId, bytes32 salt) internal returns (DeepAttackSucker) {
        return _createTestSuckerWithFee(projectId, salt, 0);
    }

    function _createTestSuckerWithFee(uint256 projectId, bytes32 salt, uint256 fee)
        internal
        returns (DeepAttackSucker)
    {
        // Mock registry.toRemoteFee() to return the requested fee.
        vm.mockCall(MOCK_REGISTRY, abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(fee));

        DeepAttackSucker singleton = new DeepAttackSucker(
            IJBDirectory(DIRECTORY),
            IJBPermissions(PERMISSIONS),
            IJBTokens(TOKENS),
            IJBSuckerRegistry(MOCK_REGISTRY),
            FORWARDER
        );

        DeepAttackSucker clone =
            DeepAttackSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        clone.initialize(projectId);

        return clone;
    }

    function _mockMint(address beneficiary, uint256 amount) internal {
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, amount, beneficiary, "", false)),
            abi.encode(amount)
        );
    }

    function _enableTokenMapping(address token) internal {
        sucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );
    }

    // =========================================================================
    // SECTION 1: fromRemote nonce handling
    // =========================================================================

    /// @notice fromRemote with nonce == current nonce: should silently ignore (no update).
    function test_fromRemote_sameNonce_silentlyIgnored() public {
        // Set current inbox nonce to 5.
        sucker.test_setInboxRoot(TOKEN, 5, bytes32(uint256(0xdead)));

        // Try to deliver a root with nonce=5 (same as current).
        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 5, root: bytes32(uint256(0xbeef))})
        });

        vm.prank(address(sucker)); // peer = address(this) for clones
        sucker.fromRemote(root);

        // Inbox should still have the old root, not the new one.
        assertEq(sucker.test_getInboxRoot(TOKEN), bytes32(uint256(0xdead)), "Root should NOT be updated for same nonce");
        assertEq(sucker.test_getInboxNonce(TOKEN), 5, "Nonce should remain 5");
    }

    /// @notice fromRemote with nonce < current: should silently ignore.
    function test_fromRemote_lowerNonce_silentlyIgnored() public {
        sucker.test_setInboxRoot(TOKEN, 10, bytes32(uint256(0xdead)));

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 3, root: bytes32(uint256(0xbeef))})
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root);

        assertEq(sucker.test_getInboxRoot(TOKEN), bytes32(uint256(0xdead)), "Root should NOT update for lower nonce");
        assertEq(sucker.test_getInboxNonce(TOKEN), 10, "Nonce should remain 10");
    }

    /// @notice fromRemote with nonce gap (1 → 5): should accept, skipping intermediate nonces.
    function test_fromRemote_nonceGap_accepted() public {
        sucker.test_setInboxRoot(TOKEN, 1, bytes32(uint256(0xaaa)));

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 5, root: bytes32(uint256(0xbbb))})
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root);

        assertEq(sucker.test_getInboxNonce(TOKEN), 5, "Should accept nonce 5 after nonce 1");
        assertEq(sucker.test_getInboxRoot(TOKEN), bytes32(uint256(0xbbb)), "Root should update");
    }

    /// @notice fromRemote when DEPRECATED: should silently ignore even with valid higher nonce.
    function test_fromRemote_deprecated_stillAccepts() public {
        // Set deprecation in the past so state=DEPRECATED.
        sucker.test_setDeprecatedAfter(block.timestamp - 1);
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.DEPRECATED), "Should be DEPRECATED");

        sucker.test_setInboxRoot(TOKEN, 1, bytes32(uint256(0xaaaa)));

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 2, root: bytes32(uint256(0xbbbb))})
        });

        // Roots are accepted in DEPRECATED state to prevent stranding tokens that were sent
        // before deprecation. Double-spend is not a concern because toRemote is already disabled.
        vm.prank(address(sucker));
        sucker.fromRemote(root);

        assertEq(sucker.test_getInboxRoot(TOKEN), bytes32(uint256(0xbbbb)), "Root SHOULD update even when DEPRECATED");
        assertEq(sucker.test_getInboxNonce(TOKEN), 2, "Nonce should update to 2 even when DEPRECATED");
    }

    /// @notice fromRemote when SENDING_DISABLED: should still accept roots (only sending is disabled).
    function test_fromRemote_sendingDisabled_stillAccepts() public {
        // Set deprecation so we're in SENDING_DISABLED window:
        // state() checks: block.timestamp < deprecatedAfter → not DEPRECATED
        //                  block.timestamp >= deprecatedAfter - 14 days → SENDING_DISABLED
        uint256 deprecateAt = block.timestamp + 1 days; // within 14 day window
        sucker.test_setDeprecatedAfter(deprecateAt);

        // Warp to SENDING_DISABLED window.
        vm.warp(deprecateAt - 1);
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.SENDING_DISABLED), "Should be SENDING_DISABLED");

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xabc))})
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root);

        assertEq(sucker.test_getInboxRoot(TOKEN), bytes32(uint256(0xabc)), "Should accept root in SENDING_DISABLED");
        assertEq(sucker.test_getInboxNonce(TOKEN), 1, "Nonce should update");
    }

    // =========================================================================
    // SECTION 2: Claim proof forgery and cross-token attacks
    // =========================================================================

    /// @notice Claim with wrong beneficiary: merkle proof should fail.
    function test_claim_wrongBeneficiary_reverts() public {
        address realBeneficiary = address(0xAAA);
        address fakeBeneficiary = address(0xBBB);

        // Insert a leaf for the real beneficiary.
        sucker.test_insertIntoTree(10 ether, TOKEN, 5 ether, bytes32(uint256(uint160(realBeneficiary))));
        bytes32 root = sucker.test_getOutboxRoot(TOKEN);
        sucker.test_setInboxRoot(TOKEN, 1, root);
        sucker.test_setOutboxBalance(TOKEN, 100 ether);

        // Try to claim with the WRONG beneficiary — proof won't match.
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(fakeBeneficiary))), // WRONG
                projectTokenCount: 10 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });

        // Should revert with InvalidProof (the hash won't match the tree).
        vm.expectRevert();
        sucker.claim(claimData);
    }

    /// @notice Claim with wrong amount: merkle proof should fail.
    function test_claim_wrongAmount_reverts() public {
        address beneficiary = address(0xAAA);

        sucker.test_insertIntoTree(10 ether, TOKEN, 5 ether, bytes32(uint256(uint160(beneficiary))));
        bytes32 root = sucker.test_getOutboxRoot(TOKEN);
        sucker.test_setInboxRoot(TOKEN, 1, root);
        sucker.test_setOutboxBalance(TOKEN, 100 ether);

        // Try with inflated amount.
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(beneficiary))),
                projectTokenCount: 10 ether,
                terminalTokenAmount: 100 ether // WRONG — real is 5 ether
            }),
            proof: proof
        });

        vm.expectRevert();
        sucker.claim(claimData);
    }

    /// @notice Claim with proof from token A against token B's inbox: should fail.
    function test_claim_crossTokenProof_reverts() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");

        // Insert into tokenA's tree.
        sucker.test_insertIntoTree(10 ether, tokenA, 5 ether, bytes32(uint256(uint160(address(0xAAA)))));

        // Set token B's inbox root to something different.
        sucker.test_setInboxRoot(tokenB, 1, bytes32(uint256(0xcccc)));

        // Claim against token B using token A's proof data → mismatch.
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: tokenB, // targeting token B's inbox
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(0xAAA)))),
                projectTokenCount: 10 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });

        vm.expectRevert();
        sucker.claim(claimData);
    }

    // =========================================================================
    // SECTION 3: Double-spend — claim + emergency exit on same leaf
    // =========================================================================

    /// @notice Verify that a leaf claimed via `claim()` uses a different executed slot
    ///         than `exitThroughEmergencyHatch()`. This is by design — they track
    ///         different trees (inbox vs outbox).
    function test_claimAndEmergencyExit_differentSlots() public {
        // Insert a leaf at index 0 in the outbox.
        sucker.test_insertIntoTree(10 ether, TOKEN, 5 ether, bytes32(uint256(uint160(address(this)))));

        bytes32 outboxRoot = sucker.test_getOutboxRoot(TOKEN);

        // Set inbox root to outbox root (simulating a round-trip).
        sucker.test_setInboxRoot(TOKEN, 1, outboxRoot);
        sucker.test_setOutboxBalance(TOKEN, 100 ether);
        // Fund sucker: outbox balance + claim terminalTokenAmount for _addToBalance.
        vm.deal(address(sucker), 105 ether);

        _mockMint(address(this), 10 ether);

        // Do a regular claim at index 0 (bypass merkle for testing).
        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 10 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });
        sucker.claim(claimData);

        // Verify claim executed for inbox (token-keyed).
        assertTrue(sucker.test_isExecuted(TOKEN, 0), "Index 0 should be marked executed for claim");

        // The emergency exit uses a DIFFERENT key: address(bytes20(keccak256(abi.encode(token)))).
        // So the same index 0 is NOT marked in the emergency slot.
        assertFalse(sucker.test_isEmergencyExecuted(TOKEN, 0), "Emergency slot should NOT be marked by claim");
    }

    /// @notice If a root was already sent (numberOfClaimsSent covers index),
    ///         emergency exit should reject the claim to prevent double-spend.
    function test_emergencyExit_alreadySentRoot_reverts() public {
        // Insert 3 leaves.
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(this)))));
        sucker.test_insertIntoTree(2 ether, TOKEN, 2 ether, bytes32(uint256(uint160(address(this)))));
        sucker.test_insertIntoTree(3 ether, TOKEN, 3 ether, bytes32(uint256(uint160(address(this)))));

        // Mark that 2 claims were sent (indices 0 and 1 covered).
        sucker.test_setNumberOfClaimsSent(TOKEN, 2);
        sucker.test_setOutboxBalance(TOKEN, 100 ether);
        vm.deal(address(sucker), 100 ether);

        // Enable emergency hatch.
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: false, emergencyHatch: true, minGas: 0, addr: bytes32(uint256(uint160(makeAddr("remote"))))
            })
        );

        // Index 0 was part of the sent root → should revert (could be double-spent on remote).
        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 1 ether,
                terminalTokenAmount: 1 ether
            }),
            proof: proof
        });

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, TOKEN, 0));
        sucker.exitThroughEmergencyHatch(claimData);

        // Index 1 (last sent) → should also revert.
        claimData.leaf.index = 1;
        claimData.leaf.projectTokenCount = 2 ether;
        claimData.leaf.terminalTokenAmount = 2 ether;
        sucker.test_setNextMerkleCheckToBe(true);

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, TOKEN, 1));
        sucker.exitThroughEmergencyHatch(claimData);
    }

    /// @notice Index NOT covered by numberOfClaimsSent → emergency exit should succeed.
    function test_emergencyExit_unsentIndex_succeeds() public {
        // Insert 3 leaves.
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(this)))));
        sucker.test_insertIntoTree(2 ether, TOKEN, 2 ether, bytes32(uint256(uint160(address(this)))));
        sucker.test_insertIntoTree(3 ether, TOKEN, 3 ether, bytes32(uint256(uint160(address(this)))));

        // Only 2 were sent (indices 0 and 1). Index 2 was NOT sent.
        sucker.test_setNumberOfClaimsSent(TOKEN, 2);
        sucker.test_setOutboxBalance(TOKEN, 100 ether);
        vm.deal(address(sucker), 100 ether);

        // Enable emergency hatch.
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: false, emergencyHatch: true, minGas: 0, addr: bytes32(uint256(uint160(makeAddr("remote"))))
            })
        );

        _mockMint(address(this), 3 ether);

        // Index 2 → was NOT sent, so emergency exit should work.
        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 2,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 3 ether,
                terminalTokenAmount: 3 ether
            }),
            proof: proof
        });

        sucker.exitThroughEmergencyHatch(claimData);

        // Verify it was marked as executed in the emergency slot.
        assertTrue(sucker.test_isEmergencyExecuted(TOKEN, 2), "Emergency exit at index 2 should be marked");
    }

    /// @notice Double emergency exit with the same index → should revert on second try.
    function test_emergencyExit_doubleClaim_reverts() public {
        sucker.test_insertIntoTree(5 ether, TOKEN, 5 ether, bytes32(uint256(uint160(address(this)))));
        sucker.test_setOutboxBalance(TOKEN, 100 ether);
        vm.deal(address(sucker), 100 ether);

        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: false, emergencyHatch: true, minGas: 0, addr: bytes32(uint256(uint160(makeAddr("remote"))))
            })
        );

        _mockMint(address(this), 5 ether);

        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 5 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });

        // First exit succeeds.
        sucker.exitThroughEmergencyHatch(claimData);

        // Second exit with same index → revert.
        sucker.test_setNextMerkleCheckToBe(true);
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, TOKEN, 0));
        sucker.exitThroughEmergencyHatch(claimData);
    }

    /// @notice Emergency exit when hatch not enabled and not deprecated → should revert.
    function test_emergencyExit_noHatchNoDeprecation_reverts() public {
        sucker.test_insertIntoTree(5 ether, TOKEN, 5 ether, bytes32(uint256(uint160(address(this)))));
        sucker.test_setOutboxBalance(TOKEN, 100 ether);

        // Token is enabled (not emergency hatch), sucker is ENABLED (not deprecated).
        _enableTokenMapping(TOKEN);

        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 5 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_TokenHasInvalidEmergencyHatchState.selector, TOKEN));
        sucker.exitThroughEmergencyHatch(claimData);
    }

    /// @notice Emergency exit balance underflow — claim more than tracked outbox balance.
    function test_emergencyExit_balanceUnderflow_reverts() public {
        sucker.test_insertIntoTree(10 ether, TOKEN, 10 ether, bytes32(uint256(uint160(address(this)))));

        // Set outbox balance to only 1 ether, but claim asks for 10 ether.
        sucker.test_setOutboxBalance(TOKEN, 1 ether);
        vm.deal(address(sucker), 100 ether);

        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: false, emergencyHatch: true, minGas: 0, addr: bytes32(uint256(uint160(makeAddr("remote"))))
            })
        );

        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 10 ether,
                terminalTokenAmount: 10 ether
            }),
            proof: proof
        });

        // _outboxOf[token].balance -= 10 ether when balance is only 1 ether → arithmetic underflow.
        vm.expectRevert();
        sucker.exitThroughEmergencyHatch(claimData);
    }

    // =========================================================================
    // SECTION 4: Deprecation state machine
    // =========================================================================

    /// @notice Verify the full state progression: ENABLED → DEPRECATION_PENDING → SENDING_DISABLED → DEPRECATED.
    function test_deprecationStateMachine_fullProgression() public {
        // Initially ENABLED.
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.ENABLED));

        // Set deprecation 30 days from now.
        uint256 deprecateAt = block.timestamp + 30 days;
        sucker.test_setDeprecatedAfter(deprecateAt);

        // Still before (deprecateAt - 14 days) → DEPRECATION_PENDING.
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.DEPRECATION_PENDING));

        // Warp to exactly (deprecateAt - 14 days) → SENDING_DISABLED.
        vm.warp(deprecateAt - 14 days);
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.SENDING_DISABLED));

        // Warp to just before deprecateAt → still SENDING_DISABLED.
        vm.warp(deprecateAt - 1);
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.SENDING_DISABLED));

        // Warp to exactly deprecateAt → DEPRECATED.
        vm.warp(deprecateAt);
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.DEPRECATED));
    }

    /// @notice setDeprecation too soon (less than maxMessagingDelay from now) → should revert.
    function test_setDeprecation_tooSoon_reverts() public {
        // Mock permissions for the owner.
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        // Try to set deprecation 1 day from now (too soon, min is 14 days).
        uint256 tooSoon = uint40(block.timestamp + 1 days);
        vm.expectRevert();
        sucker.setDeprecation(uint40(tooSoon));
    }

    /// @notice setDeprecation(0) cancels deprecation and returns to ENABLED.
    function test_setDeprecation_zero_cancelsDeprecation() public {
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        // Set a valid deprecation.
        uint256 validTime = block.timestamp + 30 days;
        sucker.setDeprecation(uint40(validTime));
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.DEPRECATION_PENDING));

        // Cancel it.
        sucker.setDeprecation(0);
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.ENABLED));
    }

    /// @notice setDeprecation when already SENDING_DISABLED → should revert.
    function test_setDeprecation_whenSendingDisabled_reverts() public {
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        // Force SENDING_DISABLED state.
        uint256 deprecateAt = block.timestamp + 1 days;
        sucker.test_setDeprecatedAfter(deprecateAt);
        vm.warp(deprecateAt - 1); // within 14-day window
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.SENDING_DISABLED));

        // Try to change deprecation — should revert (already in terminal path).
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_Deprecated.selector));
        sucker.setDeprecation(uint40(block.timestamp + 60 days));
    }

    // =========================================================================
    // SECTION 5: Token mapping edge cases
    // =========================================================================

    /// @notice Remapping a token with existing outbox items → should revert.
    function test_mapToken_remapWithExistingOutbox_reverts() public {
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        address token = makeAddr("erc20Token");
        address remoteA = makeAddr("remoteA");
        address remoteB = makeAddr("remoteB");

        // Initial mapping.
        sucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: true, emergencyHatch: false, minGas: 200_000, addr: bytes32(uint256(uint160(remoteA)))
            })
        );

        // Insert items into the outbox (creating tree count > 0).
        sucker.test_insertIntoTree(10 ether, token, 5 ether, bytes32(uint256(uint160(address(this)))));

        // Try to remap to a different remote token.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSucker.JBSucker_TokenAlreadyMapped.selector, token, bytes32(uint256(uint160(remoteA)))
            )
        );
        sucker.mapToken(
            JBTokenMapping({localToken: token, minGas: 200_000, remoteToken: bytes32(uint256(uint160(remoteB)))})
        );
    }

    /// @notice Mapping after emergency hatch enabled → should revert.
    function test_mapToken_afterEmergencyHatch_reverts() public {
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        address token = makeAddr("erc20Token");

        // Enable emergency hatch.
        sucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: false,
                emergencyHatch: true,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remote"))))
            })
        );

        // Try any mapping operation.
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_TokenHasInvalidEmergencyHatchState.selector, token));
        sucker.mapToken(
            JBTokenMapping({
                localToken: token, minGas: 200_000, remoteToken: bytes32(uint256(uint160(makeAddr("newRemote"))))
            })
        );
    }

    /// @notice mapToken without permission → should revert.
    function test_mapToken_noPermission_reverts() public {
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false));

        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert();
        sucker.mapToken(
            JBTokenMapping({
                localToken: makeAddr("token"),
                minGas: 200_000,
                remoteToken: bytes32(uint256(uint160(makeAddr("remote"))))
            })
        );
    }

    /// @notice mapToken: native token → non-native remote → should revert.
    function test_mapToken_nativeToNonNative_reverts() public {
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        bytes32 nonNativeRemote = bytes32(uint256(uint160(makeAddr("nonNative"))));
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_InvalidNativeRemoteAddress.selector, nonNativeRemote));
        sucker.mapToken(JBTokenMapping({localToken: JBConstants.NATIVE_TOKEN, minGas: 0, remoteToken: nonNativeRemote}));
    }

    /// @notice mapToken: ERC20 with gas below minimum → should revert.
    function test_mapToken_belowMinGas_reverts() public {
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBSucker.JBSucker_BelowMinGas.selector,
                100, // given
                200_000 // minimum
            )
        );
        sucker.mapToken(
            JBTokenMapping({
                localToken: makeAddr("erc20"),
                minGas: 100, // Way below MESSENGER_ERC20_MIN_GAS_LIMIT
                remoteToken: bytes32(uint256(uint160(makeAddr("remote"))))
            })
        );
    }

    // =========================================================================
    // SECTION 6: prepare() edge cases
    // =========================================================================

    /// @notice prepare with zero beneficiary → should revert.
    function test_prepare_zeroBeneficiary_reverts() public {
        _enableTokenMapping(TOKEN);

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_ZeroBeneficiary.selector));
        sucker.prepare(10 ether, bytes32(0), 0, TOKEN);
    }

    /// @notice prepare when SENDING_DISABLED → should revert.
    function test_prepare_sendingDisabled_reverts() public {
        _enableTokenMapping(TOKEN);

        // Mock TOKENS.tokenOf() so prepare gets past the project token check.
        vm.mockCall(TOKENS, abi.encodeCall(IJBTokens.tokenOf, (PROJECT_ID)), abi.encode(makeAddr("projectToken")));

        // Force SENDING_DISABLED.
        uint256 deprecateAt = block.timestamp + 1 days;
        sucker.test_setDeprecatedAfter(deprecateAt);
        vm.warp(deprecateAt - 1);
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.SENDING_DISABLED));

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_Deprecated.selector));
        sucker.prepare(10 ether, bytes32(uint256(uint160(address(this)))), 0, TOKEN);
    }

    /// @notice prepare when DEPRECATED → should revert.
    function test_prepare_deprecated_reverts() public {
        _enableTokenMapping(TOKEN);

        // Mock TOKENS.tokenOf() so prepare gets past the project token check.
        vm.mockCall(TOKENS, abi.encodeCall(IJBTokens.tokenOf, (PROJECT_ID)), abi.encode(makeAddr("projectToken")));

        sucker.test_setDeprecatedAfter(block.timestamp - 1);
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.DEPRECATED));

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_Deprecated.selector));
        sucker.prepare(10 ether, bytes32(uint256(uint160(address(this)))), 0, TOKEN);
    }

    /// @notice prepare with unmapped token → should revert.
    function test_prepare_unmappedToken_reverts() public {
        address unmapped = makeAddr("unmappedToken");

        // Mock token check (project has an ERC20 token).
        vm.mockCall(TOKENS, abi.encodeCall(IJBTokens.tokenOf, (PROJECT_ID)), abi.encode(makeAddr("projectToken")));

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_TokenNotMapped.selector, unmapped));
        sucker.prepare(10 ether, bytes32(uint256(uint160(address(this)))), 0, unmapped);
    }

    // =========================================================================
    // SECTION 7: toRemote / _sendRoot edge cases
    // =========================================================================

    /// @notice toRemote with emergency hatch enabled → should revert.
    function test_toRemote_emergencyHatch_reverts() public {
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: false, emergencyHatch: true, minGas: 0, addr: bytes32(uint256(uint160(makeAddr("remote"))))
            })
        );

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_TokenHasInvalidEmergencyHatchState.selector, TOKEN));
        sucker.toRemote(TOKEN);
    }

    /// @notice toRemote with nothing to send (empty outbox, no new claims) → should revert.
    function test_toRemote_nothingToSend_reverts() public {
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remote"))))
            })
        );

        // Nothing in the outbox — balance is 0, count == numberOfClaimsSent == 0.
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_NothingToSend.selector));
        sucker.toRemote(TOKEN);
    }

    /// @notice toRemote with insufficient msg.value for toRemoteFee → should revert.
    function test_toRemote_insufficientFee_reverts() public {
        // Create a sucker with toRemoteFee = 0.001 ether (via registry mock).
        DeepAttackSucker feeSucker = _createTestSuckerWithFee(PROJECT_ID, "fee_sucker_salt", 0.001 ether);

        feeSucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remote"))))
            })
        );

        // Insert an item so there IS something to send.
        feeSucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(this)))));

        // Send less than the required fee (toRemoteFee = 0.001 ether).
        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_InsufficientMsgValue.selector, 0.0005 ether, 0.001 ether)
        );
        feeSucker.toRemote{value: 0.0005 ether}(TOKEN);
    }

    // ==================== Registry setToRemoteFee tests ====================

    /// @notice Registry owner can set fee within MAX_TO_REMOTE_FEE.
    function test_registry_setToRemoteFee_happyPath() public {
        JBSuckerRegistry registry = new JBSuckerRegistry({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            initialOwner: address(this),
            trustedForwarder: FORWARDER
        });

        registry.setToRemoteFee(0.0005 ether);
        assertEq(registry.toRemoteFee(), 0.0005 ether, "Fee should be updated");
    }

    /// @notice Registry owner can set fee to exactly MAX_TO_REMOTE_FEE.
    function test_registry_setToRemoteFee_exactMax() public {
        JBSuckerRegistry registry = new JBSuckerRegistry({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            initialOwner: address(this),
            trustedForwarder: FORWARDER
        });

        registry.setToRemoteFee(0.001 ether);
        assertEq(registry.toRemoteFee(), 0.001 ether, "Fee should be set to max");
    }

    /// @notice Registry owner can set fee to zero.
    function test_registry_setToRemoteFee_zero() public {
        JBSuckerRegistry registry = new JBSuckerRegistry({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            initialOwner: address(this),
            trustedForwarder: FORWARDER
        });

        assertEq(registry.toRemoteFee(), 0.001 ether, "Initial fee should be MAX_TO_REMOTE_FEE");

        registry.setToRemoteFee(0);
        assertEq(registry.toRemoteFee(), 0, "Fee should be zero");
    }

    /// @notice Non-owner cannot set fee on registry.
    function test_registry_setToRemoteFee_unauthorized_reverts() public {
        JBSuckerRegistry registry = new JBSuckerRegistry({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            initialOwner: address(this),
            trustedForwarder: FORWARDER
        });

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        registry.setToRemoteFee(0.0005 ether);
    }

    /// @notice Fee above MAX_TO_REMOTE_FEE reverts on registry.
    function test_registry_setToRemoteFee_exceedsMax_reverts() public {
        JBSuckerRegistry registry = new JBSuckerRegistry({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            initialOwner: address(this),
            trustedForwarder: FORWARDER
        });

        vm.expectRevert(
            abi.encodeWithSelector(JBSuckerRegistry.JBSuckerRegistry_FeeExceedsMax.selector, 0.002 ether, 0.001 ether)
        );
        registry.setToRemoteFee(0.002 ether);
    }

    /// @notice setToRemoteFee on registry emits ToRemoteFeeChanged event.
    function test_registry_setToRemoteFee_emitsEvent() public {
        JBSuckerRegistry registry = new JBSuckerRegistry({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            initialOwner: address(this),
            trustedForwarder: FORWARDER
        });

        vm.expectEmit(false, false, false, true, address(registry));
        emit IJBSuckerRegistry.ToRemoteFeeChanged(0.001 ether, 0.0005 ether, address(this));

        registry.setToRemoteFee(0.0005 ether);
    }

    /// @notice Registry initializes toRemoteFee to MAX_TO_REMOTE_FEE.
    function test_registry_toRemoteFee_initializedToMax() public {
        JBSuckerRegistry registry = new JBSuckerRegistry({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            initialOwner: address(this),
            trustedForwarder: FORWARDER
        });

        assertEq(registry.toRemoteFee(), 0.001 ether, "toRemoteFee should be initialized to MAX_TO_REMOTE_FEE");
        assertEq(registry.MAX_TO_REMOTE_FEE(), 0.001 ether, "MAX_TO_REMOTE_FEE should be 0.001 ether");
    }

    // ==================== End Registry setToRemoteFee tests ====================

    /// @notice _sendRoot clears balance BEFORE AMB call — verify balance is 0 after toRemote.
    function test_sendRoot_clearsBalanceBeforeAMB() public {
        _enableTokenMapping(TOKEN);

        // Insert items with total balance of 10 ether.
        sucker.test_insertIntoTree(5 ether, TOKEN, 5 ether, bytes32(uint256(uint160(address(this)))));
        sucker.test_insertIntoTree(5 ether, TOKEN, 5 ether, bytes32(uint256(uint160(address(0xBBB)))));

        assertEq(sucker.test_getOutboxBalance(TOKEN), 10 ether, "Outbox balance should be 10 ether");

        // Send root.
        sucker.toRemote(TOKEN);

        // Balance should be cleared.
        assertEq(sucker.test_getOutboxBalance(TOKEN), 0, "Outbox balance should be 0 after sendRoot");

        // Nonce should be incremented.
        assertEq(sucker.test_getOutboxNonce(TOKEN), 1, "Nonce should be 1");

        // numberOfClaimsSent should be updated.
        assertEq(sucker.test_getNumberOfClaimsSent(TOKEN), 2, "numberOfClaimsSent should be 2");

        // The AMB received the correct amount.
        assertEq(sucker.lastAMBAmount(), 10 ether, "AMB should receive 10 ether");
    }

    /// @notice If AMB reverts after balance cleared, funds are lost. Verify the behavior.
    function test_sendRoot_AMBRevert_fundsLost() public {
        _enableTokenMapping(TOKEN);

        sucker.test_insertIntoTree(10 ether, TOKEN, 10 ether, bytes32(uint256(uint160(address(this)))));

        // Make AMB revert.
        sucker.test_setShouldRevertAMB(true);

        // toRemote will revert, which means the entire tx reverts and balance is NOT cleared.
        // This is actually the correct behavior — the revert rolls back state.
        vm.expectRevert("AMB reverted");
        sucker.toRemote(TOKEN);

        // Verify balance was NOT cleared (tx reverted).
        assertEq(sucker.test_getOutboxBalance(TOKEN), 10 ether, "Balance should remain if AMB reverts");
    }

    // =========================================================================
    // SECTION 8: Balance manipulation
    // =========================================================================

    /// @notice Direct ETH transfer inflates actual balance but not tracked outbox balance.
    ///         amountToAddToBalanceOf should reflect the difference.
    function test_amountToAddToBalance_inflatedByDirectTransfer() public {
        // Send 10 ether directly first, then set tracked outbox balance.
        vm.deal(address(sucker), 10 ether);

        // Set tracked outbox balance (must be <= actual balance to avoid underflow).
        sucker.test_setOutboxBalance(TOKEN, 3 ether);

        // amountToAddToBalanceOf = actualBalance - outboxBalance = 10 - 3 = 7 ether.
        uint256 addable = sucker.amountToAddToBalanceOf(TOKEN);
        assertEq(addable, 7 ether, "Addable should be actual minus tracked");
    }

    // =========================================================================
    // SECTION 9: enableEmergencyHatchFor edge cases
    // =========================================================================

    /// @notice enableEmergencyHatchFor without SUCKER_SAFETY permission → should revert.
    function test_enableEmergencyHatch_noPermission_reverts() public {
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false));

        address[] memory tokens = new address[](1);
        tokens[0] = TOKEN;

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        sucker.enableEmergencyHatchFor(tokens);
    }

    /// @notice enableEmergencyHatchFor sets emergencyHatch=true and enabled=false.
    function test_enableEmergencyHatch_setsCorrectState() public {
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        // Start with enabled token.
        _enableTokenMapping(TOKEN);
        JBRemoteToken memory before = sucker.test_getRemoteToken(TOKEN);
        assertTrue(before.enabled, "Should start enabled");
        assertFalse(before.emergencyHatch, "Should start without hatch");

        address[] memory tokens = new address[](1);
        tokens[0] = TOKEN;
        sucker.enableEmergencyHatchFor(tokens);

        JBRemoteToken memory after_ = sucker.test_getRemoteToken(TOKEN);
        assertFalse(after_.enabled, "Should be disabled after hatch");
        assertTrue(after_.emergencyHatch, "Emergency hatch should be true");
    }

    // =========================================================================
    // SECTION 10: Merkle tree integrity
    // =========================================================================

    /// @notice Multiple insertions produce unique roots. Verify no collisions.
    function test_merkleTree_uniqueRootsPerInsertion() public {
        bytes32[] memory roots = new bytes32[](20);

        for (uint256 i = 0; i < 20; i++) {
            sucker.test_insertIntoTree((i + 1) * 1 ether, TOKEN, (i + 1) * 0.5 ether, bytes32(uint256(1000 + i)));
            roots[i] = sucker.test_getOutboxRoot(TOKEN);
        }

        // Verify all roots are unique.
        for (uint256 i = 0; i < 20; i++) {
            for (uint256 j = i + 1; j < 20; j++) {
                assertTrue(roots[i] != roots[j], "Roots should be unique");
            }
        }

        assertEq(sucker.test_getOutboxCount(TOKEN), 20, "Count should be 20");
    }

    /// @notice Verify that the _buildTreeHash is deterministic and order-sensitive.
    function test_treeHash_deterministic() public pure {
        bytes32 hash1 =
            keccak256(abi.encode(uint256(10 ether), uint256(5 ether), bytes32(uint256(uint160(address(0xAAA))))));
        bytes32 hash2 =
            keccak256(abi.encode(uint256(10 ether), uint256(5 ether), bytes32(uint256(uint160(address(0xAAA))))));
        bytes32 hash3 =
            keccak256(abi.encode(uint256(5 ether), uint256(10 ether), bytes32(uint256(uint160(address(0xAAA)))))); // swapped

        assertEq(hash1, hash2, "Same inputs should produce same hash");
        assertTrue(hash1 != hash3, "Different inputs should produce different hash");
    }

    // =========================================================================
    // SECTION 11: Claim when no inbox root set
    // =========================================================================

    /// @notice Claim when inbox root is bytes32(0) → proof check will fail.
    function test_claim_noInboxRoot_reverts() public {
        // Don't set any inbox root. inbox.root is bytes32(0).
        assertEq(sucker.test_getInboxRoot(TOKEN), bytes32(0), "Inbox should be empty");

        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 10 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });

        // The computed branch root won't match bytes32(0).
        vm.expectRevert();
        sucker.claim(claimData);
    }

    // =========================================================================
    // SECTION 12: toRemote when DEPRECATED or SENDING_DISABLED
    // =========================================================================

    /// @notice toRemote when DEPRECATED → _sendRoot should revert.
    function test_toRemote_deprecated_reverts() public {
        _enableTokenMapping(TOKEN);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(this)))));

        sucker.test_setDeprecatedAfter(block.timestamp - 1);
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.DEPRECATED));

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_Deprecated.selector));
        sucker.toRemote(TOKEN);
    }

    /// @notice toRemote when SENDING_DISABLED → _sendRoot should revert.
    function test_toRemote_sendingDisabled_reverts() public {
        _enableTokenMapping(TOKEN);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(this)))));

        uint256 deprecateAt = block.timestamp + 1 days;
        sucker.test_setDeprecatedAfter(deprecateAt);
        vm.warp(deprecateAt - 1);
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.SENDING_DISABLED));

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_Deprecated.selector));
        sucker.toRemote(TOKEN);
    }

    // =========================================================================
    // SECTION 13: Emergency exit via deprecation (not per-token hatch)
    // =========================================================================

    /// @notice When sucker is DEPRECATED (not per-token hatch), emergency exit should work.
    function test_emergencyExit_viaDeprecation_succeeds() public {
        // Insert a leaf.
        sucker.test_insertIntoTree(5 ether, TOKEN, 5 ether, bytes32(uint256(uint160(address(this)))));
        sucker.test_setOutboxBalance(TOKEN, 100 ether);
        vm.deal(address(sucker), 100 ether);

        // Token is NOT hatch-enabled, but sucker is DEPRECATED.
        _enableTokenMapping(TOKEN);
        sucker.test_setDeprecatedAfter(block.timestamp - 1);
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.DEPRECATED));

        _mockMint(address(this), 5 ether);

        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 5 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });

        // Should succeed because DEPRECATED state allows emergency exit.
        sucker.exitThroughEmergencyHatch(claimData);
        assertTrue(sucker.test_isEmergencyExecuted(TOKEN, 0), "Should be marked executed");
    }

    /// @notice When SENDING_DISABLED, emergency exit should also work.
    function test_emergencyExit_viaSendingDisabled_succeeds() public {
        sucker.test_insertIntoTree(5 ether, TOKEN, 5 ether, bytes32(uint256(uint160(address(this)))));
        sucker.test_setOutboxBalance(TOKEN, 100 ether);
        vm.deal(address(sucker), 100 ether);

        _enableTokenMapping(TOKEN);

        // Force SENDING_DISABLED.
        uint256 deprecateAt = block.timestamp + 1 days;
        sucker.test_setDeprecatedAfter(deprecateAt);
        vm.warp(deprecateAt - 1);
        assertEq(uint256(sucker.state()), uint256(JBSuckerState.SENDING_DISABLED));

        _mockMint(address(this), 5 ether);

        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 5 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });

        sucker.exitThroughEmergencyHatch(claimData);
        assertTrue(sucker.test_isEmergencyExecuted(TOKEN, 0), "Should be marked executed");
    }

    // =========================================================================
    // SECTION 14: Multiple claims on different indices
    // =========================================================================

    /// @notice Claim multiple indices sequentially — each should succeed once.
    function test_claim_multipleIndices_eachSucceedsOnce() public {
        // Insert 5 leaves.
        for (uint256 i = 0; i < 5; i++) {
            sucker.test_insertIntoTree((i + 1) * 1 ether, TOKEN, (i + 1) * 0.5 ether, bytes32(uint256(100 + i)));
        }

        bytes32 root = sucker.test_getOutboxRoot(TOKEN);
        sucker.test_setInboxRoot(TOKEN, 1, root);
        sucker.test_setOutboxBalance(TOKEN, 100 ether);
        // Fund sucker: outbox balance + total claim amounts (0.5+1+1.5+2+2.5 = 7.5 ether).
        vm.deal(address(sucker), 108 ether);

        // Claim each index.
        for (uint256 i = 0; i < 5; i++) {
            _mockMint(address(uint160(100 + i)), (i + 1) * 1 ether);

            sucker.test_setNextMerkleCheckToBe(true);
            bytes32[32] memory proof;
            JBClaim memory claimData = JBClaim({
                token: TOKEN,
                leaf: JBLeaf({
                    index: i,
                    beneficiary: bytes32(uint256(100 + i)),
                    projectTokenCount: (i + 1) * 1 ether,
                    terminalTokenAmount: (i + 1) * 0.5 ether
                }),
                proof: proof
            });

            sucker.claim(claimData);
            assertTrue(sucker.test_isExecuted(TOKEN, i), "Index should be marked executed");
        }

        // Re-claiming any index should fail.
        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory dupProof;
        JBClaim memory dupClaim = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 2, beneficiary: bytes32(uint256(102)), projectTokenCount: 3 ether, terminalTokenAmount: 1.5 ether
            }),
            proof: dupProof
        });

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, TOKEN, 2));
        sucker.claim(dupClaim);
    }

    // =========================================================================
    // SECTION 15: Nonce increment on toRemote
    // =========================================================================

    /// @notice Multiple toRemote calls increment nonce sequentially.
    function test_toRemote_nonceIncrementsSequentially() public {
        _enableTokenMapping(TOKEN);

        // Round 1.
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(this)))));
        sucker.toRemote(TOKEN);
        assertEq(sucker.test_getOutboxNonce(TOKEN), 1);

        // Round 2.
        sucker.test_insertIntoTree(2 ether, TOKEN, 2 ether, bytes32(uint256(uint160(address(this)))));
        sucker.toRemote(TOKEN);
        assertEq(sucker.test_getOutboxNonce(TOKEN), 2);

        // Round 3.
        sucker.test_insertIntoTree(3 ether, TOKEN, 3 ether, bytes32(uint256(uint160(address(this)))));
        sucker.toRemote(TOKEN);
        assertEq(sucker.test_getOutboxNonce(TOKEN), 3);
    }

    /// @notice toRemote with zero outbox balance but unsent tree items → should still work
    ///         because count != numberOfClaimsSent (the "nothing to send" guard passes).
    function test_toRemote_zeroBalance_zeroMin_succeeds() public {
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remote"))))
            })
        );

        // Insert an item with 0 terminal token amount.
        sucker.test_insertIntoTree(1 ether, TOKEN, 0, bytes32(uint256(uint160(address(this)))));

        // Balance is 0, but count (1) != numberOfClaimsSent (0) → passes nothing-to-send guard.
        sucker.toRemote(TOKEN);
        assertEq(sucker.test_getOutboxNonce(TOKEN), 1);
    }

    // =========================================================================
    // SECTION 16: MESSAGE_VERSION validation (INTEROP)
    // =========================================================================

    /// @notice fromRemote with wrong message version → should revert with InvalidMessageVersion.
    function test_fromRemote_wrongVersion_reverts() public {
        JBMessageRoot memory root = JBMessageRoot({
            version: 0, // Wrong version — current is 1
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xbeef))})
        });

        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_InvalidMessageVersion.selector, 0, sucker.MESSAGE_VERSION())
        );
        vm.prank(address(sucker)); // peer
        sucker.fromRemote(root);
    }

    /// @notice fromRemote with future message version → should revert with InvalidMessageVersion.
    function test_fromRemote_futureVersion_reverts() public {
        JBMessageRoot memory root = JBMessageRoot({
            version: 2, // Future version
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xbeef))})
        });

        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_InvalidMessageVersion.selector, 2, sucker.MESSAGE_VERSION())
        );
        vm.prank(address(sucker));
        sucker.fromRemote(root);
    }

    /// @notice fromRemote with correct version → should NOT revert with InvalidMessageVersion.
    function test_fromRemote_correctVersion_passesVersionCheck() public {
        JBMessageRoot memory root = JBMessageRoot({
            version: sucker.MESSAGE_VERSION(),
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xbeef))})
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root);

        // Should update inbox since version is correct and nonce is higher.
        assertEq(sucker.test_getInboxNonce(TOKEN), 1, "Nonce should be 1 after valid message");
        assertEq(sucker.test_getInboxRoot(TOKEN), bytes32(uint256(0xbeef)), "Root should be updated");
    }

    // =========================================================================
    // StaleRootRejected event emission
    // =========================================================================

    /// @notice fromRemote with stale nonce should emit StaleRootRejected event.
    function test_fromRemote_staleNonce_emitsEvent() public {
        sucker.test_setInboxRoot(TOKEN, 5, bytes32(uint256(0xdead)));

        JBMessageRoot memory root = JBMessageRoot({
            version: sucker.MESSAGE_VERSION(),
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 3, root: bytes32(uint256(0xbeef))})
        });

        vm.expectEmit(true, false, false, true, address(sucker));
        emit IJBSucker.StaleRootRejected({token: TOKEN, receivedNonce: 3, currentNonce: 5});

        vm.prank(address(sucker));
        sucker.fromRemote(root);
    }

    // =========================================================================
    // SECTION 17: uint128 overflow guard (INTEROP-5)
    // =========================================================================

    /// @notice prepare with terminalTokenAmount > uint128 max → should revert.
    function test_prepare_terminalAmountExceedsUint128_reverts() public {
        _enableTokenMapping(TOKEN);

        vm.mockCall(TOKENS, abi.encodeCall(IJBTokens.tokenOf, (PROJECT_ID)), abi.encode(makeAddr("projectToken")));

        // Mock the token transfer for prepare
        vm.mockCall(makeAddr("projectToken"), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

        // The overflow guard fires inside _insertIntoTree, which is called from prepare
        // after computing terminalTokenAmount. For a direct test, use the test helper.
        uint256 overflowAmount = uint256(type(uint128).max) + 1;

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_AmountExceedsUint128.selector, overflowAmount));
        sucker.test_insertIntoTree(1 ether, TOKEN, overflowAmount, bytes32(uint256(uint160(address(this)))));
    }

    /// @notice prepare with projectTokenCount > uint128 max → should revert.
    function test_prepare_projectTokenCountExceedsUint128_reverts() public {
        uint256 overflowAmount = uint256(type(uint128).max) + 1;

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_AmountExceedsUint128.selector, overflowAmount));
        sucker.test_insertIntoTree(overflowAmount, TOKEN, 1 ether, bytes32(uint256(uint160(address(this)))));
    }

    /// @notice Amounts at exactly uint128 max → should succeed.
    function test_insertIntoTree_exactUint128Max_succeeds() public {
        uint256 maxU128 = uint256(type(uint128).max);

        // Both at max should work.
        sucker.test_insertIntoTree(maxU128, TOKEN, maxU128, bytes32(uint256(uint160(address(this)))));
        assertEq(sucker.test_getOutboxCount(TOKEN), 1, "Should have 1 item");
    }

    /// @notice Fuzz: any amount > uint128 max should revert.
    function test_insertIntoTree_fuzz_uint128Overflow_reverts(uint256 amount) public {
        amount = bound(amount, uint256(type(uint128).max) + 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_AmountExceedsUint128.selector, amount));
        sucker.test_insertIntoTree(amount, TOKEN, 1 ether, bytes32(uint256(uint160(address(this)))));
    }

    // =========================================================================
    // SECTION 18: bytes32 peer and beneficiary (INTEROP cross-VM compat)
    // =========================================================================

    /// @notice peer() returns bytes32 representation of address(this).
    function test_peer_returnBytes32() public view {
        bytes32 peerValue = sucker.peer();
        assertEq(peerValue, bytes32(uint256(uint160(address(sucker)))), "peer should be bytes32 of address");
    }

    /// @notice prepare with bytes32(0) beneficiary → reverts with ZeroBeneficiary.
    function test_prepare_zeroBeneficiaryBytes32_reverts() public {
        _enableTokenMapping(TOKEN);

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_ZeroBeneficiary.selector));
        sucker.prepare(10 ether, bytes32(0), 0, TOKEN);
    }

    /// @notice prepare with a valid 32-byte SVM beneficiary (non-EVM format) → should succeed past beneficiary check.
    function test_prepare_svmBeneficiary_passesCheck() public {
        _enableTokenMapping(TOKEN);
        vm.mockCall(TOKENS, abi.encodeCall(IJBTokens.tokenOf, (PROJECT_ID)), abi.encode(makeAddr("projectToken")));

        // A typical SVM address has all 32 bytes used (high bits non-zero).
        bytes32 svmBeneficiary = bytes32(uint256(0xdeadbeefcafebabe1234567890abcdef1234567890abcdef1234567890abcdef));

        // This will proceed past the beneficiary check. It may fail later (e.g., token transfer),
        // but should NOT fail with ZeroBeneficiary.
        vm.mockCall(makeAddr("projectToken"), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

        // May revert for other reasons (token handling), but NOT ZeroBeneficiary.
        try sucker.prepare(10 ether, svmBeneficiary, 0, TOKEN) {}
        catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(selector != JBSucker.JBSucker_ZeroBeneficiary.selector, "Should not revert with ZeroBeneficiary");
        }
    }

    /// @notice mapToken with bytes32(0) remoteToken disables the mapping.
    function test_mapToken_bytes32ZeroDisables() public {
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        address token = makeAddr("erc20Token");

        // First enable a mapping.
        sucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteA"))))
            })
        );

        // Map to bytes32(0) to disable.
        sucker.mapToken(JBTokenMapping({localToken: token, minGas: 200_000, remoteToken: bytes32(0)}));

        JBRemoteToken memory mapping_ = sucker.test_getRemoteToken(token);
        assertFalse(mapping_.enabled, "Should be disabled");
        // addr is preserved (so it can be re-enabled to the same remote).
        assertEq(mapping_.addr, bytes32(uint256(uint160(makeAddr("remoteA")))), "Remote addr should be preserved");
    }

    /// @notice fromRemote with same nonce (not strictly greater) should emit StaleRootRejected.
    function test_fromRemote_sameNonce_emitsEvent() public {
        sucker.test_setInboxRoot(TOKEN, 5, bytes32(uint256(0xdead)));

        JBMessageRoot memory root = JBMessageRoot({
            version: sucker.MESSAGE_VERSION(),
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 5, root: bytes32(uint256(0xbeef))})
        });

        vm.expectEmit(true, false, false, true, address(sucker));
        emit IJBSucker.StaleRootRejected({token: TOKEN, receivedNonce: 5, currentNonce: 5});

        vm.prank(address(sucker));
        sucker.fromRemote(root);

        // Inbox should remain unchanged.
        assertEq(sucker.test_getInboxNonce(TOKEN), 5, "Nonce should remain unchanged");
    }

    receive() external payable {}
}
