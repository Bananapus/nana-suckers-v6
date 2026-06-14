// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {PeerValueScratch} from "../../src/structs/PeerValueScratch.sol";

/// @notice Harness that exposes `_recordPeerValue` and `_peerValueScratch` for direct testing.
/// @dev Inheriting from JBSuckerRegistry brings the entire constructor surface — caller mocks the directory's
/// PROJECTS() call so construction succeeds.
contract _RecordPeerValueHarness is JBSuckerRegistry {
    constructor(IJBDirectory directory)
        JBSuckerRegistry(directory, IJBPermissions(address(0)), IJBPrices(address(0)), address(this), address(0))
    {}

    function exposed_peerValueScratch(uint256 len) external pure returns (PeerValueScratch memory) {
        return _peerValueScratch(len);
    }

    function exposed_recordSequence(
        uint256 len,
        uint256[] memory chainIds,
        uint256[] memory values,
        uint256[] memory snapshotTimestamps,
        bool[] memory isActives
    )
        external
        pure
        returns (PeerValueScratch memory)
    {
        PeerValueScratch memory scratch = _peerValueScratch(len);
        for (uint256 i; i < chainIds.length; ++i) {
            scratch.chainCount = _recordPeerValue({
                scratch: scratch,
                chainId: chainIds[i],
                value: values[i],
                snapshotTimestamp: snapshotTimestamps[i],
                isActive: isActives[i]
            });
        }
        return scratch;
    }
}

/// @notice Exhaustive coverage of `_recordPeerValue` aggregation semantics. Existing tests cover example cases
/// (active vs deprecated, same-chain dedup). This file probes the merge rules in isolation:
///   - Fresh (higher `snapshotTimestamp`) always wins.
///   - On equal `snapshotTimestamp`, the larger `value` wins (MAX tie-break).
///   - Active values replace deprecated even when the deprecated `snapshotTimestamp` is higher.
///   - Deprecated values only fill the gap until an active value is observed for a chain.
///   - Per-chain insertions never cross-contaminate other chains.
contract RecordPeerValueAggregationTest is Test {
    _RecordPeerValueHarness internal h;

    function setUp() public {
        // Mock directory.PROJECTS() so the registry constructor succeeds; we never call into it.
        IJBDirectory directory = IJBDirectory(makeAddr("directory"));
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.PROJECTS.selector),
            abi.encode(IJBProjects(makeAddr("projects")))
        );
        h = new _RecordPeerValueHarness(directory);
    }

    function _exec(
        uint256 len,
        uint256[] memory ids,
        uint256[] memory vals,
        uint256[] memory ts,
        bool[] memory act
    )
        internal
        view
        returns (PeerValueScratch memory)
    {
        return h.exposed_recordSequence(len, ids, vals, ts, act);
    }

    function _arr1(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _arr2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _arr3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _arr4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory r) {
        r = new uint256[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    function _b1(bool a) internal pure returns (bool[] memory r) {
        r = new bool[](1);
        r[0] = a;
    }

    function _b2(bool a, bool b) internal pure returns (bool[] memory r) {
        r = new bool[](2);
        r[0] = a;
        r[1] = b;
    }

    function _b3(bool a, bool b, bool c) internal pure returns (bool[] memory r) {
        r = new bool[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _b4(bool a, bool b, bool c, bool d) internal pure returns (bool[] memory r) {
        r = new bool[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    // -- Fresh wins --

    /// @notice Two active suckers on the same chain — the one with the higher `snapshotTimestamp` wins.
    function test_sameChain_twoActive_freshSnapshotWins() public view {
        PeerValueScratch memory s = _exec(
            2,
            _arr2(1, 1),
            _arr2(100, 1), // second sucker reports a much smaller value
            _arr2(10, 20), // but with a fresher snapshot
            _b2(true, true)
        );
        assertEq(s.chainCount, 1);
        assertEq(s.values[0], 1, "fresher snapshot wins regardless of value");
        assertEq(s.snapshotTimestamps[0], 20);
        assertTrue(s.hasActiveValue[0]);
    }

    /// @notice Same chain, same `snapshotTimestamp`, two active suckers — MAX value wins (tie-break).
    function test_sameChain_twoActive_equalSnapshot_maxValueWins() public view {
        PeerValueScratch memory s = _exec(2, _arr2(1, 1), _arr2(50, 100), _arr2(10, 10), _b2(true, true));
        assertEq(s.chainCount, 1);
        assertEq(s.values[0], 100, "equal snapshotTimestamp -> MAX value wins");
    }

    /// @notice Active replaces deprecated even when deprecated's snapshot is fresher.
    function test_activeReplacesDeprecated_evenWithStaleSnapshot() public view {
        PeerValueScratch memory s = _exec(
            2,
            _arr2(1, 1),
            _arr2(200, 50),
            _arr2(50, 10), // deprecated entry has the FRESHER snapshot
            _b2(false, true) // deprecated first, then active
        );
        assertEq(s.chainCount, 1);
        assertEq(s.values[0], 50, "active value replaces deprecated regardless of snapshot ordering");
        assertEq(s.snapshotTimestamps[0], 10);
        assertTrue(s.hasActiveValue[0]);
    }

    /// @notice Deprecated cannot replace an existing active value (the inverse direction).
    function test_deprecatedCannotReplaceActive() public view {
        PeerValueScratch memory s = _exec(
            2,
            _arr2(1, 1),
            _arr2(50, 200), // deprecated reports a higher value
            _arr2(10, 50), // and a fresher snapshot
            _b2(true, false) // but it's deprecated and active was first
        );
        assertEq(s.chainCount, 1);
        assertEq(s.values[0], 50, "deprecated cannot overwrite active");
        assertTrue(s.hasActiveValue[0]);
    }

    /// @notice Two deprecated values on the same chain — fresher wins via the deprecated-also-takes-MAX path.
    function test_sameChain_twoDeprecated_freshSnapshotWins() public view {
        PeerValueScratch memory s = _exec(2, _arr2(1, 1), _arr2(100, 1), _arr2(10, 20), _b2(false, false));
        assertEq(s.chainCount, 1);
        assertEq(s.values[0], 1);
        assertEq(s.snapshotTimestamps[0], 20);
        assertFalse(s.hasActiveValue[0]);
    }

    // -- Zero / tied snapshot edge cases --

    /// @notice `snapshotTimestamp = 0` is treated as the stalest possible value — any positive timestamp overrides.
    function test_zeroSnapshot_loses_toAnyPositive() public view {
        PeerValueScratch memory s = _exec(2, _arr2(1, 1), _arr2(100, 50), _arr2(0, 1), _b2(true, true));
        assertEq(s.values[0], 50, "snapshot 1 beats snapshot 0");
    }

    /// @notice Equal snapshot AND equal value: first writer's slot is kept (no replacement when neither >).
    function test_equalSnapshot_equalValue_firstWriterKept() public view {
        PeerValueScratch memory s = _exec(2, _arr2(1, 1), _arr2(100, 100), _arr2(10, 10), _b2(true, true));
        assertEq(s.values[0], 100);
        assertEq(s.snapshotTimestamps[0], 10);
    }

    // -- Cross-chain independence --

    /// @notice Per-chain merges never cross-contaminate other chains.
    function test_threeChains_independent_storage() public view {
        PeerValueScratch memory s =
            _exec(3, _arr3(7, 11, 7), _arr3(50, 100, 200), _arr3(5, 5, 10), _b3(true, true, true));
        // chain 7 gets two writes — the second (timestamp 10, value 200) wins.
        // chain 11 gets one write.
        assertEq(s.chainCount, 2, "two distinct chains observed");
        // Find chain 7's slot deterministically.
        uint256 slot7 = s.chainIds[0] == 7 ? 0 : 1;
        uint256 slot11 = 1 - slot7;
        assertEq(s.values[slot7], 200, "chain 7 takes the second write");
        assertEq(s.values[slot11], 100, "chain 11 is independent");
    }

    /// @notice A scratch sized for N suckers can hold up to N distinct chains, no more.
    function test_chainCountCannotExceedScratchLength() public view {
        PeerValueScratch memory s = _exec(2, _arr2(1, 2), _arr2(10, 20), _arr2(1, 1), _b2(true, true));
        assertEq(s.chainCount, 2);
        assertEq(s.chainIds.length, 2, "scratch sized for 2");
    }

    // -- Property fuzz: aggregated value equals the canonical max over active inputs per chain --

    /// @notice For any sequence of single-chain active writes, the aggregated value equals the value at the
    /// freshest snapshot, with MAX as tie-break.
    function testFuzz_sameChain_activeOnly_freshestWinsWithMaxTiebreak(
        uint256[16] memory vals,
        uint256[16] memory tss
    )
        public
        view
    {
        uint256 n = 16;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory vsArr = new uint256[](n);
        uint256[] memory tsArr = new uint256[](n);
        bool[] memory act = new bool[](n);
        uint256 expectedTs = 0;
        uint256 expectedVal = 0;
        for (uint256 i; i < n; ++i) {
            ids[i] = 42;
            vsArr[i] = vals[i];
            tsArr[i] = tss[i];
            act[i] = true;
            if (tss[i] > expectedTs || (tss[i] == expectedTs && vals[i] > expectedVal)) {
                expectedTs = tss[i];
                expectedVal = vals[i];
            }
        }
        PeerValueScratch memory s = _exec(n, ids, vsArr, tsArr, act);
        assertEq(s.chainCount, 1);
        assertEq(s.values[0], expectedVal);
        assertEq(s.snapshotTimestamps[0], expectedTs);
    }

    /// @notice For two peer chains with active and deprecated lanes, each chain selects the freshest active lane;
    ///         if no active lane exists, it falls back to the freshest deprecated lane.
    function testFuzz_twoChains_mixedActiveDeprecated_matchReferenceModel(
        uint256[4] memory vals,
        uint256[4] memory tss
    )
        public
        view
    {
        // Chain 1 has active and deprecated lanes. The active lane should win even if deprecated is fresher or larger,
        // as long as it is not an empty sentinel (value 0, timestamp 0) — a never-synced active record is skipped,
        // and
        // that case is covered by its own property test.
        vm.assume(!(vals[0] == 0 && tss[0] == 0));
        // Chain 2 has only deprecated lanes, so it should use the freshest deprecated snapshot with MAX as tie-break.
        PeerValueScratch memory s = _exec({
            len: 4,
            ids: _arr4(1, 1, 2, 2),
            vals: _arr4(vals[0], vals[1], vals[2], vals[3]),
            ts: _arr4(tss[0], tss[1], tss[2], tss[3]),
            act: _b4(true, false, false, false)
        });

        assertEq(s.chainCount, 2);

        uint256 slot1 = s.chainIds[0] == 1 ? 0 : 1;
        uint256 slot2 = 1 - slot1;

        // Chain 1: one active lane and one deprecated lane. The active lane owns the peer-chain value.
        assertEq(s.values[slot1], vals[0]);
        assertEq(s.snapshotTimestamps[slot1], tss[0]);
        assertTrue(s.hasActiveValue[slot1]);

        // Chain 2: no active lane. Deprecated lanes use the same freshness/MAX selection rule as migration fallback.
        uint256 expectedChain2Value = vals[3];
        uint256 expectedChain2Timestamp = tss[3];
        if (tss[2] > tss[3] || (tss[2] == tss[3] && vals[2] > vals[3])) {
            expectedChain2Value = vals[2];
            expectedChain2Timestamp = tss[2];
        }
        assertEq(s.values[slot2], expectedChain2Value);
        assertEq(s.snapshotTimestamps[slot2], expectedChain2Timestamp);
        assertFalse(s.hasActiveValue[slot2]);
    }
}
