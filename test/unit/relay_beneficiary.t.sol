// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {JBRelayBeneficiary} from "../../src/libraries/JBRelayBeneficiary.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";

/// @notice Thin wrapper that exposes the internal library function for testing.
contract RelayBeneficiaryHarness {
    function resolve(
        address payer,
        address beneficiary,
        uint256 projectId,
        bytes memory metadata,
        IJBSuckerRegistry registry
    )
        external
        view
        returns (address)
    {
        return JBRelayBeneficiary.resolve(payer, beneficiary, projectId, metadata, registry);
    }
}

contract RelayBeneficiaryTest is Test {
    RelayBeneficiaryHarness harness;
    IJBSuckerRegistry registry;

    address payer = address(0xAAA);
    address beneficiary = address(0xBBB);
    address relayAddress = address(0xCCC);
    uint256 projectId = 1;

    function setUp() public {
        harness = new RelayBeneficiaryHarness();
        registry = IJBSuckerRegistry(makeAddr("registry"));
    }

    /// @notice Helper: mock isSuckerOf to return the given value.
    function _mockIsSucker(bool isSucker) internal {
        vm.mockCall(
            address(registry),
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (projectId, payer)),
            abi.encode(isSucker)
        );
    }

    /// @notice Helper: build metadata containing the relay beneficiary address.
    function _buildMetadata(address relay) internal pure returns (bytes memory) {
        return JBMetadataResolver.addToMetadata(bytes(""), JBRelayBeneficiary.ID, abi.encode(relay));
    }

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------

    function test_resolve_returnsOriginalIfNotSucker() public {
        _mockIsSucker(false);

        bytes memory metadata = _buildMetadata(relayAddress);

        address result = harness.resolve(payer, beneficiary, projectId, metadata, registry);
        assertEq(result, beneficiary, "Should return original beneficiary when payer is not a sucker");
    }

    function test_resolve_returnsOriginalIfNoMetadata() public {
        _mockIsSucker(true);

        address result = harness.resolve(payer, beneficiary, projectId, bytes(""), registry);
        assertEq(result, beneficiary, "Should return original beneficiary when metadata is empty");
    }

    function test_resolve_returnsOriginalIfMetadataNotFound() public {
        _mockIsSucker(true);

        // Build metadata with a different ID so the relay key is absent.
        bytes4 otherId = bytes4(keccak256("SOME_OTHER_KEY"));
        bytes memory metadata = JBMetadataResolver.addToMetadata(bytes(""), otherId, abi.encode(relayAddress));

        address result = harness.resolve(payer, beneficiary, projectId, metadata, registry);
        assertEq(result, beneficiary, "Should return original beneficiary when relay key is not in metadata");
    }

    function test_resolve_returnsOriginalIfRelayBeneficiaryZero() public {
        _mockIsSucker(true);

        bytes memory metadata = _buildMetadata(address(0));

        address result = harness.resolve(payer, beneficiary, projectId, metadata, registry);
        assertEq(result, beneficiary, "Should return original beneficiary when relay address is zero");
    }

    function test_resolve_returnsRelayBeneficiary() public {
        _mockIsSucker(true);

        bytes memory metadata = _buildMetadata(relayAddress);

        address result = harness.resolve(payer, beneficiary, projectId, metadata, registry);
        assertEq(result, relayAddress, "Should return relay beneficiary from metadata");
    }

    function test_resolve_returnsOriginalIfDataTooShort() public {
        _mockIsSucker(true);

        // Manually craft metadata where the relay key exists but the data segment is shorter than 32 bytes.
        //
        // JBMetadataResolver format:
        //   [0..31]  : 32-byte reserved header
        //   [32..36] : bytes4 id + uint8 offset (lookup table entry)
        //   [37]     : 0x00 terminator (no more entries)
        //   [offset*32 ..] : data
        //
        // We place the ID at byte 32, with offset = 2 (data starts at byte 64).
        // Then we only write 16 bytes of data instead of 32, making data.length < 32.
        bytes memory metadata = new bytes(64 + 16); // 80 bytes total

        // Write the relay ID at position 32 (first lookup entry).
        bytes4 id = JBRelayBeneficiary.ID;
        metadata[32] = id[0];
        metadata[33] = id[1];
        metadata[34] = id[2];
        metadata[35] = id[3];
        // Offset = 2 means data starts at byte 64.
        metadata[36] = bytes1(uint8(2));
        // Terminator at position 37 (next entry ID byte is 0).

        // Write 16 bytes of non-zero data starting at byte 64 (less than 32 bytes).
        for (uint256 i = 64; i < 80; i++) {
            metadata[i] = bytes1(uint8(0xFF));
        }

        address result = harness.resolve(payer, beneficiary, projectId, metadata, registry);
        assertEq(result, beneficiary, "Should return original beneficiary when relay data is too short");
    }
}
