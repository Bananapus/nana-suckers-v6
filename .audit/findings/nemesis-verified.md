# N E M E S I S — Verified Findings

```
    ╔═══════════════════════════════════════════════════════════════╗
    ║                                                               ║
    ║   Your code was written with confidence.                      ║
    ║   Nemesis questioned that confidence.                         ║
    ║   Then mapped what your confidence forgot to protect.         ║
    ║   Then questioned it again.                                   ║
    ║                                                               ║
    ║   Verdict: The confidence was largely justified.              ║
    ║                                                               ║
    ╚═══════════════════════════════════════════════════════════════╝
```

## Scope
- **Language:** Solidity 0.8.26
- **Modules analyzed:** 17 contracts, interfaces, libraries, deployers, deployment scripts
- **Functions analyzed:** 52 entry points
- **Coupled state pairs mapped:** 5
- **Mutation paths traced:** 14
- **Nemesis loop iterations:** 3 (2 full passes + 1 targeted convergence check)

## Nemesis Map (Phase 1 Cross-Reference)

| Function | Writes A | Writes B | A↔B Pair | Sync Status |
|---|---|---|---|---|
| `_insertIntoTree()` | outbox.tree ✓ | outbox.balance ✓ | tree↔balance | ✓ SYNCED |
| `_sendRoot()` | outbox.balance ✓ | outbox.numberOfClaimsSent ✓ | balance↔claims | ✓ SYNCED |
| `_sendRoot()` | outbox.nonce ✓ | outbox.tree.root ✓ | nonce↔root | ✓ SYNCED |
| `fromRemote()` | inbox.nonce ✓ | inbox.root ✓ | nonce↔root | ✓ SYNCED |
| `exitThroughEmergencyHatch()` | outbox.balance ✓ | _executedFor ✓ | balance↔executed | ✓ SYNCED |
| `_mapToken()` | enabled ✓ | emergencyHatch ✓ | enabled↔hatch | ✓ SYNCED |
| `enableEmergencyHatchFor()` | enabled ✓ | emergencyHatch ✓ | enabled↔hatch | ✓ SYNCED |

**No gaps in the cross-reference.** Every function that modifies one side of a coupled pair also modifies the other.

## Verification Summary

| ID | Source | Coupled Pair | Breaking Op | Severity | Verdict |
|----|--------|-------------|-------------|----------|---------|
| NM-001 | Feynman-only | N/A | `mapTokens()` | LOW | TRUE POS |
| NM-002 | Feynman-only | N/A | `_isRemotePeer()` | LOW | TRUE POS |
| NM-003 | Feynman-only | N/A | Deploy scripts | Info | TRUE POS |

## Verified Findings (TRUE POSITIVES only)

### Finding NM-001: `mapTokens()` msg.value dust from integer division
**Severity:** LOW
**Source:** Feynman-only (Pass 1)
**Verification:** Code trace — confirmed

**Feynman Question that exposed it:**
> Q1.1: Why does the integer division at L492 not handle the remainder?

**State Mapper gap that confirmed it:**
> Not a state inconsistency — this is a value-handling edge case in the transport payment splitting logic.

**Breaking Operation:** `mapTokens()` at `src/JBSucker.sol:L492`
- Divides `msg.value` by `numberToDisable`
- Remainder (< `numberToDisable` wei) stays in the contract

**Trigger Sequence:**
1. Call `mapTokens([disable1, disable2, disable3])` with `msg.value = 10 wei`
2. Each `_mapToken` gets `10 / 3 = 3 wei` as transport payment
3. 1 wei remainder permanently stuck in contract

**Consequence:**
- Dust amounts of ETH stuck in contract (maximum `numberToDisable - 1` wei per call)
- If native token is mapped: excess flows to project via `amountToAddToBalanceOf` — self-healing
- If native token is NOT mapped: ETH permanently stuck — no sweep function
- If `numberToDisable == 0` but `msg.value > 0`: entire `msg.value` stuck (user error)

**Verification Evidence:**
- Code trace confirms no remainder handling at L492
- `receive() external payable {}` accepts any ETH
- No sweep or recovery function exists for arbitrary ETH

**Fix:**
```solidity
// Option A: Refund remainder after processing all mappings
uint256 totalUsed = numberToDisable > 0 ? (msg.value / numberToDisable) * numberToDisable : 0;
if (msg.value > totalUsed) {
    (bool sent,) = _msgSender().call{value: msg.value - totalUsed}("");
    if (!sent) revert(); // or emit event
}

// Option B: Give last disable call the remainder
// In the loop: use msg.value - (msg.value / numberToDisable) * (numberToDisable - 1) for last call
```

---

### Finding NM-002: CCIP authentication via self-call pattern (design note)
**Severity:** LOW (Informational)
**Source:** Feynman-only (Pass 1, Category 3 — consistency comparison)
**Verification:** Code trace — security equivalent

**Feynman Question that exposed it:**
> Q3.1: If OP/ARB `_isRemotePeer` validates the bridge messenger AND the peer, why does CCIP only validate `sender == address(this)`?

**Analysis:**
CCIP splits authentication: `ccipReceive()` validates router + origin + chain selector (L134, L141), then self-calls `fromRemote()`. The `_isRemotePeer` check ensures `fromRemote` is only callable through this authenticated path. Equivalent security, different architecture.

**Impact:** None. Documented for auditor awareness of the divergent authentication pattern.

---

### Finding NM-003: Deploy scripts use "nana-suckers-v5" for V6 code
**Severity:** Informational
**Source:** Feynman-only (Pass 1)
**Files:** `script/Deploy.s.sol`, `script/helpers/SuckerDeploymentLib.sol`

**Impact:** No security impact. Cosmetic naming inconsistency in Sphinx deployment configuration.

---

## Feedback Loop Discoveries
**None.** No findings emerged from the cross-feed between Feynman and State Inconsistency auditors. This indicates the codebase has strong alignment between its business logic reasoning and its state management — both dimensions are internally consistent.

## False Positives Eliminated

### From Feynman (Pass 1):
8 false positives identified and eliminated:
1. `amountToAddToBalanceOf` underflow — impossible by construction (balance invariant)
2. Double-spend via emergency exit + remote claim — blocked by `numberOfClaimsSent` check
3. Token re-mapping double-spend — blocked by `_mapToken` guard (L847-852)
4. `_sendRoot` count-0 underflow — unreachable (count > 0 guaranteed by callers)
5. Reentrancy in `prepare()` — no profit opportunity (tokens transferred away first)
6. Reentrancy in `claim()` — leaf marked executed before external calls
7. `fromRemote` state atomicity — no external calls between state updates
8. `deprecatedAfter` underflow in `state()` — prevented by `setDeprecation` enforcement

### From State Mapper (Pass 2):
0 false positives — no findings to verify.

## Multi-Transaction Journey Testing (Phase 5)
6 adversarial sequences tested:
1. **Deposit → partial withdraw → claim** — Correct
2. **Prepare → emergency exit (no root sent)** — Correct
3. **Prepare → toRemote → prepare more → emergency exit** — Correct (sent leaves blocked, unsent allowed)
4. **Token disable → re-enable → prepare → toRemote** — Correct (append-only tree preserves all leaves)
5. **Out-of-order CCIP nonces** — Documented and accepted behavior
6. **Rounding/accumulation across many prepares** — No drift (exact amounts in leaves)

**No vulnerabilities found via adversarial sequence testing.**

## Summary
- Total functions analyzed: **52**
- Coupled state pairs mapped: **5**
- Mutation paths traced: **14**
- Nemesis loop iterations: **3** (converged after 2 full + 1 targeted)
- Raw findings (pre-verification): 0 C | 0 H | 0 M | 3 L
- Feedback loop discoveries: **0** (neither auditor's findings enriched the other's — no cross-cutting bugs)
- After verification: **3 TRUE POSITIVE** | **0 FALSE POSITIVE** | **0 DOWNGRADED**
- Final: **0 CRITICAL | 0 HIGH | 0 MEDIUM | 2 LOW | 1 Informational**

---

## Assessment

The nana-suckers-v6 codebase demonstrates strong security engineering:

1. **Checks-effects-interactions pattern** consistently applied across all state-modifying functions
2. **Atomic state updates** — coupled variables always updated together
3. **Double-spend prevention** via bitmap tracking (`_executedFor`) with separate slots for regular claims vs emergency exits
4. **Emergency exit safety** via `numberOfClaimsSent` accurately tracking which leaves have been communicated to the remote peer
5. **Token remapping protection** preventing double-spend via `_mapToken` guard (L847-852)
6. **Balance invariant maintenance** ensuring `_balanceOf >= _outboxOf.balance` at all times
7. **Comprehensive documentation** of design decisions and tradeoffs (nonce ordering, CCIP amount validation, refund handling)

The only findings are dust-level value handling (NM-001) and design pattern observations (NM-002, NM-003). No critical, high, or medium severity issues were found.
