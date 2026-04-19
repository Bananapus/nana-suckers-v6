// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";

import {IJBSuckerRegistry} from "../interfaces/IJBSuckerRegistry.sol";

/// @notice Library to resolve the relay beneficiary from metadata injected by a relay terminal or sucker.
/// @dev When a sucker pays a project on behalf of a remote user, the sucker is both payer and beneficiary.
/// The real user's address is embedded in the payment metadata under the `ID` key. Data hooks and pay hooks
/// use this library to resolve the real beneficiary so that NFTs, credits, etc. accrue to the correct user.
library JBRelayBeneficiary {
    /// @notice The metadata ID used to identify the relay beneficiary entry.
    /// @dev Global constant (not per-contract) because the metadata is injected by the sucker but read by
    /// unrelated hooks. Using `keccak256("JB_RELAY_BENEFICIARY")` ensures no collisions with contract-specific IDs.
    bytes4 constant ID = bytes4(keccak256("JB_RELAY_BENEFICIARY"));

    /// @notice Resolve the effective beneficiary for a payment.
    /// @dev Returns `beneficiary` unchanged if the payer is not a registered sucker or if no relay data is found.
    /// @param payer The address that called `terminal.pay()` (i.e. `context.payer`).
    /// @param beneficiary The beneficiary set in the payment context (i.e. `context.beneficiary`).
    /// @param projectId The project being paid.
    /// @param metadata The payment metadata (`context.payerMetadata` or `context.metadata`).
    /// @param registry The sucker registry used to verify that `payer` is a legitimate sucker.
    /// @return effectiveBeneficiary The resolved beneficiary — the relay address if valid, or the original.
    function resolve(
        address payer,
        address beneficiary,
        uint256 projectId,
        bytes memory metadata,
        IJBSuckerRegistry registry
    )
        internal
        view
        returns (address effectiveBeneficiary)
    {
        // Only trust relay metadata when the payer is a registered sucker for this project.
        if (!registry.isSuckerOf(projectId, payer)) {
            return beneficiary;
        }

        // Try to find relay beneficiary data in the metadata.
        (bool found, bytes memory data) = JBMetadataResolver.getDataFor({id: ID, metadata: metadata});
        if (!found || data.length < 32) {
            return beneficiary;
        }

        // Decode the relay beneficiary address.
        address relayBeneficiary = abi.decode(data, (address));
        if (relayBeneficiary == address(0)) {
            return beneficiary;
        }

        return relayBeneficiary;
    }
}
