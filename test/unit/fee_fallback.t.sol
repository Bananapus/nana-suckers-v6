// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBSucker.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @notice Test harness sucker that mimics a zero-cost bridge (like OP/Base) —
///         reverts in _sendRootOverAMB if transportPayment != 0.
contract ZeroCostBridgeSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    /// @notice Whether _sendRootOverAMB was called successfully.
    // forge-lint: disable-next-line(mixed-case-variable)
    bool public sendRootOverAMBCalled;

    /// @notice The transportPayment value received by _sendRootOverAMB.
    uint256 public lastTransportPayment;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        uint256 feeProjectId,
        IJBSuckerRegistry registry,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, feeProjectId, registry, forwarder)
    {}

    // forge-lint: disable-next-line(mixed-case-function)
    function _sendRootOverAMB(
        uint256 transportPayment,
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBMessageRoot memory
    )
        internal
        override
    {
        // Mimic OP/Base bridge behavior: revert on non-zero transportPayment.
        if (transportPayment != 0) {
            revert JBSucker_UnexpectedMsgValue(transportPayment);
        }
        lastTransportPayment = transportPayment;
        sendRootOverAMBCalled = true;
    }

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == _toAddress(peer());
    }

    function peerChainId() external view virtual override returns (uint256) {
        return block.chainid;
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
}

/// @title FeeFallbackTest
/// @notice Tests that zero-cost bridges (OP, Base, Celo, Arb L2->L1) are not DoS'd
///         when the fee terminal is missing or reverts.
contract FeeFallbackTest is Test {
    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(0);
    address constant REGISTRY = address(1100);

    uint256 constant FEE_PROJECT_ID = 1;
    uint256 constant PROJECT_ID = 2;
    address constant TOKEN = address(0x000000000000000000000000000000000000EEEe);

    uint256 constant TO_REMOTE_FEE = 0.001 ether;

    ZeroCostBridgeSucker sucker;

    function setUp() public {
        vm.warp(100 days);

        // Deploy singleton and clone.
        ZeroCostBridgeSucker singleton = new ZeroCostBridgeSucker(
            IJBDirectory(DIRECTORY),
            IJBPermissions(PERMISSIONS),
            IJBTokens(TOKENS),
            FEE_PROJECT_ID,
            IJBSuckerRegistry(REGISTRY),
            FORWARDER
        );

        sucker = ZeroCostBridgeSucker(
            payable(address(LibClone.cloneDeterministic(address(singleton), "fee_fallback_salt")))
        );
        sucker.initialize(PROJECT_ID);

        // Common mocks.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));

        // Mock the registry's toRemoteFee() to return a non-zero fee.
        vm.mockCall(REGISTRY, abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(TO_REMOTE_FEE));
    }

    /// @notice toRemote() with msg.value == fee, no fee terminal, zero-cost bridge.
    ///         Before the fix: transportPayment was set to msg.value (non-zero), causing bridge revert.
    ///         After the fix: transportPayment stays at msg.value - fee == 0, bridge succeeds.
    function test_toRemote_noFeeTerminal_zeroCostBridge_succeeds() public {
        // Map a token so toRemote has something to send.
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );

        // Insert a leaf so the outbox tree is non-empty.
        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        // Mock: no fee terminal exists (returns address(0)).
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(0))
        );

        // Call toRemote with exactly the fee amount.
        // transportPayment should be msg.value - fee == 0.
        sucker.toRemote{value: TO_REMOTE_FEE}(TOKEN);

        // Verify the bridge was called successfully.
        assertTrue(sucker.sendRootOverAMBCalled(), "Bridge call should succeed with transportPayment == 0");
        assertEq(sucker.lastTransportPayment(), 0, "transportPayment should be 0 for zero-cost bridge");
    }

    /// @notice toRemote() with msg.value == fee, fee terminal reverts, zero-cost bridge.
    ///         Before the fix: transportPayment was set to msg.value (non-zero), causing bridge revert.
    ///         After the fix: transportPayment stays at msg.value - fee == 0, bridge succeeds.
    function test_toRemote_feeTerminalReverts_zeroCostBridge_succeeds() public {
        // Map a token so toRemote has something to send.
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );

        // Insert a leaf so the outbox tree is non-empty.
        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        // Mock: fee terminal exists but pay() reverts.
        address feeTerminal = makeAddr("feeTerminal");
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(feeTerminal)
        );
        vm.mockCallRevert(feeTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), "fee payment failed");

        // Call toRemote with exactly the fee amount.
        sucker.toRemote{value: TO_REMOTE_FEE}(TOKEN);

        // Verify the bridge was called successfully.
        assertTrue(sucker.sendRootOverAMBCalled(), "Bridge call should succeed even when fee terminal reverts");
        assertEq(sucker.lastTransportPayment(), 0, "transportPayment should be 0 for zero-cost bridge");
    }

    /// @notice toRemote() with msg.value > fee still passes the excess to the bridge as transportPayment.
    function test_toRemote_excessValuePassedAsBridgePayment() public {
        // Use a sucker that accepts any transportPayment (not zero-cost).
        // For this test, we re-use the same sucker but DON'T check transportPayment != 0.
        // Instead, just verify the value is correctly calculated.

        // Map a token so toRemote has something to send.
        sucker.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );

        // Insert a leaf so the outbox tree is non-empty.
        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        // Mock: no fee terminal.
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(0))
        );

        // Call with extra value for bridge transport. The zero-cost bridge check will see
        // transportPayment = 0.005 ether (non-zero) and revert. This is expected behavior —
        // zero-cost bridges should be called with exactly the fee amount.
        uint256 extraForBridge = 0.005 ether;
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_UnexpectedMsgValue.selector, extraForBridge));
        sucker.toRemote{value: TO_REMOTE_FEE + extraForBridge}(TOKEN);
    }
}
