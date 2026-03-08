# State Inconsistency Audit — Verified Findings

## Coupled State Dependency Map
See `state-inconsistency-raw.md` for the full map. 5 coupled pairs identified across the codebase.

## Mutation Matrix
See `state-inconsistency-raw.md` for the full matrix. 14 mutation points analyzed.

## Parallel Path Comparison
See `state-inconsistency-raw.md` for the full comparison table.

## Verification Summary

| ID | Coupled Pair | Breaking Op | Original Severity | Verdict | Final Severity |
|----|-------------|-------------|-------------------|---------|----------------|
| — | — | — | — | — | — |

**No state inconsistency findings.** All coupled state pairs are updated consistently across all 14 mutation points and all parallel code paths.

## Key Validation Results

### Pair 1: `outbox.balance` ↔ actual token balance
- **5 mutation paths checked** (insertIntoTree, sendRoot, emergencyExit, addToBalance, pullBackingAssets)
- Every increase/decrease to outbox.balance has a corresponding real token movement
- The `amountToAddToBalanceOf` subtraction is safe by construction

### Pair 2: `outbox.tree.count` ↔ `outbox.numberOfClaimsSent`
- `numberOfClaimsSent` only updated in `_sendRoot` where it's set to `tree.count`
- `tree.count` only increases (append-only tree via `_insertIntoTree`)
- Emergency exit correctly uses `numberOfClaimsSent` to gate which leaves can be reclaimed

### Pair 3: `inbox.root` ↔ `inbox.nonce`
- Both updated atomically in `fromRemote()` — no function updates one without the other
- Nonce strictly increasing (`root.remoteRoot.nonce > inbox.nonce`)

### Pair 4: `remoteToken.enabled` ↔ `remoteToken.emergencyHatch`
- `_mapToken` sets `emergencyHatch = false` when enabling
- `enableEmergencyHatchFor` sets `enabled = false` when enabling emergency hatch
- Mutual exclusion maintained across all paths
- Emergency hatch permanence: `_mapToken` reverts if `emergencyHatch == true`

### Cross-chain Pair 5: outbox nonce ↔ inbox nonce
- Outbox nonce incremented atomically with root send
- Inbox accepts any nonce > current (documented non-sequential behavior)
- Skipped nonces permanently lost (accepted tradeoff, documented)

## Summary
- Coupled state pairs mapped: 5
- Mutation paths analyzed: 14
- Raw findings (pre-verification): 0
- After verification: 0 TRUE POSITIVE | 0 FALSE POSITIVE
- Final: **0 CRITICAL | 0 HIGH | 0 MEDIUM | 0 LOW**
