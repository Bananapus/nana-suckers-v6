// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBSucker.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBPayRemoteMessage} from "../../src/structs/JBPayRemoteMessage.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";
import {JBSuckerState} from "../../src/enums/JBSuckerState.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice Unit tests for `payRemote`, `payFromRemote`, and `sendRootFromPayRemote` on JBSucker.
contract PayRemoteTest is Test {
    // -----------------------------------------------------------------------
    // Constants / mock addresses
    // -----------------------------------------------------------------------

    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant FORWARDER = address(0);
    address constant TERMINAL = address(2000);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);

    uint256 constant PROJECT_ID = 42;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    PayRemoteTestSucker sucker;
    ERC20Mock erc20;

    // -----------------------------------------------------------------------
    // Setup
    // -----------------------------------------------------------------------

    function setUp() public {
        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");
        vm.label(TOKENS, "MOCK_TOKENS");
        vm.label(TERMINAL, "MOCK_TERMINAL");
        vm.label(CONTROLLER, "MOCK_CONTROLLER");
        vm.label(PROJECT, "MOCK_PROJECT");

        // Mock DIRECTORY.PROJECTS() so the JBSucker constructor succeeds.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));

        // Deploy the singleton.
        PayRemoteTestSucker singleton = new PayRemoteTestSucker(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER
        );

        // Clone and initialize with our project ID.
        sucker = PayRemoteTestSucker(payable(LibClone.cloneDeterministic(address(singleton), bytes32(0))));
        sucker.initialize(PROJECT_ID);

        // Deploy a mock ERC-20 and give the test caller some tokens.
        erc20 = new ERC20Mock("Mock", "MOCK", address(this), 1000 ether);
    }

    // =======================================================================
    // payRemote — revert tests
    // =======================================================================

    /// @notice Reverts when the beneficiary is bytes32(0).
    function test_payRemote_revertsIfZeroBeneficiary() public {
        vm.expectRevert(JBSucker.JBSucker_ZeroBeneficiary.selector);
        sucker.payRemote({
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: bytes32(0),
            minTokensOut: 0,
            metadata: ""
        });
    }

    /// @notice Reverts when amount is 0.
    function test_payRemote_revertsIfZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_InsufficientBalance.selector, 0, 0));
        sucker.payRemote({
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            beneficiary: bytes32(uint256(1)),
            minTokensOut: 0,
            metadata: ""
        });
    }

    /// @notice Reverts when the token is not mapped to a remote token.
    function test_payRemote_revertsIfTokenNotMapped() public {
        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_TokenNotMapped.selector, JBConstants.NATIVE_TOKEN)
        );
        sucker.payRemote{value: 1 ether}({
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: bytes32(uint256(1)),
            minTokensOut: 0,
            metadata: ""
        });
    }

    /// @notice Reverts when amount exceeds uint128 max.
    function test_payRemote_revertsIfAmountExceedsUint128() public {
        uint256 overflowAmount = uint256(type(uint128).max) + 1;

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_AmountExceedsUint128.selector, overflowAmount));
        sucker.payRemote({
            token: JBConstants.NATIVE_TOKEN,
            amount: overflowAmount,
            beneficiary: bytes32(uint256(1)),
            minTokensOut: 0,
            metadata: ""
        });
    }

    /// @notice Reverts when msg.value < amount for native token.
    function test_payRemote_revertsIfInsufficientMsgValueNative() public {
        // Map native token so we get past the mapping check.
        sucker.test_setRemoteToken(
            JBConstants.NATIVE_TOKEN,
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 0, addr: bytes32(uint256(0xAAAA))})
        );

        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_InsufficientMsgValue.selector, 0.5 ether, 1 ether)
        );
        sucker.payRemote{value: 0.5 ether}({
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: bytes32(uint256(1)),
            minTokensOut: 0,
            metadata: ""
        });
    }

    /// @notice Reverts when the sucker is in DEPRECATED state.
    function test_payRemote_revertsIfDeprecated() public {
        // Map native token.
        sucker.test_setRemoteToken(
            JBConstants.NATIVE_TOKEN,
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 0, addr: bytes32(uint256(0xAAAA))})
        );

        // Mock the DIRECTORY.PROJECTS() call and project owner for setDeprecation permission check.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));

        // Set deprecation timestamp and warp past it so state() == DEPRECATED.
        uint40 deprecationTimestamp = uint40(block.timestamp + 14 days);
        sucker.setDeprecation(deprecationTimestamp);
        vm.warp(deprecationTimestamp);

        vm.expectRevert(JBSucker.JBSucker_Deprecated.selector);
        sucker.payRemote{value: 1 ether}({
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: bytes32(uint256(1)),
            minTokensOut: 0,
            metadata: ""
        });
    }

    // =======================================================================
    // payRemote — happy path tests
    // =======================================================================

    /// @notice Successful payRemote with native token. Verifies event emission and _sendPayOverAMB call.
    function test_payRemote_nativeToken() public {
        bytes32 remoteAddr = bytes32(uint256(0xBBBB));
        bytes32 beneficiary = bytes32(uint256(uint160(address(0xCAFE))));
        uint256 amount = 1 ether;
        uint256 transportBudget = 0.2 ether;

        // Map native token.
        sucker.test_setRemoteToken(
            JBConstants.NATIVE_TOKEN,
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 0, addr: remoteAddr})
        );

        // Expected transport split: hop1 = 0.1 ether, return = 0.1 ether.
        uint256 expectedHop1 = transportBudget / 2;
        uint256 expectedReturn = transportBudget - expectedHop1;

        vm.expectEmit(true, true, false, true, address(sucker));
        emit IJBSucker.PayRemote({
            beneficiary: beneficiary,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            returnTransport: expectedReturn,
            caller: address(this)
        });

        sucker.payRemote{value: amount + transportBudget}({
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: beneficiary,
            minTokensOut: 100,
            metadata: ""
        });

        // Verify the test harness recorded the _sendPayOverAMB call.
        assertTrue(sucker.sendPayOverAMBCalled(), "sendPayOverAMB should have been called");
        assertEq(sucker.lastPayTransportPayment(), expectedHop1, "transport payment mismatch");
        assertEq(sucker.lastPayToken(), JBConstants.NATIVE_TOKEN, "token mismatch");
        assertEq(sucker.lastPayAmount(), amount, "amount mismatch");
    }

    /// @notice Successful payRemote with ERC-20. Verifies token pull and event emission.
    function test_payRemote_erc20() public {
        bytes32 remoteAddr = bytes32(uint256(0xCCCC));
        bytes32 beneficiary = bytes32(uint256(uint160(address(0xBEEF))));
        uint256 amount = 50 ether;
        uint256 transportBudget = 0.1 ether;

        // Map the ERC-20 token.
        sucker.test_setRemoteToken(
            address(erc20),
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 0, addr: remoteAddr})
        );

        // Approve the sucker to pull tokens.
        erc20.approve(address(sucker), amount);

        uint256 balanceBefore = erc20.balanceOf(address(this));

        uint256 expectedHop1 = transportBudget / 2;
        uint256 expectedReturn = transportBudget - expectedHop1;

        vm.expectEmit(true, true, false, true, address(sucker));
        emit IJBSucker.PayRemote({
            beneficiary: beneficiary,
            token: address(erc20),
            amount: amount,
            returnTransport: expectedReturn,
            caller: address(this)
        });

        sucker.payRemote{value: transportBudget}({
            token: address(erc20),
            amount: amount,
            beneficiary: beneficiary,
            minTokensOut: 0,
            metadata: ""
        });

        // Verify ERC-20 was pulled from caller.
        assertEq(erc20.balanceOf(address(this)), balanceBefore - amount, "caller balance should decrease by amount");
        assertEq(erc20.balanceOf(address(sucker)), amount, "sucker should hold the ERC-20 tokens");

        // Verify the test harness recorded the _sendPayOverAMB call.
        assertTrue(sucker.sendPayOverAMBCalled(), "sendPayOverAMB should have been called");
        assertEq(sucker.lastPayTransportPayment(), expectedHop1, "transport payment mismatch");
        assertEq(sucker.lastPayToken(), address(erc20), "token mismatch");
        assertEq(sucker.lastPayAmount(), amount, "amount mismatch");
    }

    // =======================================================================
    // payFromRemote — revert tests
    // =======================================================================

    /// @notice Reverts when the caller is not the remote peer.
    function test_payFromRemote_revertsIfNotPeer() public {
        // Ensure remote peer checking is enabled (default), and call from a random address.
        JBPayRemoteMessage memory message = JBPayRemoteMessage({
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: 1 ether,
            returnTransport: 0,
            beneficiary: bytes32(uint256(1)),
            minTokensOut: 0,
            metadata: ""
        });

        address randomCaller = address(0xDEAD);
        vm.prank(randomCaller);
        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_NotPeer.selector, bytes32(uint256(uint160(randomCaller))))
        );
        sucker.payFromRemote(message);
    }

    /// @notice Successful payFromRemote with native token. Mocks terminal.pay and cashOutTokensOf, verifies events.
    function test_payFromRemote_nativeToken() public {
        // Enable remote peer validation for the sucker's own address.
        sucker.test_setIsRemotePeer(true);

        address token = JBConstants.NATIVE_TOKEN;
        uint256 amount = 1 ether;
        uint256 projectTokensReceived = 500 ether;
        uint256 terminalTokensReclaimed = 0.9 ether;
        bytes32 beneficiary = bytes32(uint256(uint160(address(0xCAFE))));

        // Map the native token so the return bridge can be attempted.
        bytes32 remoteAddr = bytes32(uint256(0xAAAA));
        sucker.test_setRemoteToken(
            token, JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 0, addr: remoteAddr})
        );

        // Fund the sucker with native token so it can pay the terminal.
        vm.deal(address(sucker), amount + 1 ether);

        // Mock DIRECTORY.primaryTerminalOf -> TERMINAL.
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, token)),
            abi.encode(TERMINAL)
        );

        // Mock terminal.pay -> returns projectTokensReceived.
        // We use a broad mock that matches any call to terminal.pay for this project.
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(projectTokensReceived));

        // Mock cashOutTokensOf -> returns terminalTokensReclaimed.
        vm.mockCall(
            TERMINAL,
            abi.encodeWithSelector(IJBCashOutTerminal.cashOutTokensOf.selector),
            abi.encode(terminalTokensReclaimed)
        );

        JBPayRemoteMessage memory message = JBPayRemoteMessage({
            token: bytes32(uint256(uint160(token))),
            amount: amount,
            returnTransport: 0.01 ether,
            beneficiary: beneficiary,
            minTokensOut: 0,
            metadata: ""
        });

        // Expect the PayFromRemote event.
        vm.expectEmit(true, true, false, true, address(sucker));
        emit IJBSucker.PayFromRemote({
            beneficiary: beneficiary,
            token: token,
            amountPaid: amount,
            projectTokensReceived: projectTokensReceived,
            terminalTokensReclaimed: terminalTokensReclaimed,
            caller: address(sucker)
        });

        // Call payFromRemote as the sucker itself (simulating the bridge messenger).
        vm.prank(address(sucker));
        sucker.payFromRemote(message);
    }

    // =======================================================================
    // sendRootFromPayRemote — revert tests
    // =======================================================================

    /// @notice Reverts when called by an external address (not address(this)).
    function test_sendRootFromPayRemote_revertsIfNotSelf() public {
        address externalCaller = address(0x1234);

        JBRemoteToken memory remoteToken =
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 0, addr: bytes32(uint256(0xAAAA))});

        vm.prank(externalCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSucker.JBSucker_NotPeer.selector, bytes32(uint256(uint160(externalCaller)))
            )
        );
        sucker.sendRootFromPayRemote({transportPayment: 0, token: JBConstants.NATIVE_TOKEN, remoteToken: remoteToken});
    }
}

// ===========================================================================
// Test Harness
// ===========================================================================

/// @notice A concrete JBSucker subclass for testing payRemote / payFromRemote.
/// Records _sendPayOverAMB arguments for post-call assertions and exposes helpers to
/// manipulate internal storage that is otherwise inaccessible from the test.
contract PayRemoteTestSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;

    // -----------------------------------------------------------------------
    // Recorded _sendPayOverAMB call data
    // -----------------------------------------------------------------------

    // forge-lint: disable-next-line(mixed-case-variable)
    bool public sendPayOverAMBCalled;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public lastPayTransportPayment;
    // forge-lint: disable-next-line(mixed-case-variable)
    address public lastPayToken;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public lastPayAmount;

    // -----------------------------------------------------------------------
    // Remote peer toggle
    // -----------------------------------------------------------------------

    // forge-lint: disable-next-line(mixed-case-variable)
    bool private _isRemotePeerEnabled;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
    {}

    // -----------------------------------------------------------------------
    // Test helpers
    // -----------------------------------------------------------------------

    /// @notice Set whether _isRemotePeer returns true for all callers.
    // forge-lint: disable-next-line(mixed-case-function)
    function test_setIsRemotePeer(bool enabled) external {
        _isRemotePeerEnabled = enabled;
    }

    /// @notice Directly write a remote token mapping.
    // forge-lint: disable-next-line(mixed-case-function)
    function test_setRemoteToken(address token, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[token] = remoteToken;
    }

    // -----------------------------------------------------------------------
    // Abstract overrides
    // -----------------------------------------------------------------------

    function _isRemotePeer(address) internal view override returns (bool valid) {
        return _isRemotePeerEnabled;
    }

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

    function _sendPayOverAMB(
        uint256 transportPayment,
        address token,
        uint256 amount,
        JBRemoteToken memory,
        JBPayRemoteMessage memory
    )
        internal
        override
    {
        sendPayOverAMBCalled = true;
        lastPayTransportPayment = transportPayment;
        lastPayToken = token;
        lastPayAmount = amount;
    }

    function peerChainId() external view override returns (uint256) {
        return block.chainid;
    }

    /// @dev No-op for testing so addToBalance calls don't revert.
    function _addToBalance(address, uint256, uint256) internal override {}
}
