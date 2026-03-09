// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../src/JBSucker.sol";
import {JBAddToBalanceMode} from "../src/enums/JBAddToBalanceMode.sol";
import {JBClaim} from "../src/structs/JBClaim.sol";
import {JBLeaf} from "../src/structs/JBLeaf.sol";
import {JBInboxTreeRoot} from "../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";
import {JBOutboxTree} from "../src/structs/JBOutboxTree.sol";
import {JBRemoteToken} from "../src/structs/JBRemoteToken.sol";
import {IJBSuckerExtended} from "../src/interfaces/IJBSuckerExtended.sol";
import {MerkleLib} from "../src/utils/MerkleLib.sol";

/// @notice Test harness sucker that exposes internals for audit finding regression tests.
contract AuditFindingsSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    bool nextCheckShouldPass;

    /// @notice Whether _sendRootOverAMB was called (for verifying L-5 fix).
    bool public sendRootOverAMBCalled;

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
    {
        sendRootOverAMBCalled = true;
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

    function test_setNextMerkleCheckToBe(bool _pass) external {
        nextCheckShouldPass = _pass;
    }

    function test_setOutboxBalance(address token, uint256 amount) external {
        _outboxOf[token].balance = amount;
    }

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
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

    function test_getOutboxCount(address token) external view returns (uint256) {
        return _outboxOf[token].tree.count;
    }

    function test_getOutboxNonce(address token) external view returns (uint64) {
        return _outboxOf[token].nonce;
    }

    function test_resetSendRootOverAMBCalled() external {
        sendRootOverAMBCalled = false;
    }
}

/// @title JBSucker_AuditFindingsTest
/// @notice Regression tests for audit findings M-4, L-4, L-5, and L-6.
contract JBSucker_AuditFindingsTest is Test {
    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);
    address constant TERMINAL = address(1200);

    uint256 constant PROJECT_ID = 1;
    address constant TOKEN = address(0x000000000000000000000000000000000000EEEe);

    AuditFindingsSucker suckerManual;
    AuditFindingsSucker suckerOnClaim;

    function setUp() public {
        vm.warp(100 days);

        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");
        vm.label(TOKENS, "MOCK_TOKENS");
        vm.label(CONTROLLER, "MOCK_CONTROLLER");
        vm.label(PROJECT, "MOCK_PROJECT");
        vm.label(TERMINAL, "MOCK_TERMINAL");

        // Create MANUAL mode sucker.
        suckerManual = _createSucker(JBAddToBalanceMode.MANUAL, "manual_salt");

        // Create ON_CLAIM mode sucker.
        suckerOnClaim = _createSucker(JBAddToBalanceMode.ON_CLAIM, "onclaim_salt");

        // Common mocks.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, TOKEN)), abi.encode(TERMINAL)
        );
    }

    // =========================================================================
    // L-5: `_sendRoot` underflow revert on empty tree with minBridgeAmount=0
    // =========================================================================

    /// @notice Verifies that `toRemote()` does not revert when the outbox tree is empty and `minBridgeAmount` is 0.
    /// @dev Before the fix, `_sendRoot` would underflow at `count - 1` when `outbox.tree.count == 0`.
    /// After the fix, `_sendRoot` returns early when the tree is empty without reverting.
    function test_L5_toRemoteWithEmptyTreeAndZeroMinBridgeAmount() public {
        // Map a token with minBridgeAmount = 0.
        suckerManual.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken")))),
                minBridgeAmount: 0
            })
        );

        // Reset the tracking flag.
        suckerManual.test_resetSendRootOverAMBCalled();

        // The outbox tree is empty (no `prepare()` calls).
        assertEq(suckerManual.test_getOutboxCount(TOKEN), 0);

        // Call toRemote -- should NOT revert (the fix adds an early return for empty tree).
        suckerManual.toRemote(TOKEN);

        // Verify that _sendRootOverAMB was NOT called (early return before reaching the AMB send).
        assertFalse(suckerManual.sendRootOverAMBCalled(), "sendRootOverAMB should not be called on empty tree");

        // Verify that the nonce was not incremented (nothing was sent).
        assertEq(suckerManual.test_getOutboxNonce(TOKEN), 0, "Nonce should remain 0 when tree is empty");
    }

    /// @notice Verifies that `toRemote()` still works normally when the tree has entries.
    function test_L5_toRemoteWithNonEmptyTreeStillWorks() public {
        // Map a token with minBridgeAmount = 0.
        suckerManual.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken")))),
                minBridgeAmount: 0
            })
        );

        // Insert a leaf into the tree and give ETH backing.
        vm.deal(address(suckerManual), 1 ether);
        suckerManual.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));
        assertEq(suckerManual.test_getOutboxCount(TOKEN), 1);

        // Reset the tracking flag.
        suckerManual.test_resetSendRootOverAMBCalled();

        // Call toRemote -- should succeed and call the AMB.
        suckerManual.toRemote(TOKEN);

        assertTrue(suckerManual.sendRootOverAMBCalled(), "sendRootOverAMB should be called on non-empty tree");
        assertEq(suckerManual.test_getOutboxNonce(TOKEN), 1, "Nonce should be incremented after send");
    }

    // =========================================================================
    // L-6: `exitThroughEmergencyHatch` does not emit event
    // =========================================================================

    /// @notice Verifies that `exitThroughEmergencyHatch()` emits the `EmergencyExit` event.
    function test_L6_emergencyExitEmitsEvent() public {
        address beneficiaryAddr = address(0xBEEF);
        bytes32 beneficiary = bytes32(uint256(uint160(beneficiaryAddr)));
        uint256 terminalTokenAmount = 1 ether;
        uint256 projectTokenCount = 5 ether;

        // Set up the sucker to be deprecated so emergency exit is allowed.
        uint256 deprecationTimestamp = block.timestamp + 14 days;
        suckerManual.setDeprecation(uint40(deprecationTimestamp));
        vm.warp(deprecationTimestamp);

        // Set outbox balance to cover the exit.
        suckerManual.test_setOutboxBalance(TOKEN, terminalTokenAmount);

        // Insert a leaf so there's something to claim.
        suckerManual.test_insertIntoTree(projectTokenCount, TOKEN, terminalTokenAmount, beneficiary);

        // Deal ETH to cover the outbox balance.
        vm.deal(address(suckerManual), terminalTokenAmount);

        // Mock the mint call.
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, projectTokenCount, beneficiaryAddr, "", false)),
            abi.encode(projectTokenCount)
        );

        // Set merkle check to pass.
        suckerManual.test_setNextMerkleCheckToBe(true);

        // Build the claim data.
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: beneficiary,
                projectTokenCount: projectTokenCount,
                terminalTokenAmount: terminalTokenAmount
            }),
            proof: proof
        });

        // Expect the EmergencyExit event with the correct parameters.
        vm.expectEmit(true, true, false, true, address(suckerManual));
        emit IJBSuckerExtended.EmergencyExit({
            beneficiary: beneficiaryAddr,
            token: TOKEN,
            terminalTokenAmount: terminalTokenAmount,
            projectTokenCount: projectTokenCount,
            caller: address(this)
        });

        // Perform the emergency exit.
        suckerManual.exitThroughEmergencyHatch(claimData);
    }

    // =========================================================================
    // M-4: Arbitrum non-atomic token+message bridging
    // Documents that ON_CLAIM mode protects against claiming without backing.
    // =========================================================================

    /// @notice Demonstrates that ON_CLAIM mode correctly reverts when the sucker does not hold enough
    /// terminal tokens to cover the claim. This is the protection against the Arbitrum non-atomicity
    /// issue (M-4): if the message ticket is redeemed before the token ticket arrives, `_addToBalance`
    /// in `_handleClaim` will revert because `amountToAddToBalanceOf` checks the actual token balance.
    ///
    /// @dev Arbitrum non-atomicity background: `JBArbitrumSucker._toL2()` creates two independent
    /// retryable tickets for ERC-20 bridging -- one for the token bridge and one for the `fromRemote`
    /// message. These can be redeemed in any order on L2. In MANUAL mode, the claim would succeed
    /// even if tokens haven't arrived. ON_CLAIM mode prevents this by requiring sufficient balance at
    /// claim time.
    function test_M4_onClaimModeRevertsWhenTokensNotYetArrived() public {
        address beneficiaryAddr = address(0xBEEF);
        bytes32 beneficiary = bytes32(uint256(uint160(beneficiaryAddr)));
        uint256 terminalTokenAmount = 1 ether;
        uint256 projectTokenCount = 5 ether;

        // Set up inbox root so claim validation passes (simulate fromRemote being called).
        suckerOnClaim.test_setNextMerkleCheckToBe(true);

        // Mock the addToBalanceOf call -- but note: the ON_CLAIM sucker will check amountToAddToBalanceOf
        // first, which depends on the actual balance of the contract.
        // The sucker has 0 balance (tokens have NOT arrived yet from the Arbitrum gateway).

        // Mock the token mint so it would succeed if we got that far.
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, projectTokenCount, beneficiaryAddr, "", false)),
            abi.encode(projectTokenCount)
        );

        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: TOKEN,
            leaf: JBLeaf({
                index: 0,
                beneficiary: beneficiary,
                projectTokenCount: projectTokenCount,
                terminalTokenAmount: terminalTokenAmount
            }),
            proof: proof
        });

        // The claim should revert because the ON_CLAIM sucker's _handleClaim calls _addToBalance,
        // which checks amountToAddToBalanceOf. With 0 contract balance and 0 outbox balance,
        // amountToAddToBalance = 0, which is less than terminalTokenAmount (1 ether).
        // This demonstrates the ON_CLAIM protection against the Arbitrum non-atomicity issue.
        vm.expectRevert();
        suckerOnClaim.claim(claimData);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createSucker(JBAddToBalanceMode mode, bytes32 salt) internal returns (AuditFindingsSucker) {
        AuditFindingsSucker singleton = new AuditFindingsSucker(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), mode, FORWARDER
        );

        AuditFindingsSucker sucker =
            AuditFindingsSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        sucker.initialize(PROJECT_ID);

        return sucker;
    }
}
