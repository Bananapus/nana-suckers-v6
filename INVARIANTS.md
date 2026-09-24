# Invariants of `nana-suckers-v6`

Scope: the cross-chain bridging primitives that move a Juicebox V6 project-token position from one chain to another — the `JBSucker` base contract, its chain-specific transports (`JBOptimismSucker` / `JBBaseSucker` / `JBArbitrumSucker` / `JBCCIPSucker`), and the `JBSuckerRegistry` that gates deployment, owner-gated token mappings, and shared fees. The package on npm is `@bananapus/suckers-v6`. Archived (reference only — not compiled or deployed): `JBSwapCCIPSucker` (+ its swap libs/structs `JBSwapPoolLib` / `JBSwapLib` / `JBPendingSwap` / `JBConversionRate`) and `JBCeloSucker`; see `src/archive/`.

Trust model in one sentence: a **pair of suckers** lets a holder burn project tokens on the local chain into a Merkle-committed claim, ship the committing root + backing terminal-token value across an external AMB, and let any caller mint to the **leaf-encoded beneficiary** on the destination — front-run safe, double-spend safe, fee-bypass safe, and operator-driven only at the configuration boundary; accounting (supply / surplus / balance) additionally propagates as a **per-source-chain gossip bundle** across the whole project's sucker mesh, so a hub-and-spoke topology (L2s bridged only through mainnet) shares every chain's accounting without a direct sucker between every pair.

This file documents the invariants the **runtime contracts in this repo** enforce. It does not document downstream consumers (data hooks or distributors); those have their own invariants documents. Cross-chain economic divergence between projects (the arbitrage model) lives in the canonical `INVARIANTS.md` at `../INVARIANTS.md` Section D2.

---

## Section A — Guarantees to token holders bridging

## A.1 Prepare — burn local, commit to a leaf

- `prepare(projectTokenCount, beneficiary, minTokensReclaimed, token, metadata)` pulls the caller's project tokens, cashes them out at the **local** terminal rate via the project's primary terminal for `token`, and appends a leaf to the outbox tree (`JBSucker.sol:683-738`).
- Reverts on `projectTokenCount == 0` (`JBSucker_ZeroProjectTokenCount`) — closes a populated-nonce DoS at the source layer (this source-side guard also covered the archived swap-CCIP destination leg).
- Reverts on `beneficiary == bytes32(0)` — the remote chain mint would fail unrecoverably.
- Reverts when the token is not mapped (`enabled == false`) or the sucker is in `SENDING_DISABLED` / `DEPRECATED`.
- The reclaimed terminal-token amount is enforced by `_pullBackingAssets` to equal exactly the terminal's reported `reclaimedAmount` via balance-delta `assert` — guarantees no fee-on-transfer silent loss, and acts as an implicit reentrancy guard (a nested `prepare` would corrupt the delta).
- The leaf hash `_buildTreeHash(...)` (`JBSucker.sol:1841-1861`) covers `(projectTokenCount, terminalTokenAmount, beneficiary, metadata)`, and the Merkle path binds that hash to the leaf's `index`. The `metadata` is opaque attribution payload that the sucker protocol never inspects — but it is *covered by the leaf hash*, so attribution data is authenticated against the origin commitment.
- Beneficiary type: `bytes32` for cross-VM compatibility. For EVM peers it is the EVM address left-padded; for SVM peers it is the full 32-byte pubkey.

## A.2 Permissionless relay — `toRemote`

- `toRemote(token)` is permissionless (`JBSucker.sol:804-858`). Anyone willing to pay the registry's `toRemoteFee` plus the bridge transport cost can ship the current outbox root + locked funds across the AMB.
- Reverts on emergency-hatched tokens; reverts in `SENDING_DISABLED` / `DEPRECATED`; reverts when nothing has changed since the last relay (`outbox.balance == 0 && tree.count == numberOfClaimsSent`).
- Fee payment is **best-effort**: a `try/catch` around the fee project's `terminal.pay(...)`. On failure the fee ETH is retained as **refundable caller credit** (not silently rebated to `transportPayment`), which is critical for zero-cost bridges (OP/Base/Arb L2→L1) that revert if any value is forwarded to the AMB call.
- `transportPayment = msg.value - toRemoteFee` is exactly what flows to `_sendRootOverAMB`. The implementation does not silently re-route ETH between accounts.
- `syncAccountingData()` is also permissionless, but it sends only the accounting gossip bundle — this chain's own record plus every peer-chain record the project knows (gathered through the registry), each stamped with its origin chain's freshness key and excluding the destination chain. It pays no registry `toRemoteFee`, allows retrying unchanged accounting data, and forwards `msg.value` only as bridge transport payment. A plain `toRemote` root send carries the same bundle alongside its root, so a root relay also propagates accounting.

## A.3 Claim — mint to leaf beneficiary, never to caller

- `claim(JBClaim)` and `claim(JBClaim[])` are permissionless (`JBSucker.sol:1078-1109`, `JBSucker.sol:408-423`).
- The minted project tokens and the `addToBalanceOf` deposit are credited to **`claimData.leaf.beneficiary`**, never to `msg.sender`. The caller pays gas; the beneficiary receives the position.
- `_validate(...)` enforces:
  - `index < 2^_TREE_DEPTH` (no out-of-range proofs),
  - `_executedFor[terminalToken].get(index) == false` (no double-claim — OZ BitMaps, one bit per leaf),
  - the leaf hash `keccak256(abi.encodePacked(projectTokenCount, terminalTokenAmount, beneficiary, metadata))` (via `_buildTreeHash`) verifies against the token's latest inbox root or one of its `_INBOX_ROOT_RING_SIZE` (4) retained recent inbox roots (`_selectRetainedInboxRoot`).
- **Per-leaf hash defense (Section D, F-REF-D class).** After validation, `executedLeafHashOf[terminalToken][index] = leafHash` (`JBSucker.sol:230, 1684`). The bare executed bitmap proves "some leaf at index I was executed"; the stored hash proves *which* leaf — binding the index to the actual `(amount, beneficiary, metadata)` content. Downstream hooks whose address is the beneficiary (notably `JBReferralSplitHook.claimAndPush`) re-derive the leaf hash from caller-supplied claim data and reject any forged data — the naive bitmap-only check is **not** sufficient and is exploitable by a front-running attacker that pre-empts the legitimate `claim` with a self-serving leaf shape. See `jb-sucker-claim-front-run-defense` skill.

## A.4 Cross-chain message ingress — `fromRemote` and `fromRemoteAccounting`

- `fromRemote(JBMessageRoot)` is auth-gated to the messenger (`JBSucker.sol:543-602`). Critically, it uses **raw `msg.sender`**, never `_msgSender()`, to authenticate the AMB (`JBSucker.sol:548-550`). This defeats ERC-2771 forwarder spoofing — a trusted forwarder cannot append a calldata suffix to impersonate the bridge messenger.
- `MESSAGE_VERSION` mismatches revert.
- Per-token inbox state advances on any **strictly-greater** `root.remoteRoot.nonce` (not strictly sequential). Stale nonces emit `StaleRootRejected` and return silently (intentional — reverting would lose bridged native ETH).
- `fromRemoteAccounting(JBAccountingSnapshot)` is auth-gated to the same messenger path and applies the same message-version gate, but it has no token-local root, amount, or inbox state to update — it carries only the accounting gossip bundle.
- **Both** ingress paths carry the same gossip bundle: `fromRemote(JBMessageRoot)` and `fromRemoteAccounting(JBAccountingSnapshot)` each pass `accounts` (a `JBChainAccounting[]`) into `_storeAccountingBundle`, which stores each record per source chain.
- The **per-source-chain accounting store** (`peerChainTotalSupplyOf[chainId]` plus the per-chain raw context set `_peerContextsOf[chainId]`, gated by `snapshotTimestampOf[chainId]`) advances per chain only when that record's `sourceTimestamp > snapshotTimestampOf[chainId]` — fresher source-timestamp wins for that chain, regardless of whether the record arrived with a root or through `fromRemoteAccounting`. A record describing the receiver's own chain (`block.chainid`) or chain 0 is dropped. A fresher record rebuilds that chain's raw context set, so contexts dropped by the new record simply vanish. Contexts are stored **un-valued** (each keeps its source amount and decimals), but their token keys are localized at **store time**: `_storeChainAccounting` re-keys a context whose token matches this sucker's remote-to-local reservation (`_localTokenForRemoteToken`) to the mapped local token, and an unmapped token key stays as received. `peerChainAccountsOf()` therefore returns these localized keys. Each stored key resolves to a local currency at **read time** in `JBSuckerLib.foldPeerContexts` — there is no per-token currency cache. Contexts are summed only when they match on **both currency and decimals**, and this fold runs **per source chain**. Same-currency contexts that carry different decimals (including ones appended by `IJBPeerChainAdjustedAccounts` hooks) are kept as separate per-`(currency, decimals)` entries and decimals-adjusted independently at read time, so raw amounts on different scales are never summed across precisions. Optional data-hook peer adjustments are read through `staticcall` and defensively decoded; reverting, non-supporting, or malformed successful returns contribute no extra supply or contexts. Stale records cannot roll back the chain they describe.
- Roots are accepted in `DEPRECATED` state to prevent stranding tokens already sent before deprecation — outbound sends are blocked in `SENDING_DISABLED`/`DEPRECATED` so double-spend is impossible.
- Unmapped tokens are accepted (claims later fail at mapping lookup) — rejecting at ingress time would permanently lose bridged tokens for a token that becomes mappable later.

## A.5 Emergency hatch — local exit

- `exitThroughEmergencyHatch(JBClaim)` lets an outbox depositor reclaim their position on the origin chain after either (a) per-token `enableEmergencyHatchFor(...)` was called, or (b) the sucker reached `SENDING_DISABLED` / `DEPRECATED` (`JBSucker.sol:493-525`).
- `_validateForEmergencyExit` enforces:
  - emergency-exit state is active for the token,
  - the leaf has not been claimed remotely — gated by `outbox.numberOfClaimsSent`: if `numberOfClaimsSent != 0 && numberOfClaimsSent - 1 >= index`, exit reverts (`JBSucker.sol:1785`),
  - a **separate bitmap slot** keyed by `address(bytes20(keccak256(abi.encode(terminalToken))))` prevents double-emergency-exit (`JBSucker.sol:1794`),
  - the leaf is in the outbox tree (proof checked against `_computeOutboxRoot`).
- `_outboxOf[token].balance -= terminalTokenAmount` is decremented before the external mint/add-to-balance so the same leaf cannot double-exit via reentrancy.
- The emergency exit pays the **leaf beneficiary** (whoever the original `prepare` caller chose), not the `prepare` caller and not `msg.sender`. This is intentional: the depositor delegated their claim to the beneficiary at `prepare` time and the leaf does not store the depositor address.

## A.6 Retained-fee / refund recovery

- `claimRetainedToRemoteFee(beneficiary)` lets each caller pull their own retained `toRemoteFee` credits (`JBSucker.sol:427-443`).
- `claimRetainedTransportPaymentRefund(beneficiary)` lets each caller pull their own retained CCIP transport-payment refunds (`JBSucker.sol:447-463`).
- Both clear state **before** the ETH send (no reentrancy refund-doubling). Both reject `beneficiary == address(0)`. Both pull from a per-caller balance only — a caller can never claim another caller's retained credits.

## A.7 Cross-VM amount cap

- `_insertIntoTree` reverts if `projectTokenCount > type(uint128).max` or `terminalTokenAmount > type(uint128).max`. The cap is for SVM / Solana compatibility; EVM-only use is still bounded to ~3.4e38 wei per leaf, which is operationally unreachable.

---

## Section B — Guarantees to operators / project owners

## B.1 Token mapping is immutable once committed

- `mapToken(JBTokenMapping)` / `mapTokens(JBTokenMapping[])` require `JBPermissionIds.MAP_SUCKER_TOKEN` (`JBSucker.sol:1127-1132, 633-663`).
- Setting `remoteToken = bytes32(0)` **disables** a mapping. If the outbox has unsent leaves, a final root flush is sent (requires `msg.value` to cover transport).
- **Immutability rule:** once `_outboxOf[localToken].tree.count != 0` (first `prepare` happened), the mapping cannot be changed to a *different* non-zero remote token — only disabled. This is the operator-side load-bearing invariant for cross-chain accounting coherence.
- Owner-gated mappings are checked before they can be chosen: `_mapToken` calls `JBSuckerRegistry.requireTokenMappingAllowed(localToken, peerChainId(), remoteToken)` for the sucker's own peer chain.
- Different-address local/remote mappings and native/native mappings must be approved by the registry owner for the exact `(localToken, remoteChainId, remoteToken)` route. Non-native same-address mappings and `remoteToken == bytes32(0)` disablements pass without owner approval.
- Route-scoping is load-bearing: an approval for mainnet USDC to Optimism USDC cannot authorize a mainnet-to-Arbitrum sucker mapping to Arbitrum USDC.
- `_validateTokenMapping` enforces a per-bridge native-mapping policy:
  - OP / Arb (base class): `NATIVE_TOKEN` may only map to `NATIVE_TOKEN` or `bytes32(0)`.
  - CCIP: `NATIVE_TOKEN` may map to an arbitrary remote ERC-20 (the remote chain might denominate ETH as a wrapped token).
- All variants enforce `map.minGas >= MESSENGER_ERC20_MIN_GAS_LIMIT` for ERC-20 mappings so a too-low gas limit cannot strand bridged tokens. CCIP also enforces it for `NATIVE_TOKEN` mappings (it wraps native before bridging); the OP / Arb base check returns before the floor for `NATIVE_TOKEN` mappings.
- `mapToken` and `mapTokens` refund all `msg.value` not used by an actual final root send, including enable-only value,
  duplicate/no-op disable value, and integer-division dust.

## B.2 Deprecation has a 14-day delay

- `setDeprecation(uint40 timestamp)` requires `JBPermissionIds.SET_SUCKER_DEPRECATION` (`JBSucker.sol:744-770`).
- `timestamp` must be `0` (cancel) or `> block.timestamp + _maxMessagingDelay()` — i.e. at least **14 days** in the future (`_maxMessagingDelay()` returns `14 days` on every implementation).
- Only callable while sending is still enabled. Once the sucker enters `SENDING_DISABLED`, deprecation can no longer be adjusted — the wind-down is irrevocable.

## B.3 State machine

`JBSuckerState` is computed view-side from `deprecatedAfter` and `block.timestamp` (`JBSucker.sol:1037-1061`):

```
ENABLED              deprecatedAfter == 0
DEPRECATION_PENDING  0 < block.timestamp < deprecatedAfter - 14 days
SENDING_DISABLED     deprecatedAfter - 14 days <= block.timestamp < deprecatedAfter
DEPRECATED           block.timestamp >= deprecatedAfter
```

- `prepare` / `toRemote` revert in `SENDING_DISABLED` and `DEPRECATED`.
- `fromRemote` accepts in **every** state (including `DEPRECATED`) so in-flight messages cannot strand.
- `exitThroughEmergencyHatch` works in `SENDING_DISABLED` and `DEPRECATED` globally, or per-token after `enableEmergencyHatchFor`.

## B.4 Emergency hatch is one-way

- `enableEmergencyHatchFor(tokens[])` requires `JBPermissionIds.SUCKER_SAFETY` (`JBSucker.sol:468-487`).
- Sets `enabled = false`, `emergencyHatch = true` for each token. **No mechanism re-enables** — recovery requires deploying a new sucker pair.
- This intentional irreversibility prevents an operator from re-opening a bridge that may have already had emergency exits drain the outbox accounting.

## B.5 Registry-gated deployment

- `JBSuckerRegistry.deploySuckersFor(projectId, salt, configurations[])` requires `JBPermissionIds.DEPLOY_SUCKERS` against the project owner (`JBSuckerRegistry.sol:1021-1089`).
- Every non-zero `peer` field, including one equal to the registry's own address, additionally requires `JBPermissionIds.SET_SUCKER_PEER`. Only `peer == bytes32(0)` (the deterministic same-address peer) is covered by `DEPLOY_SUCKERS` alone; an explicit remote authority is treated as a separate elevation.
- Each `configuration.deployer` must be on the registry allowlist.
- Initial mappings in `configuration.mappings` still pass through the registry's owner-gated token-pair allowlist. `DEPLOY_SUCKERS` bypasses the project's separate `MAP_SUCKER_TOKEN` permission for initial setup, not the registry-owner approval required for native/native or different-address routes.
- The salt is mixed with `_msgSender()` (`keccak256(abi.encode(sender, salt))`) so the same project deploying from different EOAs on different chains gets different sucker addresses — the same-address peer assumption breaks deliberately rather than silently routing to a wrong peer.

---

## Section C — Per-contract operation inventory

## C.1 JBSucker — `src/JBSucker.sol` (2105 lines)

Base contract. All cross-chain variants inherit. ERC-2771–aware for app-layer calls; raw `msg.sender` for AMB ingress.

### Token holders (permissionless surface)

- **`prepare(uint256 projectTokenCount, bytes32 beneficiary, uint256 minTokensReclaimed, address token, bytes32 metadata)`** — `JBSucker.sol:683-738`. Pulls caller's project tokens, calls the primary terminal's `cashOutTokensOf` with the sucker as holder (the sucker passes no tax rate; project data hooks such as `REVOwner` and `JBOmnichainDeployer` return `cashOutTaxRate = 0` for a registered sucker; see Section D2 of the canonical doc for the arbitrage rationale), inserts an outbox leaf binding `(count, terminalTokenAmount, beneficiary, metadata)`.
  - **Invariant:** zero-count / zero-beneficiary rejected; token must be enabled; sucker must allow sending; balance-delta `assert` defeats fee-on-transfer and reentrancy.
  - **Cannot:** ship a leaf for a token the sender doesn't own; ship in `SENDING_DISABLED`; bypass `minTokensReclaimed`.

- **`claim(JBClaim calldata)` / `claim(JBClaim[] calldata)`** — `JBSucker.sol:1078-1109`, `JBSucker.sol:408-423`. Verifies merkle proof against the token's latest inbox root or one of its retained recent inbox roots, sets bitmap, stores `executedLeafHashOf[token][index]`, then mints project tokens to `leaf.beneficiary` and adds terminal tokens to project balance.
  - **Invariant:** leaf hash binds `(projectTokenCount, terminalTokenAmount, beneficiary, metadata)` and the Merkle proof binds it to `index`; bitmap prevents replay; **mint goes to leaf beneficiary, not caller**; downstream contracts can authenticate front-run via per-leaf hash.

- **`exitThroughEmergencyHatch(JBClaim calldata)`** — `JBSucker.sol:493-525`. Local exit for outbox depositors when emergency state is open for the token (per-token hatch OR global `SENDING_DISABLED`/`DEPRECATED`).
  - **Invariant:** `numberOfClaimsSent` guards against double-spend across chains; separate bitmap slot prevents double-emergency-exit; `outbox.balance` decremented before mint.

### Cross-chain ingress (AMB-only)

- **`fromRemote(JBMessageRoot calldata root) payable`** — `JBSucker.fromRemote`. Only the messenger via `_isRemotePeer(msg.sender)`. Uses raw `msg.sender`, never `_msgSender()`.
  - **Invariant:** per-token inbox advances on strictly-greater nonce; the gossip bundle in `root.accounts` is stored per source chain via `_storeAccountingBundle`, each chain advancing on its own strictly-greater `sourceTimestamp` (records for `block.chainid` / chain 0 dropped); stale nonces silently ignored (event-emitting); accepted even in `DEPRECATED`.
- **`fromRemoteAccounting(JBAccountingSnapshot calldata snapshot)`** — only the messenger via `_isRemotePeer(msg.sender)`. Uses raw `msg.sender`, never `_msgSender()`.
  - **Invariant:** the gossip bundle in `snapshot.accounts` is stored per source chain via `_storeAccountingBundle`, each chain advancing on its own strictly-greater `sourceTimestamp` (records for `block.chainid` / chain 0 dropped); token-local inbox roots and claimable balances are unchanged.

### Permissionless relay

- **`toRemote(address token) payable`** — `JBSucker.sol:804-858`. Ships outbox root + locked terminal-token funds across the bridge.
  - **Invariant:** registry fee paid best-effort (retained on failure for caller pull); `transportPayment` preserved as `msg.value - fee`; reverts on emergency-hatched tokens; reverts if nothing changed since last relay.
- **`syncAccountingData() payable`** — ships only the accounting gossip bundle (this chain's record plus every peer-chain record the project knows, gathered via the registry, excluding the destination chain) across the bridge.
  - **Invariant:** no registry `toRemoteFee`; root/inbox state and `numberOfClaimsSent` unchanged, including on duplicate accounting bundles.

### Operator / permissioned configuration

- **`mapToken(JBTokenMapping calldata) payable`** / **`mapTokens(JBTokenMapping[] calldata) payable`** — `JBSucker.sol:1127-1132, 633-663`. `MAP_SUCKER_TOKEN` permission.
  - **Invariant:** mapping immutable to a different non-zero token once outbox has entries; disable triggers final root flush; per-bridge native-mapping policy enforced; min-gas floor enforced.

- **`enableEmergencyHatchFor(address[] calldata tokens)`** — `JBSucker.sol:468-487`. `SUCKER_SAFETY` permission.
  - **Invariant:** one-way; `enabled` and `emergencyHatch` set atomically per token.

- **`setDeprecation(uint40 timestamp)`** — `JBSucker.sol:744-770`. `SET_SUCKER_DEPRECATION` permission.
  - **Invariant:** 14-day delay floor; only callable while sending enabled; `timestamp == 0` cancels.

### Refund pulls (caller-only)

- **`claimRetainedToRemoteFee(address payable beneficiary)`** — `JBSucker.sol:427-443`. Pulls caller's retained fee credits.
- **`claimRetainedTransportPaymentRefund(address payable beneficiary)`** — `JBSucker.sol:447-463`. Pulls caller's retained CCIP refunds.
  - **Invariant:** clears state before sending; per-caller balance.

### Initialization (clone-factory only)

- **`initialize(uint256 initialProjectId)`** / **`initialize(uint256 localProjectId, bytes32 remotePeer)`** — `JBSucker.sol:1113-1122`. Single-shot per clone via OZ `Initializable`.
  - **Invariant:** records `deployer = _msgSender()`; explicit `remotePeer == 0` uses deterministic same-address peer; non-zero requires `SET_SUCKER_PEER` upstream at the registry.

### Views

- `inboxOf(token)`, `outboxOf(token)`, `remoteTokenFor(token)`, `isMapped(token)`, `amountToAddToBalanceOf(token)`, `peer()`, `projectId()`, `state()`, `peerChainIds(bool includeVirtual)`, `peerChainContextsOf(uint256 chainId)`, `peerChainTotalSupplyOf(uint256 chainId)` (public mapping), `peerChainTotalSupplyValue(uint256 chainId)`, `peerChainAccountsOf()`, `executedLeafHashOf(token, index)` (public storage), `snapshotTimestampOf(uint256 chainId)` (public mapping), `peerChainId()` (virtual — overridden per chain), `supportsInterface(bytes4)`.
- `peerChainIds(bool includeVirtual)` returns the sucker's directly-connected peer chain, plus — when `includeVirtual` is true — every source chain it has heard about through gossip. **Invariant:** the directly-connected peer is always present when it is a real remote chain, so the registry can enumerate it as soon as the sucker is deployed; until the first record it is an empty sentinel (value 0, freshness 0) that the registry's value views skip, so a deprecated sucker's record keeps answering for that chain until the replacement syncs; the virtual set is a projection of `_peerChainIds` and introduces no new state. The registry aggregates the `includeVirtual: true` set.
- `peerChainContextsOf(uint256 chainId)` returns `(JBPeerChainContext[] contexts, uint256 snapshot)` — one source chain's **raw, oracle-free** peer-chain view, where `JBPeerChainContext{currency, decimals, surplus, balance}` carries the un-valued per-currency amounts resolved from that chain's raw stored contexts. The sucker holds no prices/oracle reference; valuation happens at read time in the registry. **Invariant:** this resolves `_peerContextsOf[chainId]` (un-valued; keyed by this sucker's local token where a remote-to-local reservation matched at store time, otherwise by the received token key) to local currencies and folds same-`(currency, decimals)` entries in `JBSuckerLib.foldPeerContexts`, pairing it with that chain's `snapshotTimestampOf[chainId]` freshness key — it introduces no new state.
- `peerChainTotalSupplyValue(uint256 chainId)` returns a `JBPeerChainValue{value, peerChainId, snapshotTimestamp}` so `JBSuckerRegistry` can read one chain's raw token supply, peer chain ID, and snapshot freshness in one call. **Invariant:** `value` equals `peerChainTotalSupplyOf(chainId)` exactly — a pure projection that introduces no new state.
- `peerChainAccountsOf()` returns the un-valued `JBChainAccounting[]` records this sucker holds for every known peer chain: source amounts and decimals as received, with each context's token key as stored (this sucker's local token where a remote-to-local reservation matched, otherwise the received key). **Invariant:** the registry reads this to gather a project's full cross-chain knowledge and re-gossip it; a pure projection of the per-chain store, introducing no new state.

### `receive() external payable`

- Intentionally unrestricted (`JBSucker.sol:390`). Accepts ETH from the bridge contract, the wrapped-native unwrap path, terminal returns during `cashOutTokensOf`, and bridge-refund flows. Excess ETH simply becomes `amountToAddToBalanceOf(NATIVE_TOKEN)` and benefits the project.

## C.2 JBOptimismSucker — `src/JBOptimismSucker.sol`

OP-Stack transport. Used for Optimism mainnet and similarly-shaped chains.

- **`peerChainId()` view** — hardcoded `1 ↔ 10`, `11_155_111 ↔ 11_155_420` mapping (mainnet/sepolia symmetry).
- **`_isRemotePeer(address sender)`** — verifies `sender == OPMESSENGER && xDomainMessageSender == peer()` (`JBOptimismSucker.sol:82-84`).
- **`_sendRootOverAMB(...)`** — bridges ERC-20 via `OPBRIDGE.bridgeERC20To` (allowance granted, then revoked to zero); forwards root via `OPMESSENGER.sendMessage{value: nativeValue}` calling `JBSucker.fromRemote(root)` on peer. Reverts on non-zero `transportPayment` (OP bridge is zero-cost).
- **`_sendAccountingSnapshotOverAMB(...)`** — forwards an OP messenger call to `JBSucker.fromRemoteAccounting(snapshot)` with no token bridge and rejects non-zero `transportPayment`.

## C.3 JBBaseSucker — `src/JBBaseSucker.sol`

Thin OP-Stack subclass for Base. Overrides only `peerChainId()` (Base ↔ mainnet pair).

## C.4 [ARCHIVED] JBCeloSucker — `src/archive/JBCeloSucker.sol`

Archived (`src/archive/`, not compiled or deployed) — retained for reference.

OP-Stack-like transport on Celo. Adjusts `_addToBalance` and `_sendRootOverAMB` for Celo's native-token semantics. Overrides `_validateTokenMapping` to allow native↔ERC-20 mappings (Celo's native is CELO, not ETH).

## C.5 JBArbitrumSucker — `src/JBArbitrumSucker.sol`

Arbitrum transport. Splits behavior by `LAYER == L1 | L2`.

- **`peerChainId()`** — `1 ↔ 42161`, `11_155_111 ↔ 421_614`.
- **`_isRemotePeer(address sender)`** — L1: `sender == ARBINBOX.bridge() && peer == IOutbox(bridge.activeOutbox()).l2ToL1Sender()`. L2: `sender == AddressAliasHelper.applyL1ToL2Alias(peer)` (`JBArbitrumSucker.sol:377-390`).
- **`_sendRootOverAMB(...)`** — L1→L2 via `_toL2` (creates two retryable tickets: one for the ERC-20 token bridge, one for the root message — these are redeemed *independently* on L2 with no ordering guarantee; `_addToBalance` defends via `amountToAddToBalanceOf` balance check). L2→L1 via `_toL1` using `ArbSys.sendTxToL1`. L2→L1 ERC-20 sends approve the local token to the gateway selected by the remote L1 token, matching the router transfer key. L2→L1 is zero-cost (reverts on non-zero `transportPayment`); L1→L2 requires `transportPayment > 0` for retryable tickets.
- **`_sendAccountingSnapshotOverAMB(...)`** — sends only `JBSucker.fromRemoteAccounting(snapshot)`. L1→L2 still requires retryable-ticket payment; L2→L1 remains zero-cost and rejects non-zero `transportPayment`.

## C.6 JBCCIPSucker — `src/JBCCIPSucker.sol`

Chainlink CCIP transport. Adds inbound `ccipReceive`.

- **`peerChainId()`** — returns `REMOTE_CHAIN_ID` set at construction.
- **`getRouter()`** view — returns `CCIP_ROUTER` address.
- **`ccipReceive(Client.Any2EVMMessage)`** — `JBCCIPSucker.sol:140-220`. Only the immutable `CCIP_ROUTER` (raw `msg.sender` check). Verifies decoded `origin == _peerAddress()` and `sourceChainSelector == REMOTE_CHAIN_SELECTOR`. Discriminates the `abi.encode(uint8 messageType, bytes payload)` message data directly; accepts `_CCIP_MSG_TYPE_ROOT` and `_CCIP_MSG_TYPE_ACCOUNTING`.
  - **Delivered-amount invariants** (`JBCCIPSucker.sol:170-195`): `destTokenAmounts.length <= 1`; if length 0 then `root.amount == 0`; if length 1 then `delivered.token` equals the local mapped token for ERC-20 roots or the router-reported wrapped-native token for native roots, and `delivered.amount >= root.amount`. These bind the advertised root to the actually-bridged tokens — a compromised peer that ships an inflated root cannot mint unbacked project tokens.
  - Native-token roots are unwrapped only after the delivered token is confirmed to be the router's wrapped-native token.
  - Forwards to `this.fromRemote(root)` after delivery validation.
- **Accounting-message invariants:** `_CCIP_MSG_TYPE_ACCOUNTING` must deliver zero token amounts and forwards to `this.fromRemoteAccounting(snapshot)`, so a malformed accounting delivery cannot create claim backing.
- **`_sendRootOverAMB(...)`** — supports two fee modes: native-ETH (`transportPayment > 0`) or LINK pulled from `_msgSender()` (`transportPayment == 0`, for chains like Tempo with no meaningful native). Failed refunds retained as caller credit via `_retainTransportPaymentRefund`.
- **`_sendAccountingSnapshotOverAMB(...)`** — uses the same native-ETH/LINK fee modes as root sends with an empty token-amount list and a typed accounting payload.
- **`_isRemotePeer(address)`** — returns `sender == address(this)` because `ccipReceive` (not the AMB callback) is the authoritative ingress point.
- **`_validateTokenMapping(...)`** — removes the OP/Arb native-only restriction; still enforces `minGas >= MESSENGER_ERC20_MIN_GAS_LIMIT`.

## C.7 [ARCHIVED] JBSwapCCIPSucker — `src/archive/JBSwapCCIPSucker.sol`

Archived (`src/archive/`, not compiled or deployed) — retained for reference.

CCIP variant that swaps the bridged token into the locally-required token (e.g. bridge USDC, swap to ETH on the destination).

- Overrides **`claim(JBClaim)`** — `src/archive/JBSwapCCIPSucker.sol:548-555`. Blocks claims while `_retrySwapLocked || _ccipReceiveSwapLocked`; sets transient `_currentClaimLeafIndex` so the overridden `_addToBalance` looks up the correct nonce-indexed conversion rate.
- Overrides **`_addToBalance(...)`** — scales the source-denominated leaf amount to local-denomination via `_conversionRateOf[token][nonce]`. Reverts if there is a `pendingSwapOf[token][nonce]` (failed swap awaiting retry).
- **`ccipReceive(Client.Any2EVMMessage)`** — extends the CCIP validation with: zero-leaf batches **record nothing** in `_batchStartOf` / `_batchEndOf` / `_populatedNonceByIndex` (closes the destination-side leg of the populated-nonce DoS — paired with the source-side `prepare(0)` revert in `JBSucker`); successful-but-zero-output swaps route to `pendingSwapOf` for `retrySwap`.
- **`retrySwap(address localToken, uint64 nonce)`** — permissionless. Locks `_retrySwapLocked` (blocks concurrent claims), re-runs the swap via `_executeSwapOrRevert`, populates the conversion rate so claims can proceed.
- **`uniswapV3SwapCallback(...)`** / **`unlockCallback(bytes)`** — verified V3/V4 pool callbacks for the swap path.
- **`executeSwapExternal(...)`** — self-callable internal helper exposed for the swap routing.

## C.8 JBSuckerRegistry — `src/JBSuckerRegistry.sol`

Ownable registry. Tracks per-project sucker inventory + deployer allowlist + owner-gated token-pair allowlist + shared `toRemoteFee`.

### Owner (governance)

- **`allowSuckerDeployer(address)` / `allowSuckerDeployers(address[])`** — `JBSuckerRegistry.sol:922-946`. `onlyOwner`. Adds a deployer to the allowlist.
- **`allowTokenMapping(address,uint256,bytes32)` / `allowTokenMappings(address[],uint256[],bytes32[])`** — owner-only. Adds route-scoped approvals for native/native or different-address local/remote mappings.
- **`removeTokenMapping(address,uint256,bytes32)` / `removeTokenMappings(address[],uint256[],bytes32[])`** — owner-only. Removes route-scoped token-mapping approvals; existing sucker mappings remain whatever they already are, but the pair can no longer be chosen again unless it passes without approval.
- **`removeSuckerDeployer(address)`** — `JBSuckerRegistry.sol:1117-1120`. `onlyOwner`. Removes a deployer; existing suckers it deployed remain registered.
- **`setToRemoteFee(uint256 fee)`** — `JBSuckerRegistry.sol:1187-1192`. `onlyOwner`. Capped at `MAX_TO_REMOTE_FEE`.

### Per-project permissioned

- **`deploySuckersFor(uint256 projectId, bytes32 salt, JBSuckerDeployerConfig[] calldata configurations)`** — `JBSuckerRegistry.sol:1021-1089`. `DEPLOY_SUCKERS` against the project owner; every non-zero `peer` (including the registry's own address) also requires `SET_SUCKER_PEER`.
  - **Invariant:** salt mixed with `_msgSender()`; deployer must be on allowlist; sucker recorded as `_SUCKER_EXISTS`; initial token mappings applied via `sucker.mapTokens(configuration.mappings)`.

### Permissionless

- **`removeDeprecatedSucker(uint256 projectId, address sucker)`** — `JBSuckerRegistry.sol:1096-1112`. Anyone after the sucker enters `DEPRECATED` state. Marks `_SUCKER_DEPRECATED` so it's excluded from `suckersOf` / `suckerPairsOf` listings, **but** retains mint permission (`isSuckerOf` still returns true) so pending claims can fulfill.

### Views

- `allSuckersOf(projectId)` — active + deprecated.
- `suckersOf(projectId)` — active only.
- `suckerPairsOf(projectId)` — active suckers with their `peerChainId`.
- `isSuckerOf(projectId, addr)` — true for both active and deprecated entries.
- `peerChainAccountsOf(uint256 projectId, uint256 exceptChainId)` gathers a project's full cross-chain knowledge — the only place a hub chain's per-peer suckers are visible together. A sucker building an outbound gossip bundle calls this and prepends its own local record. Records are deduped per source chain (freshest wins; an active sucker's record supersedes a deprecated one's), with the destination chain (`exceptChainId`) and the local chain excluded. Suckers and records that revert are silently skipped.
- `requireTokenMappingAllowed(localToken, remoteChainId, remoteToken)` enforces the token-pair allowlist used by suckers. Disabling a mapping (`remoteToken == bytes32(0)`) and non-native same-address mappings pass directly. Native/native mappings and different-address mappings require a stored owner approval for that exact route.
- The registry holds `IJBPrices PRICES` and does the valuation, exactly as the terminal store values local surplus. Aggregate views value one sucker's raw contexts for one source chain internally. Each context is decimals-adjusted, then a context whose currency already equals the requested currency is taken at **par via an identity short-circuit** (no feed consulted), while a cross-currency context is valued through `PRICES.pricePerUnitOf(projectId, fromCurrency, toCurrency, 18)`. A cross-currency price read that reverts (for example a missing feed) or returns zero is caught in `_tryValued`, and `_remoteValueOf` then reports that `(sucker, chain)` as unvalued — dropping just that one (sucker, chain) (bias-low / conservative, the safe direction).
- `totalRemoteBalanceOf(projectId, currency, decimals)` / `totalRemoteSurplusOf(projectId, currency, decimals)` / `remoteTotalSupplyOf(projectId)` keep the **same signatures** but now aggregate over **every (sucker, chain) pair** and dedup per source chain — **aggregate views with explicit failure semantics**:
  - `totalRemoteBalanceOf` / `totalRemoteSurplusOf` value each (sucker, chain) pair internally; `remoteTotalSupplyOf` reads each chain's raw token supply via the sucker's `peerChainTotalSupplyValue(chainId)`.
  - `try/catch` around each (sucker, chain); failing pairs (including a missing cross-currency feed) are silently skipped (fail-open for liveness, bias-low).
  - A sucker that reports a zero peer chain ID (after a successful read) reverts the whole aggregate, matching deploy-time validation.
  - Multiple (sucker, chain) pairs reporting the same source chain are **deduped per source chain by freshest accepted record timestamp** (each sucker caches the *entire* remote chain's state per source chain; SUM would double-count).
  - MAX is only a same-freshness tie-breaker.
  - Deprecated suckers are used only as a fallback when no active sucker answers for that source chain.
  - **These are estimates, not settlement data** — consumers must not treat them as authoritative.

---

## Section D — Cross-cutting invariants

1. **Per-leaf executed-hash defense.** `executedLeafHashOf[token][index]` stores the keccak256 of the leaf content after `_validate` succeeds. Downstream beneficiary contracts (notably `JBReferralSplitHook`) re-derive the hash via `abi.encodePacked(projectTokenCount, terminalTokenAmount, beneficiary, metadata)` (same shape as `_buildTreeHash`) and authenticate that a front-runner did not pre-empt their claim with a different leaf shape. The naive "just check the executed bitmap" defense is **insufficient**; see `jb-sucker-claim-front-run-defense` skill.

2. **AMB ingress uses raw `msg.sender`.** `fromRemote`, `fromRemoteAccounting`, and `ccipReceive` **never** use `_msgSender()` for caller authentication. ERC-2771 forwarder spoofing is structurally impossible.

3. **Per-source-chain freshness key.** `peerChainTotalSupplyOf[chainId]` and that chain's raw context set `_peerContextsOf[chainId]` are gated by `snapshotTimestampOf[chainId]` independently per source chain (strictly greater source-timestamp wins for that chain, regardless of whether the record arrived with a root or through `fromRemoteAccounting`; a fresher record rebuilds that chain's context set; records for `block.chainid` / chain 0 are dropped). Per-token inbox roots are gated by per-token nonce (strictly greater). Independent gates — neither chain nor the inbox can roll any other back.

4. **OZ BitMaps `_executedFor`** — one bit per leaf per token. Claim path uses key `terminalToken`; emergency-exit path uses key `address(bytes20(keccak256(abi.encode(terminalToken))))`. The two paths are slot-disjoint, but both are append-only (`set` only, never cleared).

5. **uint128 amount cap.** `_insertIntoTree` reverts if `projectTokenCount` or `terminalTokenAmount` exceeds `type(uint128).max`. SVM-compat constraint.

6. **Conservation of project supply across chains.** For an asset operated through suckers, `total project token supply ≈ Σ local_supply_per_chain + Σ outbox.balance_per_chain (in flight)`. The protocol does not reconstruct this on-chain; consumers read the per-source-chain `peerChainTotalSupplyOf[chainId]` records each sucker holds (deduped per chain by the registry's aggregate views) to drive cross-chain cashout/borrow math.

7. **Outbox accounting invariants** (tested in `test/unit/invariants.t.sol`):
   - `outbox.balance == totalInserted - totalEmergencyExited - totalSent`.
   - `outbox.balance <= address(this).balance` for the token.
   - `numberOfClaimsSent <= tree.count`.
   - `MerkleLib.Tree.count` is append-only.
   - Outbox nonce monotonically non-decreasing.

8. **Burn-on-strand vs park-and-retry is the consumer's call.** Whether bridged credit that lands on a chain with no recoverable settlement path is burned or deferred is decided by the **beneficiary** contract, not by the sucker.

9. **`receive()` is intentionally unrestricted** — bridge contracts, wrapped-native unwrap, and terminal returns all need to deliver ETH. Any excess simply increases `amountToAddToBalanceOf` and benefits the project.

10. **Fee retention isolates caller-paid ETH.** `retainedToRemoteFeeBalance` and `retainedTransportPaymentRefundBalance` are **excluded** from `amountToAddToBalanceOf(NATIVE_TOKEN)` — failed fees and CCIP refunds never silently become project-claimable.

11. **CCIP delivered-token and delivered-amount checks.** `JBCCIPSucker.ccipReceive` verifies `destTokenAmounts.length <= 1`, the delivered token identity (including router wrapped-native for native roots), and `delivered.amount >= root.amount`. A compromised peer cannot ship an inflated root that would let claims mint unbacked project tokens.

12. **`_buildTreeHash` ↔ `abi.encodePacked` equivalence.** The leaf hash construction is exactly `keccak256(abi.encodePacked(projectTokenCount, terminalTokenAmount, beneficiary, metadata))` — downstream contracts can re-derive it without a library import.

---

## Section E — Out-of-scope centralization caveats

- **`JBSuckerRegistry` is Ownable.** The owner can:
  - add/remove sucker deployers from the allowlist (controls who can deploy a sucker against the project);
  - set `toRemoteFee` up to `MAX_TO_REMOTE_FEE` (capped — the maximum harm is bounded);
  - **cannot** mint, freeze, or redirect funds in any individual sucker;
  - **cannot** un-map a token or close a sucker.
  Renouncing ownership freezes the fee permanently at its current value (a deliberate credible-commitment knob, not a bug).

- **`toRemoteFee` is paid into `FEE_PROJECT_ID`** (the protocol fee project, typically project 1), not the sucker's own project. Best-effort: failures retain ETH as caller-pull credit.

- **Per-revnet operators** with `MAP_SUCKER_TOKEN` / `SUCKER_SAFETY` / `SET_SUCKER_DEPRECATION` permissions can map tokens (subject to immutability), open the emergency hatch (one-way), and schedule deprecation (14-day delay). Their revnet, their problem.

- **Bridge counterparties** (Optimism `CrossDomainMessenger`, Arbitrum `Bridge`/`Outbox`/`ArbSys`, Chainlink CCIP `Router`) are immutable at sucker deploy time and trusted for message authenticity. A compromise of the AMB compromises every sucker that uses it. CCIP router cannot be rotated — Chainlink router rotation would brick the sucker.

- **Default same-address peer (`_peer == bytes32(0)` ⇒ `_toBytes32(address(this))`)** assumes deterministic cross-chain deployment via the same deployer + same salt. The registry's salt mixing with `_msgSender()` makes this property a deliberate user-controlled invariant — different EOAs deploying on different chains will get different sucker addresses and the default-peer symmetry will not hold. `deploySuckersFor` requires `SET_SUCKER_PEER` for every non-zero explicit peer, including the registry's own address; only `peer == bytes32(0)` needs `DEPLOY_SUCKERS` alone.

- **Controller must exist on the destination chain.** `_handleClaim` calls `controllerOf(projectId).mintTokensOf(...)`. If the destination project / controller does not exist, claims permanently revert. This is a deployment hazard, not an invariant a contract can enforce.

---

## Section F — Key code references

- Per-leaf hash store (front-run defense): `src/JBSucker.sol:230` (mapping), `src/JBSucker.sol:1684` (write).
- Leaf hash construction: `src/JBSucker.sol:1841-1861` (`_buildTreeHash`).
- Raw `msg.sender` for AMB: `src/JBSucker.sol` (`fromRemote`, `fromRemoteAccounting`), `src/JBCCIPSucker.sol` (`ccipReceive`).
- Inbox nonce gate: `src/JBSucker.sol:575-597`.
- Per-source-chain freshness gate and bundle storage: `JBSucker._storeChainAccounting` (per record) and `JBSucker._storeAccountingBundle` (per bundle), shared by `fromRemote` and `fromRemoteAccounting`.
- State machine: `src/JBSucker.sol:1037-1061`.
- 14-day deprecation delay: `src/JBSucker.sol:744-770`, `_maxMessagingDelay()` `src/JBSucker.sol:1895`.
- Emergency hatch (per-token, one-way): `src/JBSucker.sol:468-487`.
- Emergency exit validation: `src/JBSucker.sol:1756-1817` (`_validateForEmergencyExit`).
- Outbox immutability rule (mapping can disable, not remap): `JBSucker._mapToken` at `src/JBSucker.sol:1339-1344`.
- `toRemote` best-effort fee + retention: `src/JBSucker.sol:804-858`.
- `prepare` zero-count revert (DoS defense source side): `src/JBSucker.sol:697-699`.
- CCIP delivered-amount check: `src/JBCCIPSucker.sol:170-195`.
- Outbox uint128 cap: `src/JBSucker.sol:_insertIntoTree` at `src/JBSucker.sol:1242-1280`.
- Registry deployment auth + salt mixing: `src/JBSuckerRegistry.sol:1021-1089`.
- Registry aggregate-view dedup logic: `JBSuckerRegistry._recordPeerValue` (per-source-chain dedup across every (sucker, chain) pair), shared by `_aggregateRemoteValueOf` and `remoteTotalSupplyOf`.
- Registry gossip-bundle gather (hub forwards sibling-spoke records): `JBSuckerRegistry.peerChainAccountsOf`.
- Outbound gossip-bundle assembly: `JBSuckerLib.buildAccountingSnapshot` / `JBSuckerLib._buildGossipBundle`.
- Read-time raw-context currency resolution and fold: `JBSuckerLib.foldPeerContexts`.

For the cross-chain economic-divergence (arbitrage) model that frames *why* sucker `prepare` uses `cashOutTaxRate=0` and the normal cashout path uses the aggregated rate, see Section D2 of `../INVARIANTS.md`.

For audit / risk register treatment of bridge-specific failure modes, see `RISKS.md` in this repo. For change-management posture and Safe-controlled surfaces, see `ADMINISTRATION.md`.
