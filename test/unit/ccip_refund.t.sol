// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBCCIPSucker} from "../../src/JBCCIPSucker.sol";
import {JBCCIPSuckerDeployer} from "../../src/deployers/JBCCIPSuckerDeployer.sol";

import {IJBCCIPSuckerDeployer} from "../../src/interfaces/IJBCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @notice Harness that exposes internal state for testing.
contract CCIPSuckerHarness is JBCCIPSucker {
    using MerkleLib for MerkleLib.Tree;

    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions,
        // forge-lint: disable-next-line(mixed-case-variable)
        address trusted_forwarder
    )
        JBCCIPSucker(deployer, directory, tokens, permissions, 1, IJBSuckerRegistry(address(1)), trusted_forwarder)
    {}

    /// @notice Directly insert a leaf into the outbox tree for testing.
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

    /// @notice Set the remote token mapping for testing.
    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

    /// @notice Get outbox balance.
    function test_getOutboxBalance(address token) external view returns (uint256) {
        return _outboxOf[token].balance;
    }
}

/// @notice Non-payable contract that calls toRemote — simulates a contract caller that can't receive refunds.
contract NonPayableCaller {
    function callToRemote(address sucker, address token) external payable {
        JBCCIPSucker(payable(sucker)).toRemote{value: msg.value}(token);
    }
}

/// @notice Payable contract that calls toRemote — receives refunds normally.
contract PayableCaller {
    function callToRemote(address sucker, address token) external payable {
        JBCCIPSucker(payable(sucker)).toRemote{value: msg.value}(token);
    }

    receive() external payable {}
}

/// @title CCIPRefundTest
/// @notice Tests that CCIP refund failure emits event instead of reverting.
contract CCIPRefundTest is Test {
    address constant DIRECTORY = address(0x1001);
    address constant PERMISSIONS = address(0x1002);
    address constant TOKENS = address(0x1003);
    address constant MOCK_ROUTER = address(0x2001);
    address constant FORWARDER = address(0x3001);
    address constant PROJECT = address(0x4001);

    uint256 constant PROJECT_ID = 42;
    uint256 constant REMOTE_CHAIN_ID = 137;
    uint64 constant REMOTE_CHAIN_SELECTOR = 4_051_577_828_743_386_545;
    address constant TOKEN = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    CCIPSuckerHarness sucker;

    function setUp() public {
        // Mock the deployer interface for the constructor.
        address mockDeployer = address(0x5001);
        vm.mockCall(
            mockDeployer, abi.encodeCall(IJBCCIPSuckerDeployer.ccipRemoteChainId, ()), abi.encode(REMOTE_CHAIN_ID)
        );
        vm.mockCall(
            mockDeployer,
            abi.encodeCall(IJBCCIPSuckerDeployer.ccipRemoteChainSelector, ()),
            abi.encode(REMOTE_CHAIN_SELECTOR)
        );
        vm.mockCall(mockDeployer, abi.encodeCall(IJBCCIPSuckerDeployer.ccipRouter, ()), abi.encode(MOCK_ROUTER));

        // Deploy singleton harness.
        CCIPSuckerHarness singleton = new CCIPSuckerHarness(
            JBCCIPSuckerDeployer(payable(mockDeployer)),
            IJBDirectory(DIRECTORY),
            IJBTokens(TOKENS),
            IJBPermissions(PERMISSIONS),
            FORWARDER
        );

        // Clone and initialize.
        sucker = CCIPSuckerHarness(payable(LibClone.cloneDeterministic(address(singleton), "ccip_refund_test")));
        sucker.initialize(PROJECT_ID);

        // Mock directory for ownerOf (needed for mapToken permission checks).
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));

        // Mock primaryTerminalOf to return address(0) so the toRemote fee payment path is skipped.
        // (The fee is 0 but the DIRECTORY call still happens unconditionally.)
        vm.mockCall(DIRECTORY, abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector), abi.encode(address(0)));

        // Mock the registry's toRemoteFee() to return 0 (registry is address(1) with no code).
        vm.mockCall(address(1), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));

        // Put code at MOCK_ROUTER so etch works.
        vm.etch(MOCK_ROUTER, bytes("0x1"));
    }

    /// @notice Set up CCIP router mocks for a successful bridge operation.
    // forge-lint: disable-next-line(mixed-case-function)
    function _mockCCIPSuccess(uint256 fee) internal {
        // Mock getFee to return the specified fee.
        vm.mockCall(MOCK_ROUTER, abi.encodeWithSelector(IRouterClient.getFee.selector), abi.encode(fee));

        // Mock ccipSend to succeed (return a messageId).
        vm.mockCall(
            MOCK_ROUTER, abi.encodeWithSelector(IRouterClient.ccipSend.selector), abi.encode(bytes32(uint256(0xabcdef)))
        );
    }

    /// @notice Set up a token mapping and insert outbox items.
    function _setupOutbox(address token, uint256 amount) internal {
        sucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );

        // Insert a leaf into the outbox.
        sucker.test_insertIntoTree(1 ether, token, amount, bytes32(uint256(uint160(address(this)))));
    }

    // =========================================================================
    // Non-payable caller — refund failure emits event, does NOT revert
    // =========================================================================

    /// @notice When refund fails (non-payable caller), toRemote should succeed and emit TransportPaymentRefundFailed.
    function test_toRemote_nonPayableCaller_emitsEventOnRefundFailure() public {
        address erc20 = makeAddr("bridgedERC20");
        uint256 bridgeFee = 0.05 ether;
        uint256 transportPayment = 0.1 ether;
        uint256 expectedRefund = transportPayment - bridgeFee;

        _setupOutbox(erc20, 10 ether);
        _mockCCIPSuccess(bridgeFee);

        // Give the sucker ERC20 balance for the bridge.
        vm.mockCall(erc20, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))), abi.encode(true));

        NonPayableCaller caller = new NonPayableCaller();
        vm.deal(address(caller), transportPayment);

        // The non-payable caller can't receive the refund.
        // This should emit TransportPaymentRefundFailed instead of reverting.
        vm.expectEmit(true, false, false, true, address(sucker));
        emit JBCCIPSucker.TransportPaymentRefundFailed(address(caller), expectedRefund);

        caller.callToRemote{value: transportPayment}(address(sucker), erc20);

        // The bridge operation completed successfully despite the refund failure.
        // The excess funds remain in the sucker contract.
        assertEq(sucker.test_getOutboxBalance(erc20), 0, "Outbox balance should be cleared");
    }

    /// @notice When refund succeeds (payable caller), no event is emitted.
    function test_toRemote_payableCaller_refundSucceeds() public {
        address erc20 = makeAddr("bridgedERC20");
        uint256 bridgeFee = 0.05 ether;
        uint256 transportPayment = 0.1 ether;

        _setupOutbox(erc20, 10 ether);
        _mockCCIPSuccess(bridgeFee);

        vm.mockCall(erc20, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))), abi.encode(true));

        PayableCaller caller = new PayableCaller();

        // Snapshot balance AFTER setup but BEFORE the call.
        uint256 callerBalanceBefore = address(caller).balance;

        caller.callToRemote{value: transportPayment}(address(sucker), erc20);

        // Caller should have received the refund (0.05 ether back from the 0.1 sent).
        uint256 expectedRefund = transportPayment - bridgeFee;
        assertEq(address(caller).balance, callerBalanceBefore + expectedRefund, "Caller should receive refund");
    }

    /// @notice When transportPayment == fees exactly, no refund attempt is made (zero refund skip).
    function test_toRemote_exactFee_noRefundAttempt() public {
        address erc20 = makeAddr("bridgedERC20");
        uint256 bridgeFee = 0.05 ether;

        _setupOutbox(erc20, 10 ether);
        _mockCCIPSuccess(bridgeFee);

        vm.mockCall(erc20, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))), abi.encode(true));

        NonPayableCaller caller = new NonPayableCaller();
        vm.deal(address(caller), bridgeFee);

        // With exact fee, refundAmount = 0, so no refund is attempted.
        // Even a non-payable caller should succeed without any event.
        caller.callToRemote{value: bridgeFee}(address(sucker), erc20);

        // No revert, no event — the zero-refund path was taken.
        assertEq(sucker.test_getOutboxBalance(erc20), 0, "Outbox balance should be cleared");
    }
}
