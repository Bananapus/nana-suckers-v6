// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {JBPeerChainAdjustedAccountsLib} from "../../src/libraries/JBPeerChainAdjustedAccountsLib.sol";
import {JBSourceContext} from "../../src/structs/JBSourceContext.sol";

/// @title PeerChainDecodeProperties
/// @notice Formal verification of `JBPeerChainAdjustedAccountsLib.decode`, the fail-soft manual ABI decoder for
///         optional `IJBPeerChainAdjustedAccounts` return data.
/// @dev The existing `test/unit/peer_chain_adjusted_accounts_lib.t.sol` covers concrete malformed cases. This file
///      adds the two properties that only symbolic/fuzz coverage can establish:
///      (1) round-trip identity over the full value domain for well-formed input, and
///      (2) totality — the decoder never reverts and never over-allocates for ANY input bytes (its whole reason for
///      existing: a malformed optional hook must fail soft instead of reverting the cross-chain snapshot).
///      `decode` is pure with a fixed byte layout, so Halmos proves the fixed-shape round trips symbolically; the
///      arbitrary-bytes totality property is fuzz-only (symbolic-length `bytes` + a data-driven loop is intractable).
contract PeerChainDecodeProperties is Test {
    // =========================================================================
    // Property 1: round-trip identity for well-formed input (empty array)
    // =========================================================================
    /// @notice `decode(abi.encode(supply, []))` returns `(supply, [])` for any supply.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_decode_roundTripEmpty(uint256 supply) public pure {
        bytes memory data = abi.encode(supply, new JBSourceContext[](0));
        (uint256 gotSupply, JBSourceContext[] memory gotContexts) = JBPeerChainAdjustedAccountsLib.decode(data);

        assert(gotSupply == supply);
        assert(gotContexts.length == 0);
    }

    function testFuzz_decode_roundTripEmpty(uint256 supply) public pure {
        bytes memory data = abi.encode(supply, new JBSourceContext[](0));
        (uint256 gotSupply, JBSourceContext[] memory gotContexts) = JBPeerChainAdjustedAccountsLib.decode(data);

        assertEq(gotSupply, supply, "supply");
        assertEq(gotContexts.length, 0, "empty contexts");
    }

    // =========================================================================
    // Property 2: round-trip identity for well-formed input (single context, all fields symbolic)
    // =========================================================================
    /// @notice For any single context whose fields already fit the struct's wire types (uint8/uint128, guaranteed by
    ///         `abi.encode` of the typed struct), `decode(abi.encode(supply, [ctx]))` recovers `(supply, [ctx])`
    ///         exactly. This proves the manual assembly reads and the narrowing-guard casts agree with `abi.decode`
    ///         across the whole value domain, not just the one concrete vector the unit test checks.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_decode_roundTripSingle(
        uint256 supply,
        bytes32 token,
        uint8 decimals,
        uint128 surplus,
        uint128 balance
    )
        public
        pure
    {
        JBSourceContext[] memory ctxs = new JBSourceContext[](1);
        ctxs[0] = JBSourceContext({token: token, decimals: decimals, surplus: surplus, balance: balance});
        bytes memory data = abi.encode(supply, ctxs);

        (uint256 gotSupply, JBSourceContext[] memory got) = JBPeerChainAdjustedAccountsLib.decode(data);

        assert(gotSupply == supply);
        assert(got.length == 1);
        assert(got[0].token == token);
        assert(got[0].decimals == decimals);
        assert(got[0].surplus == surplus);
        assert(got[0].balance == balance);
    }

    function testFuzz_decode_roundTripMulti(uint256 supply, JBSourceContext[] memory ctxs) public pure {
        // Cap the length to keep the encoded buffer small (truncating avoids fuzzer assume-rejections).
        if (ctxs.length > 8) {
            assembly ("memory-safe") {
                mstore(ctxs, 8)
            }
        }
        bytes memory data = abi.encode(supply, ctxs);

        (uint256 gotSupply, JBSourceContext[] memory got) = JBPeerChainAdjustedAccountsLib.decode(data);

        assertEq(gotSupply, supply, "supply");
        assertEq(got.length, ctxs.length, "length");
        for (uint256 i; i < ctxs.length; i++) {
            assertEq(got[i].token, ctxs[i].token, "token");
            assertEq(got[i].decimals, ctxs[i].decimals, "decimals");
            assertEq(got[i].surplus, ctxs[i].surplus, "surplus");
            assertEq(got[i].balance, ctxs[i].balance, "balance");
        }
    }

    // =========================================================================
    // Property 3: totality — never reverts, never over-allocates, for ANY input bytes
    // =========================================================================
    /// @notice `decode` accepts untrusted return data from optional hooks; it must never revert or read out of
    ///         bounds regardless of the bytes. This fuzzes arbitrary buffers (the call itself failing = test
    ///         failure) and asserts the decoded array length can never exceed what the buffer can physically hold
    ///         (`length * 128 <= data.length`), catching any hostile-length over-allocation.
    function testFuzz_decode_totalityAndBound(bytes memory data) public pure {
        (uint256 supply, JBSourceContext[] memory contexts) = JBPeerChainAdjustedAccountsLib.decode(data);

        // Every decoded struct occupies 128 bytes inside the buffer, so the count is physically bounded by it.
        assertLe(contexts.length * 128, data.length, "decoded context count fits the buffer");

        // A non-empty result requires at least the 96-byte tuple head + one 128-byte struct.
        if (contexts.length > 0) {
            assertGe(data.length, 96 + 128, "non-empty result needs head + at least one struct");
        } else {
            // Silence unused-variable warning while keeping supply in the decode call graph.
            supply;
        }
    }

    // =========================================================================
    // Property 4: a truncated head (< 96 bytes) always yields the empty result
    // =========================================================================
    /// @notice Any buffer shorter than the 96-byte minimum tuple head decodes to `(0, [])` — the reads that would
    ///         otherwise point outside the buffer are never performed.
    function testFuzz_decode_shortHeadIsEmpty(bytes memory data) public pure {
        vm.assume(data.length < 96);
        (uint256 supply, JBSourceContext[] memory contexts) = JBPeerChainAdjustedAccountsLib.decode(data);

        assertEq(supply, 0, "supply zero on short head");
        assertEq(contexts.length, 0, "empty on short head");
    }
}
