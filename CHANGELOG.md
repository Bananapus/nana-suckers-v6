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
- `JBSwapCCIPSucker`
- `JBCeloSucker`
- the deployers, structs, and interfaces under `src/`

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

The original motivator is the cross-chain referral split hook (`nana-referral-split-hook-v6`): when a referrer
on chain Y earns credit for fee-paying activity on chain X, the hook on X uses the fee project's sucker to
bridge the entitled fee-project tokens. The leaf's `metadata` carries `(originChainId, referralProjectId)` so the
sibling hook on chain Y can atomically claim, re-pay the fee project locally, and push to the local distributor
for the right referrer — all under the merkle proof's authentication, no off-chain coordination needed.

The field is generic: any future leaf consumer (NFT split hooks, buyback hooks, etc.) can use it for its own
attribution scheme without further sucker changes. Pass `bytes32(0)` for ordinary bridges that don't need it.

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
