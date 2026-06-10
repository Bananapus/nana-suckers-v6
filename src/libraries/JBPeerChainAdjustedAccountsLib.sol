// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBSourceContext} from "../structs/JBSourceContext.sol";

/// @notice Helpers for reading optional `IJBPeerChainAdjustedAccounts` return data.
library JBPeerChainAdjustedAccountsLib {
    /// @notice Decodes peer-chain adjusted accounting return data, falling back to no contribution if malformed.
    /// @param data The raw return data from a `peerChainAdjustedAccountsOf` call.
    /// @return supply The extra supply to include in `sourceTotalSupply`.
    /// @return contexts The extra per-context surplus and balance to include in the snapshot, un-valued.
    function decode(bytes memory data) internal pure returns (uint256 supply, JBSourceContext[] memory contexts) {
        // The payload for `(uint256, JBSourceContext[])` is:
        //   word 0: supply
        //   word 1: offset to the dynamic `contexts` array tail, relative to the payload start
        //   tail word 0: contexts.length
        //   tail words: each `JBSourceContext`, encoded as 4 ABI words.
        if (data.length < 96) return (0, new JBSourceContext[](0));

        uint256 contextsOffset;
        assembly ("memory-safe") {
            supply := mload(add(data, 32))
            contextsOffset := mload(add(data, 64))
        }

        if (contextsOffset < 64 || contextsOffset % 32 != 0 || contextsOffset > data.length - 32) {
            return (0, new JBSourceContext[](0));
        }

        uint256 contextCount;
        assembly ("memory-safe") {
            contextCount := mload(add(add(data, 32), contextsOffset))
        }

        uint256 contextsStart = contextsOffset + 32;
        if (contextCount > (data.length - contextsStart) / 128) return (0, new JBSourceContext[](0));

        contexts = new JBSourceContext[](contextCount);

        for (uint256 i; i < contextCount; i++) {
            uint256 contextOffset = contextsStart + i * 128;
            bytes32 token;
            uint256 decimals;
            uint256 surplus;
            uint256 contextBalance;

            assembly ("memory-safe") {
                let contextPointer := add(add(data, 32), contextOffset)
                token := mload(contextPointer)
                decimals := mload(add(contextPointer, 32))
                surplus := mload(add(contextPointer, 64))
                contextBalance := mload(add(contextPointer, 96))
            }

            if (decimals > type(uint8).max || surplus > type(uint128).max || contextBalance > type(uint128).max) {
                return (0, new JBSourceContext[](0));
            }

            // Casting is safe because the guard above rejected larger values.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 checkedDecimals = uint8(decimals);
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128 checkedSurplus = uint128(surplus);
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128 checkedBalance = uint128(contextBalance);

            contexts[i] = JBSourceContext({
                token: token, decimals: checkedDecimals, surplus: checkedSurplus, balance: checkedBalance
            });
        }
    }
}
