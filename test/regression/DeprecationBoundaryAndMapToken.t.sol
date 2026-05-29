// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBSucker.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";

/// @title DeprecationBoundaryAndMapToken
/// @notice Regression coverage for deprecation-boundary and map-token behaviors:
///   1. Arbitrum ERC-20 retryable data length is covered by fork/integration tests.
///   2. CCIP LINK-fee mode requires caller-provided LINK and is covered by integration tests.
///   3. `setDeprecation` rejects the exact unsafe boundary timestamp.
///   4. `_mapToken` disables a token before sending its final root.
contract DeprecationBoundaryAndMapTokenTest is Test {
    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);

    uint256 constant PROJECT_ID = 1;

    address tokenA = makeAddr("tokenA");
    bytes32 remoteA = bytes32(uint256(1));

    function setUp() public {
        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");
        vm.label(TOKENS, "MOCK_TOKENS");
        vm.label(CONTROLLER, "MOCK_CONTROLLER");
        vm.label(PROJECT, "MOCK_PROJECT");

        // Mock DIRECTORY.PROJECTS() — required by JBSucker constructor.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        // Mock ownerOf(projectId) to return the test contract (the caller), so permission checks pass.
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        // Mock DIRECTORY.controllerOf so snapshot construction doesn't revert.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(address(0)));
        // Mock DIRECTORY.terminalsOf so _buildETHAggregate() in _sendRoot() doesn't revert.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(new IJBTerminal[](0)));
    }

    // -----------------------------------------------------------------------
    //  Arbitrum ERC-20 retryable data length
    // -----------------------------------------------------------------------

    /// @notice Arbitrum sends use `IL1ArbitrumGateway.getOutboundCalldata()` to price the full retryable payload.
    /// @dev Requires a fork test with real Arbitrum gateway contracts to verify submission-cost coverage.
    function test_fix1_arbitrumDataLength_documentedAsForked() external pure {
        // Intentionally empty. See JBArbitrumSucker._toL2() and the Arbitrum fork tests.
    }

    // -----------------------------------------------------------------------
    //  CCIP LINK-fee caller-provided LINK
    // -----------------------------------------------------------------------

    /// @notice LINK-fee mode pulls LINK from the caller instead of the sucker's prefunded balance.
    /// @dev Requires a full CCIP router/LINK setup for end-to-end verification.
    function test_fix2_ccipLinkFeeCallerProvided_documentedAsIntegration() external pure {
        // Intentionally empty. This path requires CCIP router and LINK token mocks.
        // See: JBCCIPLib.sendCCIPMessage() and JBCCIPSucker._sendRootOverAMB().
    }

    // -----------------------------------------------------------------------
    //  setDeprecation boundary check
    // -----------------------------------------------------------------------

    /// @notice `setDeprecation` rejects timestamps exactly at the minimum-delay boundary.
    function test_setDeprecation_rejectsTimestampAtExactBoundary() external {
        TestSucker sucker = _createTestSucker(PROJECT_ID, "fix3-boundary");

        // _maxMessagingDelay() returns 14 days.
        uint256 exactBoundary = block.timestamp + 14 days;

        // The exact boundary is rejected because users need a full messaging-delay window.
        vm.expectRevert(
            abi.encodeWithSelector(
                // forge-lint: disable-next-line(unsafe-typecast)
                JBSucker.JBSucker_DeprecationTimestampTooSoon.selector,
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256(uint40(exactBoundary)),
                exactBoundary
            )
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        sucker.setDeprecation(uint40(exactBoundary));
    }

    /// @notice A timestamp one second past the boundary is accepted.
    function test_setDeprecation_acceptsTimestampPastBoundary() external {
        TestSucker sucker = _createTestSucker(PROJECT_ID, "fix3-accept");

        // One second past the boundary should be accepted.
        uint256 pastBoundary = block.timestamp + 14 days + 1;

        // forge-lint: disable-next-line(unsafe-typecast)
        sucker.setDeprecation(uint40(pastBoundary));

        // Verify the deprecation was set by checking state is now DEPRECATION_PENDING.
        assertEq(uint8(sucker.state()), uint8(JBSuckerState.DEPRECATION_PENDING));
    }

    /// @notice Timestamps well past the boundary are accepted.
    function test_setDeprecation_acceptsTimestampWellPastBoundary() external {
        TestSucker sucker = _createTestSucker(PROJECT_ID, "fix3-well-past");

        uint256 wellPast = block.timestamp + 30 days;

        // forge-lint: disable-next-line(unsafe-typecast)
        sucker.setDeprecation(uint40(wellPast));

        assertEq(uint8(sucker.state()), uint8(JBSuckerState.DEPRECATION_PENDING));
    }

    /// @notice Cancelling deprecation (`timestamp == 0`) is always allowed.
    function test_setDeprecation_cancellingAlwaysAllowed() external {
        TestSucker sucker = _createTestSucker(PROJECT_ID, "fix3-cancel");

        // First set a valid deprecation.
        uint256 validTime = block.timestamp + 14 days + 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        sucker.setDeprecation(uint40(validTime));
        assertEq(uint8(sucker.state()), uint8(JBSuckerState.DEPRECATION_PENDING));

        // Cancel it.
        sucker.setDeprecation(0);
        assertEq(uint8(sucker.state()), uint8(JBSuckerState.ENABLED));
    }

    // -----------------------------------------------------------------------
    //  Reentrancy-safe token disable in _mapToken
    // -----------------------------------------------------------------------

    /// @notice `_mapToken` disables the token before sending its final root, blocking reentrant `prepare()`.
    function test_mapToken_disableSetsEnabledFalseBeforeSendRoot() external {
        // Allow any caller to pass permission checks.
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        ReentrancySucker sucker = _createReentrancySucker(PROJECT_ID, "fix4-reentrancy");

        // Set up a mapped token with an unsent outbox entry.
        sucker.test_setRemoteToken(
            tokenA, JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 200_000, addr: remoteA})
        );
        sucker.test_setOutboxTreeCount(tokenA, 1);

        // Mock TOKENS.tokenOf so the reentrant prepare() reaches the disabled-token check.
        address fakeProjectToken = makeAddr("fakeProjectToken");
        vm.mockCall(TOKENS, abi.encodeCall(IJBTokens.tokenOf, (PROJECT_ID)), abi.encode(fakeProjectToken));

        // Configure the reentrancy sucker to attempt prepare() during _sendRootOverAMB.
        sucker.test_setReentrancyToken(tokenA);

        // Disable the token by mapping to address(0).
        // ReentrancySucker._sendRootOverAMB calls prepare(), which should revert because `enabled` is already false.
        // The revert inside _sendRootOverAMB bubbles up to mapToken.
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_TokenNotMapped.selector, tokenA));
        sucker.mapToken(JBTokenMapping({localToken: tokenA, minGas: 200_000, remoteToken: bytes32(0)}));
    }

    /// @notice A successful disable leaves the token mapping disabled when no reentrancy is attempted.
    function test_mapToken_disablePathSetsEnabledFalse() external {
        // Allow any caller to pass permission checks.
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        TestSucker sucker = _createTestSucker(PROJECT_ID, "fix4-disable");

        // Set up a mapped token with an unsent outbox entry.
        sucker.test_setRemoteToken(
            tokenA, JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 200_000, addr: remoteA})
        );
        sucker.test_setOutboxTreeCount(tokenA, 1);

        // Disable the token.
        sucker.mapToken(JBTokenMapping({localToken: tokenA, minGas: 200_000, remoteToken: bytes32(0)}));

        // Verify the token is disabled.
        JBRemoteToken memory result = sucker.remoteTokenFor(tokenA);
        assertFalse(result.enabled, "Token should be disabled after mapToken(remoteToken=0)");
        // The addr should be preserved (not zeroed) so re-enabling maps to the same remote token.
        assertEq(result.addr, remoteA, "Remote address should be preserved after disable");
    }

    // -----------------------------------------------------------------------
    //  Helpers
    // -----------------------------------------------------------------------

    function _createTestSucker(uint256 projectId, bytes32 salt) internal returns (TestSucker) {
        TestSucker singleton =
            new TestSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER);
        vm.label(address(singleton), "SUCKER_SINGLETON");

        TestSucker sucker =
            TestSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        vm.label(address(sucker), "SUCKER");
        sucker.initialize(projectId);

        return sucker;
    }

    function _createReentrancySucker(uint256 projectId, bytes32 salt) internal returns (ReentrancySucker) {
        ReentrancySucker singleton =
            new ReentrancySucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER);
        vm.label(address(singleton), "REENTRANCY_SUCKER_SINGLETON");

        ReentrancySucker sucker =
            ReentrancySucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        vm.label(address(sucker), "REENTRANCY_SUCKER");
        sucker.initialize(projectId);

        return sucker;
    }
}

/// @notice A minimal test sucker for these regression tests.
/// @dev Extends JBSucker with no-op AMB and helpers for setting internal state.
contract TestSucker is JBSucker {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, IJBPrices(address(1)), tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
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

    function _isRemotePeer(address sender) internal view override returns (bool valid) {
        return sender == _toAddress(peer());
    }

    function peerChainId() external view virtual override returns (uint256) {
        return block.chainid;
    }

    function _addToBalance(address, uint256, uint256) internal override {}

    /// @notice Set the remote token mapping for testing.
    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

    /// @notice Set the outbox tree count for testing (simulates unsent claims).
    function test_setOutboxTreeCount(address token, uint256 count) external {
        _outboxOf[token].tree.count = count;
    }
}

/// @notice A test sucker variant that attempts reentrancy during _sendRootOverAMB.
/// @dev Verifies that `_mapToken` sets `enabled = false` before `_sendRoot`, so reentrant `prepare()` reverts.
contract ReentrancySucker is JBSucker {
    /// @notice The token to attempt reentrancy with during _sendRootOverAMB.
    address internal _reentrancyToken;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, IJBPrices(address(1)), tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
    {}

    /// @notice During `_sendRootOverAMB`, attempt to call `prepare()` on this contract.
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
        if (_reentrancyToken != address(0)) {
            // This reentrant prepare() should revert because _mapToken already disabled the token.
            this.prepare({
                projectTokenCount: 1,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                minTokensReclaimed: 0,
                token: _reentrancyToken,
                metadata: bytes32(0)
            });
        }
    }

    function _isRemotePeer(address sender) internal view override returns (bool valid) {
        return sender == _toAddress(peer());
    }

    function peerChainId() external view virtual override returns (uint256) {
        return block.chainid;
    }

    function _addToBalance(address, uint256, uint256) internal override {}

    /// @notice Configure the token to attempt reentrancy with.
    function test_setReentrancyToken(address token) external {
        _reentrancyToken = token;
    }

    /// @notice Set the remote token mapping for testing.
    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

    /// @notice Set the outbox tree count for testing (simulates unsent claims).
    function test_setOutboxTreeCount(address token, uint256 count) external {
        _outboxOf[token].tree.count = count;
    }
}
