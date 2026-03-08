// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v5/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v5/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v5/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../src/JBSucker.sol";
import {JBAddToBalanceMode} from "../src/enums/JBAddToBalanceMode.sol";
import {JBSuckerState} from "../src/enums/JBSuckerState.sol";
import {JBClaim} from "../src/structs/JBClaim.sol";
import {JBLeaf} from "../src/structs/JBLeaf.sol";
import {JBInboxTreeRoot} from "../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../src/structs/JBTokenMapping.sol";
import {MerkleLib} from "../src/utils/MerkleLib.sol";
import {CCIPHelper} from "../src/libraries/CCIPHelper.sol";

/// @notice A test sucker that exposes internals and supports mixed NATIVE/ERC20 token scenarios.
contract TempoTestSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;

    bool nextCheckShouldPass;

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
    {}

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == peer();
    }

    function peerChainId() external view virtual override returns (uint256) {
        return block.chainid;
    }

    function _validateBranchRoot(
        bytes32 expectedRoot,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        address beneficiary,
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
        address beneficiary
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

/// @title TempoSuckerSecurity
/// @notice Security tests for Tempo blockchain integration, focusing on mixed NATIVE_TOKEN/ERC20 token mappings.
/// @dev Tempo's native token is USD (not ETH). ETH exists only as an ERC20 (WETH) on Tempo.
///      This test suite validates that the sucker system handles this architecture correctly.
contract TempoSuckerSecurity is Test {
    using MerkleLib for MerkleLib.Tree;

    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);

    uint256 constant PROJECT_ID = 1;

    /// @dev Simulated WETH ERC20 address on Tempo (not NATIVE_TOKEN)
    address constant WETH_ON_TEMPO = address(0xE770e770E770E770e770e770E770e770E770E770);

    /// @dev WTEMP is wrapped native USD on Tempo — NOT the same as WETH
    address constant WTEMP = 0xe875EB5437E55B74D18f6C090a5A14e4804dB2d9;

    TempoTestSucker ethSucker; // Sucker on ETH side
    TempoTestSucker tempoSucker; // Sucker on Tempo side

    function setUp() public {
        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");
        vm.label(TOKENS, "MOCK_TOKENS");
        vm.label(CONTROLLER, "MOCK_CONTROLLER");

        ethSucker = _createTestSucker(PROJECT_ID, "eth_sucker");
        tempoSucker = _createTestSucker(PROJECT_ID, "tempo_sucker");

        // Mock directory
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
    }

    function _createTestSucker(uint256 projectId, bytes32 salt) internal returns (TempoTestSucker) {
        TempoTestSucker singleton = new TempoTestSucker(
            IJBDirectory(DIRECTORY),
            IJBPermissions(PERMISSIONS),
            IJBTokens(TOKENS),
            JBAddToBalanceMode.MANUAL,
            FORWARDER
        );

        TempoTestSucker clone = TempoTestSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        clone.initialize(projectId);
        return clone;
    }

    // =========================================================================
    // Test 1: Mixed NATIVE/ERC20 mapping — ETH→Tempo direction
    // =========================================================================
    /// @notice When NATIVE_TOKEN on ETH maps to WETH_ON_TEMPO (ERC20), the sucker on Tempo
    ///         should NOT attempt to unwrap the received token. The inbox should be keyed by WETH_ON_TEMPO.
    function test_mixedMapping_ethToTempo_inboxKeyedByERC20() public {
        // On the ETH side: localToken = NATIVE_TOKEN, remoteToken = WETH_ON_TEMPO
        // When _sendRoot constructs the message, root.token = remoteToken.addr = WETH_ON_TEMPO
        // On Tempo side: fromRemote receives root.token = WETH_ON_TEMPO

        JBMessageRoot memory root = JBMessageRoot({
            token: WETH_ON_TEMPO, // This is what the Tempo sucker receives
            amount: 5 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xAABBCC))})
        });

        // Simulate fromRemote call from the peer (self for test sucker)
        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(root);

        // The inbox should be keyed by WETH_ON_TEMPO (ERC20), NOT by NATIVE_TOKEN
        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 1, "Inbox nonce for WETH_ON_TEMPO should be 1");
        assertEq(
            tempoSucker.test_getInboxRoot(WETH_ON_TEMPO),
            bytes32(uint256(0xAABBCC)),
            "Inbox root should match for WETH_ON_TEMPO"
        );

        // NATIVE_TOKEN inbox should remain untouched
        assertEq(tempoSucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN), 0, "NATIVE_TOKEN inbox should be empty");
    }

    // =========================================================================
    // Test 2: Mixed NATIVE/ERC20 mapping — Tempo→ETH direction
    // =========================================================================
    /// @notice When WETH_ON_TEMPO (ERC20) on Tempo maps to NATIVE_TOKEN on ETH, the ETH sucker
    ///         receives root.token = NATIVE_TOKEN, triggering the WETH unwrap path.
    function test_mixedMapping_tempoToEth_inboxKeyedByNativeToken() public {
        // On Tempo side: localToken = WETH_ON_TEMPO, remoteToken = NATIVE_TOKEN
        // When _sendRoot constructs message, root.token = remoteToken.addr = NATIVE_TOKEN
        // On ETH side: fromRemote receives root.token = NATIVE_TOKEN

        JBMessageRoot memory root = JBMessageRoot({
            token: JBConstants.NATIVE_TOKEN, // ETH sucker receives NATIVE_TOKEN
            amount: 5 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xDDEEFF))})
        });

        // Simulate fromRemote on ETH side
        vm.prank(address(ethSucker));
        ethSucker.fromRemote(root);

        // Inbox should be keyed by NATIVE_TOKEN
        assertEq(ethSucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN), 1, "Inbox nonce for NATIVE_TOKEN should be 1");
        assertEq(
            ethSucker.test_getInboxRoot(JBConstants.NATIVE_TOKEN),
            bytes32(uint256(0xDDEEFF)),
            "Inbox root should match for NATIVE_TOKEN"
        );
    }

    // =========================================================================
    // Test 3: Double-claim prevention on mixed NATIVE/ERC20 mapping
    // =========================================================================
    /// @notice Verify that claiming the same leaf twice reverts, even when the token mapping
    ///         is mixed (NATIVE_TOKEN on one side, ERC20 on the other).
    function test_doubleClaim_mixedMapping() public {
        address token = WETH_ON_TEMPO; // ERC20 on Tempo side

        // Insert a leaf for WETH_ON_TEMPO
        tempoSucker.test_insertIntoTree(5 ether, token, 5 ether, address(120));
        bytes32 root = tempoSucker.test_getOutboxRoot(token);
        tempoSucker.test_setInboxRoot(token, 1, root);
        tempoSucker.test_setOutboxBalance(token, 100 ether);

        // Mock controller for minting
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, 5 ether, address(120), "", false)),
            abi.encode(5 ether)
        );

        // First claim succeeds
        tempoSucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: token,
            leaf: JBLeaf({
                index: 0, beneficiary: address(120), projectTokenCount: 5 ether, terminalTokenAmount: 5 ether
            }),
            proof: proof
        });
        tempoSucker.claim(claimData);

        // Second claim with same index must revert
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, token, 0));
        tempoSucker.claim(claimData);
    }

    // =========================================================================
    // Test 4: WTEMP ≠ WETH — wrapped native mismatch
    // =========================================================================
    /// @notice WTEMP (wrapped native USD on Tempo) and WETH (wrapped ETH on Tempo) are different tokens.
    ///         Verify that inbox roots are correctly segregated by token address.
    function test_wrappedNativeMismatch_wtempNotWeth() public {
        // WTEMP and WETH_ON_TEMPO are completely different tokens
        assertTrue(WTEMP != WETH_ON_TEMPO, "WTEMP and WETH_ON_TEMPO must be different addresses");

        // Set up separate inbox roots for WTEMP and WETH_ON_TEMPO
        tempoSucker.test_setInboxRoot(WTEMP, 1, bytes32(uint256(0x111)));
        tempoSucker.test_setInboxRoot(WETH_ON_TEMPO, 1, bytes32(uint256(0x222)));

        // Verify they are independently tracked
        assertEq(tempoSucker.test_getInboxRoot(WTEMP), bytes32(uint256(0x111)), "WTEMP inbox should be independent");
        assertEq(
            tempoSucker.test_getInboxRoot(WETH_ON_TEMPO), bytes32(uint256(0x222)), "WETH inbox should be independent"
        );

        // Setting one should not affect the other
        tempoSucker.test_setInboxRoot(WTEMP, 2, bytes32(uint256(0x333)));
        assertEq(
            tempoSucker.test_getInboxRoot(WETH_ON_TEMPO),
            bytes32(uint256(0x222)),
            "Updating WTEMP should not affect WETH inbox"
        );
    }

    // =========================================================================
    // Test 5: Round-trip bridge accounting (ETH→Tempo→ETH)
    // =========================================================================
    /// @notice Verify that outbox trees and inbox roots remain consistent during a round-trip bridge.
    ///         ETH→Tempo (as WETH ERC20) → back to ETH (as NATIVE_TOKEN).
    function test_roundTripAccounting() public {
        // === Leg 1: ETH → Tempo ===
        // On ETH side, user prepares NATIVE_TOKEN for bridging
        ethSucker.test_insertIntoTree(10 ether, JBConstants.NATIVE_TOKEN, 5 ether, address(1000));
        bytes32 ethOutboxRoot = ethSucker.test_getOutboxRoot(JBConstants.NATIVE_TOKEN);
        uint256 ethOutboxCount = ethSucker.test_getOutboxCount(JBConstants.NATIVE_TOKEN);
        assertEq(ethOutboxCount, 1, "ETH outbox should have 1 leaf");

        // Simulate: root arrives on Tempo as WETH_ON_TEMPO (the remote token addr)
        JBMessageRoot memory toTempoMsg = JBMessageRoot({
            token: WETH_ON_TEMPO, amount: 5 ether, remoteRoot: JBInboxTreeRoot({nonce: 1, root: ethOutboxRoot})
        });

        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(toTempoMsg);
        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 1, "Tempo inbox nonce should be 1");

        // === Leg 2: Tempo → ETH ===
        // On Tempo side, user prepares WETH_ON_TEMPO for bridging back
        tempoSucker.test_insertIntoTree(10 ether, WETH_ON_TEMPO, 5 ether, address(2000));
        bytes32 tempoOutboxRoot = tempoSucker.test_getOutboxRoot(WETH_ON_TEMPO);
        uint256 tempoOutboxCount = tempoSucker.test_getOutboxCount(WETH_ON_TEMPO);
        assertEq(tempoOutboxCount, 1, "Tempo outbox should have 1 leaf");

        // Simulate: root arrives on ETH as NATIVE_TOKEN (the remote token addr)
        JBMessageRoot memory toEthMsg = JBMessageRoot({
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: tempoOutboxRoot})
        });

        vm.prank(address(ethSucker));
        ethSucker.fromRemote(toEthMsg);
        assertEq(ethSucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN), 1, "ETH inbox nonce should be 1");

        // Verify: Both sides have correct inbox roots from the round-trip
        assertEq(tempoSucker.test_getInboxRoot(WETH_ON_TEMPO), ethOutboxRoot, "Tempo inbox should hold ETH outbox root");
        assertEq(
            ethSucker.test_getInboxRoot(JBConstants.NATIVE_TOKEN),
            tempoOutboxRoot,
            "ETH inbox should hold Tempo outbox root"
        );
    }

    // =========================================================================
    // Test 6: Nonce replay prevention across mixed token types
    // =========================================================================
    /// @notice Verify that replaying a message with the same nonce is silently ignored,
    ///         even when crossing between NATIVE_TOKEN and ERC20 token types.
    function test_nonceReplay_mixedTokenTypes() public {
        JBMessageRoot memory root = JBMessageRoot({
            token: WETH_ON_TEMPO,
            amount: 5 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xAABBCC))})
        });

        // First delivery — accepted
        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(root);
        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 1);

        // Replay with same nonce — silently ignored
        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(root);
        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 1, "Nonce should not advance on replay");

        // Higher nonce — accepted
        root.remoteRoot.nonce = 2;
        root.remoteRoot.root = bytes32(uint256(0xDDEEFF));
        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(root);
        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 2, "Nonce should advance to 2");
    }

    // =========================================================================
    // Test 7: Outbox tree isolation between NATIVE_TOKEN and WETH_ON_TEMPO
    // =========================================================================
    /// @notice On Tempo, NATIVE_TOKEN (USD) and WETH_ON_TEMPO (ETH as ERC20) are different tokens
    ///         with separate outbox trees. Inserting into one should not affect the other.
    function test_outboxTreeIsolation_nativeVsWeth() public {
        // Insert into NATIVE_TOKEN (USD) outbox
        tempoSucker.test_insertIntoTree(1 ether, JBConstants.NATIVE_TOKEN, 1 ether, address(100));

        // Insert into WETH_ON_TEMPO outbox
        tempoSucker.test_insertIntoTree(2 ether, WETH_ON_TEMPO, 2 ether, address(200));

        // Verify separate tree counts
        assertEq(tempoSucker.test_getOutboxCount(JBConstants.NATIVE_TOKEN), 1, "NATIVE outbox should have 1 leaf");
        assertEq(tempoSucker.test_getOutboxCount(WETH_ON_TEMPO), 1, "WETH outbox should have 1 leaf");

        // Verify separate roots
        bytes32 nativeRoot = tempoSucker.test_getOutboxRoot(JBConstants.NATIVE_TOKEN);
        bytes32 wethRoot = tempoSucker.test_getOutboxRoot(WETH_ON_TEMPO);
        assertTrue(nativeRoot != wethRoot, "NATIVE and WETH outbox roots should differ");
    }

    // =========================================================================
    // Test 8: CCIPHelper constants for Tempo testnet
    // =========================================================================
    /// @notice Verify that the CCIPHelper library returns correct constants for Tempo testnet.
    function test_ccipHelper_tempoTestnetConstants() public pure {
        // Verify chain ID
        assertEq(CCIPHelper.TEMPO_TEST_ID, 42_429, "Tempo testnet chain ID should be 42429");

        // Verify selector
        assertEq(CCIPHelper.TEMPO_TEST_SEL, 3_963_528_237_232_804_922, "Tempo testnet CCIP selector should match");

        // Verify router
        assertEq(
            CCIPHelper.TEMPO_TEST_ROUTER,
            0xAE7D1b3D8466718378038de45D4D376E73A04EB6,
            "Tempo testnet router should match"
        );

        // Verify WTEMP address
        assertEq(
            CCIPHelper.TEMPO_TEST_WETH, 0xe875EB5437E55B74D18f6C090a5A14e4804dB2d9, "Tempo testnet WTEMP should match"
        );

        // Verify lookup functions
        assertEq(CCIPHelper.routerOfChain(42_429), CCIPHelper.TEMPO_TEST_ROUTER, "routerOfChain should match");
        assertEq(CCIPHelper.selectorOfChain(42_429), CCIPHelper.TEMPO_TEST_SEL, "selectorOfChain should match");
        assertEq(CCIPHelper.wethOfChain(42_429), CCIPHelper.TEMPO_TEST_WETH, "wethOfChain should match");
    }

    // =========================================================================
    // Test 9: Emergency exit with mixed token mapping
    // =========================================================================
    /// @notice Verify emergency exit works correctly when the sucker on Tempo uses WETH_ON_TEMPO
    ///         (an ERC20 token that maps to NATIVE_TOKEN on ETH).
    function test_emergencyExit_mixedMapping() public {
        address token = WETH_ON_TEMPO;

        // Set up a remote mapping: WETH_ON_TEMPO → NATIVE_TOKEN on ETH
        tempoSucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: JBConstants.NATIVE_TOKEN,
                minBridgeAmount: 0
            })
        );

        // Insert leaf and set inbox root
        tempoSucker.test_insertIntoTree(1 ether, token, 1 ether, address(this));
        bytes32 root = tempoSucker.test_getOutboxRoot(token);
        tempoSucker.test_setInboxRoot(token, 1, root);
        tempoSucker.test_setOutboxBalance(token, 10 ether);

        // Deprecate the sucker
        uint256 deprecationTimestamp = block.timestamp + 14 days;
        tempoSucker.setDeprecation(uint40(deprecationTimestamp));
        vm.warp(deprecationTimestamp);

        // Mock controller for minting
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, 1 ether, address(this), "", false)),
            abi.encode(1 ether)
        );

        // Bypass merkle validation for this test
        tempoSucker.test_setNextMerkleCheckToBe(true);

        bytes32[32] memory proof;
        JBClaim memory claim = JBClaim({
            token: token,
            leaf: JBLeaf({
                index: 0, beneficiary: address(this), projectTokenCount: 1 ether, terminalTokenAmount: 1 ether
            }),
            proof: proof
        });

        // Emergency exit should work for ERC20 token (WETH_ON_TEMPO) on Tempo
        tempoSucker.exitThroughEmergencyHatch(claim);
    }

    // =========================================================================
    // Test 10: Independent nonce tracking for different token types
    // =========================================================================
    /// @notice Verify that NATIVE_TOKEN and WETH_ON_TEMPO have independent nonce tracking
    ///         in the inbox, preventing cross-token nonce confusion.
    function test_independentNonceTracking() public {
        // Deliver message for WETH_ON_TEMPO at nonce 1
        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(
            JBMessageRoot({
                token: WETH_ON_TEMPO,
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xAA))})
            })
        );

        // Deliver message for NATIVE_TOKEN at nonce 5 (independent nonce space)
        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(
            JBMessageRoot({
                token: JBConstants.NATIVE_TOKEN,
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 5, root: bytes32(uint256(0xBB))})
            })
        );

        // Verify independent nonce tracking
        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 1, "WETH nonce should be 1");
        assertEq(tempoSucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN), 5, "NATIVE nonce should be 5");

        // Advancing NATIVE nonce should not affect WETH nonce
        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(
            JBMessageRoot({
                token: JBConstants.NATIVE_TOKEN,
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 6, root: bytes32(uint256(0xCC))})
            })
        );
        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 1, "WETH nonce should still be 1");
        assertEq(tempoSucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN), 6, "NATIVE nonce should advance to 6");
    }

    receive() external payable {}
}
