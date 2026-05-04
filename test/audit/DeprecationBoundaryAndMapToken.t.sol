// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBSucker.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";

/// @title CertikAIScan — Tests for CertiK AI scan fixes
/// @notice Covers fixes 1-5 from the CertiK AI scan remediation:
///   Fix 1: Arbitrum ERC-20 dataLength underestimate (placeholder — requires fork test)
///   Fix 2: CCIP LINK-fee caller-provided (placeholder — requires CCIP router setup)
///   Fix 3: setDeprecation boundary check (< changed to <=)
///   Fix 4: Reentrancy-safe token disable in _mapToken (enabled = false before _sendRoot)
contract CertikAIScanTest is Test {
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
    //  Fix 1: Arbitrum ERC-20 dataLength underestimate
    // -----------------------------------------------------------------------

    /// @notice Fix 1: The Arbitrum sucker now queries IL1ArbitrumGateway.getOutboundCalldata()
    ///         for the actual payload length instead of hardcoding dataLength: 96.
    /// @dev This fix requires a fork test with real Arbitrum gateway contracts to verify
    ///      that the submission cost covers the actual gateway calldata. The fix was verified
    ///      via code review: JBArbitrumSucker._toL2() now calls
    ///      `IL1ArbitrumGateway(gateway).getOutboundCalldata(...)` and passes the result's
    ///      `.length` to `calculateRetryableSubmissionFee`, ensuring the submission cost
    ///      accounts for the full gateway-wrapped calldata (which is significantly larger
    ///      than the user data alone).
    function test_fix1_arbitrumDataLength_documentedAsForked() external pure {
        // Intentionally empty — this fix is verified via fork test and code review.
        // See: JBArbitrumSucker._toL2(), lines calling getOutboundCalldata().
    }

    // -----------------------------------------------------------------------
    //  Fix 2: CCIP LINK-fee caller-provided LINK
    // -----------------------------------------------------------------------

    /// @notice Fix 2: LINK-fee mode now pulls LINK from the caller via transferFrom instead
    ///         of using the sucker's pre-funded balance. This keeps toRemote permissionless
    ///         while preventing anyone from draining the sucker's LINK.
    /// @dev This fix requires a full CCIP router mock (ICCIPRouter, LINK token, chain selector)
    ///      to test end-to-end. The fix was verified via fork tests (ForkMainnet, ForkClaimMainnet,
    ///      ForkSwapMainnet) which confirm LINK is pulled from the caller's balance.
    ///      See: JBCCIPLib.sendCCIPMessage() feeTokenPayer parameter.
    function test_fix2_ccipLinkFeeCallerProvided_documentedAsIntegration() external pure {
        // Intentionally empty — this fix requires CCIP router + LINK token mocks.
        // See: JBCCIPLib.sendCCIPMessage() and JBCCIPSucker._sendRootOverAMB().
    }

    // -----------------------------------------------------------------------
    //  Fix 3: setDeprecation boundary check (< changed to <=)
    // -----------------------------------------------------------------------

    /// @notice Fix 3: setDeprecation now rejects timestamps exactly at the boundary.
    ///         Before the fix, `timestamp == block.timestamp + _maxMessagingDelay()` was accepted.
    ///         After the fix, the `<` was changed to `<=`, so this boundary value is rejected.
    function test_setDeprecation_rejectsTimestampAtExactBoundary() external {
        CertikTestSucker sucker = _createTestSucker(PROJECT_ID, "fix3-boundary");

        // _maxMessagingDelay() returns 14 days.
        uint256 exactBoundary = block.timestamp + 14 days;

        // The exact boundary should now be rejected (the fix changed < to <=).
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSucker.JBSucker_DeprecationTimestampTooSoon.selector, uint256(uint40(exactBoundary)), exactBoundary
            )
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        sucker.setDeprecation(uint40(exactBoundary));
    }

    /// @notice Fix 3: A timestamp one second past the boundary should be accepted.
    function test_setDeprecation_acceptsTimestampPastBoundary() external {
        CertikTestSucker sucker = _createTestSucker(PROJECT_ID, "fix3-accept");

        // One second past the boundary should be accepted.
        uint256 pastBoundary = block.timestamp + 14 days + 1;

        // forge-lint: disable-next-line(unsafe-typecast)
        sucker.setDeprecation(uint40(pastBoundary));

        // Verify the deprecation was set by checking state is now DEPRECATION_PENDING.
        assertEq(uint8(sucker.state()), uint8(JBSuckerState.DEPRECATION_PENDING));
    }

    /// @notice Fix 3: Timestamps well past the boundary should still be accepted.
    function test_setDeprecation_acceptsTimestampWellPastBoundary() external {
        CertikTestSucker sucker = _createTestSucker(PROJECT_ID, "fix3-well-past");

        uint256 wellPast = block.timestamp + 30 days;

        // forge-lint: disable-next-line(unsafe-typecast)
        sucker.setDeprecation(uint40(wellPast));

        assertEq(uint8(sucker.state()), uint8(JBSuckerState.DEPRECATION_PENDING));
    }

    /// @notice Fix 3: Cancelling deprecation (timestamp == 0) should always be allowed.
    function test_setDeprecation_cancellingAlwaysAllowed() external {
        CertikTestSucker sucker = _createTestSucker(PROJECT_ID, "fix3-cancel");

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
    //  Fix 4: Reentrancy-safe token disable in _mapToken
    // -----------------------------------------------------------------------

    /// @notice Fix 4: _mapToken now sets `_remoteTokenFor[token].enabled = false` before
    ///         calling `_sendRoot()` in the disable path. This prevents reentrancy via
    ///         `prepare()` during the `_sendRoot` call. If someone tries to call `prepare()`
    ///         during `_sendRootOverAMB`, it should revert with JBSucker_TokenNotMapped
    ///         because the token is already disabled.
    function test_mapToken_disableSetsEnabledFalseBeforeSendRoot() external {
        // Allow any caller to pass permission checks.
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        ReentrancySucker sucker = _createReentrancySucker(PROJECT_ID, "fix4-reentrancy");

        // Set up a mapped token with an unsent outbox entry.
        sucker.test_setRemoteToken(
            tokenA, JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 200_000, addr: remoteA})
        );
        sucker.test_setOutboxTreeCount(tokenA, 1);

        // Mock TOKENS.tokenOf so the reentrant prepare() gets past the ERC-20 check
        // and reaches the _remoteTokenFor[token].enabled check (which is the fix under test).
        address fakeProjectToken = makeAddr("fakeProjectToken");
        vm.mockCall(TOKENS, abi.encodeCall(IJBTokens.tokenOf, (PROJECT_ID)), abi.encode(fakeProjectToken));

        // Configure the reentrancy sucker to attempt prepare() during _sendRootOverAMB.
        sucker.test_setReentrancyToken(tokenA);

        // Disable the token by mapping to address(0).
        // The ReentrancySucker's _sendRootOverAMB will try to call prepare(), which should
        // revert with JBSucker_TokenNotMapped because `enabled` was set to false BEFORE _sendRoot.
        // The revert inside _sendRootOverAMB bubbles up to mapToken.
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_TokenNotMapped.selector, tokenA));
        sucker.mapToken(JBTokenMapping({localToken: tokenA, minGas: 200_000, remoteToken: bytes32(0)}));
    }

    /// @notice Fix 4: Verify that after a successful disable (no reentrancy), the token
    ///         mapping shows enabled == false.
    function test_mapToken_disablePathSetsEnabledFalse() external {
        // Allow any caller to pass permission checks.
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        CertikTestSucker sucker = _createTestSucker(PROJECT_ID, "fix4-disable");

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

    function _createTestSucker(uint256 projectId, bytes32 salt) internal returns (CertikTestSucker) {
        CertikTestSucker singleton =
            new CertikTestSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER);
        vm.label(address(singleton), "SUCKER_SINGLETON");

        CertikTestSucker sucker =
            CertikTestSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
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

/// @notice A minimal test sucker for CertiK AI scan fix tests.
/// @dev Extends JBSucker with no-op AMB and helpers for setting internal state.
contract CertikTestSucker is JBSucker {
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
/// @dev Used to verify Fix 4: _mapToken sets enabled=false before calling _sendRoot,
///      so a reentrant prepare() call reverts with JBSucker_TokenNotMapped.
contract ReentrancySucker is JBSucker {
    /// @notice The token to attempt reentrancy with during _sendRootOverAMB.
    address internal _reentrancyToken;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, address(1), tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
    {}

    /// @notice During _sendRootOverAMB, attempt to call prepare() on this contract.
    ///         If Fix 4 is correct, prepare() will revert because the token is already disabled.
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
            // Attempt reentrant prepare() — this should revert with JBSucker_TokenNotMapped
            // because _mapToken already set enabled = false before calling _sendRoot.
            this.prepare({
                projectTokenCount: 1,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                minTokensReclaimed: 0,
                token: _reentrancyToken
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
