// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../src/JBSucker.sol";

import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../src/structs/JBRemoteToken.sol";
import {MerkleLib} from "../src/utils/MerkleLib.sol";

/// @notice Test harness that exposes JBSucker internals for interop testing.
/// @dev Extends JBSucker to expose _buildTreeHash, _toBytes32, _toAddress, _insertIntoTree,
///      and merkle tree state without the _validateBranchRoot bypass from AttackTestSucker.
contract InteropTestSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address forwarder
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), forwarder)
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

    function _isRemotePeer(address) internal pure override returns (bool) {
        return false;
    }

    function peerChainId() external pure override returns (uint256) {
        return 1;
    }

    // --- Exposed internals ---

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_buildTreeHash(
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary
    )
        external
        pure
        returns (bytes32)
    {
        return _buildTreeHash(projectTokenCount, terminalTokenAmount, beneficiary);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_toBytes32(address addr) external pure returns (bytes32) {
        return _toBytes32(addr);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_toAddress(bytes32 remote) external pure returns (address) {
        return _toAddress(remote);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_insertIntoTree(
        uint256 projectTokenCount,
        address token,
        uint256 terminalTokenAmount,
        bytes32 beneficiary
    )
        external
    {
        _insertIntoTree(projectTokenCount, token, terminalTokenAmount, beneficiary);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getOutboxRoot(address token) external view returns (bytes32) {
        return _outboxOf[token].tree.root();
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getOutboxCount(address token) external view returns (uint256) {
        return _outboxOf[token].tree.count;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getOutboxBranch(address token) external view returns (bytes32[32] memory) {
        bytes32[32] memory branch;
        for (uint256 i; i < 32; i++) {
            branch[i] = _outboxOf[token].tree.branch[i];
        }
        return branch;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_setInboxRoot(address token, uint64 nonce, bytes32 root) external {
        _inboxOf[token] = JBInboxTreeRoot({nonce: nonce, root: root});
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_validateBranchRoot(
        bytes32 expectedRoot,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        uint256 index,
        bytes32[32] calldata leaves
    )
        external
    {
        _validateBranchRoot(expectedRoot, projectTokenCount, terminalTokenAmount, beneficiary, index, leaves);
    }
}

/// @title InteropCompat
/// @notice Cross-VM interoperability tests proving that EVM and SVM suckers produce
///         identical leaf hashes, merkle trees, address encodings, and message formats.
///         These tests mock the SVM side in pure Solidity by replicating the exact byte
///         layout that the SVM Rust code uses.
contract InteropCompat is Test {
    using MerkleLib for MerkleLib.Tree;

    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant FORWARDER = address(1100);

    InteropTestSucker sucker;

    function setUp() public {
        // Mock DIRECTORY.PROJECTS() so the JBSucker constructor can initialize the PROJECTS immutable.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(address(0)));

        InteropTestSucker singleton =
            new InteropTestSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), FORWARDER);

        sucker = InteropTestSucker(payable(address(LibClone.cloneDeterministic(address(singleton), "interop"))));
        sucker.initialize(1);
    }

    // =========================================================================
    // Section 1: Leaf Hash Compatibility
    // =========================================================================

    /// @notice Replicate SVM build_tree_hash in Solidity and verify it matches _buildTreeHash.
    /// @dev SVM constructs a 96-byte buffer:
    ///      [0..32]  = projectTokenCount as uint256 big-endian (u128 zero-padded to 32 bytes)
    ///      [32..64] = terminalTokenAmount as uint256 big-endian (u128 zero-padded to 32 bytes)
    ///      [64..96] = beneficiary as bytes32
    ///      Then keccak256(buffer).
    ///      EVM's abi.encode(uint256, uint256, bytes32) produces the exact same layout.
    function _svmBuildTreeHash(
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary
    )
        internal
        pure
        returns (bytes32)
    {
        // Manual 96-byte buffer matching SVM's build_tree_hash exactly
        bytes memory data = new bytes(96);
        assembly {
            // data starts at data+32 (skip length prefix)
            let ptr := add(data, 32)
            // [0..32] = projectTokenCount as big-endian uint256
            mstore(ptr, projectTokenCount)
            // [32..64] = terminalTokenAmount as big-endian uint256
            mstore(add(ptr, 32), terminalTokenAmount)
            // [64..96] = beneficiary as bytes32
            mstore(add(ptr, 64), beneficiary)
        }
        return keccak256(data);
    }

    function test_leafHash_evmAddress() public view {
        address beneficiaryAddr = 0xdeAd000000000000000000000000000000001234;
        bytes32 beneficiary = bytes32(uint256(uint160(beneficiaryAddr)));
        uint256 projectTokens = 1000e18;
        uint256 terminalTokens = 500e6;

        bytes32 evmHash = sucker.exposed_buildTreeHash(projectTokens, terminalTokens, beneficiary);
        bytes32 svmHash = _svmBuildTreeHash(projectTokens, terminalTokens, beneficiary);
        assertEq(evmHash, svmHash, "EVM address leaf hash mismatch");
    }

    function test_leafHash_svmPubkey() public view {
        // Full 32-byte SVM pubkey (all bytes used, high bits set)
        bytes32 svmPubkey = 0xff01020304050607080910111213141516171819202122232425262728293031;
        uint256 projectTokens = 42e18;
        uint256 terminalTokens = 7e6;

        bytes32 evmHash = sucker.exposed_buildTreeHash(projectTokens, terminalTokens, svmPubkey);
        bytes32 svmHash = _svmBuildTreeHash(projectTokens, terminalTokens, svmPubkey);
        assertEq(evmHash, svmHash, "SVM pubkey leaf hash mismatch");
    }

    function test_leafHash_uint128Max() public view {
        uint256 maxU128 = type(uint128).max;
        bytes32 beneficiary = bytes32(uint256(1));

        bytes32 evmHash = sucker.exposed_buildTreeHash(maxU128, maxU128, beneficiary);
        bytes32 svmHash = _svmBuildTreeHash(maxU128, maxU128, beneficiary);
        assertEq(evmHash, svmHash, "u128 max leaf hash mismatch");
    }

    function test_leafHash_smallValues() public view {
        bytes32 beneficiary = bytes32(uint256(uint160(address(1))));

        bytes32 evmHash = sucker.exposed_buildTreeHash(1, 1, beneficiary);
        bytes32 svmHash = _svmBuildTreeHash(1, 1, beneficiary);
        assertEq(evmHash, svmHash, "Small value leaf hash mismatch");
    }

    function test_leafHash_zeroAmounts() public view {
        bytes32 beneficiary = bytes32(uint256(uint160(address(0xBEEF))));

        bytes32 evmHash = sucker.exposed_buildTreeHash(0, 0, beneficiary);
        bytes32 svmHash = _svmBuildTreeHash(0, 0, beneficiary);
        assertEq(evmHash, svmHash, "Zero amount leaf hash mismatch");
    }

    function testFuzz_leafHash_anyU128(uint128 projectTokens, uint128 terminalTokens, bytes32 beneficiary) public view {
        bytes32 evmHash = sucker.exposed_buildTreeHash(uint256(projectTokens), uint256(terminalTokens), beneficiary);
        bytes32 svmHash = _svmBuildTreeHash(uint256(projectTokens), uint256(terminalTokens), beneficiary);
        assertEq(evmHash, svmHash, "Fuzz leaf hash mismatch");
    }

    // =========================================================================
    // Section 2: Address Format Convention
    // =========================================================================

    function test_toBytes32_rightAligned() public view {
        address addr = 0x1234567890AbcdEF1234567890aBcdef12345678;
        bytes32 result = sucker.exposed_toBytes32(addr);

        // Upper 12 bytes should be zero
        for (uint256 i; i < 12; i++) {
            assertEq(uint8(result[i]), 0, "Upper byte not zero");
        }

        // Lower 20 bytes should be the address
        assertEq(address(uint160(uint256(result))), addr, "Lower 20 bytes mismatch");
    }

    function test_toAddress_extractsLower20() public view {
        address addr = 0xdeAd000000000000000000000000000000001234;
        bytes32 padded = bytes32(uint256(uint160(addr)));
        address result = sucker.exposed_toAddress(padded);
        assertEq(result, addr);
    }

    function test_roundTrip_addressToBytes32() public {
        address original = makeAddr("roundTrip");
        bytes32 asBytes32 = sucker.exposed_toBytes32(original);
        address recovered = sucker.exposed_toAddress(asBytes32);
        assertEq(recovered, original, "Round-trip failed");
    }

    function testFuzz_roundTrip(address addr) public view {
        bytes32 asBytes32 = sucker.exposed_toBytes32(addr);
        address recovered = sucker.exposed_toAddress(asBytes32);
        assertEq(recovered, addr, "Fuzz round-trip failed");
    }

    function test_toAddress_svmPubkeyTruncates() public view {
        // SVM pubkey with high bits set — _toAddress should truncate to lower 20 bytes
        bytes32 svmPubkey = 0xFF01020304050607080910111213141516171819202122232425262728293031;
        address result = sucker.exposed_toAddress(svmPubkey);
        // Lower 20 bytes: 0x13141516171819202122232425262728293031XX
        assertEq(result, address(uint160(uint256(svmPubkey))), "SVM pubkey truncation mismatch");
    }

    // =========================================================================
    // Section 3: Merkle Tree Cross-Chain Proof
    // =========================================================================

    /// @notice Build a merkle tree with a single leaf, extract the proof, and verify it.
    ///         This simulates: SVM inserts leaf → SVM builds proof → EVM verifies proof.
    function test_merkleProof_singleLeaf() public {
        address token = address(0xAAAA);
        uint256 projectTokens = 100e18;
        uint256 terminalTokens = 50e6;
        bytes32 beneficiary = bytes32(uint256(uint160(makeAddr("claimer"))));

        // Insert a single leaf (simulates SVM prepare)
        sucker.exposed_insertIntoTree(projectTokens, token, terminalTokens, beneficiary);

        // Get the resulting root
        bytes32 treeRoot = sucker.exposed_getOutboxRoot(token);
        assertEq(sucker.exposed_getOutboxCount(token), 1, "Count should be 1");

        // Build the proof for index 0 in a single-leaf tree.
        // For a tree with 1 leaf at index 0, the proof is all Z_HASHES (sibling at each level is the zero hash).
        bytes32[32] memory proof = _zeroProof();

        // Compute the expected leaf hash
        bytes32 leafHash = _svmBuildTreeHash(projectTokens, terminalTokens, beneficiary);

        // Verify using MerkleLib.branchRoot
        bytes32 computedRoot = MerkleLib.branchRoot(leafHash, proof, 0);
        assertEq(computedRoot, treeRoot, "Merkle proof verification failed for single leaf");

        // Also verify via the sucker's _validateBranchRoot (should not revert)
        sucker.exposed_setInboxRoot(token, 1, treeRoot);
        sucker.exposed_validateBranchRoot(treeRoot, projectTokens, terminalTokens, beneficiary, 0, proof);
    }

    /// @notice Build a tree with 4 leaves, verify proof for each leaf.
    ///         Uses a power-of-2 count to make proof construction straightforward.
    function test_merkleProof_multipleLeaves() public {
        address token = address(0xBBBB);

        // 4 leaves (power of 2 for clean tree structure)
        bytes32[4] memory leafHashes;
        uint256[4] memory projectTokens = [uint256(100e18), uint256(200e18), uint256(300e18), uint256(400e18)];
        uint256[4] memory terminalTokens = [uint256(50e6), uint256(100e6), uint256(150e6), uint256(200e6)];
        bytes32[4] memory beneficiaries = [
            bytes32(uint256(uint160(makeAddr("user1")))),
            bytes32(uint256(uint160(makeAddr("user2")))),
            bytes32(uint256(uint160(makeAddr("user3")))),
            bytes32(uint256(uint160(makeAddr("user4"))))
        ];

        for (uint256 i; i < 4; i++) {
            sucker.exposed_insertIntoTree(projectTokens[i], token, terminalTokens[i], beneficiaries[i]);
            leafHashes[i] = _svmBuildTreeHash(projectTokens[i], terminalTokens[i], beneficiaries[i]);
        }

        bytes32 treeRoot = sucker.exposed_getOutboxRoot(token);
        assertEq(sucker.exposed_getOutboxCount(token), 4, "Count should be 4");

        // Build proofs manually for a 4-leaf tree:
        // Level 0 pairs: (leaf0, leaf1), (leaf2, leaf3)
        // Level 1 pairs: (hash01, hash23)
        // Level 2+: (root, Z_i)
        bytes32 hash01 = keccak256(abi.encodePacked(leafHashes[0], leafHashes[1]));
        bytes32 hash23 = keccak256(abi.encodePacked(leafHashes[2], leafHashes[3]));

        // Verify leaf 0 (index=0, binary=...00)
        {
            bytes32[32] memory proof = _zeroProofFrom(2);
            proof[0] = leafHashes[1]; // sibling at level 0
            proof[1] = hash23; // sibling at level 1
            bytes32 computedRoot = MerkleLib.branchRoot(leafHashes[0], proof, 0);
            assertEq(computedRoot, treeRoot, "Proof failed for leaf 0");
        }

        // Verify leaf 1 (index=1, binary=...01)
        {
            bytes32[32] memory proof = _zeroProofFrom(2);
            proof[0] = leafHashes[0]; // sibling at level 0
            proof[1] = hash23; // sibling at level 1
            bytes32 computedRoot = MerkleLib.branchRoot(leafHashes[1], proof, 1);
            assertEq(computedRoot, treeRoot, "Proof failed for leaf 1");
        }

        // Verify leaf 2 (index=2, binary=...10)
        {
            bytes32[32] memory proof = _zeroProofFrom(2);
            proof[0] = leafHashes[3]; // sibling at level 0
            proof[1] = hash01; // sibling at level 1
            bytes32 computedRoot = MerkleLib.branchRoot(leafHashes[2], proof, 2);
            assertEq(computedRoot, treeRoot, "Proof failed for leaf 2");
        }

        // Verify leaf 3 (index=3, binary=...11)
        {
            bytes32[32] memory proof = _zeroProofFrom(2);
            proof[0] = leafHashes[2]; // sibling at level 0
            proof[1] = hash01; // sibling at level 1
            bytes32 computedRoot = MerkleLib.branchRoot(leafHashes[3], proof, 3);
            assertEq(computedRoot, treeRoot, "Proof failed for leaf 3");
        }
    }

    /// @notice SVM-style leaf hash inserted into EVM tree, proof verified via branchRoot.
    ///         This is the core cross-chain scenario: SVM prepares → EVM claims.
    function test_merkleProof_svmBeneficiaryCrossChain() public {
        address token = address(0xCCCC);
        bytes32 svmPubkey = 0xABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789;
        uint256 projectTokens = 500e18;
        uint256 terminalTokens = 250e6;

        // SVM inserts with full 32-byte pubkey beneficiary
        sucker.exposed_insertIntoTree(projectTokens, token, terminalTokens, svmPubkey);

        bytes32 treeRoot = sucker.exposed_getOutboxRoot(token);

        // Build proof and verify using SVM-style hash
        bytes32[32] memory proof = _zeroProof();
        bytes32 leafHash = _svmBuildTreeHash(projectTokens, terminalTokens, svmPubkey);
        bytes32 computedRoot = MerkleLib.branchRoot(leafHash, proof, 0);
        assertEq(computedRoot, treeRoot, "Cross-chain SVM beneficiary proof failed");
    }

    // =========================================================================
    // Section 4: MessageRoot Encoding
    // =========================================================================

    /// @notice Verify abi.encode(JBMessageRoot) layout matches SVM's expected field positions.
    /// @dev SVM MessageRoot: { version: u8, token: [u8;32], amount: u128, nonce: u64, root: [u8;32] }
    ///      EVM abi.encode packs each field into 32-byte slots (all static, no offset pointer):
    ///      Slot 0 (offset 32): version (uint8, right-aligned in 32 bytes)
    ///      Slot 1 (offset 64): token (bytes32)
    ///      Slot 2 (offset 96): amount (uint256)
    ///      Slot 3 (offset 128): remoteRoot.nonce (uint64, right-aligned in 32 bytes)
    ///      Slot 4 (offset 160): remoteRoot.root (bytes32)
    ///      Slot 5 (offset 192): sourceTotalSupply (uint256)
    ///      Slot 6 (offset 224): sourceCurrency (uint256)
    ///      Slot 7 (offset 256): sourceDecimals (uint8, right-aligned in 32 bytes)
    ///      Slot 8 (offset 288): sourceSurplus (uint256)
    ///      Slot 9 (offset 320): sourceBalance (uint256)
    function test_messageRoot_encoding() public pure {
        JBMessageRoot memory msg_ = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(0xAABBCCDD)),
            amount: 1000e18,
            remoteRoot: JBInboxTreeRoot({nonce: 42, root: bytes32(uint256(0x1234))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0
        });

        bytes memory encoded = abi.encode(msg_);

        // The struct is all-static (no dynamic arrays), so abi.encode produces a fixed-size tuple.
        // Offset 32 accounts for the Solidity memory bytes length prefix.
        // Slot 0 (offset 32): version
        uint8 decodedVersion;
        assembly {
            decodedVersion := mload(add(encoded, 32))
        }
        assertEq(decodedVersion, 1, "Version mismatch");

        // Slot 1 (offset 64): token
        bytes32 decodedToken;
        assembly {
            decodedToken := mload(add(encoded, 64))
        }
        assertEq(decodedToken, bytes32(uint256(0xAABBCCDD)), "Token mismatch");

        // Slot 2 (offset 96): amount
        uint256 decodedAmount;
        assembly {
            decodedAmount := mload(add(encoded, 96))
        }
        assertEq(decodedAmount, 1000e18, "Amount mismatch");

        // Slot 3 (offset 128): nonce (part of JBInboxTreeRoot)
        uint64 decodedNonce;
        assembly {
            decodedNonce := mload(add(encoded, 128))
        }
        assertEq(decodedNonce, 42, "Nonce mismatch");

        // Slot 4 (offset 160): root (part of JBInboxTreeRoot)
        bytes32 decodedRoot;
        assembly {
            decodedRoot := mload(add(encoded, 160))
        }
        assertEq(decodedRoot, bytes32(uint256(0x1234)), "Root mismatch");
    }

    function test_messageRoot_versionConstant() public view {
        assertEq(sucker.MESSAGE_VERSION(), 1, "MESSAGE_VERSION should be 1");
    }

    function test_messageRoot_amountFitsU128() public pure {
        // Verify that amounts up to uint128.max can be encoded
        JBMessageRoot memory msg_ = JBMessageRoot({
            version: 1,
            token: bytes32(0),
            amount: type(uint128).max,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(0)}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0
        });

        bytes memory encoded = abi.encode(msg_);
        // All-static tuple: slot 2 (amount) at offset 96 (32 length prefix + 2*32).
        uint256 decodedAmount;
        assembly {
            decodedAmount := mload(add(encoded, 96))
        }
        assertEq(decodedAmount, type(uint128).max, "u128 max amount encoding mismatch");
        // SVM reads this as u128 — the upper 128 bits must be zero
        assertTrue(decodedAmount <= type(uint128).max, "Amount exceeds u128");
    }

    // =========================================================================
    // Section 5: uint128 Boundary
    // =========================================================================

    function test_uint128_exactMax_works() public {
        address token = address(0xDDDD);
        uint256 maxU128 = type(uint128).max;
        bytes32 beneficiary = bytes32(uint256(1));

        // Should not revert
        sucker.exposed_insertIntoTree(maxU128, token, maxU128, beneficiary);
        assertEq(sucker.exposed_getOutboxCount(token), 1, "Insert at u128 max should succeed");
    }

    function test_uint128_overflow_projectTokens_reverts() public {
        address token = address(0xEEEE);
        uint256 overflow = uint256(type(uint128).max) + 1;
        bytes32 beneficiary = bytes32(uint256(1));

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_AmountExceedsUint128.selector, overflow));
        sucker.exposed_insertIntoTree(overflow, token, 100, beneficiary);
    }

    function test_uint128_overflow_terminalTokens_reverts() public {
        address token = address(0xFFFF);
        uint256 overflow = uint256(type(uint128).max) + 1;
        bytes32 beneficiary = bytes32(uint256(1));

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_AmountExceedsUint128.selector, overflow));
        sucker.exposed_insertIntoTree(100, token, overflow, beneficiary);
    }

    function testFuzz_uint128_validHashMatch(uint128 projectTokens, uint128 terminalTokens) public view {
        bytes32 beneficiary = bytes32(uint256(uint160(address(0xBEEF))));
        bytes32 evmHash = sucker.exposed_buildTreeHash(uint256(projectTokens), uint256(terminalTokens), beneficiary);
        bytes32 svmHash = _svmBuildTreeHash(uint256(projectTokens), uint256(terminalTokens), beneficiary);
        assertEq(evmHash, svmHash, "Fuzz u128 hash mismatch");
    }

    // =========================================================================
    // Section 6: Z_HASH Verification
    // =========================================================================

    function test_zHash_0() public pure {
        assertEq(MerkleLib.Z_0, bytes32(0), "Z_0 should be zero");
    }

    function test_zHash_1() public pure {
        bytes32 expected = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
        assertEq(MerkleLib.Z_1, expected, "Z_1 mismatch");
    }

    function test_zHash_2() public pure {
        bytes32 z1 = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
        bytes32 expected = keccak256(abi.encodePacked(z1, z1));
        assertEq(MerkleLib.Z_2, expected, "Z_2 mismatch");
    }

    function test_zHash_chain_to_5() public pure {
        bytes32 z = bytes32(0);
        for (uint256 i; i < 5; i++) {
            z = keccak256(abi.encodePacked(z, z));
        }
        assertEq(MerkleLib.Z_5, z, "Z_5 mismatch");
    }

    function test_zHash_32_emptyTreeRoot() public pure {
        // Z_32 is the root of a tree where all 2^32 leaves are zero.
        // Compute iteratively.
        bytes32 z = bytes32(0);
        for (uint256 i; i < 32; i++) {
            z = keccak256(abi.encodePacked(z, z));
        }
        assertEq(MerkleLib.Z_32, z, "Z_32 (empty tree root) mismatch");
    }

    function test_zHash_emptyTreeRootMatchesMerkleLib() public view {
        // An empty tree's root() should return Z_32.
        // We can test this by reading the root of a tree with 0 insertions.
        address token = address(0x9999);
        bytes32 root = sucker.exposed_getOutboxRoot(token);
        assertEq(root, MerkleLib.Z_32, "Empty tree root should be Z_32");
    }

    function test_zHashes_matchSVM() public pure {
        // Spot-check several Z_HASHES against the SVM constants (from lib.rs).
        // Z_1
        assertEq(
            MerkleLib.Z_1, hex"ad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5", "Z_1 SVM mismatch"
        );
        // Z_8
        assertEq(
            MerkleLib.Z_8, hex"9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af", "Z_8 SVM mismatch"
        );
        // Z_16
        assertEq(
            MerkleLib.Z_16, hex"2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f", "Z_16 SVM mismatch"
        );
        // Z_32
        assertEq(
            MerkleLib.Z_32, hex"27ae5ba08d7291c96c8cbddcc148bf48a6d68c7974b94356f53754ef6171d757", "Z_32 SVM mismatch"
        );
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Returns a proof of all zero hashes (valid for a single-leaf tree at index 0).
    function _zeroProof() internal pure returns (bytes32[32] memory proof) {
        proof[0] = MerkleLib.Z_0;
        proof[1] = MerkleLib.Z_1;
        proof[2] = MerkleLib.Z_2;
        proof[3] = MerkleLib.Z_3;
        proof[4] = MerkleLib.Z_4;
        proof[5] = MerkleLib.Z_5;
        proof[6] = MerkleLib.Z_6;
        proof[7] = MerkleLib.Z_7;
        proof[8] = MerkleLib.Z_8;
        proof[9] = MerkleLib.Z_9;
        proof[10] = MerkleLib.Z_10;
        proof[11] = MerkleLib.Z_11;
        proof[12] = MerkleLib.Z_12;
        proof[13] = MerkleLib.Z_13;
        proof[14] = MerkleLib.Z_14;
        proof[15] = MerkleLib.Z_15;
        proof[16] = MerkleLib.Z_16;
        proof[17] = MerkleLib.Z_17;
        proof[18] = MerkleLib.Z_18;
        proof[19] = MerkleLib.Z_19;
        proof[20] = MerkleLib.Z_20;
        proof[21] = MerkleLib.Z_21;
        proof[22] = MerkleLib.Z_22;
        proof[23] = MerkleLib.Z_23;
        proof[24] = MerkleLib.Z_24;
        proof[25] = MerkleLib.Z_25;
        proof[26] = MerkleLib.Z_26;
        proof[27] = MerkleLib.Z_27;
        proof[28] = MerkleLib.Z_28;
        proof[29] = MerkleLib.Z_29;
        proof[30] = MerkleLib.Z_30;
        proof[31] = MerkleLib.Z_31;
    }

    /// @dev Returns a proof where levels [0, startLevel) are bytes32(0) (to be filled by caller)
    ///      and levels [startLevel, 32) are the appropriate Z_HASHES.
    function _zeroProofFrom(uint256 startLevel) internal pure returns (bytes32[32] memory proof) {
        for (uint256 i = startLevel; i < 32; i++) {
            proof[i] = _zHashAt(i);
        }
    }

    /// @dev Returns Z_HASH at level i.
    function _zHashAt(uint256 i) internal pure returns (bytes32) {
        if (i == 0) return MerkleLib.Z_0;
        if (i == 1) return MerkleLib.Z_1;
        if (i == 2) return MerkleLib.Z_2;
        if (i == 3) return MerkleLib.Z_3;
        if (i == 4) return MerkleLib.Z_4;
        if (i == 5) return MerkleLib.Z_5;
        if (i == 6) return MerkleLib.Z_6;
        if (i == 7) return MerkleLib.Z_7;
        if (i == 8) return MerkleLib.Z_8;
        if (i == 9) return MerkleLib.Z_9;
        if (i == 10) return MerkleLib.Z_10;
        if (i == 11) return MerkleLib.Z_11;
        if (i == 12) return MerkleLib.Z_12;
        if (i == 13) return MerkleLib.Z_13;
        if (i == 14) return MerkleLib.Z_14;
        if (i == 15) return MerkleLib.Z_15;
        if (i == 16) return MerkleLib.Z_16;
        if (i == 17) return MerkleLib.Z_17;
        if (i == 18) return MerkleLib.Z_18;
        if (i == 19) return MerkleLib.Z_19;
        if (i == 20) return MerkleLib.Z_20;
        if (i == 21) return MerkleLib.Z_21;
        if (i == 22) return MerkleLib.Z_22;
        if (i == 23) return MerkleLib.Z_23;
        if (i == 24) return MerkleLib.Z_24;
        if (i == 25) return MerkleLib.Z_25;
        if (i == 26) return MerkleLib.Z_26;
        if (i == 27) return MerkleLib.Z_27;
        if (i == 28) return MerkleLib.Z_28;
        if (i == 29) return MerkleLib.Z_29;
        if (i == 30) return MerkleLib.Z_30;
        if (i == 31) return MerkleLib.Z_31;
        return MerkleLib.Z_32;
    }
}
