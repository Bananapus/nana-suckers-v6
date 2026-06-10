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
        // `data` is a Solidity `bytes` value. In memory, its first word is the byte length, and the hook's ABI return
        // payload begins one word later at `data + 32`.
        //
        // The payload for `(uint256, JBSourceContext[])` is:
        //   word 0: supply
        //   word 1: offset to the dynamic `contexts` array tail, relative to the payload start
        //   tail word 0: contexts.length
        //   tail words: each `JBSourceContext`, encoded as 4 ABI words.
        //
        // A valid return needs at least the two-word tuple head plus the array-length word. Anything shorter would
        // make the reads below point outside the returned buffer, so the optional contribution is ignored.
        if (data.length < 96) return (0, new JBSourceContext[](0));

        // The tuple head is fixed-width, so read it directly instead of `abi.decode`:
        // - `supply` is word 0 of the ABI payload.
        // - `contextsOffset` is word 1 and points to the dynamic-array tail.
        // Manual reads let malformed optional hooks fail soft instead of reverting the whole snapshot.
        uint256 contextsOffset;
        assembly ("memory-safe") {
            // Skip the `bytes` length word and read payload word 0.
            supply := mload(add(data, 32))
            // Read payload word 1. The value is payload-relative, not memory-object-relative.
            contextsOffset := mload(add(data, 64))
        }

        // The dynamic array tail must start after the two-word tuple head (`>= 64`), be ABI-word aligned, and leave
        // room for its own length word. If any of these fail, `abi.decode` would revert; this helper treats the
        // optional hook as absent.
        if (contextsOffset < 64 || contextsOffset % 32 != 0 || contextsOffset > data.length - 32) {
            return (0, new JBSourceContext[](0));
        }

        // `contextsOffset` was proven to leave room for the array length word, so this read is in-bounds. Add `32` to
        // `data` first because offsets are relative to the payload start, not the `bytes` length word.
        uint256 contextCount;
        assembly ("memory-safe") {
            contextCount := mload(add(add(data, 32), contextsOffset))
        }

        // Skip the array-length word to reach the first encoded `JBSourceContext`.
        uint256 contextsStart = contextsOffset + 32;
        // Each `JBSourceContext` is four ABI words: token, decimals, surplus, balance. This bounds check prevents both
        // oversized allocation from a hostile length word and out-of-bounds reads in the loop.
        if (contextCount > (data.length - contextsStart) / 128) return (0, new JBSourceContext[](0));

        // Only allocate after proving the claimed array length fits inside the returned bytes.
        contexts = new JBSourceContext[](contextCount);

        for (uint256 i; i < contextCount; i++) {
            // Move to the encoded struct for this index. The multiplication is safe because `contextCount` already
            // proved every 128-byte struct fits in the buffer.
            uint256 contextOffset = contextsStart + i * 128;
            // Read narrowed fields as full words first. The ABI decoder would reject out-of-range values for
            // `uint8`/`uint128`, so the manual decoder must check those ranges before casting.
            bytes32 token;
            uint256 decimals;
            uint256 surplus;
            uint256 contextBalance;

            assembly ("memory-safe") {
                // Point at the first word of the encoded `JBSourceContext`.
                let contextPointer := add(add(data, 32), contextOffset)
                // Struct word 0: source-local token, padded to bytes32.
                token := mload(contextPointer)
                // Struct word 1: decimal precision, encoded as a full ABI word.
                decimals := mload(add(contextPointer, 32))
                // Struct word 2: raw surplus in the context's own decimals.
                surplus := mload(add(contextPointer, 64))
                // Struct word 3: raw recorded balance in the context's own decimals.
                contextBalance := mload(add(contextPointer, 96))
            }

            // Mirror ABI decoder type checks before narrowing. Returning `(0, [])` avoids silently truncating a
            // malformed hook's values into smaller wire types.
            if (decimals > type(uint8).max || surplus > type(uint128).max || contextBalance > type(uint128).max) {
                return (0, new JBSourceContext[](0));
            }

            // Casting is safe because the guard above rejected larger values, but forge lint cannot infer that.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 checkedDecimals = uint8(decimals);
            // Casting is safe for the same reason as `checkedDecimals`.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128 checkedSurplus = uint128(surplus);
            // Casting is safe for the same reason as `checkedDecimals`.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128 checkedBalance = uint128(contextBalance);

            // Store the checked values using the struct's actual wire types. At this point every memory read was
            // inside the buffer and every narrowed cast has been proven safe.
            contexts[i] = JBSourceContext({
                token: token, decimals: checkedDecimals, surplus: checkedSurplus, balance: checkedBalance
            });
        }
    }
}
