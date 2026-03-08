# State Inconsistency Audit — Raw Findings (Pre-Verification)

## Coupled State Dependency Map

### Pair 1: `_outboxOf[token].balance` ↔ actual token balance held by sucker
**Invariant:** `_balanceOf(token, address(this)) >= _outboxOf[token].balance` (always)
**Mutation points:** `_insertIntoTree()` (+= terminalTokenAmount), `_sendRoot()` (delete balance), `exitThroughEmergencyHatch()` (-= terminalTokenAmount)

### Pair 2: `_outboxOf[token].tree.count` ↔ `_outboxOf[token].numberOfClaimsSent`
**Invariant:** `numberOfClaimsSent <= tree.count` (always); `numberOfClaimsSent == tree.count` after `_sendRoot`
**Mutation points:** `_insertIntoTree()` (count via tree.insert), `_sendRoot()` (numberOfClaimsSent = count)

### Pair 3: `_inboxOf[token].root` ↔ `_inboxOf[token].nonce`
**Invariant:** root and nonce are always updated atomically; nonce is strictly increasing
**Mutation points:** `fromRemote()` only

### Pair 4: `_remoteTokenFor[token].enabled` ↔ `_remoteTokenFor[token].emergencyHatch`
**Invariant:** `enabled && emergencyHatch` is never true simultaneously; `emergencyHatch` is permanent once set
**Mutation points:** `_mapToken()` (sets enabled, resets emergencyHatch to false), `enableEmergencyHatchFor()` (sets enabled=false, emergencyHatch=true)

### Pair 5: `_outboxOf[token].nonce` ↔ `_inboxOf[remoteToken].nonce` (cross-chain)
**Invariant:** Remote inbox nonce tracks sent outbox nonces (monotonically increasing)
**Mutation points:** `_sendRoot()` (increments outbox nonce), `fromRemote()` (updates inbox nonce)

## Mutation Matrix

| State Variable | Mutating Function | Updates Coupled State? |
|---|---|---|
| `_outboxOf[token].balance` | `_insertIntoTree()` (+= amount) | N/A — actual balance increases via `_pullBackingAssets` ✓ |
| `_outboxOf[token].balance` | `_sendRoot()` (delete) | Tokens sent via bridge ✓ |
| `_outboxOf[token].balance` | `exitThroughEmergencyHatch()` (-= amount) | Tokens returned via `_handleClaim` ✓ |
| `_outboxOf[token].tree` | `_insertIntoTree()` (insert) | balance updated in same function ✓ |
| `_outboxOf[token].numberOfClaimsSent` | `_sendRoot()` (= count) | balance deleted in same function ✓ |
| `_outboxOf[token].nonce` | `_sendRoot()` (++) | All outbox state updated atomically ✓ |
| `_inboxOf[token].root` | `fromRemote()` | nonce updated atomically ✓ |
| `_inboxOf[token].nonce` | `fromRemote()` | root updated atomically ✓ |
| `_remoteTokenFor[token].enabled` | `_mapToken()` | emergencyHatch set to false ✓ |
| `_remoteTokenFor[token].enabled` | `enableEmergencyHatchFor()` | emergencyHatch set to true ✓ |
| `_remoteTokenFor[token].emergencyHatch` | `enableEmergencyHatchFor()` | enabled set to false ✓ |
| `_executedFor[token]` | `_validate()` (set bit) | N/A — standalone bitmap ✓ |
| `_executedFor[emergencyAddr]` | `_validateForEmergencyExit()` (set bit) | N/A — standalone bitmap ✓ |
| `deprecatedAfter` | `setDeprecation()` | N/A — standalone timestamp ✓ |

**Result: ALL mutations update their coupled state correctly. No gaps found.**

## Parallel Path Comparison

| Coupled State | `prepare()`→`toRemote()` | `exitThroughEmergencyHatch()` | `_mapToken` (disable) |
|---|---|---|---|
| `outbox.balance` | Increased by `_insertIntoTree`, reset by `_sendRoot` | Decreased per-claim | Reset by `_sendRoot` |
| `outbox.tree` | Leaf inserted | Not modified (tree is append-only) | Not modified |
| `outbox.numberOfClaimsSent` | Set to tree.count by `_sendRoot` | Read (not modified) | Set to tree.count by `_sendRoot` |
| `outbox.nonce` | Incremented by `_sendRoot` | Not modified | Incremented by `_sendRoot` |
| `_executedFor` bitmap | Not used (outbox path) | Set via emergency address derivation | Not used |

**All parallel paths update coupled state consistently.** No missing updates found.

## Operation Ordering Analysis

### `_sendRoot()` (L932-979)
```
step 1: amount = outbox.balance         → reads balance
step 2: delete outbox.balance           → clears balance
step 3: nonce = ++outbox.nonce          → increments nonce
step 4: root = outbox.tree.root()       → reads tree root
step 5: outbox.numberOfClaimsSent = count → updates claims sent
step 6: _sendRootOverAMB(...)           → external call (bridge)
```
All state updates (steps 2-5) happen BEFORE the external call (step 6). ✓ Checks-effects-interactions respected.

### `exitThroughEmergencyHatch()` (L605-627)
```
step 1: _validateForEmergencyExit(...)  → marks leaf as executed
step 2: outbox.balance -= amount        → decreases balance
step 3: _handleClaim(...)               → external calls (mint, addToBalance)
```
State updates (steps 1-2) happen BEFORE external calls (step 3). ✓

### `claim()` (L392-420)
```
step 1: _validate(...)                  → marks leaf as executed
step 2: emit Claimed(...)               → event
step 3: _handleClaim(...)               → external calls (mint, addToBalance)
```
Leaf marked executed (step 1) BEFORE external calls (step 3). ✓

### `fromRemote()` (L433-464)
```
step 1: _isRemotePeer check            → auth (may have external call in OP/ARB)
step 2: inbox.nonce = root.nonce        → updates nonce
step 3: inbox.root = root.root          → updates root
```
No external calls after state updates. ✓

## Masking Code Analysis

### Pattern found: `amountToAddToBalanceOf()` (L190)
```solidity
return _balanceOf({token: token, addr: address(this)}) - _outboxOf[token].balance;
```
This subtraction has no defensive clamp. If the invariant (actual balance >= outbox.balance) were broken, this would revert with underflow. This is CORRECT behavior — an underflow here would indicate a critical bug, and reverting is the right response (fail loud, not silent).

### Pattern found: Emergency exit `numberOfClaimsSent` check (L1099)
```solidity
if (outboxOfToken.numberOfClaimsSent != 0 && outboxOfToken.numberOfClaimsSent - 1 >= index)
```
The `numberOfClaimsSent != 0` guard prevents underflow in `numberOfClaimsSent - 1`. This is correct defensive coding, not masking a bug.

**No masking code hiding broken invariants found.**

## Raw Findings

**No state inconsistency findings.** All coupled state pairs are updated consistently across all mutation paths.
