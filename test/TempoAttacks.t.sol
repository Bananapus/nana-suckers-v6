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

/// @notice Reusable test sucker for attack testing.
contract AttackTempoSucker is JBSucker {
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

    function test_getInboxNonce(address token) external view returns (uint64) {
        return _inboxOf[token].nonce;
    }

    function test_getInboxRoot(address token) external view returns (bytes32) {
        return _inboxOf[token].root;
    }

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

    function test_setDeprecatedAfter(uint40 ts) external {
        deprecatedAfter = ts;
    }
}

/// @title TempoAttacks
/// @notice Attack surface testing for the Tempo cross-chain integration.
/// @dev Tests re-entrancy vectors, double-claiming, front-running, and cross-chain accounting invariants
///      specific to the mixed NATIVE_TOKEN/ERC20 architecture of Tempo.
contract TempoAttacks is Test {
    using MerkleLib for MerkleLib.Tree;

    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant CONTROLLER = address(900);
    address constant PROJECT = address(1000);
    address constant FORWARDER = address(1100);

    uint256 constant PROJECT_ID = 1;

    /// @dev Simulated WETH ERC20 on Tempo
    address constant WETH_ON_TEMPO = address(0xE770e770E770E770e770e770E770e770E770E770);

    AttackTempoSucker sucker;

    function setUp() public {
        vm.label(DIRECTORY, "MOCK_DIRECTORY");
        vm.label(PERMISSIONS, "MOCK_PERMISSIONS");

        sucker = _createTestSucker(PROJECT_ID, "attack_salt");

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
    }

    function _createTestSucker(uint256 projectId, bytes32 salt) internal returns (AttackTempoSucker) {
        AttackTempoSucker singleton = new AttackTempoSucker(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), 1, FORWARDER
        );

        AttackTempoSucker clone =
            AttackTempoSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        clone.initialize(projectId);
        return clone;
    }

    function _toBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    // =========================================================================
    // INVARIANT 1: No tokens created from nothing
    // =========================================================================
    function test_invariant_noTokensFromNothing() public {
        address token = WETH_ON_TEMPO;

        sucker.test_insertIntoTree(5 ether, token, 3 ether, address(100));
        sucker.test_insertIntoTree(10 ether, token, 7 ether, address(200));

        assertEq(sucker.test_getOutboxCount(token), 2, "Should have 2 leaves");

        vm.deal(address(sucker), 100 ether);

        assertEq(address(sucker).balance, 100 ether, "ETH balance should be inflated");
        assertEq(sucker.test_getOutboxCount(token), 2, "Outbox count should still be 2");
    }

    // =========================================================================
    // INVARIANT 2: No double-spend across different token types
    // =========================================================================
    function test_invariant_noDoubleSpendAcrossTokenTypes() public {
        address wethToken = WETH_ON_TEMPO;
        address nativeToken = JBConstants.NATIVE_TOKEN;

        sucker.test_insertIntoTree(5 ether, wethToken, 5 ether, address(120));
        sucker.test_insertIntoTree(5 ether, nativeToken, 5 ether, address(120));

        bytes32 wethRoot = sucker.test_getOutboxRoot(wethToken);
        bytes32 nativeRoot = sucker.test_getOutboxRoot(nativeToken);
        sucker.test_setInboxRoot(wethToken, 1, wethRoot);
        sucker.test_setInboxRoot(nativeToken, 1, nativeRoot);
        sucker.test_setOutboxBalance(wethToken, 100 ether);
        sucker.test_setOutboxBalance(nativeToken, 100 ether);

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, 5 ether, address(120), "", false)),
            abi.encode(5 ether)
        );

        bytes32[32] memory proof;

        // Claim for WETH_ON_TEMPO at index 0
        sucker.test_setNextMerkleCheckToBe(true);
        JBClaim memory wethClaim = JBClaim({
            token: wethToken,
            leaf: JBLeaf({
                index: 0,
                beneficiary: _toBytes32(address(120)),
                projectTokenCount: 5 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });
        sucker.claim(wethClaim);

        // Claim for NATIVE_TOKEN at index 0 should ALSO succeed (separate bitmap per token)
        sucker.test_setNextMerkleCheckToBe(true);
        JBClaim memory nativeClaim = JBClaim({
            token: nativeToken,
            leaf: JBLeaf({
                index: 0,
                beneficiary: _toBytes32(address(120)),
                projectTokenCount: 5 ether,
                terminalTokenAmount: 5 ether
            }),
            proof: proof
        });
        sucker.claim(nativeClaim);

        // But claiming WETH again at index 0 should revert
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, wethToken, 0));
        sucker.claim(wethClaim);

        // And claiming NATIVE again at index 0 should revert
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_LeafAlreadyExecuted.selector, nativeToken, 0));
        sucker.claim(nativeClaim);
    }

    // =========================================================================
    // ATTACK 1: Front-running token mapping change
    // =========================================================================
    function test_attack_frontRunTokenMappingChange() public {
        address token = WETH_ON_TEMPO;

        sucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: _toBytes32(JBConstants.NATIVE_TOKEN),
                toRemoteFee: 0
            })
        );

        sucker.test_insertIntoTree(10 ether, token, 5 ether, address(100));
        bytes32 root = sucker.test_getOutboxRoot(token);
        sucker.test_setInboxRoot(token, 1, root);

        address maliciousRemote = makeAddr("maliciousRemote");
        sucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: true, emergencyHatch: false, minGas: 200_000, addr: _toBytes32(maliciousRemote), toRemoteFee: 0
            })
        );

        bytes32 storedRoot = sucker.test_getInboxRoot(token);
        assertEq(storedRoot, root, "Inbox root should persist regardless of remote mapping change");
    }

    // =========================================================================
    // ATTACK 2: Cross-token inbox root confusion
    // =========================================================================
    function test_attack_crossTokenInboxConfusion() public {
        sucker.test_insertIntoTree(10 ether, WETH_ON_TEMPO, 5 ether, address(100));
        sucker.test_insertIntoTree(20 ether, JBConstants.NATIVE_TOKEN, 10 ether, address(200));

        bytes32 wethRoot = sucker.test_getOutboxRoot(WETH_ON_TEMPO);
        bytes32 nativeRoot = sucker.test_getOutboxRoot(JBConstants.NATIVE_TOKEN);

        sucker.test_setInboxRoot(WETH_ON_TEMPO, 1, wethRoot);
        sucker.test_setInboxRoot(JBConstants.NATIVE_TOKEN, 1, nativeRoot);

        assertTrue(wethRoot != nativeRoot, "Different trees should produce different roots");
    }

    // =========================================================================
    // ATTACK 3: Deprecated sucker message injection
    // =========================================================================
    function test_attack_deprecatedSuckerMessageInjection() public {
        vm.warp(30 days);

        sucker.test_setDeprecatedAfter(uint40(block.timestamp + 1));
        vm.warp(block.timestamp + 1);
        assertEq(uint8(sucker.state()), uint8(JBSuckerState.DEPRECATED));

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: _toBytes32(WETH_ON_TEMPO),
            amount: 1000 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xDEAD))})
        });

        vm.prank(address(sucker));
        sucker.fromRemote(root);

        assertEq(sucker.test_getInboxNonce(WETH_ON_TEMPO), 0, "Inbox should not update when deprecated");
    }

    // =========================================================================
    // ATTACK 4: Nonce gap exploitation
    // =========================================================================
    function test_attack_nonceGapExploitation() public {
        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: _toBytes32(WETH_ON_TEMPO),
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xAA))})
            })
        );
        assertEq(sucker.test_getInboxNonce(WETH_ON_TEMPO), 1);

        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: _toBytes32(WETH_ON_TEMPO),
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 5, root: bytes32(uint256(0xBB))})
            })
        );
        assertEq(sucker.test_getInboxNonce(WETH_ON_TEMPO), 5, "Nonce gap should be accepted");

        vm.prank(address(sucker));
        sucker.fromRemote(
            JBMessageRoot({
                version: 1,
                token: _toBytes32(WETH_ON_TEMPO),
                amount: 1 ether,
                remoteRoot: JBInboxTreeRoot({nonce: 3, root: bytes32(uint256(0xCC))})
            })
        );
        assertEq(sucker.test_getInboxNonce(WETH_ON_TEMPO), 5, "Stale nonce 3 should be ignored");
    }

    // =========================================================================
    // ATTACK 5: Claim with beneficiary mismatch
    // =========================================================================
    function test_attack_beneficiaryMismatch() public {
        address token = WETH_ON_TEMPO;
        address realBeneficiary = address(100);
        address attacker = address(999);

        sucker.test_insertIntoTree(5 ether, token, 5 ether, realBeneficiary);
        bytes32 root = sucker.test_getOutboxRoot(token);
        sucker.test_setInboxRoot(token, 1, root);
        sucker.test_setOutboxBalance(token, 100 ether);

        bytes32[32] memory proof;
        JBClaim memory attackClaim = JBClaim({
            token: token,
            leaf: JBLeaf({
                index: 0, beneficiary: _toBytes32(attacker), projectTokenCount: 5 ether, terminalTokenAmount: 5 ether
            }),
            proof: proof
        });

        vm.expectRevert();
        sucker.claim(attackClaim);
    }

    // =========================================================================
    // INVARIANT 3: Outbox tree count is monotonically increasing
    // =========================================================================
    function test_invariant_outboxCountMonotonic() public {
        address token = WETH_ON_TEMPO;

        uint256 prevCount = 0;
        for (uint256 i = 0; i < 20; i++) {
            sucker.test_insertIntoTree((i + 1) * 1 ether, token, (i + 1) * 0.5 ether, address(uint160(1000 + i)));

            uint256 newCount = sucker.test_getOutboxCount(token);
            assertTrue(newCount > prevCount, "Count must strictly increase");
            prevCount = newCount;
        }

        assertEq(prevCount, 20, "Final count should be 20");
    }

    // =========================================================================
    // INVARIANT 4: Inbox nonce is monotonically increasing per token
    // =========================================================================
    function test_invariant_inboxNonceMonotonic() public {
        uint64 wethNonce = 0;
        uint64 nativeNonce = 0;

        for (uint64 i = 1; i <= 10; i++) {
            vm.prank(address(sucker));
            sucker.fromRemote(
                JBMessageRoot({
                    version: 1,
                    token: _toBytes32(WETH_ON_TEMPO),
                    amount: 1 ether,
                    remoteRoot: JBInboxTreeRoot({nonce: i, root: bytes32(uint256(i))})
                })
            );
            uint64 newWethNonce = sucker.test_getInboxNonce(WETH_ON_TEMPO);
            assertTrue(newWethNonce > wethNonce, "WETH nonce must increase");
            wethNonce = newWethNonce;

            vm.prank(address(sucker));
            sucker.fromRemote(
                JBMessageRoot({
                    version: 1,
                    token: _toBytes32(JBConstants.NATIVE_TOKEN),
                    amount: 1 ether,
                    remoteRoot: JBInboxTreeRoot({nonce: i * 2, root: bytes32(uint256(i * 100))})
                })
            );
            uint64 newNativeNonce = sucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN);
            assertTrue(newNativeNonce > nativeNonce, "NATIVE nonce must increase");
            nativeNonce = newNativeNonce;
        }

        assertEq(wethNonce, 10, "Final WETH nonce should be 10");
        assertEq(nativeNonce, 20, "Final NATIVE nonce should be 20");
    }

    receive() external payable {}
}
