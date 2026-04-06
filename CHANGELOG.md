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
- `JBCeloSucker`
- the deployers, structs, and interfaces under `src/`

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
