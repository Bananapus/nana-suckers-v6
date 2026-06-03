# Changelog

## Scope

This file describes the verified change from `nana-suckers-v5` to the current `nana-suckers-v6` repo.

## Current v6 surface

- `JBSucker`
- `JBSuckerRegistry`
- `JBOptimismSucker`
- `JBArbitrumSucker`
- `JBBaseSucker`
- `JBCCIPSucker`
- the deployers, structs, and interfaces under `src/`

Archived (reference only — not compiled or deployed): `JBSwapCCIPSucker` (+ its swap libs/structs `JBSwapPoolLib`, `JBSwapLib`, `JBPendingSwap`, `JBConversionRate`) and `JBCeloSucker`, along with their deployers and interfaces; see `src/archive/`.

## 0.0.70 — Fix: key the peer-context merge on currency AND decimals

`fromRemote` previously merged same-currency peer contexts by **currency only**, summing their raw,
un-valued amounts even when the contexts carried **different decimals** (e.g. a 6-decimal and an 18-decimal
representation of the same currency such as USD). The merged bucket kept one decimals value while adding
amounts expressed in another precision, so the cross-chain surplus aggregate was corrupted whenever a
project — or an `IJBPeerChainAdjustedAccounts` hook — emitted same-currency contexts at different decimals.

The merge now keys on **both currency and decimals**: same-currency contexts that differ in decimals are
kept as separate per-`(currency, decimals)` entries, and `JBSuckerRegistry` decimals-adjusts each
independently before summing at read time (`remoteSurplusOf`/`_valued`). Same-asset contexts (the same token
across terminals → same currency and decimals) still merge as before. No storage-layout change.

## 0.0.69 — Value cross-chain surplus in the registry; suckers carry raw per-context snapshots

Reworks how a project's cross-chain surplus and balance are reported. Previously a sucker collapsed its
whole multi-token surplus to one ETH-denominated value on the source side and the destination converted it
through a price feed whose missing-feed `try/catch` swallowed to zero on the numerator only — an asymmetric
collapse that under-priced cash-outs.

Now the **suckers are raw, oracle-free data carriers**. `fromRemote` rebuilds an enumerable per-currency
context set; each remote context resolves to its local token, whose authoritative accounting-context
currency is read once from the terminal (a project may set this to a well-known id like USD) and cached
(immutable). Same-currency contexts within a snapshot sum; a fresher snapshot rebuilds the whole set. The
sucker exposes one raw view, `peerChainContextsOf() -> (JBPeerChainContext[] contexts, uint256 chainId,
uint256 snapshot)`; the `PRICES` reference and the four valued views are removed from the sucker.

**`JBSuckerRegistry` now holds `IJBPrices PRICES` and does the valuation**, exactly as `JBTerminalStore`
values local surplus: per-sucker `remoteBalanceOf`/`remoteSurplusOf(sucker, projectId, currency, decimals)`,
aggregates `totalRemoteBalanceOf`/`totalRemoteSurplusOf(projectId, currency, decimals)` (dedup same-peer
suckers by freshest snapshot, then sum), and the unchanged `remoteTotalSupplyOf(projectId)`. A context whose
currency already matches the requested currency is taken at par with no feed (same-asset revnets never
consult a feed); a missing cross-currency feed reverts and is swallowed per-sucker (conservative). The
authoritative-currency terminal read uses a low-level staticcall guarded by a returndata-length check so a
non-conforming terminal can't block a bridge message. The now-unused `JBDenominatedAmount` struct is removed.

## 0.0.68 — Raise dependency floors and document conventions

Raise dependency floors to the latest published versions, and document NatSpec, comment, and lint conventions in
STYLE_GUIDE.md. No source contracts changed.

## 0.0.67 — Fold per-sucker remote-aggregate reads into one call

`JBSuckerRegistry`'s cross-chain aggregate views (`remoteBalanceOf`, `remoteSurplusOf`,
`remoteTotalSupplyOf`) previously made **three** separate `staticcall`s into each of a project's suckers
per iteration: one for the value, one for the immutable peer chain ID, and one for the snapshot freshness
key. Each sucker now exposes a combined view (`peerChainBalanceValueOf`, `peerChainSurplusValueOf`,
`peerChainTotalSupplyValue`) that returns the value bundled with the peer chain ID and snapshot freshness
key in a single `JBPeerChainValue` struct, and the registry reads each sucker **once**. The aggregated
results are unchanged — same per-chain dedup, same active-over-deprecated preference, same
freshness/MAX tie-break, and the same revert when a sucker reports a zero peer chain ID.

`JBSucker.peerChainId()` is now `public` (was `external`) so the combined views can read it internally
without a self-call; its external ABI is unchanged. `JBSuckerRegistry`'s runtime size shrank slightly;
each sucker variant grew by ~0.5 KB for the three added views and stays well under the EIP-170 limit.

A new regression suite (`RegistryAggregateReadEquivalence.t.sol`) pins the aggregate return values
across distinct-chain, same-chain-dedup, deprecated-fallback, active-override, zero-peer-chain, and
empty cases, proving the single-call path is behavior-preserving.

## 0.0.65 — Archive `JBCeloSucker` subsystem

The `JBCeloSucker` subsystem (`JBCeloSucker`, `JBCeloSuckerDeployer`, `IJBCeloSuckerDeployer`, plus
`test/ForkCelo.t.sol`) is unused and has been moved to `src/archive/` and `test/archive/`. It is
excluded from compilation via the `foundry.toml` skip glob and is not deployed by `deploy-all`. The
code is retained for reference only.

## 0.0.64 — Archive `JBSwapCCIPSucker` swap subsystem + claim resilience

**Archived (reference only)**

The `JBSwapCCIPSucker` swap subsystem (`JBSwapCCIPSucker`, `JBSwapCCIPSuckerDeployer`,
`IJBSwapCCIPSuckerDeployer`, the swap libraries `JBSwapPoolLib` / `JBSwapLib`, and the swap structs
`JBPendingSwap` / `JBConversionRate`, plus its swap test suite) is unused and has been moved to
`src/archive/` and `test/archive/`. It is excluded from compilation via the `foundry.toml` skip glob
and is not deployed by `deploy-all`. Retiring it from the build also freed the EIP-170 headroom that
the live sucker variants had been competing for.

**Per-leaf batch-claim resilience**

`claim(JBClaim[])` now wraps each leaf in a `try`/`catch`: a single bad leaf no longer reverts the
whole batch. Failed leaves emit `ClaimFailed` and are skipped, so the remaining valid claims still
settle.

**Inbox-root ring**

`fromRemote` now retains the last 4 inbox roots in a ring buffer instead of only the latest. `_validate`
accepts a proof against any retained root, which tolerates out-of-order / racing root deliveries.
Double-spend is still guarded by the index-keyed `_executedFor` bitmap, so accepting an older retained
root cannot replay an already-executed leaf.

## Unreleased — `executedLeafHashOf` + `allSuckersOf` for hook hardening

Two surgical additions to support `JBReferralSplitHook`'s hardening pass against the front-run and
deprecated-sucker findings in `AUDIT_REPORT_4`. Both extend the read surface without changing any
existing behavior on the write side.

**What changed**

- `JBSucker`: new public `mapping(address token => mapping(uint256 index => bytes32)) executedLeafHashOf`.
  Written inside `_validate` immediately after the executed bitmap bit set. Stores
  `_buildTreeHash(projectTokenCount, terminalTokenAmount, beneficiary, metadata)` so a beneficiary
  contract can authenticate post-hoc settlement when its own `sucker.claim` call was front-run by a
  direct external caller. The bare `_executedFor` bitmap proves "some leaf at index I was executed"
  but not "which leaf"; the hash binds the index to the actual leaf content. Pre-image-resistant, so
  a zero return unambiguously means "not executed".
- `JBSuckerRegistry`: new `allSuckersOf(uint256 projectId) external view returns (address[])` —
  returns every key in `_suckersOf[projectId]`, including deprecated entries. `suckersOf` filters
  out deprecated; `isSuckerOf` is single-address. Neither was sufficient for consumers that need
  "has any sucker ever peered to chain X?" — e.g. `JBReferralSplitHook.burnUnbridgeableCreditFor`
  needs this check to refuse to permaburn credit that's still bridgeable via a deprecated sucker.

**Risk surface**

Zero new trust paths and zero new write paths. The existing `claim` / `_validate` flow now writes
one additional storage slot per execution (~20k gas first time). Beneficiary contracts that don't
care about front-run defense ignore the new field; their behavior is byte-identical to before.

**Bytecode side-effects (incidental cleanup)**

The hash storage write tipped `JBSwapCCIPSucker` (the largest sucker variant) over EIP-170. Two
small refactors made room:

1. `_addToBalance` collapsed the duplicated `terminal.addToBalanceOf(...)` ERC-20 / native-token
   branches into a single call with `{value: nativeValue}` conditionally non-zero. Pre-call
   approve + post-call balance assertion stay ERC-20-only. Saves ~119 bytes propagated through
   every sucker variant via inheritance.
2. `_validate` precomputes the leaf hash once and passes it to `_validateBranchRoot`, removing a
   duplicate `_buildTreeHash` call. Saves a small amount per claim path.
3. `JBPendingSwap` and `JBConversionRate` extracted from `JBSwapCCIPSucker` to dedicated files in
   `src/structs/` (bytecode-neutral, code-organization only).

After these changes, `JBSwapCCIPSucker` has ~70 bytes of EIP-170 headroom (was ~22 bytes pre-PR).

**Test coverage**

- `test/SuckerRegressions.t.sol::test_executedLeafHashOf_isPopulatedOnClaim` — verifies the slot is
  zero before claim and equals `keccak256(abi.encodePacked(projectTokenCount, terminalTokenAmount,
  beneficiary, metadata))` after claim. Neighboring indices stay zero.
- `test/regression/DeprecatedRemovalUndercount.t.sol::test_allSuckersOf_includesDeprecatedAfterRemoval`
  — verifies `suckersOf` filters out removed-deprecated entries while `allSuckersOf` still reports
  them, so downstream "is this chain bridgeable?" checks don't return a false negative.

## Unreleased — `JBLeaf.metadata` attribution field

The merkle leaf now carries a fifth field: a `bytes32 metadata` payload that travels inside the leaf hash but is
opaque to the sucker protocol itself.

**What changed**

- `JBLeaf` struct: new trailing `bytes32 metadata` field.
- `IJBSucker.prepare`: new trailing `bytes32 metadata` parameter. The metadata is included in the leaf hash, so it's
  covered by the merkle root — receivers can trust it once the claim's merkle proof verifies.
- `_buildTreeHash` hashes 128 bytes (was 96): `keccak256(projectTokenCount || terminalTokenAmount || beneficiary || metadata)`.
- `_insertIntoTree`, `_validate`, `_validateBranchRoot`, `_validateForEmergencyExit` all thread `metadata` through.
- Events `InsertToOutboxTree` and `Claimed` carry the field so off-chain indexers can read it directly without
  cracking the leaf.
- SVM leaf encoding widens from 96 bytes to 128 bytes; the new 32-byte suffix is the `metadata` field. The
  `_svmBuildTreeHash` interop test mirrors the layout exactly so EVM↔SVM hash equality is preserved.

**Intended use**

The field is generic: any future leaf consumer can use it for its own claim context without further sucker changes.
Pass `bytes32(0)` for ordinary bridges that don't need it.

**Risk surface**

Zero new trust paths. The bridge protocol stays leaf-in-leaf-out; we just put one more 32-byte field under the
same root. Existing claim, emergency-exit, and root-relay flows behave identically when `metadata == bytes32(0)`.
The leaf-hash domain changes (96 → 128 bytes), but since nothing is deployed yet there's no on-chain
compatibility concern.

## 0.0.46 — Bump nana-core-v6 to 0.0.53

`@bananapus/core-v6@0.0.53` ([nana-core-v6 PR #145](https://github.com/Bananapus/nana-core-v6/pull/145)) drops the `via_ir` requirement on `JBCashOutHookSpecsLib`, which lets this package consume the cross-project cashout work (`payAfterCashOutTokensOf` / `addToBalanceAfterCashOutTokensOf`) without needing `via_ir = true` in its own foundry profile.

- No src changes — suckers doesn't reference `IJBFeeTerminal.FEE()` or any of the touched core surfaces.
- All `JBRulesetMetadata` test literals patched to include `pauseCrossProjectFeeFreeInflows: false`.

`package.json`: version `0.0.44 → 0.0.46` (skipping 0.0.45 because nothing shipped at that intermediate revision), core dep `^0.0.48 → ^0.0.53`.

## Summary

- Cross-chain identifiers are now modeled for a wider address space. The v6 repo uses `bytes32` where the v5 repo used EVM `address` assumptions.
- Message handling is versioned instead of implicitly trusting an older fixed format.
- The anti-spam and fee model changed materially. v5's per-token minimum-bridge assumptions were replaced by a registry-level `toRemoteFee` flow in v6.
- The old manual add-to-balance mode is gone from the current repo.
- Celo support is now part of the repo's first-class contract set.
- The repo moved from the v5 `0.8.23` baseline to `0.8.28`.

## Verified deltas

- `IJBSucker.peer()` now returns `bytes32`.
- `IJBSucker.prepare(...)` now takes a `bytes32 beneficiary`.
- `Claimed` and `InsertToOutboxTree` changed their `beneficiary` field from `address` to `bytes32`.
- The `Claimed` event no longer carries the old `autoAddedToBalance` boolean.
- The public `ADD_TO_BALANCE_MODE()` surface and the manual mode path are gone from the interface.
- `StaleRootRejected(...)` is a new event on the interface.

## Breaking ABI changes

- `JBRemoteToken.addr` changed from `address` to `bytes32`.
- `JBTokenMapping.remoteToken` changed from `address` to `bytes32`.
- `JBMessageRoot` gained `version` and changed `token` from `address` to `bytes32`.
- `IJBSucker.peer()` changed return type.
- `IJBSucker.prepare(...)` changed parameter type for `beneficiary`.
- The manual add-to-balance mode surface was removed.

## Indexer impact

- `Claimed` and `InsertToOutboxTree` require schema changes because `beneficiary` is no longer an EVM address.
- Remote token and peer identifiers should be stored as raw 32-byte values.
- `StaleRootRejected` is new and can be used to monitor out-of-order or duplicate delivery attempts.

## Migration notes

- Treat every cross-chain identifier schema as migrated, including indexers and bridge metadata.
- Rebuild integrations around the current fee and registry model. Old `minBridgeAmount` assumptions are stale.
- Use the current v6 structs and events for ABI regeneration. This repo has too many widened fields for manual patching to be safe.

## ABI appendix

- Changed functions
  - `peer() -> bytes32`
  - `prepare(..., bytes32 beneficiary, ...)`
- Changed events
  - `Claimed`
  - `InsertToOutboxTree`
- Added events
  - `StaleRootRejected`
- Removed surface
  - manual add-to-balance mode / `ADD_TO_BALANCE_MODE()`
- Changed structs
  - `JBRemoteToken`
  - `JBTokenMapping`
  - `JBMessageRoot`
