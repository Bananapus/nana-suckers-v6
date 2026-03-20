// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../src/JBSucker.sol";
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
        uint256 feeProjectId,
        address trustedForwarder
    )
        JBSucker(directory, permissions, tokens, feeProjectId, trustedForwarder)
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
        return _toBytes32(sender) == peer();
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

    /// @dev Override to skip terminal interactions in tests.
    function _addToBalance(address, uint256) internal override {}

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
        _insertIntoTree(projectTokenCount, token, terminalTokenAmount, _toBytes32(beneficiary));
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
        TempoTestSucker singleton =
            new TempoTestSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), 1, FORWARDER);

        TempoTestSucker clone = TempoTestSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        clone.initialize(projectId);
        return clone;
    }

    function _toBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    // =========================================================================
    // Test 1: Mixed NATIVE/ERC20 mapping — ETH→Tempo direction
    // =========================================================================
    function test_mixedMapping_ethToTempo_inboxKeyedByERC20() public {
        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: _toBytes32(WETH_ON_TEMPO),
            amount: 5 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xAABBCC))})
        });

        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(root);

        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 1, "Inbox nonce for WETH_ON_TEMPO should be 1");
        assertEq(
            tempoSucker.test_getInboxRoot(WETH_ON_TEMPO),
            bytes32(uint256(0xAABBCC)),
            "Inbox root should match for WETH_ON_TEMPO"
        );

        assertEq(tempoSucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN), 0, "NATIVE_TOKEN inbox should be empty");
    }

    // =========================================================================
    // Test 2: Mixed NATIVE/ERC20 mapping — Tempo→ETH direction
    // =========================================================================
    function test_mixedMapping_tempoToEth_inboxKeyedByNativeToken() public {
        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: _toBytes32(JBConstants.NATIVE_TOKEN),
            amount: 5 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xDDEEFF))})
        });

        vm.prank(address(ethSucker));
        ethSucker.fromRemote(root);

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
    function test_doubleClaim_mixedMapping() public {
        address token = WETH_ON_TEMPO;

        tempoSucker.test_insertIntoTree(5 ether, token, 5 ether, address(120));
        bytes32 root = tempoSucker.test_getOutboxRoot(token);
        tempoSucker.test_setInboxRoot(token, 1, root);
        tempoSucker.test_setOutboxBalance(token, 100 ether);

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, 5 ether, address(120), "", false)),
            abi.encode(5 ether)
        );

        tempoSucker.test_setNextMerkleCheckToBe(true);
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: token,
            leaf: JBLeaf({
                index: 0,
                beneficiary: _toBytes32(address(120)),
                projectTokenCount: 5 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });
        tempoSucker.claim(claimData);

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, token, 0));
        tempoSucker.claim(claimData);
    }

    // =========================================================================
    // Test 4: WTEMP ≠ WETH — wrapped native mismatch
    // =========================================================================
    function test_wrappedNativeMismatch_wtempNotWeth() public {
        assertTrue(WTEMP != WETH_ON_TEMPO, "WTEMP and WETH_ON_TEMPO must be different addresses");

        tempoSucker.test_setInboxRoot(WTEMP, 1, bytes32(uint256(0x111)));
        tempoSucker.test_setInboxRoot(WETH_ON_TEMPO, 1, bytes32(uint256(0x222)));

        assertEq(tempoSucker.test_getInboxRoot(WTEMP), bytes32(uint256(0x111)), "WTEMP inbox should be independent");
        assertEq(
            tempoSucker.test_getInboxRoot(WETH_ON_TEMPO), bytes32(uint256(0x222)), "WETH inbox should be independent"
        );

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
    function test_roundTripAccounting() public {
        // Leg 1: ETH → Tempo
        ethSucker.test_insertIntoTree(10 ether, JBConstants.NATIVE_TOKEN, 5 ether, address(1000));
        bytes32 ethOutboxRoot = ethSucker.test_getOutboxRoot(JBConstants.NATIVE_TOKEN);
        uint256 ethOutboxCount = ethSucker.test_getOutboxCount(JBConstants.NATIVE_TOKEN);
        assertEq(ethOutboxCount, 1, "ETH outbox should have 1 leaf");

        JBMessageRoot memory toTempoMsg = JBMessageRoot({
            version: 1,
            token: _toBytes32(WETH_ON_TEMPO),
            amount: 5 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: ethOutboxRoot})
        });

        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(toTempoMsg);
        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 1, "Tempo inbox nonce should be 1");

        // Leg 2: Tempo → ETH
        tempoSucker.test_insertIntoTree(10 ether, WETH_ON_TEMPO, 5 ether, address(2000));
        bytes32 tempoOutboxRoot = tempoSucker.test_getOutboxRoot(WETH_ON_TEMPO);
        uint256 tempoOutboxCount = tempoSucker.test_getOutboxCount(WETH_ON_TEMPO);
        assertEq(tempoOutboxCount, 1, "Tempo outbox should have 1 leaf");

        JBMessageRoot memory toEthMsg = JBMessageRoot({
            version: 1,
            token: _toBytes32(JBConstants.NATIVE_TOKEN),
            amount: 5 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: tempoOutboxRoot})
        });

        vm.prank(address(ethSucker));
        ethSucker.fromRemote(toEthMsg);
        assertEq(ethSucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN), 1, "ETH inbox nonce should be 1");

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
    function test_nonceReplay_mixedTokenTypes() public {
        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: _toBytes32(WETH_ON_TEMPO),
            amount: 5 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xAABBCC))})
        });

        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(root);
        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 1);

        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(root);
        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 1, "Nonce should not advance on replay");

        root.remoteRoot.nonce = 2;
        root.remoteRoot.root = bytes32(uint256(0xDDEEFF));
        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(root);
        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 2, "Nonce should advance to 2");
    }

    // =========================================================================
    // Test 7: Outbox tree isolation between NATIVE_TOKEN and WETH_ON_TEMPO
    // =========================================================================
    function test_outboxTreeIsolation_nativeVsWeth() public {
        tempoSucker.test_insertIntoTree(1 ether, JBConstants.NATIVE_TOKEN, 1 ether, address(100));
        tempoSucker.test_insertIntoTree(2 ether, WETH_ON_TEMPO, 2 ether, address(200));

        assertEq(tempoSucker.test_getOutboxCount(JBConstants.NATIVE_TOKEN), 1, "NATIVE outbox should have 1 leaf");
        assertEq(tempoSucker.test_getOutboxCount(WETH_ON_TEMPO), 1, "WETH outbox should have 1 leaf");

        bytes32 nativeRoot = tempoSucker.test_getOutboxRoot(JBConstants.NATIVE_TOKEN);
        bytes32 wethRoot = tempoSucker.test_getOutboxRoot(WETH_ON_TEMPO);
        assertTrue(nativeRoot != wethRoot, "NATIVE and WETH outbox roots should differ");
    }

    // =========================================================================
    // Test 8: CCIPHelper constants for Tempo testnet
    // =========================================================================
    function test_ccipHelper_tempoTestnetConstants() public pure {
        assertEq(CCIPHelper.TEMPO_TEST_ID, 42_429, "Tempo testnet chain ID should be 42429");
        assertEq(CCIPHelper.TEMPO_TEST_SEL, 3_963_528_237_232_804_922, "Tempo testnet CCIP selector should match");
        assertEq(
            CCIPHelper.TEMPO_TEST_ROUTER,
            0xAE7D1b3D8466718378038de45D4D376E73A04EB6,
            "Tempo testnet router should match"
        );
        assertEq(
            CCIPHelper.TEMPO_TEST_WETH, 0xe875EB5437E55B74D18f6C090a5A14e4804dB2d9, "Tempo testnet WTEMP should match"
        );

        assertEq(CCIPHelper.routerOfChain(42_429), CCIPHelper.TEMPO_TEST_ROUTER, "routerOfChain should match");
        assertEq(CCIPHelper.selectorOfChain(42_429), CCIPHelper.TEMPO_TEST_SEL, "selectorOfChain should match");
        assertEq(CCIPHelper.wethOfChain(42_429), CCIPHelper.TEMPO_TEST_WETH, "wethOfChain should match");
    }

    // =========================================================================
    // Test 9: Emergency exit with mixed token mapping
    // =========================================================================
    function test_emergencyExit_mixedMapping() public {
        address token = WETH_ON_TEMPO;

        tempoSucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: _toBytes32(JBConstants.NATIVE_TOKEN),
                toRemoteFee: 0
            })
        );

        tempoSucker.test_insertIntoTree(1 ether, token, 1 ether, address(this));
        bytes32 root = tempoSucker.test_getOutboxRoot(token);
        tempoSucker.test_setInboxRoot(token, 1, root);
        tempoSucker.test_setOutboxBalance(token, 10 ether);

        uint256 deprecationTimestamp = block.timestamp + 14 days;
        tempoSucker.setDeprecation(uint40(deprecationTimestamp));
        vm.warp(deprecationTimestamp);

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, 1 ether, address(this), "", false)),
            abi.encode(1 ether)
        );

        tempoSucker.test_setNextMerkleCheckToBe(true);

        bytes32[32] memory proof;
        JBClaim memory claim = JBClaim({
            token: token,
            leaf: JBLeaf({
                index: 0,
                beneficiary: _toBytes32(address(this)),
                projectTokenCount: 1 ether,
                terminalTokenAmount: 1 ether
            }),
            proof: proof
        });

        tempoSucker.exitThroughEmergencyHatch(claim);
    }

    // =========================================================================
    // Test 10: Independent nonce tracking for different token types
    // =========================================================================
    function test_independentNonceTracking() public {
        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: _toBytes32(WETH_ON_TEMPO),
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xAA))})
            })
        );

        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: _toBytes32(JBConstants.NATIVE_TOKEN),
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 5, root: bytes32(uint256(0xBB))})
            })
        );

        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 1, "WETH nonce should be 1");
        assertEq(tempoSucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN), 5, "NATIVE nonce should be 5");

        vm.prank(address(tempoSucker));
        tempoSucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: _toBytes32(JBConstants.NATIVE_TOKEN),
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 6, root: bytes32(uint256(0xCC))})
            })
        );
        assertEq(tempoSucker.test_getInboxNonce(WETH_ON_TEMPO), 1, "WETH nonce should still be 1");
        assertEq(tempoSucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN), 6, "NATIVE nonce should advance to 6");
    }

    receive() external payable {}
}
