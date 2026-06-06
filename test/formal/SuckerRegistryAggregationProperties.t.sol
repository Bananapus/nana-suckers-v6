// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";

import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {PeerValueScratch} from "../../src/structs/PeerValueScratch.sol";

/// @notice A directory stub answering only the registry constructor's `PROJECTS()` lookup.
contract AggDirectoryStub {
    function PROJECTS() external pure returns (address) {
        return address(0);
    }
}

/// @notice Exposes the registry's internal per-chain aggregation and per-context valuation for proof.
/// @dev The aggregation helpers are `pure`; the valuation helper stays on its same-currency / zero-amount short-circuit
/// so no price feed is consulted, matching the existing `HalmosValuationHarness` approach.
contract RegistryAggHarness is JBSuckerRegistry {
    constructor(IJBDirectory directory)
        JBSuckerRegistry(directory, IJBPermissions(address(0)), IJBPrices(address(0)), address(this), address(0))
    {}

    /// @notice Allocate scratch space sized to `len` peer chains.
    function scratch(uint256 len) external pure returns (PeerValueScratch memory) {
        return _peerValueScratch(len);
    }

    /// @notice Record one peer-chain value into scratch and return the resulting scratch + new chain count.
    function record(
        PeerValueScratch memory s,
        uint256 chainId,
        uint256 value,
        uint256 snapshotTimestamp,
        bool isActive
    )
        external
        pure
        returns (PeerValueScratch memory, uint256)
    {
        uint256 newCount = _recordPeerValue({
            scratch: s,
            chainId: chainId,
            value: value,
            snapshotTimestamp: snapshotTimestamp,
            isActive: isActive
        });
        s.chainCount = newCount;
        return (s, newCount);
    }

    /// @notice Expose the per-context valuation.
    function valued(
        uint256 amount,
        uint256 fromCurrency,
        uint256 fromDecimals,
        uint256 toCurrency,
        uint256 toDecimals,
        uint256 projectId
    )
        external
        view
        returns (uint256)
    {
        return _valued({
            amount: amount,
            fromCurrency: fromCurrency,
            fromDecimals: fromDecimals,
            toCurrency: toCurrency,
            toDecimals: toDecimals,
            projectId: projectId
        });
    }
}

/// @notice Functional-correctness proofs for the sucker registry's cross-chain aggregation and valuation semantics.
/// @dev The aggregation rules (`_recordPeerValue`) encode the spec from `JBSuckerRegistry.sol:544-581`:
///  - one entry per peer chain (dedupe);
///  - an ACTIVE sucker's value always supersedes a deprecated fallback;
///  - among same-state sources, the FRESHEST snapshot wins, with MAX(value) only as a same-freshness tie-break.
/// These are what keep multiple bridge-lane suckers on one chain from double-counting and what make a deprecated
/// sucker a strict migration fallback. Dual-implemented per the repo house convention.
contract SuckerRegistryAggregationProperties is Test {
    uint256 internal constant _MAX_DECIMALS = 18;

    RegistryAggHarness internal _reg;

    function setUp() public {
        _reg = new RegistryAggHarness(IJBDirectory(address(new AggDirectoryStub())));
    }

    // ------------------------------------------------------------------ //
    // Aggregation: dedupe — one chain recorded twice stays one entry      //
    // ------------------------------------------------------------------ //

    /// @notice [FUZZ] Recording the same non-zero chain twice never grows the chain count beyond one entry.
    function testFuzz_dedupeSameChain(
        uint256 chainId,
        uint256 v1,
        uint256 v2,
        uint256 t1,
        uint256 t2,
        bool a1,
        bool a2
    )
        public
        view
    {
        PeerValueScratch memory s = _reg.scratch(4);
        uint256 c;
        (s, c) = _reg.record(s, chainId, v1, t1, a1);
        assertEq(c, 1, "first record adds one chain");
        (s, c) = _reg.record(s, chainId, v2, t2, a2);
        assertEq(c, 1, "same chain must not add a second entry");
    }

    /// @notice [FUZZ] Two distinct chains produce two separate entries.
    function testFuzz_distinctChainsSeparate(
        uint256 chainA,
        uint256 chainB,
        uint256 v1,
        uint256 v2,
        uint256 t1,
        uint256 t2
    )
        public
        view
    {
        vm.assume(chainA != chainB);
        PeerValueScratch memory s = _reg.scratch(4);
        uint256 c;
        (s, c) = _reg.record(s, chainA, v1, t1, true);
        (s, c) = _reg.record(s, chainB, v2, t2, true);
        assertEq(c, 2, "distinct chains must be separate entries");
    }

    // ------------------------------------------------------------------ //
    // Aggregation: active supersedes deprecated regardless of freshness   //
    // ------------------------------------------------------------------ //

    /// @notice [FUZZ] An active value replaces a previously-recorded deprecated value even if the active is staler.
    function testFuzz_activeSupersedesDeprecated(
        uint256 chainId,
        uint256 depValue,
        uint256 depTs,
        uint256 actValue,
        uint256 actTs
    )
        public
        view
    {
        PeerValueScratch memory s = _reg.scratch(2);
        uint256 c;
        // First a deprecated reading.
        (s, c) = _reg.record(s, chainId, depValue, depTs, false);
        assertEq(s.values[0], depValue, "deprecated value seeded");
        assertEq(s.hasActiveValue[0], false, "seeded as deprecated");

        // Then an active reading — must win unconditionally.
        (s, c) = _reg.record(s, chainId, actValue, actTs, true);
        assertEq(s.values[0], actValue, "active must supersede deprecated value");
        assertEq(s.snapshotTimestamps[0], actTs, "active must supersede deprecated timestamp");
        assertEq(s.hasActiveValue[0], true, "entry must now be marked active");
    }

    /// @notice [FUZZ] Once an active value exists, a later deprecated reading is ignored.
    function testFuzz_deprecatedNeverOverridesActive(
        uint256 chainId,
        uint256 actValue,
        uint256 actTs,
        uint256 depValue,
        uint256 depTs
    )
        public
        view
    {
        PeerValueScratch memory s = _reg.scratch(2);
        uint256 c;
        (s, c) = _reg.record(s, chainId, actValue, actTs, true);
        (s, c) = _reg.record(s, chainId, depValue, depTs, false);
        assertEq(s.values[0], actValue, "deprecated must not override active value");
        assertEq(s.snapshotTimestamps[0], actTs, "deprecated must not override active timestamp");
        assertTrue(s.hasActiveValue[0], "entry stays active");
    }

    // ------------------------------------------------------------------ //
    // Aggregation: freshest active wins; MAX only as same-ts tie-break    //
    // ------------------------------------------------------------------ //

    /// @notice [FUZZ] Among two active readings, the strictly-fresher snapshot wins regardless of value.
    function testFuzz_fresherActiveWins(
        uint256 chainId,
        uint256 oldValue,
        uint256 newValue,
        uint256 oldTs,
        uint256 newTs
    )
        public
        view
    {
        vm.assume(newTs > oldTs);
        PeerValueScratch memory s = _reg.scratch(2);
        uint256 c;
        (s, c) = _reg.record(s, chainId, oldValue, oldTs, true);
        (s, c) = _reg.record(s, chainId, newValue, newTs, true);
        assertEq(s.values[0], newValue, "fresher active snapshot must win on value");
        assertEq(s.snapshotTimestamps[0], newTs, "fresher active snapshot must win on timestamp");
    }

    /// @notice [FUZZ] A staler active reading never displaces a fresher one.
    function testFuzz_stalerActiveLoses(
        uint256 chainId,
        uint256 freshValue,
        uint256 staleValue,
        uint256 freshTs,
        uint256 staleTs
    )
        public
        view
    {
        vm.assume(freshTs > staleTs);
        PeerValueScratch memory s = _reg.scratch(2);
        uint256 c;
        (s, c) = _reg.record(s, chainId, freshValue, freshTs, true);
        (s, c) = _reg.record(s, chainId, staleValue, staleTs, true);
        assertEq(s.values[0], freshValue, "staler active must not displace fresher value");
        assertEq(s.snapshotTimestamps[0], freshTs, "staler active must not displace fresher timestamp");
    }

    /// @notice [FUZZ] On equal freshness, the LARGER value wins (MAX tie-break).
    function testFuzz_sameFreshnessMaxWins(
        uint256 chainId,
        uint256 v1,
        uint256 v2,
        uint256 ts
    )
        public
        view
    {
        PeerValueScratch memory s = _reg.scratch(2);
        uint256 c;
        (s, c) = _reg.record(s, chainId, v1, ts, true);
        (s, c) = _reg.record(s, chainId, v2, ts, true);
        uint256 expected = v1 > v2 ? v1 : v2;
        assertEq(s.values[0], expected, "same-freshness tie-break must pick max value");
        assertEq(s.snapshotTimestamps[0], ts, "timestamp unchanged on tie");
    }

    // ------------------------------------------------------------------ //
    // Valuation: same-currency decimal scaling correctness                //
    // ------------------------------------------------------------------ //
    // The cross-currency path needs a price feed (out of pure/symbolic scope); these cover the same-currency path,
    // which the snapshot fold relies on for par accounting.

    /// @notice [HALMOS] Same-currency valuation equals the canonical fixed-point decimal adjustment.
    function check_valuedSameCurrencyMatchesAdjust(
        uint64 amount,
        uint8 fromDec,
        uint8 toDec,
        uint32 currency
    )
        public
        view
    {
        if (fromDec > _MAX_DECIMALS || toDec > _MAX_DECIMALS) return;
        uint256 got = _reg.valued({
            amount: uint256(amount),
            fromCurrency: currency,
            fromDecimals: fromDec,
            toCurrency: currency,
            toDecimals: toDec,
            projectId: 1
        });
        uint256 expected =
            JBFixedPointNumber.adjustDecimals({value: uint256(amount), decimals: fromDec, targetDecimals: toDec});
        assert(got == expected);
    }

    /// @notice [FUZZ] Same-currency valuation equals the canonical fixed-point decimal adjustment.
    function testFuzz_valuedSameCurrencyMatchesAdjust(
        uint128 amount,
        uint8 fromDec,
        uint8 toDec,
        uint32 currency
    )
        public
        view
    {
        fromDec = uint8(bound(fromDec, 0, _MAX_DECIMALS));
        toDec = uint8(bound(toDec, 0, _MAX_DECIMALS));
        uint256 got = _reg.valued({
            amount: uint256(amount),
            fromCurrency: currency,
            fromDecimals: fromDec,
            toCurrency: currency,
            toDecimals: toDec,
            projectId: 1
        });
        uint256 expected =
            JBFixedPointNumber.adjustDecimals({value: uint256(amount), decimals: fromDec, targetDecimals: toDec});
        assertEq(got, expected, "same-currency valuation must equal decimal adjust");
    }

    /// @notice [FUZZ] Scaling a value UP in decimals then back DOWN to the original is lossless (no precision loss
    /// when only increasing then decreasing the same delta). Guards the par-fold accounting against silent dust.
    function testFuzz_decimalRoundTripUpThenDownLossless(uint96 amount, uint8 lowDec, uint8 hiDec) public view {
        lowDec = uint8(bound(lowDec, 0, _MAX_DECIMALS));
        hiDec = uint8(bound(hiDec, lowDec, _MAX_DECIMALS));

        uint256 up = _reg.valued(uint256(amount), 1, lowDec, 1, hiDec, 1);
        uint256 back = _reg.valued(up, 1, hiDec, 1, lowDec, 1);
        assertEq(back, uint256(amount), "scale up then back down must be lossless");
    }

    /// @notice [HALMOS] Zero amount values to zero for any same-currency decimal pair.
    function check_valuedZeroIsZero(uint8 fromDec, uint8 toDec, uint32 currency) public view {
        if (fromDec > _MAX_DECIMALS || toDec > _MAX_DECIMALS) return;
        uint256 got = _reg.valued(0, currency, fromDec, currency, toDec, 1);
        assert(got == 0);
    }
}
