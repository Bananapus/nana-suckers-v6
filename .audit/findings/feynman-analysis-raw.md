# Feynman Audit — Raw Findings (Pre-Verification)

## Scope
- **Language:** Solidity 0.8.26
- **Modules analyzed:** JBSucker, JBSuckerRegistry, JBOptimismSucker, JBArbitrumSucker, JBCCIPSucker, JBBaseSucker, JBSuckerDeployer, JBOptimismSuckerDeployer, JBArbitrumSuckerDeployer, JBCCIPSuckerDeployer, JBBaseSuckerDeployer, MerkleLib, CCIPHelper, ARBAddresses, ARBChains, Deploy.s.sol, SuckerDeploymentLib
- **Functions analyzed:** 52 entry points across all contracts
- **Lines interrogated:** ~3,400 lines of Solidity

## Phase 0 — Attacker's Hit List

### Attack Goals
1. **Double-spend bridged tokens** — claim on remote chain AND emergency exit on source chain
2. **Mint unbacked project tokens** — forge merkle proofs or manipulate inbox root
3. **Drain sucker's token balance** — exploit accounting gaps between outbox.balance and actual balance
4. **Permanent DoS** — brick the bridge so no one can prepare/claim
5. **Privilege escalation** — map tokens or deprecate without authorization

### Novel Code (highest bug density)
- `JBSucker.sol` — custom bridging logic, merkle tree accounting, emergency hatch mechanism
- `MerkleLib.sol` — incremental merkle tree (eth2 deposit pattern) with heavy assembly
- Token disable/re-enable flow with root flushing in `_mapToken`

### Value Stores
- Sucker contract holds ERC-20/ETH (`_outboxOf[token].balance` tracks earmarked funds)
- `amountToAddToBalanceOf()` represents unearmarked tokens available for the project

### Complex Paths
- `prepare()` → `toRemote()` → (bridge) → `fromRemote()` → `claim()` — crosses 4+ contracts
- `prepare()` → `enableEmergencyHatchFor()` → `exitThroughEmergencyHatch()` — fallback path

### Priority Order
1. `JBSucker._sendRoot` / `_insertIntoTree` / `_validate` / `_validateForEmergencyExit` — core value flow
2. `JBSucker.fromRemote` / `_handleClaim` — remote message processing
3. `JBSucker._mapToken` / `mapTokens` — configuration with root flushing
4. Chain-specific `_sendRootOverAMB` / `_isRemotePeer` implementations

## Function-State Matrix

| Function | Reads | Writes | Guards | External Calls |
|----------|-------|--------|--------|----------------|
| `prepare()` | `_remoteTokenFor`, `state()` | `_outboxOf[].tree`, `_outboxOf[].balance` | `enabled` check, deprecation check | `projectToken.safeTransferFrom`, `terminal.cashOutTokensOf` |
| `toRemote()` | `_remoteTokenFor`, `_outboxOf[].balance` | (via `_sendRoot`) `_outboxOf[].balance`, `.nonce`, `.numberOfClaimsSent` | `emergencyHatch`, `minBridgeAmount` | Bridge-specific |
| `fromRemote()` | `_inboxOf[].nonce`, `state()` | `_inboxOf[].nonce`, `_inboxOf[].root` | `_isRemotePeer`, version check | None |
| `claim()` | `_executedFor`, `_inboxOf[].root` | `_executedFor` | Merkle proof validation | `controller.mintTokensOf`, `terminal.addToBalanceOf` |
| `exitThroughEmergencyHatch()` | `_outboxOf[].numberOfClaimsSent`, `_executedFor` (derived addr) | `_outboxOf[].balance`, `_executedFor` | Emergency hatch/deprecation, merkle proof | `controller.mintTokensOf`, `terminal.addToBalanceOf` |
| `mapToken()` / `mapTokens()` | `_remoteTokenFor`, `_outboxOf` | `_remoteTokenFor` | `MAP_SUCKER_TOKEN` permission, `emergencyHatch` | (via `_sendRoot` if disabling) |
| `enableEmergencyHatchFor()` | `_remoteTokenFor` | `_remoteTokenFor[].enabled`, `.emergencyHatch` | `SUCKER_SAFETY` permission | None |
| `setDeprecation()` | `state()`, `deprecatedAfter` | `deprecatedAfter` | `SET_SUCKER_DEPRECATION` permission, state check | None |
| `addOutstandingAmountToBalance()` | `amountToAddToBalanceOf()` | (via `_addToBalance`) | `ADD_TO_BALANCE_MODE == MANUAL` | `terminal.addToBalanceOf` |

## Raw Findings

### FF-001: `mapTokens()` msg.value dust loss from integer division
**Severity:** LOW
**Function:** `JBSucker.mapTokens()` at `src/JBSucker.sol:L492`
**Lines:** L478-494

**Feynman Question:** Q1.1 — Why does the division happen without handling the remainder?

**The code:**
```solidity
_mapToken({map: maps[i], transportPaymentValue: numberToDisable > 0 ? msg.value / numberToDisable : 0});
```

**Why this is a concern:**
If `msg.value` is not evenly divisible by `numberToDisable`, the remainder (up to `numberToDisable - 1` wei) stays in the contract permanently. Additionally, if `numberToDisable == 0` but `msg.value > 0`, the entire `msg.value` stays in the contract.

**Scenario:**
1. User calls `mapTokens` with 3 token disable operations, sending 10 wei as msg.value
2. Each `_mapToken` call gets `10 / 3 = 3` wei as transportPaymentValue
3. 1 wei (remainder) is stuck in the contract

**Mitigating factors:**
- For native-token-mapped suckers, excess ETH flows to the project via `amountToAddToBalanceOf(NATIVE_TOKEN)`
- Remainder is dust (< `numberToDisable` wei)
- For OP/Base suckers, msg.value must be 0 anyway (no transport payment needed)

**Verdict:** TRUE POSITIVE — LOW

---

### FF-002: CCIP `_isRemotePeer` relies on self-call pattern
**Severity:** LOW (Informational)
**Function:** `JBCCIPSucker._isRemotePeer()` at `src/JBCCIPSucker.sol:L186-188`

**Feynman Question:** Q3.1 — Why does CCIP check `sender == address(this)` while OP checks `sender == OPMESSENGER && xDomainMessageSender() == peer()`?

**The code:**
```solidity
function _isRemotePeer(address sender) internal view override returns (bool _valid) {
    return sender == address(this);
}
```

**Analysis:**
The full authentication happens in `ccipReceive()` (L132-179):
- Validates `_msgSender() == CCIP_ROUTER`
- Validates `origin == peer()` (decoded from `any2EvmMessage.sender`)
- Validates `sourceChainSelector == REMOTE_CHAIN_SELECTOR`
- Then calls `this.fromRemote(root)` — making `_msgSender() == address(this)`

The security is equivalent to OP/ARB implementations but structured differently. `_isRemotePeer` is just a guard ensuring `fromRemote` is only reachable via the authenticated `ccipReceive` path.

**Verdict:** TRUE POSITIVE — LOW (design pattern observation, not a vulnerability)

---

### FF-003: Deploy script uses "nana-suckers-v5" project name for V6 code
**Severity:** Informational
**Files:** `script/Deploy.s.sol`, `script/helpers/SuckerDeploymentLib.sol`

**Feynman Question:** Q1.1 — Why does the project name say "v5" in a v6 codebase?

**Impact:** No security impact. Naming inconsistency in Sphinx deployment configuration. Could cause confusion when identifying deployments.

**Verdict:** TRUE POSITIVE — Informational

---

## False Positives Eliminated During Feynman Analysis

### FP-1: `amountToAddToBalanceOf` underflow
**Concern:** `_balanceOf(token, address(this)) - _outboxOf[token].balance` could underflow.
**Why false:** The contract's actual balance always >= outbox.balance because:
- `_insertIntoTree` increases outbox.balance by the amount received from `_pullBackingAssets`
- `_sendRoot` resets outbox.balance to 0 and sends the corresponding tokens via the bridge
- `exitThroughEmergencyHatch` decreases outbox.balance when returning tokens locally
- No path creates outbox.balance without corresponding real tokens

### FP-2: Double-spend via emergency exit + remote claim
**Concern:** User prepares, root is sent, then emergency exit enabled — user claims both sides.
**Why false:** `_validateForEmergencyExit` (L1098-1099) checks `numberOfClaimsSent - 1 >= index`. Leaves with index < numberOfClaimsSent (i.e., leaves included in a sent root) are blocked from emergency exit.

### FP-3: Token re-mapping double-spend
**Concern:** Remap token after outbox activity to claim against two different remote tokens.
**Why false:** `_mapToken` (L847-852) reverts if attempting to remap to a different remote token when `_outboxOf[token].tree.count != 0`. Re-enabling the same remote token is allowed.

### FP-4: `_sendRoot` with `count = 0` underflow
**Concern:** `uint256 index = count - 1` (L957) underflows when count is 0.
**Why false:** `_sendRoot` is only reachable from:
- `toRemote()` which requires `_outboxOf[token].balance >= remoteToken.minBridgeAmount` (and minBridgeAmount > 0 if configured, plus balance only increases via `_insertIntoTree` which increments count)
- `_mapToken` disabling path which checks `_outboxOf[token].numberOfClaimsSent != _outboxOf[token].tree.count` — if count is 0, numberOfClaimsSent is also 0, so the condition is false

### FP-5: Reentrancy in `prepare()`
**Concern:** External calls to `projectToken.safeTransferFrom` and `terminal.cashOutTokensOf` before state updates.
**Why false:** The attacker would need fresh project tokens for each reentrant call (they're transferred away first). The cash out returns terminal tokens to the sucker, increasing balance — subsequent `_insertIntoTree` correctly accounts for the new amount. No profit opportunity.

### FP-6: Reentrancy in `claim()`
**Concern:** External calls in `_handleClaim` after merkle proof validation.
**Why false:** The leaf is marked as executed in `_validate` (L1033: `_executedFor[terminalToken].set(index)`) BEFORE `_handleClaim` is called. Re-entering `claim` with the same leaf reverts at L1028-1029.

### FP-7: `fromRemote` state atomicity
**Concern:** State updates to inbox could be interrupted by external calls.
**Why false:** `fromRemote` has no external calls between its state updates. It atomically updates `inbox.nonce` and `inbox.root` in the same storage write sequence.

### FP-8: `deprecatedAfter` underflow in `state()`
**Concern:** `_deprecatedAfter - _maxMessagingDelay()` at L255 could underflow.
**Why false:** `setDeprecation` enforces `timestamp >= block.timestamp + _maxMessagingDelay()`, guaranteeing `deprecatedAfter >= _maxMessagingDelay()`.
