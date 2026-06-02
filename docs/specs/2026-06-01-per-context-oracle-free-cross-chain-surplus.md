# Per-context, oracle-free cross-chain surplus

- **Repo:** `nana-suckers-v6` (with consumer changes in `rev-net/core-v6` and a touchpoint in `nana-core-v6`)
- **Status:** IMPLEMENTED (sucker + registry); consumer wiring is a follow-up PR
- **Date:** 2026-06-01
- **Supersedes:** the ETH-collapse cross-chain surplus snapshot and the `JBTriangularPriceFeed` requirement it created

> **Reconciliation note.** This spec has been reconciled to the implemented design. The design evolved after the first draft: the cross-chain *transport* is now oracle-free (the source sends raw, un-valued per-context surplus/balance — no source-side ETH collapse, no asymmetric feed swallow), and valuation moved to a normal **read-time** step in the registry, exactly mirroring how the local terminal store values surplus. "Oracle-free" now scopes to the transport/snapshot, not "no oracle anywhere." The `src` and its 426 tests are green.

---

## 1. Summary

Cross-chain revnet cash-outs and loans valued a project's remote-chain surplus through a price oracle baked into the *snapshot transport*: the source chain collapsed its whole multi-token surplus into a single **ETH** scalar, and the destination chain converted that ETH figure into the reclaim token's currency via `JBPrices` inside the sucker. That source-side collapse plus an asymmetric on-receive feed swallow was the source of an entire class of fragility — a missing/stale/mis-registered feed silently reported the remote surplus as **zero** while the remote token supply (which needs no feed) stayed in the denominator, under-pricing every cross-chain reclaim by up to ~50%.

This spec removes the oracle from the cross-chain *transport* entirely, and re-introduces valuation only as an ordinary **local read-time** step. The source carries surplus and balance **per accounting context in each context's native decimals** (no valuation on send, no currency on the wire). The destination sucker is a **raw data carrier**: it rebuilds an enumerable per-currency context set, keying each context by the *authoritative* local accounting-context currency of the token it resolves to, and stores raw amounts — it holds **no prices**. The **registry** holds `IJBPrices` and values those raw contexts at read time, *identically to how the terminal store values local surplus*: a same-currency context is taken at **par via an identity short-circuit (no feed)**, and a cross-currency context is converted through `JBPrices.pricePerUnitOf`. A missing cross-currency feed reverts, and the registry's per-sucker `try/catch` swallows it — dropping just that sucker (bias-low/conservative), never under-pricing the whole project by keeping its supply while zeroing its surplus.

Because valuation is symmetric (the registry aggregates surplus and supply through the same per-sucker read) and same-currency reads never touch a feed, single-accounting-context projects (e.g. NANA-ETH, and the USDC revnets DEFIFA/ART) get an **exact, feed-free** cross-chain reclaim rate. Cross-asset conversion, when a project wants it, still moves to the **value-movement layer** (the swap sucker), where it is a real, bounded, one-shot swap rather than a continuous oracle read in the reclaim rate.

---

## 2. Motivation

### 2.1 The incident
`JBTriangularPriceFeed` (the ETH↔USDC feed the destination needs to convert the ETH-denominated snapshot into USDC) was registered by the deploy but never emitted by the artifact build — so the production deploy reverted at the price-feed phase on every chain, and even with it present the conversion is fragile. The triangular feed exists *only* because the current design force-collapses a pure-USDC project's surplus through ETH (`USDC → ETH → USDC`), manufacturing a conversion that the per-context design never needs.

### 2.2 The structural asymmetry (the real bug class)
Reclaim/borrow = `f(effectiveSurplus, count, effectiveSupply, tax)`.
- `effectiveSupply` folds remote supply as a **raw token count** — no oracle, never fails.
- `effectiveSurplus` folds remote surplus as a **value** — needs a cross-currency conversion that can fail.

In the old design the on-receive conversion wrapped the oracle call in `try { … } catch {}`, so a missing feed left the converted surplus at `0`. Numerator collapses, denominator stays full → systematic under-pricing. This is independent of *which* pivot currency is chosen; it is inherent to having an oracle **in the snapshot transport** at all, where the swallow is asymmetric (surplus dropped, supply kept). The fix is not a better pivot but moving valuation out of the transport and back into a symmetric read-time step (§6).

### 2.3 Why "pick a better pivot" is not the fix
baseCurrency-denomination is better than ETH (reuses the project's own feeds, less basis, no synthetic triangular feed), but it still routes a same-asset relationship (`USDC_A → USDC_B`) through a conversion the bridge itself moves **1:1**. Any feed used there can disagree with the bridge's own par movement and is arbitrageable against the bridge. The correct move is to **stop pricing the same-asset leg** and **stop pricing cross-asset legs in the rate path at all**.

---

## 3. Goals / non-goals

**Goals**
- G1. No price oracle in the cross-chain *transport* (the snapshot the source sends and the sucker stores). Valuation is a normal local read-time step in the registry.
- G2. Exact, feed-free cross-chain reclaim/borrow for single-accounting-context projects (no feed consulted at all via the identity short-circuit).
- G3. Safe-by-construction (only ever *under*-credit remote backing) for every project — a missing cross-currency feed drops a sucker, never over-credits.
- G4. Symmetric numerator/denominator handling — surplus and supply flow through the same per-sucker read, so a dropped sucker drops both; never "drop remote surplus but keep remote supply."
- G5. Retire `JBTriangularPriceFeed` (and the deploy's registration of it) for matched-context projects — the same-currency identity short-circuit replaces the synthetic ETH pivot. (The triangular feed is retired in the consumer follow-up PR.)

**Non-goals**
- N1. Valuing cross-asset remote backing inside the rate (that is the swap sucker's job; see §7.6).
- N2. Un-archiving / shipping `JBSwapCCIPSucker` (separate, size-constrained milestone; this spec only defines how it plugs in).
- N3. Changing the bonding curve (`JBCashOuts.cashOutFrom`) — it remains single-currency; per-context aggregation collapses to the reclaim currency *before* it.

---

## 4. Background — the superseded architecture (what created the bug)

Data path (send): `prepare(token)` → `toRemote(token)` → `_sendRoot(token)` → `_buildSnapshotAndSend` → `JBSuckerLib.buildSnapshotMessage` → bridge `_sendRootOverAMB`. The send pipeline shape is unchanged; only what the snapshot *carries* changed.

The superseded design valued surplus **inside the transport**, in three places that together created the asymmetry:

- **Snapshot computation (send, OLD):** `JBSuckerLib` collapsed the project's whole multi-context surplus to a single **ETH** scalar — the surplus loop called `terminal.currentSurplusOf(decimals=18, currency=JBCurrencyIds.ETH)` (terminal valuates per-context→ETH internally) and the balance loop read raw `STORE().balanceOf(...)` then ETH-valued it. The result was stamped as `sourceCurrency: ETH`, `sourceDecimals: 18`, plus scalar `sourceSurplus`/`sourceBalance`. **This source-side collapse is what manufactured the synthetic `USDC → ETH → USDC` conversion** and the `JBTriangularPriceFeed` need.
- **Wire struct (OLD):** `JBMessageRoot` carried a flat single-currency aggregate quartet — `sourceCurrency`, `sourceDecimals`, `sourceSurplus`, `sourceBalance` — alongside `sourceTotalSupply`/`sourceTimestamp` and the per-lane `token`/`amount`/`remoteRoot`/`version`.
- **Receive/store (OLD):** `fromRemote` overwrote a single shared `_peerChainSurplus`/`_peerChainBalance` (`JBDenominatedAmount`) and `peerChainTotalSupply`.
- **Expose (OLD):** the sucker exposed `peerChainSurplusValueOf` via a `convertPeerValue` helper that wrapped the destination oracle read in a `try/catch` — **the asymmetric swallow** (surplus → 0 on a missing feed, supply untouched).
- **Registry (OLD):** `remoteSurplusOf` summed per-chain converted values (oracle per chain) while `remoteTotalSupplyOf` summed raw supplies (feed-free), iterating **independently** — so a feed failure zeroed the numerator while the denominator stayed full.

The redesign below deletes the source-side collapse and the on-receive oracle entirely, makes the sucker a raw carrier, and moves a single *symmetric* valuation into the registry's read.

---

## 5. Design principles

1. **No oracle in the cross-chain transport.** The source sends raw, un-valued per-context amounts; the sucker stores raw amounts and holds no prices. There is no source-side ETH collapse and no on-receive feed read, so the asymmetric swallow is gone by construction.
2. **Read-time valuation in the registry, identical to local surplus valuation.** The registry holds `IJBPrices` and values a raw context into the requested currency exactly the way the terminal store values local surplus: adjust decimals, then `mulDiv(amount, 1e18, pricePerUnitOf(...))`. Because surplus and supply are read through the same per-sucker call, the valuation is **symmetric** — there is no path that drops surplus while keeping supply.
3. **Same-currency par via identity short-circuit.** When a context's currency already equals the requested currency, the conversion short-circuits to a pure decimals-adjust and consults **no feed**. A project may set a token's accounting-context currency to a well-known id (e.g. USD), not just the `uint32(uint160(token))` convention, so single-asset projects (NANA-ETH, DEFIFA/ART-USDC) are par-credited with zero feeds.
4. **Bias low.** Every uncertain knob under-credits remote backing. A missing cross-currency feed makes the registry's per-sucker read **revert**, which the registry's `try/catch` **swallows by dropping that whole sucker** — never over-credits. Over-counting → cross-chain over-draw (catastrophic); under-counting → under-pay (merely conservative). The clamp (`reclaim ≤ local surplus`) is a backstop, not the safety mechanism.
5. **Symmetric numerator/denominator.** Remote surplus and remote supply are read per sucker and deduped per peer chain by the same freshest-snapshot rule; a dropped/stale sucker contributes neither, never "drop surplus, keep supply."
6. **Consistency with the bridge.** Same-asset legs are valued exactly how the bridge moves them — at par (the identity short-circuit). Genuinely cross-asset backing is consolidated at the value-movement layer (the swap sucker, §7.6), not priced continuously in the rate.

---

## 6. The model

Let a reclaim/borrow be requested in a target currency `cX` and decimals `dX` (the consumer passes the reclaim context's own `currency`/`decimals`).

The source sends, per accounting context, the **raw** `{decimals, surplus, balance}` in that context's native units, plus the token it resolves to on the destination. The destination sucker rebuilds an enumerable set of `JBPeerChainContext { currency, decimals, surplus, balance }`, one entry per **local currency**, where `currency` is the *authoritative* accounting-context currency of the local token the source context resolved to (read once and cached as immutable). The registry then values, at read time, per sucker:

- **For each peer context:** `valued = adjustDecimals(amount, ctx.decimals → dX)`, and if `ctx.currency != cX`, `valued = mulDiv(valued, 1e18, PRICES.pricePerUnitOf(projectId, ctx.currency, cX, 18))`. If `ctx.currency == cX` (or `valued == 0`), the conversion **short-circuits to par — no feed**.
- **Sucker total** = Σ over that sucker's contexts. If any cross-currency feed is missing, the per-sucker read **reverts**, and the registry **drops the whole sucker** (so neither its surplus nor its supply contributes — symmetric, bias-low).
- **Aggregate** = Σ over peer chains, deduped (same-peer suckers collapse to the freshest snapshot).

Consequences:
- **Single-context project (NANA-ETH, DEFIFA/ART-USDC):** every remote context resolves to currency `cX`, so the whole snapshot is par-credited, **exact and feed-free**; remote supply is fully counted; no asymmetry possible.
- **Multi-context project:** each context is valued into `cX` at read time — same-currency at par, cross-currency through the project's own `JBPrices` feeds (the same feeds it already needs for local surplus). If a needed feed is missing, that sucker drops out wholesale (conservative under-credit), and genuinely cross-asset backing can be consolidated via the swap sucker (§7.6).

---

## 7. Detailed design

### 7.1 Wire format (`JBMessageRoot`)
The flat aggregate quartet is replaced with a per-context array; supply and freshness stay scalar. **No currency travels on the wire** — the destination derives the authoritative currency locally (§7.3), so a same-asset token at a different remote address still folds under the receiver's own currency.

```solidity
// src/structs/JBSourceContext.sol
struct JBSourceContext {
    bytes32 token;     // the source-local token this context was read from; resolved to a LOCAL token on receipt
    uint8   decimals;  // the context's native decimals (e.g. 18 ETH / 6 USDC)
    uint128 surplus;   // raw, un-valued surplus in this context's own units (uint128 SVM cap)
    uint128 balance;   // raw, un-valued balance in this context's own units (balance - surplus = payout-limit slice)
}

// src/structs/JBMessageRoot.sol
struct JBMessageRoot {
    uint8 version;                    // stays 1 — per-context is the INITIAL wire format (§7.7)
    bytes32 token;                    // unchanged: this lane's bridged token
    uint256 amount;                   // unchanged
    JBInboxTreeRoot remoteRoot;       // unchanged
    uint256 sourceTotalSupply;        // unchanged: project-wide, currency-agnostic
    JBSourceContext[] sourceContexts; // REPLACES sourceCurrency/sourceDecimals/sourceSurplus/sourceBalance
    uint256 sourceTimestamp;          // unchanged: single project-wide freshness key
}
```

Two design points baked into the struct:
- **`token` is the source-local token**, not pre-translated. The destination resolves it (token mapping → identity fallback) and derives the authoritative *local* currency itself; nothing on the wire is trusted as a currency.
- **`surplus`/`balance` are `uint128`** to match the leaf-amount cap for cross-VM (SVM/Solana) consumers.

Rationale for an **array carried on every message** (vs. repurposing the scalar fields per-lane token): every message already recomputes the full project-wide snapshot, so an array preserves the "every message refreshes the whole snapshot" cadence and avoids per-token staleness. The cost is a few extra context entries of calldata (small `N`). The encode/decode lives in `JBSuckerLib` to protect the sucker size budget (§7.8).

> Note: `sourceTotalSupply` stays a single project-wide scalar (`controller.totalTokenSupplyWithReservedTokensOf`). Supply is the revnet token, not attributable to an accounting context.

### 7.2 Send side (`JBSuckerLib`)
The ETH-aggregate build is replaced by a raw per-context build, all in the DELEGATECALL'd library to protect the sucker size budget:

- `_buildSourceContexts(directory, projectId, extraSlots)` loops `directory.terminalsOf` × `terminal.accountingContextsOf(projectId)` (both reads wrapped in `try`, so a misbehaving terminal can't brick the snapshot), and for each context calls `_readSourceContext` to produce one `JBSourceContext`:
  - **Surplus per context:** `terminal.currentSurplusOf({projectId, tokens: [ctx], decimals: ctx.decimals, currency: ctx.currency})` so it returns *this token's* surplus in its own units, **un-valued**, wrapped in `try` (a reverting terminal yields a zero-surplus context rather than failing the message).
  - **Balance per context:** the raw recorded balance in the context's own units.
  - **No prices.** The function takes no `IJBPrices` and performs no valuation — the source carries `{token, decimals, surplus, balance}` only.
- `_snapshotAccountsOf(directory, projectId)` returns `(localTotalSupply, JBSourceContext[])`, keeping the `controller.totalTokenSupplyWithReservedTokensOf` read for the scalar supply, and merges any data-hook adjustment contexts (below).
- `buildSnapshotMessage(...)` stamps `sourceContexts` (and `sourceTotalSupply`/`sourceTimestamp`) into `JBMessageRoot`; it carries **no `prices` param**.
- **Data-hook adjustment:** the peer-chain adjustment hook returns `(uint256 supplyDelta, JBSourceContext[] contexts)` — i.e. its ABI returns a per-context array directly, which `_snapshotAccountsOf` concatenates into the snapshot. (Resolved open decision: per-context return, not a synthetic ETH/18 context.)

### 7.3 Receive side (`JBSucker`) — the raw data carrier
- **Storage:** the single shared `_peerChainSurplus`/`_peerChainBalance` are replaced by an **enumerable** set, one entry per local currency, plus the existing scalars:
  ```solidity
  // src/structs/JBPeerChainContext.sol
  struct JBPeerChainContext { uint32 currency; uint8 decimals; uint128 surplus; uint128 balance; }
  JBPeerChainContext[] private _peerContexts;                  // one entry per distinct local currency
  mapping(address token => uint32 currency) private _cachedCurrencyOf; // immutable authoritative currency cache
  // peerChainTotalSupply and snapshotTimestamp stay single project-wide scalars.
  ```
- `fromRemote`: on `root.sourceTimestamp > snapshotTimestamp`, advance `snapshotTimestamp`, set `peerChainTotalSupply = root.sourceTotalSupply`, and **rebuild `_peerContexts` from scratch** (`delete _peerContexts`, then fold each `root.sourceContexts[i]`). Rebuild — not per-entry clearing — means a context that dropped out of a fresher snapshot is simply absent from the new set; no shrinking-map bookkeeping is needed.
  - **Resolution:** each source context's `token` resolves to a local token via `_localTokenForRemoteToken[ctx.token]` (the token mapping), falling back to identity `_toAddress(ctx.token)` for same-address tokens.
  - **Authoritative currency (not wire-trusted):** the local token's currency is read once via `_localCurrencyOf`, which low-level-staticcalls `DIRECTORY.primaryTerminalOf` then `terminal.accountingContextForTokenOf(projectId, token).currency`, each **guarded by a returndata-length check** so a missing/non-conforming directory or terminal can't brick the message (it just yields a fallback). A project may set this currency to a well-known id (e.g. USD), not only the `uint32(uint160(token))` convention. The authoritative result is **cached as immutable** (the accounting-context currency never changes); a not-yet-configured token falls back to the convention and is left **uncached** so a later snapshot re-reads it once the context exists.
  - **Fold/sum:** contexts resolving to the same local currency are summed (via a small `_saturatingAddU128`); the set is one entry per distinct currency. The scan is linear because the set is tiny.
- **View:** `peerChainContextsOf() returns (JBPeerChainContext[] contexts, uint256 chainId, uint256 snapshot)` exposes the raw set, the peer chain id, and the snapshot freshness key in one call. The sucker performs **no valuation and holds no prices** — pricing is entirely the registry's job (§7.4). A sibling `peerChainTotalSupplyValue()` returns `{value: peerChainTotalSupply, peerChainId, snapshotTimestamp}` so the registry can dedup supply by the same freshest-snapshot rule.

### 7.4 Valuation in the registry (`JBSuckerRegistry`)
The registry — not the sucker — holds `IJBPrices PRICES` (an immutable constructor arg) and is where raw peer contexts become a currency-valued number, **exactly as the terminal store values local surplus**.

- **Per-sucker, currency-valued reads** (registry self-call boundaries, so the aggregate can `try` them and skip a sucker whose feed is missing):
  - `remoteSurplusOf(address sucker, uint256 projectId, uint256 currency, uint256 decimals)` / `remoteBalanceOf(...)` call `sucker.peerChainContextsOf()`, then for each context add `_valued(amount, ctx.currency, ctx.decimals → currency, decimals)`. Each returns a `JBPeerChainValue { value, peerChainId, snapshotTimestamp }` so the aggregate gets the value, the chain id, and the freshness key in one call.
- **`_valued` mirrors the terminal store:** adjust decimals (`JBFixedPointNumber.adjustDecimals`), then convert currency as `mulDiv(value, 1e18, PRICES.pricePerUnitOf(projectId, fromCurrency, toCurrency, 18))`. Both steps **short-circuit on identity** (and the currency step also on a zero amount), so a **same-currency context consults no feed (par)**. A **missing cross-currency feed reverts** (fail-closed); the per-sucker `try/catch` in the aggregate **swallows it, dropping just that sucker** (bias-low).
- **Aggregates:** `totalRemoteSurplusOf(uint256 projectId, uint256 currency, uint256 decimals)` / `totalRemoteBalanceOf(...)` iterate the project's suckers, `try` each per-sucker read, and **dedup same-peer suckers by freshest snapshot** (`_recordPeerChainValue` → `_recordPeerValue`: active replaces deprecated; ties broken by larger value), then sum. `remoteTotalSupplyOf(uint256 projectId)` does the same dedup over the raw `peerChainTotalSupplyValue()` and sums — no currency, since supply is currency-agnostic.
- **Symmetry:** because supply and surplus flow through the *same* per-sucker dedup-and-sum, a sucker dropped on a missing feed contributes **neither** surplus nor supply — the asymmetry that under-priced cash-outs ~50% cannot recur.

### 7.4a Consume side (`REVLoans`, `REVOwner`, `JBOmnichainDeployer`) — follow-up PR
> The consumer wiring is a **separate follow-up PR**; the revnet contracts still call the prior per-sucker `remoteSurplusOf`/`remoteTotalSupplyOf` shape. When wired:
- `REVLoans._borrowableAmountFrom` and `REVOwner.beforeCashOutRecordedWith` call `SUCKER_REGISTRY.totalRemoteSurplusOf(projectId, currency, decimals)` + `remoteTotalSupplyOf(projectId)`, continuing to pass the reclaim context's own `context.surplus.currency` / `.decimals`. `JBOmnichainDeployer` reads the same aggregate where it needs cross-chain surplus.
- The final `JBCashOuts.cashOutFrom` is unchanged (single-currency, as required by N3); the local clamp (`reclaim ≤ local surplus`) is unchanged.
- **Multi-context behavior is automatic, not a fallback switch:** each context is valued into the reclaim currency at read time — same-currency at par, cross-currency through the project's own feeds, and a missing feed drops that sucker wholesale. Single-context projects (NANA-ETH, DEFIFA/ART) never hit a feed.

### 7.5 Safety layer (applies to every path)
- **Symmetric fail-closed** (§7.4): a sucker dropped on a missing feed contributes neither surplus nor supply, because both flow through the same per-sucker read and the same per-chain dedup.
- **Round-down:** `adjustDecimals` and `mulDiv` both round toward zero on the remote leg (bias low).
- **Freshness:** `sourceTimestamp = (block.timestamp << 128) | ++seq` is strict-monotonic and gates the whole snapshot rebuild, so a staler per-token message can't roll back shared surplus/balance/supply; the registry's per-chain dedup then prefers the freshest snapshot across same-peer suckers. (A wall-clock **staleness TTL** is *not* shipped — the monotonic gate plus freshest-snapshot dedup are the freshness mechanism; a TTL remains available as future hardening of the frozen-at-T risk if desired.)

### 7.6 Cross-asset — the swap sucker
Genuinely cross-asset backing (a project that wants surplus in asset Y to support reclaims in asset X, with no `JBPrices` feed it trusts for that pair) is **consolidated at the value-movement layer**, not continuously priced in the rate. A project arranges, via `JBSwapCCIPSucker` (`src/archive/JBSwapCCIPSucker.sol`), for the value to be **held/bridged as X** — a real swap at the bridge with TWAP-bounded, one-shot execution and an immutable per-nonce `JBConversionRate`. By the time it is surplus on the destination, it already resolves to currency `X` and folds in at par with no feed. Until that sucker is un-archived and shipped (its own size-constrained milestone — it sat at ~27 B EIP-170 margin), a cross-currency context whose feed is absent simply drops that sucker (safe under-credit). This spec defines the plug-in point (same-currency par consumption) but does **not** depend on the swap sucker for the live single-context cohort.

### 7.7 Versioning (pre-deploy — no migration)
**Nothing is deployed yet; this is a pre-deploy edit.** The per-context format is authored as the **initial** wire format, so `MESSAGE_VERSION` stays `1` — there is **no version bump, no dual-version decode, no coordinated redeploy, and no in-flight flush / native-token strand risk**. The `JBMessageRoot` ABI is simply defined in its per-context shape from the start, and the version equality gate (`JBSucker.sol:465-468`) is retained unchanged for any *future* (post-deploy) format change.
- The struct change is therefore a **plain source edit**, not a migration. The only discipline required is that every sucker implementation and both ends of every pair ship the same bytecode at deploy time (they will — single deploy).
- (For the record, were this ever attempted *after* a deployment, the heavy path would re-apply: a version mismatch strands a native-token message because `fromRemote` cannot revert-refund native (`:486-488`), forcing quiesce → flush all in-flight → redeploy at new CREATE2 addresses → re-map → resume. Out of scope while pre-deploy.)

### 7.8 EIP-170 budget
- Base `JBSucker` growth hits all four bridge implementations; the CCIP/Arbitrum suckers are the binding limiters.
- **The per-context build lives in `JBSuckerLib`** (the DELEGATECALL target that already hosts `buildSnapshotMessage`, merkle, CCIP encoding): `_buildSourceContexts`, `_readSourceContext`, `_snapshotAccountsOf`, and the data-hook adjustment merge. The receiver's `fromRemote` rebuild and `_localCurrencyOf` are thin enough to sit in `JBSucker`. **Pricing lives in `JBSuckerRegistry`** (not a bridge contract), so `IJBPrices` and `mulDiv` add no bytecode to the size-constrained suckers — the sucker is a raw carrier.
- The archived `JBSwapCCIPSucker` (~27 B margin pre-archive) cannot absorb base growth; un-archiving it is gated on its own size reduction and is out of scope here (N2).

---

## 8. Security / threat model

- **Invariant (conservation):** Σ over chains of reclaimable ≤ Σ backing. Identity-par + symmetric per-sucker drop + round-down make every deviation *under*-credit, so the invariant can only be slack, never violated by a feed event.
- **Invariant (fairness):** single-context projects reclaim at the exact global rate (par, feed-free via the identity short-circuit). Multi-context projects value cross-currency backing through their own `JBPrices` feeds at read time; a missing feed drops the sucker (under-credit, documented; swap-sucker remedy for cross-asset).
- **Trust anchor:** same-asset folding leans on the operator-set `JBTokenMapping` (immutable once the outbox has entries) and on the project's *authoritative* accounting-context currency read locally on receipt — the same trust the value-bridging and local surplus already rely on; no new trust surface. The currency is read locally and cached as immutable, never trusted from the wire.
- **Failure modes removed:** the source-side ETH collapse and the on-receive asymmetric feed swallow are gone — there is **no feed in the transport**, and valuation is a single symmetric read-time step that drops a whole sucker (both legs) on a missing feed rather than zeroing surplus while keeping supply.
- **Staticcall hardening:** `_localCurrencyOf` guards both the `primaryTerminalOf` and `accountingContextForTokenOf` reads with a returndata-length check, so a non-conforming or reverting terminal cannot brick a bridge message (it falls back to the convention currency).
- **Residual:** frozen-at-T staleness (mitigated by the strict-monotonic freshness gate + freshest-snapshot dedup; a TTL is available as future hardening, §7.5); multi-context cross-currency under-credit on a missing feed (safe, documented).
- **Griefing:** `sourceTimestamp` strict-monotonic gate (`(block.timestamp<<128)|++seq`) prevents snapshot rollback; the per-context rebuild inherits it unchanged.

---

## 9. Test plan
Port/extend the existing fork harness (`deploy-all-v6/test/fork`, `CrossChainArb*`, `USDCCrossChainSurplusFork` — note the latter must be updated off the retired triangular feed):
1. **Single-context exactness (no feed):** USDC revnet, local USDC surplus + remote USDC snapshot; assert reclaim/borrow reflects local + remote **with zero price feeds registered** (identity short-circuit), exact to wei (modulo decimals round-down).
2. **Identity / same-address:** NATIVE-context project; remote native surplus credited at par.
3. **Authoritative currency, not wire-trusted:** same-asset token at different remote addresses (USDC) and/or a project that set its context currency to USD; assert the receiver folds under its *own* derived currency, and a non-conforming terminal falls back to the convention without bricking the message.
4. **Symmetric drop on missing feed:** cross-currency context with no registered feed → assert the per-sucker read reverts and the registry's `try/catch` drops **both** that sucker's surplus and its supply; compare to local-only.
5. **Bias-low:** round-down direction verified at 6↔18 decimal boundaries; remote leg never rounds up.
6. **Read-time cross-currency:** project with USDC + ETH contexts, reclaim in USDC with remote ETH backing **and** a registered ETH/USD feed → assert the registry values it through `PRICES` exactly as local surplus; with the feed absent → assert the sucker drops out (conservative).
7. **Same-peer dedup:** two suckers to the same peer chain → assert the registry selects the freshest snapshot (active over deprecated) and does not double-count.
8. **Invariants:** extend `CrossChainArbInvariant` to assert global conservation holds for single-context projects with feeds entirely absent.
9. **Regression:** the deploy no longer registers `JBTriangularPriceFeed` (consumer follow-up PR); the `DeployArtifactCompletenessGap` test reflects the reduced artifact set.

## 10. Re-audit scope
- `nana-suckers-v6`: `JBSuckerLib` (send build: `_buildSourceContexts`/`_readSourceContext`/`_snapshotAccountsOf`/data-hook merge), `JBSucker` (storage layout, `fromRemote` rebuild, `_localCurrencyOf` staticcall guard + immutable cache, `peerChainContextsOf`/`peerChainTotalSupplyValue` views), `JBSuckerRegistry` (the read-time `_valued` + per-sucker `remoteSurplusOf`/`remoteBalanceOf`, the `try/catch` swallow, and the freshest-snapshot dedup in `totalRemote*`/`remoteTotalSupplyOf`), `JBMessageRoot`/`JBSourceContext`/`JBPeerChainContext`. Focus: the symmetric per-sucker drop, the authoritative-currency derivation, and the rebuild-on-fresher-snapshot.
- `rev-net/core-v6` (follow-up PR): `REVLoans._borrowableAmountFrom`, `REVOwner.beforeCashOutRecordedWith` rewired to `totalRemoteSurplusOf`; `JBOmnichainDeployer` cross-chain surplus read; retirement of `JBTriangularPriceFeed`.
- `nana-core-v6`: `JBTerminalStore._cashOutWithDataHook` consumption (read-only confirmation it stays single-currency).
- Deploy: removal of the triangular-feed registration for matched-context projects (in the consumer PR).

## 11. Resolved decisions
- D1. **Array-on-every-message** — every message rebuilds the whole per-context snapshot (preserves the existing refresh cadence; no per-token staleness).
- D2. **Read-time valuation in the registry** — no multi-context "fallback switch"; each context is valued into the reclaim currency via `JBPrices` (par via identity short-circuit, cross-currency via feed), and a missing feed drops the whole sucker. Cross-asset consolidation is the swap sucker's job.
- D3. **Per-context hook ABI** — `IJBPeerChainAdjustedAccounts.peerChainAdjustedAccountsOf` returns `(uint256 supply, JBSourceContext[] contexts)`, appended to the terminal contexts (no synthetic ETH/18 context).
- D4. **uint128 cap** on per-context `surplus`/`balance` (matches the leaf-amount cap for SVM/Solana consumers).
- D5. **Rebuild-not-clear** — `fromRemote` does `delete _peerContexts` then refolds, so a dropped context is simply absent from the new set; no shrinking-map bookkeeping.
- D6. **Prices live in the registry, not the sucker** — the sucker is a raw carrier (no `IJBPrices`), keeping bytecode off the size-constrained bridge contracts; the registry values at read time.
- D7. **Swallow per sucker on a missing feed** — the per-sucker read is a registry self-call boundary so the aggregate `try`s it and drops just that sucker (bias-low), never failing the whole view.

## 12. Change index
- Wire structs: `structs/JBSourceContext.sol` (`{bytes32 token; uint8 decimals; uint128 surplus; uint128 balance}`, no currency), `structs/JBPeerChainContext.sol` (`{uint32 currency; uint8 decimals; uint128 surplus; uint128 balance}`), `structs/JBMessageRoot.sol` (`JBSourceContext[] sourceContexts`); `MESSAGE_VERSION` stays `1`.
- Send: `JBSuckerLib.sol` `_buildSourceContexts`, `_readSourceContext`, `_snapshotAccountsOf`, `_peerChainAdjustedAccountsOf`, `buildSnapshotMessage` (no `prices` param).
- Receive: `JBSucker.sol` `_peerContexts` storage + `_cachedCurrencyOf`, `fromRemote` rebuild, `_localCurrencyOf` (guarded staticcalls + immutable cache), `peerChainContextsOf`, `peerChainTotalSupplyValue`, `_saturatingAddU128`.
- Valuation: `JBSuckerRegistry.sol` `PRICES` immutable, `_valued` (`adjustDecimals` + `mulDiv(amount,1e18,pricePerUnitOf)` with identity short-circuit), `remoteSurplusOf`/`remoteBalanceOf` (per-sucker self-call), `totalRemoteSurplusOf`/`totalRemoteBalanceOf`/`remoteTotalSupplyOf` (try/catch swallow + `_recordPeerChainValue` dedup).
- Consume (follow-up PR): `REVLoans.sol`, `REVOwner.sol`, `JBOmnichainDeployer`; retire `JBTriangularPriceFeed`.
- Size budget: send build in `JBSuckerLib`; pricing in `JBSuckerRegistry`; CCIP/Arbitrum suckers are the EIP-170 limiters.
