# Invariants of `nana-suckers-v6`

Scope: the cross-chain bridging primitives that move a Juicebox V6 project-token position from one chain to another — the `JBSucker` base contract, its chain-specific transports (`JBOptimismSucker` / `JBBaseSucker` / `JBArbitrumSucker` / `JBCCIPSucker`), and the `JBSuckerRegistry` that gates deployment and shared fees. The package on npm is `@bananapus/suckers-v6`. Archived (reference only — not compiled or deployed): `JBSwapCCIPSucker` (+ its swap libs/structs `JBSwapPoolLib` / `JBSwapLib` / `JBPendingSwap` / `JBConversionRate`) and `JBCeloSucker`; see `src/archive/`.

Trust model in one sentence: a **pair of suckers** lets a holder burn project tokens on the local chain into a Merkle-committed claim, ship the committing root + backing terminal-token value across an external AMB, and let any caller mint to the **leaf-encoded beneficiary** on the destination — front-run safe, double-spend safe, fee-bypass safe, and operator-driven only at the configuration boundary.

This file documents the invariants the **runtime contracts in this repo** enforce. It does not document downstream consumers (data hooks or distributors); those have their own invariants documents. Cross-chain economic divergence between projects (the arbitrage model) lives in the canonical `INVARIANTS.md` at `../INVARIANTS.md` Section D2.

---

## Section A — Guarantees to token holders bridging

## A.1 Prepare — burn local, commit to a leaf

- `prepare(projectTokenCount, beneficiary, minTokensReclaimed, token, metadata)` pulls the caller's project tokens, cashes them out at the **local** terminal rate via the project's primary terminal for `token`, and appends a leaf to the outbox tree (`JBSucker.sol:547-602`).
- Reverts on `projectTokenCount == 0` (`JBSucker_ZeroProjectTokenCount`) — closes a populated-nonce DoS at the source layer (this source-side guard also covered the archived swap-CCIP destination leg).
- Reverts on `beneficiary == bytes32(0)` — the remote chain mint would fail unrecoverably.
- Reverts when the token is not mapped (`enabled == false`) or the sucker is in `SENDING_DISABLED` / `DEPRECATED`.
- The reclaimed terminal-token amount is enforced by `_pullBackingAssets` to equal exactly the terminal's reported `reclaimedAmount` via balance-delta `assert` — guarantees no fee-on-transfer silent loss, and acts as an implicit reentrancy guard (a nested `prepare` would corrupt the delta).
- The leaf binds the full `(projectTokenCount, terminalTokenAmount, beneficiary, metadata, index)` tuple via `_buildTreeHash(...)` (`JBSucker.sol:1514-1538`). The `metadata` is opaque attribution payload that the sucker protocol never inspects — but it is *covered by the leaf hash*, so attribution data is authenticated against the origin commitment.
- Beneficiary type: `bytes32` for cross-VM compatibility. For EVM peers it is the EVM address left-padded; for SVM peers it is the full 32-byte pubkey.

## A.2 Permissionless relay — `toRemote`

- `toRemote(token)` is permissionless (`JBSucker.sol:646-700`). Anyone willing to pay the registry's `toRemoteFee` plus the bridge transport cost can ship the current outbox root + locked funds across the AMB.
- Reverts on emergency-hatched tokens; reverts in `SENDING_DISABLED` / `DEPRECATED`; reverts when nothing has changed since the last relay (`outbox.balance == 0 && tree.count == numberOfClaimsSent`).
- Fee payment is **best-effort**: a `try/catch` around the fee project's `terminal.pay(...)`. On failure the fee ETH is retained as **refundable caller credit** (not silently rebated to `transportPayment`), which is critical for zero-cost bridges (OP/Base/Arb L2→L1) that revert if any value is forwarded to the AMB call.
- `transportPayment = msg.value - toRemoteFee` is exactly what flows to `_sendRootOverAMB`. The implementation does not silently re-route ETH between accounts.

## A.3 Claim — mint to leaf beneficiary, never to caller

- `claim(JBClaim)` and `claim(JBClaim[])` are permissionless (`JBSucker.sol:291-335`).
- The minted project tokens and the `addToBalanceOf` deposit are credited to **`claimData.leaf.beneficiary`**, never to `msg.sender`. The caller pays gas; the beneficiary receives the position.
- `_validate(...)` enforces:
  - `index < 2^_TREE_DEPTH` (no out-of-range proofs),
  - `_executedFor[terminalToken].get(index) == false` (no double-claim — OZ BitMaps, one bit per leaf),
  - the leaf hash `keccak256(abi.encodePacked(projectTokenCount, terminalTokenAmount, beneficiary, metadata))` (via `_buildTreeHash`) verifies against the per-token inbox root.
- **Per-leaf hash defense (Section D, F-REF-D class).** After validation, `executedLeafHashOf[terminalToken][index] = leafHash` (`JBSucker.sol:151, 1346`). The bare executed bitmap proves "some leaf at index I was executed"; the stored hash proves *which* leaf — binding the index to the actual `(amount, beneficiary, metadata)` content. Downstream hooks whose address is the beneficiary (notably `JBReferralSplitHook.claimAndPush`) re-derive the leaf hash from caller-supplied claim data and reject any forged data — the naive bitmap-only check is **not** sufficient and is exploitable by a front-running attacker that pre-empts the legitimate `claim` with a self-serving leaf shape. See `jb-sucker-claim-front-run-defense` skill.

## A.4 Cross-chain message ingress — `fromRemote`

- `fromRemote(JBMessageRoot)` is auth-gated to the messenger (`JBSucker.sol:415-480`). Critically, it uses **raw `msg.sender`**, never `_msgSender()`, to authenticate the AMB (`JBSucker.sol:417-419`). This defeats ERC-2771 forwarder spoofing — a trusted forwarder cannot append a calldata suffix to impersonate the bridge messenger.
- `MESSAGE_VERSION` mismatches revert.
- Per-token inbox state advances on any **strictly-greater** `root.remoteRoot.nonce` (not strictly sequential). Stale nonces emit `StaleRootRejected` and return silently (intentional — reverting would lose bridged native ETH).
- The **project-wide snapshot** (`peerChainTotalSupply` plus the enumerable per-currency context set `_peerContexts`) advances only when `root.sourceTimestamp > snapshotTimestamp` — fresher source-timestamp wins, regardless of which token's message carried it. A fresher snapshot rebuilds the whole `_peerContexts` set, so contexts dropped by the new snapshot simply vanish. Each remote context resolves to its local token, whose authoritative accounting-context currency is read once from the terminal (`accountingContextForTokenOf(token).currency`) and cached; contexts within a snapshot are summed only when they match on **both currency and decimals**. Same-currency contexts that carry different decimals (including ones appended by `IJBPeerChainAdjustedAccounts` hooks) are kept as separate per-`(currency, decimals)` entries and decimals-adjusted independently at read time, so raw amounts on different scales are never summed across precisions. Stale per-token messages cannot roll back shared state.
- Roots are accepted in `DEPRECATED` state to prevent stranding tokens already sent before deprecation — outbound sends are blocked in `SENDING_DISABLED`/`DEPRECATED` so double-spend is impossible.
- Unmapped tokens are accepted (claims later fail at mapping lookup) — rejecting at ingress time would permanently lose bridged tokens for a token that becomes mappable later.

## A.5 Emergency hatch — local exit

- `exitThroughEmergencyHatch(JBClaim)` lets an outbox depositor reclaim their position on the origin chain after either (a) per-token `enableEmergencyHatchFor(...)` was called, or (b) the sucker reached `SENDING_DISABLED` / `DEPRECATED` (`JBSucker.sol:365-397`).
- `_validateForEmergencyExit` enforces:
  - emergency-exit state is active for the token,
  - the leaf has not been claimed remotely — gated by `outbox.numberOfClaimsSent`: if `numberOfClaimsSent != 0 && numberOfClaimsSent - 1 >= index`, exit reverts (`JBSucker.sol:1436`),
  - a **separate bitmap slot** keyed by `address(bytes20(keccak256(abi.encode(terminalToken))))` prevents double-emergency-exit (`JBSucker.sol:1445`),
  - the leaf is in the outbox tree (proof checked against `_computeOutboxRoot`).
- `_outboxOf[token].balance -= terminalTokenAmount` is decremented before the external mint/add-to-balance so the same leaf cannot double-exit via reentrancy.
- The emergency exit pays the **leaf beneficiary** (whoever the original `prepare` caller chose), not the `prepare` caller and not `msg.sender`. This is intentional: the depositor delegated their claim to the beneficiary at `prepare` time and the leaf does not store the depositor address.

## A.6 Retained-fee / refund recovery

- `claimRetainedToRemoteFee(beneficiary)` lets each caller pull their own retained `toRemoteFee` credits (`JBSucker.sol:855-871`).
- `claimRetainedTransportPaymentRefund(beneficiary)` lets each caller pull their own retained CCIP transport-payment refunds (`JBSucker.sol:875-891`).
- Both clear state **before** the ETH send (no reentrancy refund-doubling). Both reject `beneficiary == address(0)`. Both pull from a per-caller balance only — a caller can never claim another caller's retained credits.

## A.7 Cross-VM amount cap

- `_insertIntoTree` reverts if `projectTokenCount > type(uint128).max` or `terminalTokenAmount > type(uint128).max`. The cap is for SVM / Solana compatibility; EVM-only use is still bounded to ~3.4e38 wei per leaf, which is operationally unreachable.

---

## Section B — Guarantees to operators / project owners

## B.1 Token mapping is immutable once committed

- `mapToken(JBTokenMapping)` / `mapTokens(JBTokenMapping[])` require `JBPermissionIds.MAP_SUCKER_TOKEN` (`JBSucker.sol:488-526, 919-921`).
- Setting `remoteToken = bytes32(0)` **disables** a mapping. If the outbox has unsent leaves, a final root flush is sent (requires `msg.value` to cover transport).
- **Immutability rule:** once `_outboxOf[localToken].tree.count != 0` (first `prepare` happened), the mapping cannot be changed to a *different* non-zero remote token — only disabled. This is the operator-side load-bearing invariant for cross-chain accounting coherence.
- `_validateTokenMapping` enforces a per-bridge native-mapping policy:
  - OP / Arb (base class): `NATIVE_TOKEN` may only map to `NATIVE_TOKEN` or `bytes32(0)`.
  - CCIP: `NATIVE_TOKEN` may map to an arbitrary remote ERC-20 (the remote chain might denominate ETH as a wrapped token).
- All variants enforce `map.minGas >= MESSENGER_ERC20_MIN_GAS_LIMIT` so a too-low gas limit cannot strand bridged tokens.
- `mapTokens` refunds all `msg.value` not used by an actual final root send, including enable-only value,
  duplicate/no-op disable value, and integer-division dust.

## B.2 Deprecation has a 14-day delay

- `setDeprecation(uint40 timestamp)` requires `JBPermissionIds.SET_SUCKER_DEPRECATION` (`JBSucker.sol:608-634`).
- `timestamp` must be `0` (cancel) or `> block.timestamp + _maxMessagingDelay()` — i.e. at least **14 days** in the future (`_maxMessagingDelay()` returns `14 days` on every implementation).
- Only callable while sending is still enabled. Once the sucker enters `SENDING_DISABLED`, deprecation can no longer be adjusted — the wind-down is irrevocable.

## B.3 State machine

`JBSuckerState` is computed view-side from `deprecatedAfter` and `block.timestamp` (`JBSucker.sol:815-839`):

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

- `enableEmergencyHatchFor(tokens[])` requires `JBPermissionIds.SUCKER_SAFETY` (`JBSucker.sol:340-359`).
- Sets `enabled = false`, `emergencyHatch = true` for each token. **No mechanism re-enables** — recovery requires deploying a new sucker pair.
- This intentional irreversibility prevents an operator from re-opening a bridge that may have already had emergency exits drain the outbox accounting.

## B.5 Registry-gated deployment

- `JBSuckerRegistry.deploySuckersFor(projectId, salt, configurations[])` requires `JBPermissionIds.DEPLOY_SUCKERS` against the project owner (`JBSuckerRegistry.sol:516-584`).
- Every non-zero `peer` field additionally requires `JBPermissionIds.SET_SUCKER_PEER` (default `peer == bytes32(0)` uses the deterministic same-address peer; an explicit remote authority is treated as a separate elevation).
- Each `configuration.deployer` must be on the registry allowlist.
- The salt is mixed with `_msgSender()` (`keccak256(abi.encode(sender, salt))`) so the same project deploying from different EOAs on different chains gets different sucker addresses — the same-address peer assumption breaks deliberately rather than silently routing to a wrong peer.

---

## Section C — Per-contract operation inventory

## C.1 JBSucker — `src/JBSucker.sol` (1717 lines)

Base contract. All cross-chain variants inherit. ERC-2771–aware for app-layer calls; raw `msg.sender` for AMB ingress.

### Token holders (permissionless surface)

- **`prepare(uint256 projectTokenCount, bytes32 beneficiary, uint256 minTokensReclaimed, address token, bytes32 metadata)`** — `JBSucker.sol:547-602`. Pulls caller's project tokens, calls terminal's `cashOutTokensOf` with `cashOutTaxRate=0` (see Section D2 of the canonical doc for the arbitrage rationale), inserts an outbox leaf binding `(count, terminalTokenAmount, beneficiary, metadata)`.
  - **Invariant:** zero-count / zero-beneficiary rejected; token must be enabled; sucker must allow sending; balance-delta `assert` defeats fee-on-transfer and reentrancy.
  - **Cannot:** ship a leaf for a token the sender doesn't own; ship in `SENDING_DISABLED`; bypass `minTokensReclaimed`.

- **`claim(JBClaim calldata)` / `claim(JBClaim[] calldata)`** — `JBSucker.sol:291-335`. Verifies merkle proof against the per-token inbox root, sets bitmap, stores `executedLeafHashOf[token][index]`, then mints project tokens to `leaf.beneficiary` and adds terminal tokens to project balance.
  - **Invariant:** leaf hash binds `(projectTokenCount, terminalTokenAmount, beneficiary, metadata, index)`; bitmap prevents replay; **mint goes to leaf beneficiary, not caller**; downstream contracts can authenticate front-run via per-leaf hash.

- **`exitThroughEmergencyHatch(JBClaim calldata)`** — `JBSucker.sol:365-397`. Local exit for outbox depositors when emergency state is open for the token (per-token hatch OR global `SENDING_DISABLED`/`DEPRECATED`).
  - **Invariant:** `numberOfClaimsSent` guards against double-spend across chains; separate bitmap slot prevents double-emergency-exit; `outbox.balance` decremented before mint.

### Cross-chain ingress (AMB-only)

- **`fromRemote(JBMessageRoot calldata root) payable`** — `JBSucker.sol:415-480`. Only the messenger via `_isRemotePeer(msg.sender)`. Uses raw `msg.sender`, never `_msgSender()`.
  - **Invariant:** per-token inbox advances on strictly-greater nonce; project-wide snapshot advances on strictly-greater `sourceTimestamp`; stale nonces silently ignored (event-emitting); accepted even in `DEPRECATED`.

### Permissionless relay

- **`toRemote(address token) payable`** — `JBSucker.sol:646-700`. Ships outbox root + locked terminal-token funds across the bridge.
  - **Invariant:** registry fee paid best-effort (retained on failure for caller pull); `transportPayment` preserved as `msg.value - fee`; reverts on emergency-hatched tokens; reverts if nothing changed since last relay.

### Operator / permissioned configuration

- **`mapToken(JBTokenMapping calldata) payable`** / **`mapTokens(JBTokenMapping[] calldata) payable`** — `JBSucker.sol:488-526, 919-921`. `MAP_SUCKER_TOKEN` permission.
  - **Invariant:** mapping immutable to a different non-zero token once outbox has entries; disable triggers final root flush; per-bridge native-mapping policy enforced; min-gas floor enforced.

- **`enableEmergencyHatchFor(address[] calldata tokens)`** — `JBSucker.sol:340-359`. `SUCKER_SAFETY` permission.
  - **Invariant:** one-way; `enabled` and `emergencyHatch` set atomically per token.

- **`setDeprecation(uint40 timestamp)`** — `JBSucker.sol:608-634`. `SET_SUCKER_DEPRECATION` permission.
  - **Invariant:** 14-day delay floor; only callable while sending enabled; `timestamp == 0` cancels.

### Refund pulls (caller-only)

- **`claimRetainedToRemoteFee(address payable beneficiary)`** — `JBSucker.sol:855-871`. Pulls caller's retained fee credits.
- **`claimRetainedTransportPaymentRefund(address payable beneficiary)`** — `JBSucker.sol:875-891`. Pulls caller's retained CCIP refunds.
  - **Invariant:** clears state before sending; per-caller balance.

### Initialization (clone-factory only)

- **`initialize(uint256 initialProjectId)`** / **`initialize(uint256 localProjectId, bytes32 remotePeer)`** — `JBSucker.sol:895-913`. Single-shot per clone via OZ `Initializable`.
  - **Invariant:** records `deployer = msg.sender`; explicit `remotePeer == 0` uses deterministic same-address peer; non-zero requires `SET_SUCKER_PEER` upstream at the registry.

### Views

- `inboxOf(token)`, `outboxOf(token)`, `remoteTokenFor(token)`, `isMapped(token)`, `amountToAddToBalanceOf(token)`, `peer()`, `projectId()`, `state()`, `peerChainContextsOf()`, `peerChainTotalSupply` (public storage), `executedLeafHashOf(token, index)` (public storage), `snapshotTimestamp` (public storage), `peerChainId()` (virtual — overridden per chain), `supportsInterface(bytes4)`.
- `peerChainContextsOf()` returns `(JBPeerChainContext[] contexts, uint256 chainId, uint256 snapshot)` — the sucker's single **raw, oracle-free** peer-chain view, where `JBPeerChainContext{currency, decimals, surplus, balance}` carries the un-valued per-currency amounts. The sucker holds no prices/oracle reference; valuation happens at read time in the registry. **Invariant:** this is a pure projection of `_peerContexts` plus the snapshot freshness key — it introduces no new state.
- `peerChainTotalSupplyValue()` returns a `JBPeerChainValue{value, peerChainId, snapshotTimestamp}` so `JBSuckerRegistry` can read the raw token supply, peer chain ID, and snapshot freshness in one call. **Invariant:** `value` equals `peerChainTotalSupply` exactly — a pure projection that introduces no new state.

### `receive() external payable`

- Intentionally unrestricted (`JBSucker.sol:281`). Accepts ETH from the bridge contract, the wrapped-native unwrap path, terminal returns during `cashOutTokensOf`, and bridge-refund flows. Excess ETH simply becomes `amountToAddToBalanceOf(NATIVE_TOKEN)` and benefits the project.

## C.2 JBOptimismSucker — `src/JBOptimismSucker.sol`

OP-Stack transport. Used for Optimism mainnet and similarly-shaped chains.

- **`peerChainId()` view** — hardcoded `1 ↔ 10`, `11_155_111 ↔ 11_155_420` mapping (mainnet/sepolia symmetry).
- **`_isRemotePeer(address sender)`** — verifies `sender == OPMESSENGER && xDomainMessageSender == peer()` (`JBOptimismSucker.sol:82-84`).
- **`_sendRootOverAMB(...)`** — bridges ERC-20 via `OPBRIDGE.bridgeERC20To` (allowance granted, then revoked to zero); forwards root via `OPMESSENGER.sendMessage{value: nativeValue}` calling `JBSucker.fromRemote(root)` on peer. Reverts on non-zero `transportPayment` (OP bridge is zero-cost).

## C.3 JBBaseSucker — `src/JBBaseSucker.sol`

Thin OP-Stack subclass for Base. Overrides only `peerChainId()` (Base ↔ mainnet pair).

## C.4 [ARCHIVED] JBCeloSucker — `src/archive/JBCeloSucker.sol`

Archived (`src/archive/`, not compiled or deployed) — retained for reference.

OP-Stack-like transport on Celo. Adjusts `_addToBalance` and `_sendRootOverAMB` for Celo's native-token semantics. Overrides `_validateTokenMapping` to allow native↔ERC-20 mappings (Celo's native is CELO, not ETH).

## C.5 JBArbitrumSucker — `src/JBArbitrumSucker.sol`

Arbitrum transport. Splits behavior by `LAYER == L1 | L2`.

- **`peerChainId()`** — `1 ↔ 42161`, `11_155_111 ↔ 421_614`.
- **`_isRemotePeer(address sender)`** — L1: `sender == ARBINBOX.bridge() && peer == IOutbox(bridge.activeOutbox()).l2ToL1Sender()`. L2: `sender == AddressAliasHelper.applyL1ToL2Alias(peer)` (`JBArbitrumSucker.sol:100-113`).
- **`_sendRootOverAMB(...)`** — L1→L2 via `_toL2` (creates two retryable tickets: one for the ERC-20 token bridge, one for the root message — these are redeemed *independently* on L2 with no ordering guarantee; `_addToBalance` defends via `amountToAddToBalanceOf` balance check). L2→L1 via `_toL1` using `ArbSys.sendTxToL1`. L2→L1 is zero-cost (reverts on non-zero `transportPayment`); L1→L2 requires `transportPayment > 0` for retryable tickets.

## C.6 JBCCIPSucker — `src/JBCCIPSucker.sol`

Chainlink CCIP transport. Adds inbound `ccipReceive`.

- **`peerChainId()`** — returns `REMOTE_CHAIN_ID` set at construction.
- **`getRouter()`** view — returns `CCIP_ROUTER` address.
- **`ccipReceive(Client.Any2EVMMessage)`** — `JBCCIPSucker.sol:160-230`. Only the immutable `CCIP_ROUTER` (raw `msg.sender` check). Verifies decoded `origin == _peerAddress()` and `sourceChainSelector == REMOTE_CHAIN_SELECTOR`. Discriminates message type via `JBCCIPLib.decodeTypedMessage`; only `_CCIP_MSG_TYPE_ROOT` accepted.
  - **Delivered-amount invariants** (`JBCCIPSucker.sol:190-216`): `destTokenAmounts.length <= 1`; if length 0 then `root.amount == 0`; if length 1 then `delivered.token` equals the local mapped token for ERC-20 roots or the router-reported wrapped-native token for native roots, and `delivered.amount >= root.amount`. These bind the advertised root to the actually-bridged tokens — a compromised peer that ships an inflated root cannot mint unbacked project tokens.
  - Native-token roots are unwrapped only after the delivered token is confirmed to be the router's wrapped-native token.
  - Forwards to `this.fromRemote(root)` after delivery validation.
- **`_sendRootOverAMB(...)`** — supports two fee modes: native-ETH (`transportPayment > 0`) or LINK pulled from `_msgSender()` (`transportPayment == 0`, for chains like Tempo with no meaningful native). Failed refunds retained as caller credit via `_retainTransportPaymentRefund`.
- **`_isRemotePeer(address)`** — returns `sender == address(this)` because `ccipReceive` (not the AMB callback) is the authoritative ingress point.
- **`_validateTokenMapping(...)`** — removes the OP/Arb native-only restriction; still enforces `minGas >= MESSENGER_ERC20_MIN_GAS_LIMIT`.

## C.7 [ARCHIVED] JBSwapCCIPSucker — `src/archive/JBSwapCCIPSucker.sol`

Archived (`src/archive/`, not compiled or deployed) — retained for reference.

CCIP variant that swaps the bridged token into the locally-required token (e.g. bridge USDC, swap to ETH on the destination).

- Overrides **`claim(JBClaim)`** — `src/archive/JBSwapCCIPSucker.sol:530-537`. Blocks claims while `_retrySwapLocked || _ccipReceiveSwapLocked`; sets transient `_currentClaimLeafIndex` so the overridden `_addToBalance` looks up the correct nonce-indexed conversion rate.
- Overrides **`_addToBalance(...)`** — scales the source-denominated leaf amount to local-denomination via `_conversionRateOf[token][nonce]`. Reverts if there is a `pendingSwapOf[token][nonce]` (failed swap awaiting retry).
- **`ccipReceive(Client.Any2EVMMessage)`** — extends the CCIP validation with: zero-leaf batches **record nothing** in `_batchStartOf` / `_batchEndOf` / `_populatedNonceByIndex` (closes the destination-side leg of the populated-nonce DoS — paired with the source-side `prepare(0)` revert in `JBSucker`); successful-but-zero-output swaps route to `pendingSwapOf` for `retrySwap`.
- **`retrySwap(address localToken, uint64 nonce)`** — permissionless. Locks `_retrySwapLocked` (blocks concurrent claims), re-runs the swap via `_executeSwapOrRevert`, populates the conversion rate so claims can proceed.
- **`uniswapV3SwapCallback(...)`** / **`unlockCallback(bytes)`** — verified V3/V4 pool callbacks for the swap path.
- **`executeSwapExternal(...)`** — self-callable internal helper exposed for the swap routing.

## C.8 JBSuckerRegistry — `src/JBSuckerRegistry.sol`

Ownable registry. Tracks per-project sucker inventory + deployer allowlist + shared `toRemoteFee`.

### Owner (governance)

- **`allowSuckerDeployer(address)` / `allowSuckerDeployers(address[])`** — `JBSuckerRegistry.sol:481-505`. `onlyOwner`. Adds a deployer to the allowlist.
- **`removeSuckerDeployer(address)`** — `JBSuckerRegistry.sol:622-625`. `onlyOwner`. Removes a deployer; existing suckers it deployed remain registered.
- **`setToRemoteFee(uint256 fee)`** — `JBSuckerRegistry.sol:612-617`. `onlyOwner`. Capped at `MAX_TO_REMOTE_FEE`.

### Per-project permissioned

- **`deploySuckersFor(uint256 projectId, bytes32 salt, JBSuckerDeployerConfig[] calldata configurations)`** — `JBSuckerRegistry.sol:516-584`. `DEPLOY_SUCKERS` against the project owner; non-default `peer` also requires `SET_SUCKER_PEER`.
  - **Invariant:** salt mixed with `_msgSender()`; deployer must be on allowlist; sucker recorded as `_SUCKER_EXISTS`; initial token mappings applied via `sucker.mapTokens(configuration.mappings)`.

### Permissionless

- **`removeDeprecatedSucker(uint256 projectId, address sucker)`** — `JBSuckerRegistry.sol:591-607`. Anyone after the sucker enters `DEPRECATED` state. Marks `_SUCKER_DEPRECATED` so it's excluded from `suckersOf` / `suckerPairsOf` listings, **but** retains mint permission (`isSuckerOf` still returns true) so pending claims can fulfill.

### Views

- `allSuckersOf(projectId)` — active + deprecated.
- `suckersOf(projectId)` — active only.
- `suckerPairsOf(projectId)` — active suckers with their `peerChainId`.
- `isSuckerOf(projectId, addr)` — true for both active and deprecated entries.
- The registry holds `IJBPrices PRICES` and does the valuation, exactly as the terminal store values local surplus. Per-sucker `remoteBalanceOf(sucker, projectId, currency, decimals)` / `remoteSurplusOf(sucker, projectId, currency, decimals)` value one sucker's raw contexts into the requested currency. Each context is decimals-adjusted, then a context whose currency already equals the requested currency is taken at **par via an identity short-circuit** (no feed consulted), while a cross-currency context is valued through `PRICES.pricePerUnitOf(projectId, fromCurrency, toCurrency, 18)`. A missing cross-currency feed reverts, and the per-sucker `try/catch` in the aggregate swallows that revert — dropping just that sucker (bias-low / conservative, the safe direction).
- `totalRemoteBalanceOf(projectId, currency, decimals)` / `totalRemoteSurplusOf(projectId, currency, decimals)` / `remoteTotalSupplyOf(projectId)` — **aggregate views with explicit failure semantics**:
  - `totalRemoteBalanceOf` / `totalRemoteSurplusOf` value each sucker via the per-sucker `remoteBalanceOf` / `remoteSurplusOf` self-call; `remoteTotalSupplyOf` reads the raw token supply via the sucker's `peerChainTotalSupplyValue` (unchanged).
  - `try/catch` around each sucker; failing peers (including a missing cross-currency feed) are silently skipped (fail-open for liveness, bias-low).
  - A sucker that reports a zero peer chain ID (after a successful read) reverts the whole aggregate, matching deploy-time validation.
  - Multiple active suckers targeting the same peer chain are **deduped by freshest accepted snapshot timestamp** (each sucker caches the *entire* remote chain's state; SUM would double-count).
  - MAX is only a same-freshness tie-breaker.
  - Deprecated suckers are used only as a fallback when no active sucker answers for that peer chain.
  - **These are estimates, not settlement data** — consumers must not treat them as authoritative.

---

## Section D — Cross-cutting invariants

1. **Per-leaf executed-hash defense.** `executedLeafHashOf[token][index]` stores the keccak256 of the leaf content after `_validate` succeeds. Downstream beneficiary contracts (notably `JBReferralSplitHook`) re-derive the hash via `abi.encodePacked(projectTokenCount, terminalTokenAmount, beneficiary, metadata)` (same shape as `_buildTreeHash`) and authenticate that a front-runner did not pre-empt their claim with a different leaf shape. The naive "just check the executed bitmap" defense is **insufficient**; see `jb-sucker-claim-front-run-defense` skill.

2. **AMB ingress uses raw `msg.sender`.** `fromRemote` (`JBSucker.sol:415-480`) and `ccipReceive` (`JBCCIPSucker.sol:160-230`) **never** use `_msgSender()` for caller authentication. ERC-2771 forwarder spoofing is structurally impossible.

3. **Snapshot freshness key.** `peerChainTotalSupply` and the per-currency context set `_peerContexts` are gated by `snapshotTimestamp` (strictly greater source-timestamp wins, regardless of which token's message carried it; a fresher snapshot rebuilds the whole context set). Per-token inbox roots are gated by per-token nonce (strictly greater). Two independent gates — neither can roll the other back.

4. **OZ BitMaps `_executedFor`** — one bit per leaf per token. Claim path uses key `terminalToken`; emergency-exit path uses key `address(bytes20(keccak256(abi.encode(terminalToken))))`. The two paths are slot-disjoint, but both are append-only (`set` only, never cleared).

5. **uint128 amount cap.** `_insertIntoTree` reverts if `projectTokenCount` or `terminalTokenAmount` exceeds `type(uint128).max`. SVM-compat constraint.

6. **Conservation of project supply across chains.** For an asset operated through suckers, `total project token supply ≈ Σ local_supply_per_chain + Σ outbox.balance_per_chain (in flight)`. The protocol does not reconstruct this on-chain; data hooks aggregate `peerChainTotalSupply` snapshots from each sucker to drive cross-chain cashout/borrow math.

7. **Outbox accounting invariants** (tested in `test/unit/invariants.t.sol`):
   - `outbox.balance == totalInserted - totalEmergencyExited - totalSent`.
   - `outbox.balance <= address(this).balance` for the token.
   - `numberOfClaimsSent <= tree.count`.
   - `MerkleLib.Tree.count` is append-only.
   - Inbox nonce monotonically non-decreasing.

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

- **Default same-address peer (`peer == address(0)` ⇒ `_toBytes32(address(this))`)** assumes deterministic cross-chain deployment via the same deployer + same salt. The registry's salt mixing with `_msgSender()` makes this property a deliberate user-controlled invariant — different EOAs deploying on different chains will get different sucker addresses and the default-peer symmetry will not hold. `SET_SUCKER_PEER` exists for the case where an explicit non-default peer is needed.

- **Controller must exist on the destination chain.** `_handleClaim` calls `controllerOf(projectId).mintTokensOf(...)`. If the destination project / controller does not exist, claims permanently revert. This is a deployment hazard, not an invariant a contract can enforce.

---

## Section F — Key code references

- Per-leaf hash store (front-run defense): `src/JBSucker.sol:151` (mapping), `src/JBSucker.sol:1346` (write).
- Leaf hash construction: `src/JBSucker.sol:1514-1538` (`_buildTreeHash`).
- Raw `msg.sender` for AMB: `src/JBSucker.sol:417-419` (`fromRemote`), `src/JBCCIPSucker.sol:161-164` (`ccipReceive`).
- Inbox nonce gate: `src/JBSucker.sol:447-460`.
- Snapshot freshness gate: `src/JBSucker.sol:466-479`.
- State machine: `src/JBSucker.sol:815-839`.
- 14-day deprecation delay: `src/JBSucker.sol:608-634`, `_maxMessagingDelay()` `src/JBSucker.sol:1162`.
- Emergency hatch (per-token, one-way): `src/JBSucker.sol:340-359`.
- Emergency exit validation: `src/JBSucker.sol:1407-1468`.
- Outbox immutability rule (mapping can disable, not remap): `src/JBSucker.sol:_mapToken` at `src/JBSucker.sol:1076-`.
- `toRemote` best-effort fee + retention: `src/JBSucker.sol:646-700`.
- `prepare` zero-count revert (DoS defense source side): `src/JBSucker.sol:561-562`.
- CCIP delivered-amount check: `src/JBCCIPSucker.sol:182-216`.
- Outbox uint128 cap: `src/JBSucker.sol:_insertIntoTree` at `src/JBSucker.sol:1016-1058`.
- Registry deployment auth + salt mixing: `src/JBSuckerRegistry.sol:516-584`.
- Registry aggregate-view dedup logic: `src/JBSuckerRegistry.sol:213-365`.

For the cross-chain economic-divergence (arbitrage) model that frames *why* sucker `prepare` uses `cashOutTaxRate=0` and the normal cashout path uses the aggregated rate, see Section D2 of `../INVARIANTS.md`.

For audit / risk register treatment of bridge-specific failure modes, see `RISKS.md` in this repo. For change-management posture and Safe-controlled surfaces, see `ADMINISTRATION.md`.
