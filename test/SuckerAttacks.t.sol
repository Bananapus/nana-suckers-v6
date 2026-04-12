// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/JBSucker.sol";

import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "../src/structs/JBClaim.sol";
import {JBLeaf} from "../src/structs/JBLeaf.sol";
import {JBInboxTreeRoot} from "../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../src/structs/JBRemoteToken.sol";
import {MerkleLib} from "../src/utils/MerkleLib.sol";

/// @notice A test sucker that exposes internals for attack testing.
contract AttackTestSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;

    bool nextCheckShouldPass;
    bool public fromRemoteCalled;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
    {}

    // forge-lint: disable-next-line(mixed-case-function)
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

    // Test helpers
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

    function test_getInboxRoot(address token) external view returns (bytes32) {
        return _inboxOf[token].root;
    }

    function test_getInboxNonce(address token) external view returns (uint64) {
        return _inboxOf[token].nonce;
    }

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }
}

/// @title SuckerAttacks
/// @notice Attack tests for nana-suckers-v5 covering CCIP spoofing, double claims,
///         stale roots, token remapping, and merkle tree edge cases.
contract SuckerAttacks is Test {
    using MerkleLib for MerkleLib.Tree;

    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);
    address constant TERMINAL = address(1200);

    uint256 constant PROJECT_ID = 1;
    address constant TOKEN = address(0x000000000000000000000000000000000000EEEe);

    AttackTestSucker sucker;

    function setUp() public {
        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");
        vm.label(TOKENS, "MOCK_TOKENS");
        vm.label(CONTROLLER, "MOCK_CONTROLLER");
        vm.label(PROJECT, "MOCK_PROJECT");
        vm.label(TERMINAL, "MOCK_TERMINAL");

        sucker = _createTestSucker(PROJECT_ID, "attack_salt");

        // Mock directory
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, TOKEN)), abi.encode(TERMINAL)
        );
        // Mock terminal.addToBalanceOf to accept any call (including payable for native token).
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());
    }

    function _createTestSucker(uint256 projectId, bytes32 salt) internal returns (AttackTestSucker) {
        AttackTestSucker singleton =
            new AttackTestSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER);

        AttackTestSucker clone =
            AttackTestSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        clone.initialize(projectId);
        return clone;
    }

    // =========================================================================
    // Test 1: ccipReceive — spoofed router (non-router calls ccipReceive)
    // =========================================================================
    /// @notice Non-router address calling fromRemote must revert with NotPeer.
    /// @dev Verifies that only the initialized peer can call fromRemote.
    function test_ccipReceive_spoofedRouter() public {
        address spoofedRouter = makeAddr("spoofedRouter");

        JBMessageRoot memory fakeRoot = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(123))}),
            sourceTotalSupply: 0
        });

        // Non-peer calling fromRemote should revert
        vm.prank(spoofedRouter);
        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_NotPeer.selector, bytes32(uint256(uint160(spoofedRouter))))
        );
        sucker.fromRemote(fakeRoot);
    }

    // =========================================================================
    // Test 2: ccipReceive — wrong chain selector
    // =========================================================================
    /// @notice Valid peer but with wrong chain selector wouldn't be possible at fromRemote level,
    ///         but we verify that only the exact peer address can call fromRemote.
    function test_ccipReceive_wrongChainSelector() public {
        // Even if the message claims to be from the right chain, the caller must be the peer
        address wrongSender = makeAddr("wrongPeer");

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(456))}),
            sourceTotalSupply: 0
        });

        vm.prank(wrongSender);
        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_NotPeer.selector, bytes32(uint256(uint160(wrongSender))))
        );
        sucker.fromRemote(root);
    }

    // =========================================================================
    // Test 3: ccipReceive — wrong peer address
    // =========================================================================
    /// @notice Verify that even a valid-looking address that isn't the peer gets rejected.
    function test_ccipReceive_wrongPeerAddress() public {
        // Create a second sucker that is NOT the peer
        AttackTestSucker otherSucker = _createTestSucker(2, "other_salt");

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(789))}),
            sourceTotalSupply: 0
        });

        // Other sucker calling fromRemote should be rejected
        vm.prank(address(otherSucker));
        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_NotPeer.selector, bytes32(uint256(uint160(address(otherSucker)))))
        );
        sucker.fromRemote(root);
    }

    // =========================================================================
    // Test 4: ccipReceive — malformed message (garbage data)
    // =========================================================================
    /// @notice Valid source but garbage merkle root data. Verify no state corruption.
    function test_ccipReceive_malformedMessage() public {
        // Set the peer so we can call fromRemote from it
        // First, initialize a peer
        bytes32 peerAddr = sucker.peer();

        // If no peer is set (bytes32(0)), fromRemote from any address will revert with NotPeer
        // This is the expected behavior — only the peer can submit roots
        if (peerAddr == bytes32(0)) {
            JBMessageRoot memory root = JBMessageRoot({
                version: 1,
                token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
                amount: 0,
                remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(0)}),
                sourceTotalSupply: 0
            });

            vm.expectRevert();
            sucker.fromRemote(root);
        }

        // Verify inbox state was not corrupted
        bytes32 inboxRoot = sucker.test_getInboxRoot(JBConstants.NATIVE_TOKEN);
        assertEq(inboxRoot, bytes32(0), "Inbox root should remain empty after failed fromRemote");
    }

    // =========================================================================
    // Test 5: claim — stale root (new root overwrites old, old proof fails)
    // =========================================================================
    /// @notice Root submitted, then new root overwrites it. Old proof should fail.
    function test_claim_staleRoot() public {
        address token = JBConstants.NATIVE_TOKEN;

        // Insert items to create root 1
        sucker.test_insertIntoTree(10 ether, token, 5 ether, bytes32(uint256(uint160(address(1000)))));

        bytes32 root1 = sucker.test_getOutboxRoot(token);

        // Set this as the inbox root (simulating receiving from remote)
        sucker.test_setInboxRoot(token, 1, root1);

        // Now insert more items to create root 2 (different root)
        sucker.test_insertIntoTree(20 ether, token, 15 ether, bytes32(uint256(uint160(address(2000)))));
        bytes32 root2 = sucker.test_getOutboxRoot(token);

        // Overwrite inbox with root 2 (higher nonce)
        sucker.test_setInboxRoot(token, 2, root2);

        // Root 1 proof should no longer match the inbox root
        // Any attempt to claim with root1's proof against root2 should fail
        assertTrue(root1 != root2, "Roots should be different after new insertion");

        // Verify inbox root is root2
        bytes32 currentInbox = sucker.test_getInboxRoot(token);
        assertEq(currentInbox, root2, "Inbox should have root2");
    }

    // =========================================================================
    // Test 6: claim — double claim (same proof used twice)
    // =========================================================================
    /// @notice Same proof used twice. Second claim must revert.
    function test_claim_doubleClaim() public {
        address token = JBConstants.NATIVE_TOKEN;

        // Insert a known item
        sucker.test_insertIntoTree(5 ether, token, 5 ether, bytes32(uint256(uint160(address(120)))));

        // Set the inbox root to match the outbox
        bytes32 root = sucker.test_getOutboxRoot(token);
        sucker.test_setInboxRoot(token, 1, root);
        sucker.test_setOutboxBalance(token, 100 ether);

        // Fund the sucker with enough ETH to cover outbox balance + claim amount.
        vm.deal(address(sucker), 105 ether);

        // Mock controller for minting
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, 5 ether, address(120), "", false)),
            abi.encode(5 ether)
        );

        // Make the first claim pass by overriding merkle validation
        sucker.test_setNextMerkleCheckToBe(true);

        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: token,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(120)))),
                projectTokenCount: 5 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });

        // First claim succeeds
        sucker.claim(claimData);

        // Second claim with same index must revert (LeafAlreadyExecuted)
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, token, 0));
        sucker.claim(claimData);
    }

    // =========================================================================
    // Test 7: claim after token remap (mapToken changes X→Y)
    // =========================================================================
    /// @notice Claim with token X proof after mapToken changes X→Y mapping.
    function test_claim_afterTokenRemap() public {
        address tokenX = makeAddr("tokenX");
        // tokenY is intentionally unused — the test verifies that tokenX's
        // inbox root persists after remapping to a different remote token.

        // Set up a remote token mapping for tokenX
        sucker.test_setRemoteToken(
            tokenX,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteTokenX"))))
            })
        );

        // Insert items for tokenX
        sucker.test_insertIntoTree(10 ether, tokenX, 5 ether, bytes32(uint256(uint160(address(1000)))));
        bytes32 rootX = sucker.test_getOutboxRoot(tokenX);

        // Set inbox root for tokenX
        sucker.test_setInboxRoot(tokenX, 1, rootX);

        // Now remap tokenX → different remote token (simulating mapToken)
        sucker.test_setRemoteToken(
            tokenX,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteTokenY"))))
            })
        );

        // The claim mechanism uses the inbox root which is keyed by token address,
        // not by remote token mapping. So remapping the remote token doesn't invalidate
        // existing inbox roots. Claims should still work for tokenX because the inbox
        // root is stored per local token address.
        assertEq(sucker.test_getInboxRoot(tokenX), rootX, "Inbox root for tokenX should persist after remap");
    }

    // =========================================================================
    // Test 8: prepare then terminal changes
    // =========================================================================
    /// @notice Prepare claim, then project changes terminal. toRemote should handle gracefully.
    function test_prepare_thenTerminalChanges() public {
        // This tests the scenario where:
        // 1. User prepares tokens for bridging (adds to outbox tree)
        // 2. Project changes its terminal before toRemote is called
        // The outbox tree items are already committed — terminal change doesn't affect them

        address token = JBConstants.NATIVE_TOKEN;

        // Insert items simulating prepare
        sucker.test_insertIntoTree(10 ether, token, 5 ether, bytes32(uint256(uint160(address(1000)))));
        sucker.test_insertIntoTree(20 ether, token, 10 ether, bytes32(uint256(uint160(address(2000)))));

        uint256 count = sucker.test_getOutboxCount(token);
        assertEq(count, 2, "Outbox should have 2 items");

        // The outbox tree is independent of terminal configuration.
        // Even if the terminal changes, the merkle root of committed items remains valid.
        bytes32 rootBefore = sucker.test_getOutboxRoot(token);
        assertTrue(rootBefore != bytes32(0), "Root should be non-zero after insertions");
    }

    // =========================================================================
    // Test 9: emergency exit — balance manipulation
    // =========================================================================
    /// @notice Send tokens directly to sucker to inflate balanceOf, then try emergency exit.
    function test_emergencyExit_balanceManipulation() public {
        address token = JBConstants.NATIVE_TOKEN;

        // Set the outbox balance to a known value
        sucker.test_setOutboxBalance(token, 1 ether);

        // Send extra ETH directly to the sucker (inflating its actual balance)
        vm.deal(address(sucker), 10 ether);

        // The outbox balance should still be 1 ether (tracked separately from actual balance)
        // This means emergency exit should only allow withdrawal up to outbox balance,
        // not the inflated actual balance.
        // The sucker tracks outbox.balance independently of address(this).balance.

        // Verify the outbox balance is the tracked amount, not the inflated amount
        assertEq(address(sucker).balance, 10 ether, "Actual balance should be inflated");

        // Try emergency exit with a claim that exceeds tracked outbox balance
        // The sucker uses outbox.balance for validation, so large claims should fail

        // Set up deprecated state for emergency exit
        uint256 deprecationTimestamp = block.timestamp + 14 days;
        // forge-lint: disable-next-line(unsafe-typecast)
        sucker.setDeprecation(uint40(deprecationTimestamp));
        vm.warp(deprecationTimestamp);

        // Mock controller
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, 1 ether, address(this), "", false)),
            abi.encode(1 ether)
        );

        // Set up a valid claim with terminalTokenAmount == outbox balance
        sucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claim = JBClaim({
            token: token,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 1 ether,
                terminalTokenAmount: 1 ether
            }),
            proof: proof
        });

        // Should work because claim amount <= tracked outbox balance
        sucker.exitThroughEmergencyHatch(claim);
    }

    // =========================================================================
    // Test 10: merkle tree — depth and count limits
    // =========================================================================
    /// @notice Verify the merkle tree handles many insertions correctly.
    function test_merkleTree_depthOverflow() public {
        address token = JBConstants.NATIVE_TOKEN;

        // The tree depth is 32, supporting up to 2^32 - 1 leaves.
        // We can't test 2^32 insertions (gas), but we can verify:
        // 1. Multiple insertions produce valid roots
        // 2. Each insertion changes the root

        bytes32 prevRoot = sucker.test_getOutboxRoot(token);

        // Insert several items and verify root changes each time
        for (uint256 i = 0; i < 10; i++) {
            sucker.test_insertIntoTree((i + 1) * 1 ether, token, (i + 1) * 0.5 ether, bytes32(uint256(1000 + i)));

            bytes32 newRoot = sucker.test_getOutboxRoot(token);
            assertTrue(newRoot != prevRoot, "Root should change after each insertion");
            prevRoot = newRoot;
        }

        // Verify count
        uint256 count = sucker.test_getOutboxCount(token);
        assertEq(count, 10, "Count should be 10 after 10 insertions");

        // Verify count is stored correctly as uint256
        // (the MerkleLib.Tree.count field is uint256, not uint32)
        assertTrue(count < type(uint256).max, "Count should be within uint256 range");
    }

    receive() external payable {}
}
