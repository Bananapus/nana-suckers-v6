// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "../../src/JBSucker.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice mapTokens msg.value dust from integer division.
/// When `msg.value / numberToDisable` has a remainder, the dust wei must be refunded to the caller.
contract MapTokensDustTest is Test {
    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);

    address tokenA = makeAddr("tokenA");
    address tokenB = makeAddr("tokenB");
    address tokenC = makeAddr("tokenC");

    bytes32 remoteA = bytes32(uint256(1));
    bytes32 remoteB = bytes32(uint256(2));
    bytes32 remoteC = bytes32(uint256(3));

    uint256 projectId = 1;

    function setUp() public {
        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");
        vm.label(TOKENS, "MOCK_TOKENS");
        vm.label(CONTROLLER, "MOCK_CONTROLLER");
        vm.label(PROJECT, "MOCK_PROJECT");

        // Mock DIRECTORY.PROJECTS() and ownerOf for all tests.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(address(this)));

        // Allow any caller to pass the MAP_SUCKER_TOKEN permission check.
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));
    }

    /// @notice When mapTokens disables multiple tokens and msg.value is not evenly divisible,
    ///         the remainder (dust) must be refunded to the caller.
    function test_mapTokensDustRefunded() external {
        MapTokensDustSucker sucker = _createTestSucker(projectId, "");

        // Set up two tokens that are currently mapped and have unsent outbox entries,
        // so disabling them (remoteToken=0) triggers _sendRoot which needs transport payment.

        // Token A: mapped with unsent claims (tree.count=1, numberOfClaimsSent=0).
        sucker.test_setRemoteToken(
            tokenA,
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 200_000, addr: remoteA, minBridgeAmount: 0})
        );
        sucker.test_setOutboxTreeCount(tokenA, 1);
        // numberOfClaimsSent defaults to 0, so 0 != 1 means this token will be counted.

        // Token B: mapped with unsent claims.
        sucker.test_setRemoteToken(
            tokenB,
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 200_000, addr: remoteB, minBridgeAmount: 0})
        );
        sucker.test_setOutboxTreeCount(tokenB, 1);

        // Token C: mapped with unsent claims.
        sucker.test_setRemoteToken(
            tokenC,
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 200_000, addr: remoteC, minBridgeAmount: 0})
        );
        sucker.test_setOutboxTreeCount(tokenC, 1);

        // Build maps to disable all three tokens (remoteToken = 0).
        JBTokenMapping[] memory maps = new JBTokenMapping[](3);
        maps[0] = JBTokenMapping({localToken: tokenA, minGas: 200_000, remoteToken: bytes32(0), minBridgeAmount: 0});
        maps[1] = JBTokenMapping({localToken: tokenB, minGas: 200_000, remoteToken: bytes32(0), minBridgeAmount: 0});
        maps[2] = JBTokenMapping({localToken: tokenC, minGas: 200_000, remoteToken: bytes32(0), minBridgeAmount: 0});

        // Send 10 wei with 3 tokens to disable: 10 / 3 = 3 each, remainder = 1 wei.
        uint256 msgValue = 10;
        uint256 expectedRemainder = msgValue % 3; // 1 wei

        address caller = makeAddr("caller");
        vm.deal(caller, msgValue);

        uint256 callerBalanceBefore = caller.balance;

        vm.prank(caller);
        sucker.mapTokens{value: msgValue}(maps);

        uint256 callerBalanceAfter = caller.balance;

        // The caller should have received the 1 wei remainder back.
        assertEq(callerBalanceAfter, callerBalanceBefore - msgValue + expectedRemainder, "Dust remainder not refunded");
    }

    /// @notice When msg.value is evenly divisible, no refund is needed and nothing reverts.
    function test_mapTokensNoDustWhenEvenlyDivisible() external {
        MapTokensDustSucker sucker = _createTestSucker(projectId, "");

        sucker.test_setRemoteToken(
            tokenA,
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 200_000, addr: remoteA, minBridgeAmount: 0})
        );
        sucker.test_setOutboxTreeCount(tokenA, 1);

        sucker.test_setRemoteToken(
            tokenB,
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 200_000, addr: remoteB, minBridgeAmount: 0})
        );
        sucker.test_setOutboxTreeCount(tokenB, 1);

        JBTokenMapping[] memory maps = new JBTokenMapping[](2);
        maps[0] = JBTokenMapping({localToken: tokenA, minGas: 200_000, remoteToken: bytes32(0), minBridgeAmount: 0});
        maps[1] = JBTokenMapping({localToken: tokenB, minGas: 200_000, remoteToken: bytes32(0), minBridgeAmount: 0});

        // 10 / 2 = 5 each, no remainder.
        uint256 msgValue = 10;

        address caller = makeAddr("caller");
        vm.deal(caller, msgValue);

        uint256 callerBalanceBefore = caller.balance;

        vm.prank(caller);
        sucker.mapTokens{value: msgValue}(maps);

        uint256 callerBalanceAfter = caller.balance;

        // No remainder, so caller balance should just decrease by msgValue.
        assertEq(callerBalanceAfter, callerBalanceBefore - msgValue, "Balance should decrease by exact msgValue");
    }

    /// @notice Fuzz test: for any msg.value and any numberToDisable (1-10), dust is always refunded.
    function test_mapTokensDustFuzz(uint256 msgValue) external {
        // Bound to avoid overflow and keep test tractable. Use 3 tokens to disable.
        msgValue = bound(msgValue, 0, 10 ether);
        uint256 numberToDisable = 3;
        uint256 expectedRemainder = msgValue % numberToDisable;

        MapTokensDustSucker sucker = _createTestSucker(projectId, "fuzz");

        sucker.test_setRemoteToken(
            tokenA,
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 200_000, addr: remoteA, minBridgeAmount: 0})
        );
        sucker.test_setOutboxTreeCount(tokenA, 1);

        sucker.test_setRemoteToken(
            tokenB,
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 200_000, addr: remoteB, minBridgeAmount: 0})
        );
        sucker.test_setOutboxTreeCount(tokenB, 1);

        sucker.test_setRemoteToken(
            tokenC,
            JBRemoteToken({enabled: true, emergencyHatch: false, minGas: 200_000, addr: remoteC, minBridgeAmount: 0})
        );
        sucker.test_setOutboxTreeCount(tokenC, 1);

        JBTokenMapping[] memory maps = new JBTokenMapping[](3);
        maps[0] = JBTokenMapping({localToken: tokenA, minGas: 200_000, remoteToken: bytes32(0), minBridgeAmount: 0});
        maps[1] = JBTokenMapping({localToken: tokenB, minGas: 200_000, remoteToken: bytes32(0), minBridgeAmount: 0});
        maps[2] = JBTokenMapping({localToken: tokenC, minGas: 200_000, remoteToken: bytes32(0), minBridgeAmount: 0});

        address caller = makeAddr("caller");
        vm.deal(caller, msgValue);

        uint256 callerBalanceBefore = caller.balance;

        vm.prank(caller);
        sucker.mapTokens{value: msgValue}(maps);

        uint256 callerBalanceAfter = caller.balance;

        assertEq(
            callerBalanceAfter, callerBalanceBefore - msgValue + expectedRemainder, "Dust remainder not refunded (fuzz)"
        );
    }

    function _createTestSucker(uint256 _projectId, bytes32 salt) internal returns (MapTokensDustSucker) {
        MapTokensDustSucker singleton = new MapTokensDustSucker(
            IJBDirectory(DIRECTORY),
            IJBPermissions(PERMISSIONS),
            IJBTokens(TOKENS),
            FORWARDER
        );
        vm.label(address(singleton), "SUCKER_SINGLETON");

        MapTokensDustSucker sucker =
            MapTokensDustSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        vm.label(address(sucker), "SUCKER");
        sucker.initialize(_projectId);

        return sucker;
    }
}

contract MapTokensDustSucker is JBSucker {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, forwarder)
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

    function _isRemotePeer(address sender) internal view override returns (bool valid) {
        return sender == _toAddress(peer());
    }

    function peerChainId() external view virtual override returns (uint256) {
        return block.chainid;
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
