# Per-context, oracle-free cross-chain surplus

- **Repo:** `nana-suckers-v6` (with consumer changes in `rev-net/core-v6` and a touchpoint in `nana-core-v6`)
- **Status:** DRAFT for review + re-audit
- **Date:** 2026-06-01
- **Supersedes:** the ETH-collapse cross-chain surplus snapshot and the `JBTriangularPriceFeed` requirement it created

---

## 1. Summary

Cross-chain revnet cash-outs and loans value a project's remote-chain surplus through a price oracle today: the source chain collapses its whole multi-token surplus into a single **ETH** scalar, and the destination chain converts that ETH figure into the reclaim token's currency via `JBPrices`. That conversion is the source of an entire class of fragility — a missing/stale/mis-registered feed silently reports the remote surplus as **zero** while the remote token supply (which needs no feed) stays in the denominator, under-pricing every cross-chain reclaim by up to ~50%.

This spec removes the oracle from the cross-chain surplus path entirely. The source carries surplus **per accounting context in each context's native currency** (no valuation on send). The destination folds each remote context into its **same-asset local context at par** (1:1), then runs the *existing* local surplus valuation — so the only feeds ever consulted are the ones a project already needs for its own local surplus. Cross-asset conversion, when a project wants it, moves to the **value-movement layer** (the swap sucker), where it is a real, bounded, one-shot swap rather than a continuous oracle read in the reclaim rate.

For single-accounting-context projects (e.g. the USDC revnets DEFIFA/ART), this makes the cross-chain reclaim rate **exact and feed-free**. For multi-context projects it is conservative-and-safe by construction.

---

## 2. Motivation

### 2.1 The incident
`JBTriangularPriceFeed` (the ETH↔USDC feed the destination needs to convert the ETH-denominated snapshot into USDC) was registered by the deploy but never emitted by the artifact build — so the production deploy reverted at the price-feed phase on every chain, and even with it present the conversion is fragile. The triangular feed exists *only* because the current design force-collapses a pure-USDC project's surplus through ETH (`USDC → ETH → USDC`), manufacturing a conversion that the per-context design never needs.

### 2.2 The structural asymmetry (the real bug class)
Reclaim/borrow = `f(effectiveSurplus, count, effectiveSupply, tax)`.
- `effectiveSupply` folds remote supply as a **raw token count** — no oracle, never fails.
- `effectiveSurplus` folds remote surplus as a **value** — needs a cross-currency conversion that can fail.

`JBSuckerLib.convertPeerValue` (`src/libraries/JBSuckerLib.sol:206-216`) wraps the oracle call in `try { … } catch {}`, so a missing feed leaves the converted surplus at `0`. Numerator collapses, denominator stays full → systematic under-pricing. This is independent of *which* pivot currency is chosen; it is inherent to having an oracle in the rate path at all.

### 2.3 Why "pick a better pivot" is not the fix
baseCurrency-denomination is better than ETH (reuses the project's own feeds, less basis, no synthetic triangular feed), but it still routes a same-asset relationship (`USDC_A → USDC_B`) through a conversion the bridge itself moves **1:1**. Any feed used there can disagree with the bridge's own par movement and is arbitrageable against the bridge. The correct move is to **stop pricing the same-asset leg** and **stop pricing cross-asset legs in the rate path at all**.

---

## 3. Goals / non-goals

**Goals**
- G1. No price oracle in the cross-chain surplus/supply valuation path.
- G2. Exact, feed-free cross-chain reclaim/borrow for single-accounting-context projects.
- G3. Safe-by-construction (only ever *under*-credit remote backing) for every project.
- G4. Symmetric numerator/denominator handling — never "drop remote surplus but keep remote supply."
- G5. Retire `JBTriangularPriceFeed` (and the deploy's registration of it) for matched-context projects.

**Non-goals**
- N1. Valuing cross-asset remote backing inside the rate (that is the swap sucker's job; see §7.6).
- N2. Un-archiving / shipping `JBSwapCCIPSucker` (separate, size-constrained milestone; this spec only defines how it plugs in).
- N3. Changing the bonding curve (`JBCashOuts.cashOutFrom`) — it remains single-currency; per-context aggregation collapses to the reclaim currency *before* it.

---

## 4. Background — current architecture (verified)

Data path (send): `prepare(token)` → `toRemote(token)` → `_sendRoot(token)` → `_buildSnapshotAndSend` (`JBSucker.sol:1840-1879`) → `JBSuckerLib.buildSnapshotMessage` (`JBSuckerLib.sol:58-89`) → bridge `_sendRootOverAMB`.

- **Snapshot computation:** `JBSuckerLib._snapshotAccountsOf` (`:370-402`) → `_buildETHAggregateInternal` (`:227-308`). Surplus loop (`:245-257`) calls `terminal.currentSurplusOf(decimals=18, currency=JBCurrencyIds.ETH)` — the terminal valuates per-context→ETH internally. Balance loop (`:260-307`) reads **raw** `STORE().balanceOf(...)` per context (`:273-274`) then ETH-values it. `_ETH_DECIMALS = 18` (`:39`). Result stamped as `sourceCurrency: JBCurrencyIds.ETH`, `sourceDecimals: 18`, `sourceSurplus`, `sourceBalance` (`:83-86`).
- **Wire struct** `JBMessageRoot` (`src/structs/JBMessageRoot.sol:23-34`): flat single-currency aggregate — `sourceTotalSupply`, `sourceCurrency`, `sourceDecimals`, `sourceSurplus`, `sourceBalance`, `sourceTimestamp`, plus the per-lane `token`/`amount`/`remoteRoot`/`version`.
- **Receive/store:** `fromRemote` (`JBSucker.sol:456-530`) version-gates (`:465-468`), resolves `localToken = _toAddress(root.token)` (`:475`), and on `root.sourceTimestamp > snapshotTimestamp` overwrites the single shared `_peerChainSurplus`/`_peerChainBalance` (`JBDenominatedAmount`, `:238/:246`) and `peerChainTotalSupply` (`:166`).
- **Expose:** `peerChainSurplusValueOf`/`peerChainTotalSupplyValue` (`:836/:856`) → `_convertPeerValue` → `JBSuckerLib.convertPeerValue` (the swallow).
- **Consume (two paths, both collapse to one `cashOutFrom`):**
  - Loans: `REVLoans._borrowableAmountFrom` (`REVLoans.sol:439-458`) adds `SUCKER_REGISTRY.remoteSurplusOf(decimals, currency)` + `remoteTotalSupplyOf()` when `!scopeCashOutsToLocalBalances()`, clamps `borrowableCapacity` to local surplus.
  - Cash-out: `REVOwner.beforeCashOutRecordedWith` (`REVOwner.sol:251-258`) adds the same registry calls with `context.surplus.currency` (token-keyed) / `.decimals`; `JBTerminalStore._cashOutWithDataHook` (`JBTerminalStore.sol:961-969`) caps the reclaim at the local surplus.
- **Registry:** `JBSuckerRegistry.remoteSurplusOf` (`:265-307`) sums per-chain converted values (oracle per chain); `remoteTotalSupplyOf` (`:315-346`) sums raw supplies (feed-free). They iterate **independently** — the asymmetry.

---

## 5. Design principles

1. **No oracle in the surplus path.** Valuation is removed from send; the only conversions on consume are par (same-currency `adjustDecimals`) for matched contexts.
2. **Tiering of "same asset":**
   - **Tier 1 — identity:** `localToken == remoteToken` (NATIVE, or any token deployed at the same address across chains). Same currency id; par by construction.
   - **Tier 2 — mapped same-asset:** different addresses (USDC), declared the same asset by the sender's token mapping. Par by the operator's mapping, which is the *same* trust anchor the value-bridging already uses and is immutable once the outbox has entries.
   - **Tier 3 — cross-asset:** genuinely different assets. **Not** valued in the rate path; the swap sucker is the on-ramp; otherwise not counted.
3. **Bias low.** Every uncertain knob under-credits remote backing. Over-counting → cross-chain over-draw (catastrophic); under-counting → under-pay (merely conservative). The clamp (`reclaim ≤ local surplus`) is a backstop, not the safety mechanism.
4. **Symmetric numerator/denominator.** Remote surplus and remote supply are aggregated together per chain; if a chain's surplus can't be folded in (unmatched/stale), that chain's supply is excluded too. No "drop surplus, keep supply."
5. **Consistency with the bridge.** Same-asset legs are valued exactly how the bridge moves them — at par.

---

## 6. The model

Let a reclaim/borrow be requested in target context `X` (token `tX`, currency `cX = uint32(uint160(tX))`, decimals `dX`).

- **Remote surplus credited =** Σ over remote chains, of that chain's surplus in a context that resolves (Tier 1 identity / Tier 2 mapping) to local context `X`, taken **at par** (decimals-adjusted to `dX`, no oracle).
- **Remote surplus in any other remote context (Tier 3 for this request)** is **not** credited.
- **Remote supply credited** is included **only for chains whose every accounting context resolves to a local same-asset context** (so the denominator can never carry supply whose backing was dropped from the numerator). See §7.4 for the multi-context decision.

Consequences:
- **Single-context project (DEFIFA/ART):** the only remote context is `X` → fully par-credited, exact, feed-free; remote supply fully counted; no asymmetry possible.
- **Multi-context project, all contexts matched:** each reclaim currency credits its own matched remote context at par; remote backing in *other* contexts is conservatively not credited toward *this* reclaim (safe under-credit), unless consolidated via the swap sucker.

---

## 7. Detailed design

### 7.1 Wire format (`JBMessageRoot`)
Replace the flat aggregate quartet with a per-context array; keep supply and freshness scalar.

```solidity
// src/structs/JBSourceContext.sol  (new)
struct JBSourceContext {
    bytes32 token;     // the DESTINATION-local token for this context (sender-translated; see §7.2)
    uint32  currency;  // the context's native currency id (token-keyed or standard)
    uint8   decimals;  // the context's native decimals (e.g. 18 ETH / 6 USDC)
    uint256 surplus;   // raw, un-valued surplus in this context's own units
    uint256 balance;   // raw, un-valued balance in this context's own units (for the emergency hatch)
}

// src/structs/JBMessageRoot.sol  (changed)
struct JBMessageRoot {
    uint8 version;                  // bump to 2 (see §7.7)
    bytes32 token;                  // unchanged: this lane's bridged token
    uint256 amount;                 // unchanged
    JBInboxTreeRoot remoteRoot;     // unchanged
    uint256 sourceTotalSupply;      // unchanged: project-wide, currency-agnostic
    JBSourceContext[] sourceContexts; // REPLACES sourceCurrency/sourceDecimals/sourceSurplus/sourceBalance
    uint256 sourceTimestamp;        // unchanged: single project-wide freshness key
}
```

Rationale for an **array carried on every message** (vs. repurposing the scalar fields per-lane token): every message already recomputes the full project-wide snapshot, so an array preserves the current "every message refreshes the whole snapshot" cadence and avoids per-token staleness. The cost is a struct ABI change (a version bump we are paying anyway, §7.7) and a few extra context entries of calldata (small `N`). The encode/decode lives in `JBSuckerLib` to protect the sucker size budget (§7.8).

> Note: `sourceTotalSupply` stays a single project-wide scalar (`totalTokenSupplyWithReservedTokensOf`, `JBSuckerLib.sol:383`). Supply is the revnet token, not attributable to an accounting context.

### 7.2 Send side (`JBSuckerLib`)
- Rewrite `_buildETHAggregateInternal` (`:227-308`) → `_buildSourceContexts(...) returns (JBSourceContext[])`:
  - Loop `directory.terminalsOf` × `terminal.accountingContextsOf` (the existing nest, `:237/:261`).
  - **Balance per context:** keep the existing raw `STORE().balanceOf(terminal, projectId, ctx.token)` (`:273-274`) — delete the ETH valuation at `:279-295`.
  - **Surplus per context:** call `terminal.currentSurplusOf({projectId, tokens: [ctx.token], decimals: ctx.decimals, currency: ctx.currency})` so it returns *this token's* surplus in its own units, un-valued (verify `currentSurplusOf` returns single-token surplus when `tokens` is a one-element array; if not, derive `max(0, balance − payoutLimit)` per context).
  - **Token translation:** set `JBSourceContext.token = _remoteTokenFor[ctx.token].addr` (the destination's local token), mirroring how `root.token` is already translated on send. Skip contexts with no enabled mapping (they can't be credited remotely; emitting them is harmless but pointless).
  - **Drop the `prices` dependency** from this function — no oracle on send.
- `_snapshotAccountsOf` (`:370-402`) returns `(localTotalSupply, JBSourceContext[])`; keep the `controller.totalTokenSupplyWithReservedTokensOf` read.
- `buildSnapshotMessage` (`:58-89`) stamps `sourceContexts` instead of the ETH quartet; can drop its `prices` param.
- **Data-hook adjustment** `_peerChainAdjustedAccountsOf` (`:332-361`) + `IJBPeerChainAdjustedAccounts`: change the hook ABI to return per-context adjustments, or fold its (supply, surplus, balance) into a synthetic context — **open decision** (§11), as it currently assumes ETH/18.

### 7.3 Receive side (`JBSucker`)
- Storage: replace the single `_peerChainSurplus`/`_peerChainBalance` (`:238/:246`) with per-local-token maps:
  ```solidity
  struct JBPeerContext { uint256 surplus; uint256 balance; uint32 currency; uint8 decimals; }
  mapping(address localToken => JBPeerContext) private _peerContextOf;
  // peerChainTotalSupply (:166) and snapshotTimestamp (:252) stay single project-wide scalars.
  ```
- `fromRemote` (`:512-529`): on `root.sourceTimestamp > snapshotTimestamp`, clear/rewrite `_peerContextOf` from `root.sourceContexts` (each entry keyed by `_toAddress(entry.token)` — already the destination-local token, sender-translated) and set `peerChainTotalSupply = root.sourceTotalSupply`. **Resolution stays identity** (`_toAddress`), because the sender already mapped to the destination's local token; no receiver-side `_localTokenForRemoteToken` lookup is introduced (it remains the send-side uniqueness guard).
  - Staleness: because the whole array refreshes atomically on a fresher `sourceTimestamp`, a single project-wide freshness gate suffices (as today). Add a **staleness TTL** read on consume (§7.5).
  - Edge: a context that *disappears* from a newer snapshot must be cleared (iterate-and-zero, or version the map by `snapshotTimestamp`).
- Views: `peerChainSurplusValueOf` etc. (`:836/:856`) gain a `token` param (or token-keyed overloads) and read `_peerContextOf[token]`. **Par path only:** the conversion must be `adjustDecimals` when `entry.currency == requested currency`, and **fail-closed (return 0 + signal unmatched)** when it differs — i.e. delete the oracle branch from the cross-chain read path. (The same-currency branch of `convertPeerValue` is retained; the `pricePerUnitOf` branch is removed for this path.)

### 7.4 Consume side (`JBSuckerRegistry`, `REVLoans`, `REVOwner`)
- `JBSuckerRegistry`: aggregate **surplus and supply per peer chain in one pass** (merge `remoteSurplusOf` and `remoteTotalSupplyOf` internals, or add a combined `remoteAccountsOf(projectId, decimals, currency) → (surplus, supply, allMatched)`), so a chain whose target-context surplus is unmatched/stale contributes **neither** surplus nor supply. This closes the asymmetry at the only place both numbers are known together.
- `REVLoans._borrowableAmountFrom` (`:439-444`) and `REVOwner.beforeCashOutRecordedWith` (`:251-258`): consume the combined `(remoteSurplus, remoteSupply)` for the reclaim/borrow `currency`; the final `JBCashOuts.cashOutFrom` is unchanged (single-currency, as required by N3). The local clamp is unchanged.
- **Multi-context fallback decision (open, §11):** when a project has remote backing in a context that does *not* match the reclaim currency, choose between:
  - (a) **Local-only fallback for that chain** — drop the whole chain's remote surplus *and* supply (symmetric, simplest, most conservative); or
  - (b) **Credit matched-context surplus, exclude only the unmatched chain's supply where its surplus was dropped** (finer, still symmetric, more code).
  Recommendation: ship (a) (symmetric + minimal), document that full multi-asset credit requires consolidating remote backing into the reclaim asset via the swap sucker. DEFIFA/ART are single-context so this never triggers for the live cohort.

### 7.5 Safety layer (applies to every path)
- **Symmetric fail-closed** (§7.4): never count remote supply whose backing surplus was dropped.
- **Round-down:** all `adjustDecimals`/aggregation rounds toward zero on the remote leg (bias low).
- **Staleness TTL:** a configurable max age on `snapshotTimestamp` (decode the wall-clock high bits, `JBSucker.sol:1855`); past it, the remote contribution is treated as unmatched (dropped, both legs). This bounds the frozen-at-T risk.

### 7.6 Cross-asset (Tier 3) — the swap sucker
Tier 3 is **designed out of the rate path**, not handled in it. A project that wants remote backing in asset Y to support reclaims in asset X arranges, via `JBSwapCCIPSucker` (`src/archive/JBSwapCCIPSucker.sol`), for the value to be **held/bridged as X** (a real swap at the bridge with TWAP-bounded, one-shot execution and an immutable per-nonce `JBConversionRate`). By the time it is surplus, it is a matched (Tier 2) context. Until that sucker is un-archived and shipped (its own size-constrained milestone — it sat at ~27 B EIP-170 margin), Tier 3 remote backing is simply **not credited** (safe under-credit). This spec defines the plug-in point (matched-context par consumption) but does **not** depend on the swap sucker for the live single-context cohort.

### 7.7 Versioning (pre-deploy — no migration)
**Nothing is deployed yet; this is a pre-deploy edit.** The per-context format is authored as the **initial** wire format, so `MESSAGE_VERSION` stays `1` — there is **no version bump, no dual-version decode, no coordinated redeploy, and no in-flight flush / native-token strand risk**. The `JBMessageRoot` ABI is simply defined in its per-context shape from the start, and the version equality gate (`JBSucker.sol:465-468`) is retained unchanged for any *future* (post-deploy) format change.
- The struct change is therefore a **plain source edit**, not a migration. The only discipline required is that every sucker implementation and both ends of every pair ship the same bytecode at deploy time (they will — single deploy).
- (For the record, were this ever attempted *after* a deployment, the heavy path would re-apply: a version mismatch strands a native-token message because `fromRemote` cannot revert-refund native (`:486-488`), forcing quiesce → flush all in-flight → redeploy at new CREATE2 addresses → re-map → resume. Out of scope while pre-deploy.)

### 7.8 EIP-170 budget
- Binding constraint: **JBCCIPSucker 2,587 B** headroom; JBArbitrumSucker 2,778 B. Base `JBSucker` growth hits all four.
- **Put all new logic in `JBSuckerLib`** (17.5 KB headroom, DELEGATECALL target — already hosts `buildSnapshotMessage`, merkle, CCIP encoding): the per-context build, the array encode, and the receiver's per-context store/clear and par-read helpers. Keep `JBSucker`/`JBSuckerRegistry` deltas to storage-layout + thin wrappers.
- The archived `JBSwapCCIPSucker` (~27 B margin pre-archive) cannot absorb base growth; un-archiving it is gated on its own size reduction and is out of scope here (N2).

---

## 8. Security / threat model

- **Invariant (conservation):** Σ over chains of reclaimable ≤ Σ backing. Oracle-free par + symmetric fail-closed + round-down make every deviation *under*-credit, so the invariant can only be slack, never violated by a feed event.
- **Invariant (fairness):** single-context projects reclaim at the exact global rate (par, feed-free). Multi-context projects under-credit cross-asset remote backing (documented; swap-sucker remedy).
- **Trust anchor:** Tier-2 par leans on the operator-set `JBTokenMapping`, which is immutable once the outbox has entries (`JBSucker.sol:1210-1215`) — the same trust the value-bridging already relies on; no new trust surface.
- **Failure modes removed:** missing/stale/mis-registered ETH↔token feed → previously silent ~50% under-pricing with full-supply denominator; now there is no feed in the path, and any unmatched/stale context drops both legs symmetrically.
- **Residual:** frozen-at-T staleness (bounded by the TTL, §7.5); multi-context under-credit (safe, documented).
- **Griefing:** `sourceTimestamp` strict-monotonic gate (`:516`, `(block.timestamp<<128)|++seq`) already prevents snapshot rollback; per-context arrays inherit it unchanged.

---

## 9. Test plan
Port/extend the existing fork harness (`deploy-all-v6/test/fork`, `CrossChainArb*`, `USDCCrossChainSurplusFork` — note the latter must be updated off the retired triangular feed):
1. **Single-context exactness (no feed):** USDC revnet, local USDC surplus + remote USDC snapshot (Tier 2, par); assert reclaim/borrow reflects local + remote **with zero price feeds registered**, exact to wei (modulo decimals round-down).
2. **Tier-1 identity:** NATIVE-context project; remote native surplus credited at par.
3. **Symmetric fail-closed:** stale/unmatched remote context → assert **both** remote surplus and remote supply are dropped (no under-pricing distortion); compare to local-only.
4. **Bias-low:** round-down direction verified at 6↔18 decimal boundaries; remote leg never rounds up.
5. **Multi-context fallback:** project with USDC + ETH contexts, reclaim in USDC with remote ETH backing → assert conservative under-credit per the §7.4 decision (no oracle consulted).
6. **Staleness TTL:** past TTL → remote dropped.
7. **Invariants:** extend `CrossChainArbInvariant` to assert global conservation holds with feeds entirely absent.
8. **Regression:** the deploy no longer registers `JBTriangularPriceFeed`; the `DeployArtifactCompletenessGap` test reflects the reduced artifact set.

## 10. Re-audit scope
- `nana-suckers-v6`: `JBSuckerLib` (send build + receiver par-read + array codec), `JBSucker` (storage layout, `fromRemote`, views, version), `JBSuckerRegistry` (combined per-chain surplus+supply), `JBMessageRoot`/`JBSourceContext`. Focus: the symmetric fail-closed aggregation and the per-context store/clear.
- `rev-net/core-v6`: `REVLoans._borrowableAmountFrom`, `REVOwner.beforeCashOutRecordedWith`.
- `nana-core-v6`: `JBTerminalStore._cashOutWithDataHook` consumption (read-only confirmation it stays single-currency).
- Deploy: removal of the triangular-feed registration for matched-context projects.

## 11. Open decisions (resolve before implementation)
- D1. Array-on-every-message (§7.1, recommended) vs. per-lane repurpose (smaller calldata, introduces per-token staleness).
- D2. Multi-context unmatched fallback: local-only-per-chain (a) vs. credit-matched-exclude-unmatched-supply (b) (§7.4). Recommend (a).
- D3. `IJBPeerChainAdjustedAccounts` hook ABI: per-context return vs. synthetic context (§7.2/D).
- D4. uint128 cap on per-context `surplus`/`balance` for SVM consumers (the leaf-amount cap precedent, `JBSucker.sol:1133-1134`).
- D5. Per-context map clearing strategy on a shrinking snapshot (iterate-zero vs. timestamp-versioned map) (§7.3).

## 12. Change index (file:line)
- Send: `JBSuckerLib.sol` `_buildETHAggregateInternal:227-308`, `_snapshotAccountsOf:370-402`, `_peerChainAdjustedAccountsOf:332-361`, `buildSnapshotMessage:58-89`, `_ETH_DECIMALS:39`; `JBSucker.sol` `_buildSnapshotAndSend:1840-1879`.
- Wire: `structs/JBMessageRoot.sol:23-34` (+ new `structs/JBSourceContext.sol`); `MESSAGE_VERSION JBSucker.sol:107`, check `:465-468`.
- Receive/store/expose: `JBSucker.sol` storage `:166/:238/:246/:252`, `fromRemote:456-530` (resolve `:475`, write `:516-529`), views `:782/:799/:819/:836/:856`; `convertPeerValue JBSuckerLib.sol:184-218` (retain same-currency branch, remove oracle branch from the cross-chain read).
- Consume: `JBSuckerRegistry.sol remoteSurplusOf:265-307` / `remoteTotalSupplyOf:315-346` (merge); `REVLoans.sol:439-458`; `REVOwner.sol:215-258`; `JBTerminalStore.sol:942-970` (confirm).
- Size budget: `JBSuckerLib` (host new logic); CCIP/Arbitrum suckers are the EIP-170 limiters.
