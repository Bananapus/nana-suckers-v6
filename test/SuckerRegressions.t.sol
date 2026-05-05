// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/JBSucker.sol";

import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "../src/structs/JBClaim.sol";
import {JBLeaf} from "../src/structs/JBLeaf.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../src/structs/JBRemoteToken.sol";
import {IJBSuckerExtended} from "../src/interfaces/IJBSuckerExtended.sol";
import {MerkleLib} from "../src/utils/MerkleLib.sol";

/// @notice Test harness sucker that exposes internals for regression tests.
contract RegressionSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    bool nextCheckShouldPass;

    /// @notice Whether _sendRootOverAMB was called (for verifying empty-tree fix).
    // forge-lint: disable-next-line(mixed-case-variable)
    bool public sendRootOverAMBCalled;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, address(1), tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
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

/// @title SuckerRegressionsTest
/// @notice Regression tests for non-atomic bridging, empty-tree underflow, and emergency exit events.
contract SuckerRegressionsTest is Test {
    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);
    address constant TERMINAL = address(1200);

    uint256 constant PROJECT_ID = 1;
    address constant TOKEN = address(0x000000000000000000000000000000000000EEEe);

    RegressionSucker sucker;

    function setUp() public {
        vm.warp(100 days);

        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");
        vm.label(TOKENS, "MOCK_TOKENS");
        vm.label(CONTROLLER, "MOCK_CONTROLLER");
        vm.label(PROJECT, "MOCK_PROJECT");
        vm.label(TERMINAL, "MOCK_TERMINAL");

        // Mock PROJECTS() so the constructor can cache the immutable.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));

        sucker = _createSucker("sucker_salt");
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER, abi.encodeCall(IERC165.supportsInterface, (type(IJBController).interfaceId)), abi.encode(true)
        );
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, TOKEN)), abi.encode(TERMINAL)
        );
        // Mock terminal.addToBalanceOf to accept any call (including payable for native token).
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());
        // Mock terminal.pay so the toRemote fee payment try-catch doesn't revert on ABI decode of empty return data.
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(0)));

        // Mock the registry's toRemoteFee() to return 0 (registry is address(1) with no code).
        vm.mockCall(address(1), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));

        // Mock DIRECTORY.terminalsOf() so _buildETHAggregate() in _sendRoot() doesn't revert.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(new IJBTerminal[](0)));
    }

    // =========================================================================
    // `toRemote` reverts with NothingToSend on empty tree
    // =========================================================================

    /// @notice Verifies that `toRemote()` reverts with NothingToSend when the outbox tree is empty.
    /// @dev The "nothing to send" guard catches this case:
    /// balance == 0 && tree.count == numberOfClaimsSent → revert.
    function test_L5_toRemoteWithEmptyTreeReverts() public {
        // Map a token.
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );

        // The outbox tree is empty (no `prepare()` calls).
        assertEq(sucker.test_getOutboxCount(TOKEN), 0);

        // Call toRemote -- should revert with NothingToSend (balance=0, count==numberOfClaimsSent==0).
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_NothingToSend.selector));
        sucker.toRemote(TOKEN);
    }

    /// @notice Verifies that `toRemote()` still works normally when the tree has entries.
    function test_L5_toRemoteWithNonEmptyTreeStillWorks() public {
        // Map a token.
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );

        // Insert a leaf into the tree and give ETH backing.
        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));
        assertEq(sucker.test_getOutboxCount(TOKEN), 1);

        // Reset the tracking flag.
        sucker.test_resetSendRootOverAMBCalled();

        // Call toRemote -- should succeed and call the AMB.
        sucker.toRemote(TOKEN);

        assertTrue(sucker.sendRootOverAMBCalled(), "sendRootOverAMB should be called on non-empty tree");
        assertEq(sucker.test_getOutboxNonce(TOKEN), 1, "Nonce should be incremented after send");
    }

    // =========================================================================
    // `exitThroughEmergencyHatch` does not emit event
    // =========================================================================

    /// @notice Verifies that `exitThroughEmergencyHatch()` emits the `EmergencyExit` event.
    function test_L6_emergencyExitEmitsEvent() public {
        address beneficiaryAddr = address(0xBEEF);
        bytes32 beneficiary = bytes32(uint256(uint160(beneficiaryAddr)));
        uint256 terminalTokenAmount = 1 ether;
        uint256 projectTokenCount = 5 ether;

        // Set up the sucker to be deprecated so emergency exit is allowed.
        uint256 deprecationTimestamp = block.timestamp + 14 days + 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        sucker.setDeprecation(uint40(deprecationTimestamp));
        vm.warp(deprecationTimestamp);

        // Set outbox balance to cover the exit.
        sucker.test_setOutboxBalance(TOKEN, terminalTokenAmount);

        // Insert a leaf so there's something to claim.
        sucker.test_insertIntoTree(projectTokenCount, TOKEN, terminalTokenAmount, beneficiary);

        // Deal ETH to cover the outbox balance (set + inserted) plus the claim amount.
        // After set (1 ether) + insert (adds 1 ether), outbox balance = 2 ether.
        // After emergency exit decrements (2-1=1), amountToAddToBalance = sucker.balance - 1.
        // Need sucker.balance >= 1 + terminalTokenAmount = 2 ether.
        vm.deal(address(sucker), 2 * terminalTokenAmount);

        // Mock the mint call.
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, projectTokenCount, beneficiaryAddr, "", false)),
            abi.encode(projectTokenCount)
        );

        // Set merkle check to pass.
        sucker.test_setNextMerkleCheckToBe(true);

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
        vm.expectEmit(true, true, false, true, address(sucker));
        emit IJBSuckerExtended.EmergencyExit({
            beneficiary: beneficiaryAddr,
            token: TOKEN,
            terminalTokenAmount: terminalTokenAmount,
            projectTokenCount: projectTokenCount,
            caller: address(this)
        });

        // Perform the emergency exit.
        sucker.exitThroughEmergencyHatch(claimData);
    }

    // =========================================================================
    // Arbitrum non-atomic token+message bridging
    // Documents that ON_CLAIM mode protects against claiming without backing.
    // =========================================================================

    /// @notice Demonstrates that the sucker correctly reverts when it does not hold enough
    /// terminal tokens to cover the claim. This protects against the Arbitrum non-atomicity
    /// issue: if the message ticket is redeemed before the token ticket arrives, `_addToBalance`
    /// in `_handleClaim` will revert because `amountToAddToBalanceOf` checks the actual token balance.
    ///
    /// @dev Arbitrum non-atomicity background: `JBArbitrumSucker._toL2()` creates two independent
    /// retryable tickets for ERC-20 bridging -- one for the token bridge and one for the `fromRemote`
    /// message. These can be redeemed in any order on L2. The sucker requires sufficient balance at
    /// claim time.
    function test_M4_claimRevertsWhenTokensNotYetArrived() public {
        address beneficiaryAddr = address(0xBEEF);
        bytes32 beneficiary = bytes32(uint256(uint160(beneficiaryAddr)));
        uint256 terminalTokenAmount = 1 ether;
        uint256 projectTokenCount = 5 ether;

        // Set up inbox root so claim validation passes (simulate fromRemote being called).
        sucker.test_setNextMerkleCheckToBe(true);

        // The sucker will check amountToAddToBalanceOf when handling the claim,
        // which depends on the actual balance of the contract.
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

        // The claim should revert because _handleClaim calls _addToBalance,
        // which checks amountToAddToBalanceOf. With 0 contract balance and 0 outbox balance,
        // amountToAddToBalance = 0, which is less than terminalTokenAmount (1 ether).
        vm.expectRevert();
        sucker.claim(claimData);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createSucker(bytes32 salt) internal returns (RegressionSucker) {
        RegressionSucker singleton =
            new RegressionSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER);

        RegressionSucker s = RegressionSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        s.initialize(PROJECT_ID);

        return s;
    }
}
