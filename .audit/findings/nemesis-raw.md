# N E M E S I S — Raw Intermediate Work

## Phase 0: Recon

### Language: Solidity 0.8.26

### Attack Goals
1. Double-spend bridged tokens (claim remote + emergency exit local)
2. Mint unbacked project tokens (forge merkle proofs, manipulate inbox root)
3. Drain sucker's token balance (accounting gaps)
4. Permanent DoS (brick bridge)
5. Privilege escalation (unauthorized token mapping, deprecation)

### Novel Code
- `JBSucker.sol` — custom bridging logic with merkle tree accounting
- `MerkleLib.sol` — incremental merkle tree (eth2 deposit contract pattern)
- Emergency hatch mechanism with `numberOfClaimsSent` tracking
- Token disable/re-enable flow with root flushing

### Value Stores
- Sucker contract: ERC-20 and native ETH tracked by `_outboxOf[token].balance`
- `amountToAddToBalanceOf()`: unearmarked tokens for the project

### Complex Paths
- `prepare` → `toRemote` → (bridge) → `fromRemote` → `claim` — 4+ contracts
- `prepare` → `enableEmergencyHatchFor` → `exitThroughEmergencyHatch` — fallback

### Priority
1. Core value flow: `_sendRoot`, `_insertIntoTree`, `_validate`, `_validateForEmergencyExit`
2. Remote processing: `fromRemote`, `_handleClaim`
3. Configuration: `_mapToken`, `mapTokens`
4. Chain-specific: `_sendRootOverAMB`, `_isRemotePeer` implementations

## Phase 1: Nemesis Map (Cross-Reference)

| Function | Writes A | Writes B | A↔B Pair | Sync Status |
|---|---|---|---|---|
| `_insertIntoTree()` | outbox.tree ✓ | outbox.balance ✓ | tree↔balance | ✓ SYNCED |
| `_sendRoot()` | outbox.balance ✓ | outbox.numberOfClaimsSent ✓ | balance↔claims | ✓ SYNCED |
| `_sendRoot()` | outbox.nonce ✓ | outbox.tree.root ✓ | nonce↔root | ✓ SYNCED |
| `fromRemote()` | inbox.nonce ✓ | inbox.root ✓ | nonce↔root | ✓ SYNCED |
| `exitThroughEmergencyHatch()` | outbox.balance ✓ | _executedFor ✓ | balance↔executed | ✓ SYNCED |
| `_mapToken()` | enabled ✓ | emergencyHatch ✓ | enabled↔hatch | ✓ SYNCED |
| `enableEmergencyHatchFor()` | enabled ✓ | emergencyHatch ✓ | enabled↔hatch | ✓ SYNCED |
| `claim()` / `_validate()` | _executedFor ✓ | (no coupled write needed) | — | ✓ N/A |

**No gaps found in the cross-reference.** All functions that write to one side of a coupled pair also write to the other.

## Iterative Pass Loop

### Pass 1 — Feynman (full)
See `feynman-analysis-raw.md`. 3 LOW findings, 8 false positives eliminated.

### Pass 2 — State Inconsistency (full, enriched by Pass 1)
See `state-inconsistency-raw.md`. 0 findings. All coupled pairs consistent.

**Feynman suspects fed to State Mapper:**
- FF-001 (mapTokens msg.value): State Mapper checked — no coupled state affected by dust loss
- FF-002 (CCIP _isRemotePeer): State Mapper checked — no state gap in authentication flow

**State Mapper gaps fed to Feynman:** None — no gaps found.

### Pass 3 — Feynman (targeted)
Scope: Only items from Pass 2 output. Pass 2 produced no new findings.
Result: No new suspects. **No new findings.**

### Convergence Check
- New findings from last pass: **NO**
- New coupled pairs not previously mapped: **NO**
- New suspects not previously flagged: **NO**
- **CONVERGED after 2 full passes + 1 targeted check.**

## Phase 5: Multi-Transaction Journey Tracing

### Sequence 1: Deposit → partial withdraw → claim
1. User A: `prepare(100 tokens, beneficiaryA, 0, ETH)` → leaf 0, balance += 50 ETH
2. User B: `prepare(200 tokens, beneficiaryB, 0, ETH)` → leaf 1, balance += 100 ETH
3. Relayer: `toRemote(ETH)` → sends root(leaf0, leaf1) + 150 ETH to remote
4. Remote: `fromRemote(root)` → inbox updated with root
5. User A: `claim(leaf0, proof)` → verified, 100 tokens minted, 50 ETH added to project
6. User B: `claim(leaf1, proof)` → verified, 200 tokens minted, 100 ETH added to project
**Result: Correct.** Each claim is independent, merkle proofs are valid.

### Sequence 2: Prepare → emergency exit (no root sent)
1. User: `prepare(100 tokens, beneficiary, 0, ETH)` → leaf 0, balance += 50 ETH
2. Bridge fails. `toRemote` never called. `numberOfClaimsSent = 0`.
3. Owner: `enableEmergencyHatchFor([ETH])`
4. User: `exitThroughEmergencyHatch(leaf0)` → `numberOfClaimsSent == 0` → passes → balance -= 50 ETH → tokens minted
**Result: Correct.** User recovers funds locally.

### Sequence 3: Prepare → toRemote → prepare more → emergency exit for new leaf
1. User A: `prepare(100)` → leaf 0
2. `toRemote()` → numberOfClaimsSent = 1, balance = 0
3. User B: `prepare(200)` → leaf 1, balance += 100 ETH
4. Emergency hatch enabled
5. User B: `exitThroughEmergencyHatch(leaf1)` → `numberOfClaimsSent(1) - 1 = 0 >= 1`? → false → passes ✓
6. User A: `exitThroughEmergencyHatch(leaf0)` → `numberOfClaimsSent(1) - 1 = 0 >= 0`? → true → REVERTS ✓
**Result: Correct.** Leaf 0 was already sent remotely, correctly blocked from local exit. Leaf 1 (unsent) correctly allowed.

### Sequence 4: Token disable → re-enable → prepare → toRemote
1. Token mapped: ETH → remoteETH
2. User A: `prepare(100)` → leaf 0, balance += 50 ETH
3. Owner: `mapToken(ETH → 0x0)` → triggers `_sendRoot`, sends root + 50 ETH, numberOfClaimsSent = 1
4. Owner: `mapToken(ETH → remoteETH)` → re-enables (same addr check passes since count > 0 but addr unchanged)
5. User B: `prepare(200)` → leaf 1 (appended to same tree), balance += 100 ETH
6. `toRemote()` → sends new root (nonce 2) + 100 ETH
7. Remote: receives nonce 2 → updates inbox (nonce 2 > nonce 1)
8. User A: claim on remote with nonce 1 root — **still valid** if inbox still has nonce 1 root
   Wait — inbox.root was overwritten by nonce 2. Can User A still claim?
   User A's leaf is at index 0 in the tree. Nonce 2's root covers indices 0 AND 1.
   So User A can claim against nonce 2's root using a proof that covers both leaves. ✓
**Result: Correct.** Tree is append-only. Later roots include all previous leaves.

### Sequence 5: Out-of-order CCIP nonces
1. Nonce 1 sent (root1, 50 ETH), nonce 2 sent (root2, 100 ETH)
2. Nonce 2 arrives first → inbox.nonce = 2, inbox.root = root2
3. Nonce 1 arrives → `1 > 2`? → false → **rejected**
4. Claims only in root1 (but not root2) are lost
5. Users must emergency exit on source chain for root1-only claims
**Result: Documented and accepted behavior.** Non-sequential delivery is a known CCIP limitation.

### Sequence 6: Rounding/accumulation across many prepares
1. 1000 users each call `prepare(1 token, ...)` → 1000 leaves, balance += sum of cash outs
2. `toRemote()` → sends root covering all 1000 leaves
3. All 1000 users claim on remote → each gets their exact amount
**Result: Correct.** No accumulator drift. Each leaf stores exact amounts. Merkle tree is deterministic.

**Phase 5 Result: No vulnerabilities found via adversarial sequence testing.**
