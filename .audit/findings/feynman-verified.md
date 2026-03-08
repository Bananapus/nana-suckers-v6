# Feynman Audit — Verified Findings

## Scope
- **Language:** Solidity 0.8.26
- **Modules analyzed:** 17 (all contracts, interfaces, libraries, deployers, scripts)
- **Functions analyzed:** 52 entry points
- **Lines interrogated:** ~3,400 lines

## Verification Summary

| ID | Original Severity | Verdict | Final Severity |
|----|-------------------|---------|----------------|
| FF-001 | LOW | TRUE POSITIVE | LOW |
| FF-002 | LOW | TRUE POSITIVE | LOW (Informational) |
| FF-003 | Informational | TRUE POSITIVE | Informational |

## Guard Consistency Analysis
All functions that write to the same state variables have consistent access control:
- `_outboxOf` mutations: `prepare()` (requires `enabled` + non-deprecated), `toRemote()` (via `_sendRoot`), `exitThroughEmergencyHatch()` (requires emergency hatch)
- `_inboxOf` mutations: `fromRemote()` only (requires `_isRemotePeer`)
- `_remoteTokenFor` mutations: `_mapToken()` (requires `MAP_SUCKER_TOKEN`), `enableEmergencyHatchFor()` (requires `SUCKER_SAFETY`)
- `deprecatedAfter` mutations: `setDeprecation()` only (requires `SET_SUCKER_DEPRECATION`)

**No missing guards found.** All state-modifying functions have appropriate access control.

## Inverse Operation Parity
| Pair | Forward | Inverse | Parity |
|------|---------|---------|--------|
| Prepare/Claim | `prepare()` burns project tokens, cashes out terminal tokens, inserts leaf | `claim()` verifies proof, mints project tokens, adds terminal tokens to project | SYMMETRIC |
| Map/Disable | `_mapToken(remoteToken != 0)` enables bridging | `_mapToken(remoteToken == 0)` disables + flushes root | SYMMETRIC |
| Enable/EmergencyHatch | `_mapToken` sets `enabled=true` | `enableEmergencyHatchFor` sets `enabled=false, emergencyHatch=true` | ASYMMETRIC BY DESIGN — emergency hatch is one-way |

## Verified Findings (TRUE POSITIVES only)

### Finding FF-001: `mapTokens()` msg.value dust from integer division
**Severity:** LOW
**Module:** JBSucker
**Function:** `mapTokens()`
**Lines:** L492
**Verification:** Code trace — confirmed division remainder is unrecoverable

**Feynman Question that exposed this:**
> Q1.1: Why does the division at L492 not handle the remainder?

**The code:**
```solidity
_mapToken({map: maps[i], transportPaymentValue: numberToDisable > 0 ? msg.value / numberToDisable : 0});
```

**Why this is wrong:**
Integer division `msg.value / numberToDisable` loses the remainder. For `numberToDisable > 1`, up to `numberToDisable - 1` wei is permanently stuck. Additionally, if `numberToDisable == 0` but `msg.value > 0`, the entire `msg.value` stays in the contract with no recovery path (unless native token is mapped, in which case it flows to the project).

**Verification evidence:**
- L478-494: The loop iterates ALL mappings with the same `transportPaymentValue`, but only disabling mappings consume it via `_sendRoot`
- For native-token-mapped suckers: excess ETH is captured by `amountToAddToBalanceOf(NATIVE_TOKEN)` — mitigated
- For suckers without native token mapping: ETH is permanently stuck — no sweep function exists
- The `receive() external payable {}` at L677 accepts ETH without restriction

**Impact:** Dust amounts of ETH. Negligible for properly-configured calls.

**Suggested fix:**
```solidity
// Refund remainder to caller after all mappings are processed
uint256 remainder = msg.value - (numberToDisable > 0 ? (msg.value / numberToDisable) * numberToDisable : 0);
if (remainder != 0) { /* refund */ }
```

---

### Finding FF-002: CCIP authentication via self-call pattern (design note)
**Severity:** LOW (Informational)
**Module:** JBCCIPSucker
**Function:** `_isRemotePeer()`
**Lines:** L186-188
**Verification:** Code trace — confirmed authentication is equivalent to OP/ARB

**Feynman Question that exposed this:**
> Q3.1: Why does CCIP use `sender == address(this)` while OP/ARB verify the bridge/messenger?

**Why this is notable (not wrong):**
CCIP splits authentication across two functions: `ccipReceive()` validates router + origin + chain selector, then calls `this.fromRemote()`. The `_isRemotePeer` check `sender == address(this)` ensures `fromRemote` is only reachable through the authenticated `ccipReceive` path. This is equivalent security but architecturally different from OP/ARB which perform all validation inside `_isRemotePeer`.

**Verification evidence:**
- `ccipReceive()` L134: validates `_msgSender() == CCIP_ROUTER`
- `ccipReceive()` L141: validates `origin == peer() && sourceChainSelector == REMOTE_CHAIN_SELECTOR`
- L178: calls `this.fromRemote(root)` making `_msgSender() == address(this)` in `fromRemote`
- `_isRemotePeer()` then correctly passes

**Impact:** None — security is equivalent. Documented for auditor awareness.

---

### Finding FF-003: Deploy scripts use "nana-suckers-v5" for V6 code
**Severity:** Informational
**Files:** `script/Deploy.s.sol`, `script/helpers/SuckerDeploymentLib.sol`
**Verification:** File inspection

**Impact:** No security impact. Cosmetic naming inconsistency.

---

## False Positives Eliminated
8 false positives identified and eliminated during analysis (see `feynman-analysis-raw.md` for details):
- FP-1: `amountToAddToBalanceOf` underflow — impossible by construction
- FP-2: Double-spend via emergency exit + remote claim — blocked by `numberOfClaimsSent`
- FP-3: Token re-mapping double-spend — blocked by `_mapToken` guard
- FP-4: `_sendRoot` count-0 underflow — unreachable code path
- FP-5: Reentrancy in `prepare()` — no profit opportunity
- FP-6: Reentrancy in `claim()` — leaf marked executed before external calls
- FP-7: `fromRemote` atomicity — no external calls between state updates
- FP-8: `deprecatedAfter` underflow — prevented by `setDeprecation` check

## Summary
- Total functions analyzed: 52
- Raw findings (pre-verification): 0 CRITICAL | 0 HIGH | 0 MEDIUM | 3 LOW
- After verification: 3 TRUE POSITIVE | 0 FALSE POSITIVE | 0 DOWNGRADED
- Final: **0 CRITICAL | 0 HIGH | 0 MEDIUM | 2 LOW | 1 Informational**
