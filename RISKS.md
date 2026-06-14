# Suckers risk register

This file focuses on the bridge-like risks in the sucker system: merkle-root progression, token mapping, cross-chain consistency, and the explicit non-atomicity of source burn and destination mint.

## How to use this file

- Read `Priority risks` first; they summarize the bridge failure modes with real user-fund implications.
- Use the detailed sections for merkle, fee, emergency, and deprecation reasoning.
- Treat `Accepted Behaviors` as explicit tradeoffs in the bridge model, not oversights.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Out-of-order or asymmetric cross-chain state | If roots or peer suckers do not progress symmetrically, claims can become unavailable or one-way only. | Nonce checks, peer verification, and emergency hatch recovery. |
| P0 | Bad token mapping or registry trust | Incorrect local or remote token mapping can mint or route the wrong asset across chains. | Strict mapping controls, deploy-time review, and registry or operator scrutiny. |
| P1 | Non-atomic bridge semantics | Users can experience delays, skipped roots, or recovery flows because burn and mint are not one atomic operation. | Explicit user and operator docs, emergency procedures, and monitoring of bridge liveness. |

## 1. Trust assumptions

- **Bridge liveness.** Each implementation delegates message authentication to an external AMB (Optimism `CrossDomainMessenger`, Arbitrum `Bridge`/`Outbox`/`ArbSys`, Chainlink CCIP `Router`). A compromised or censoring AMB can forge roots, withhold messages, or permanently block claims.
- **OP Stack (Optimism, Base):** trusts `OPMESSENGER.xDomainMessageSender()` for peer identity. A vulnerability in the OP messenger (or a malicious upgrade behind a proxy) would bypass all access control.
- **Arbitrum:** L1 side trusts `ARBINBOX.bridge().activeOutbox().l2ToL1Sender()`; L2 side trusts `AddressAliasHelper.applyL1ToL2Alias(peer)`. A compromised bridge or outbox contract breaks authentication.
- **CCIP:** trusts `CCIP_ROUTER` identity plus `any2EvmMessage.sender` and `sourceChainSelector`. The router address is immutable at deploy time -- if Chainlink rotates routers, the sucker is bricked (no upgrade path).
- **Bridge spend approvals are single-use.** Sucker send paths grant external bridge/router contracts the ERC-20
  allowance needed for the current bridge send and revoke it after the send succeeds. Canonical bridges are expected to
  pull exactly or revert, but the revoke keeps later same-token funds safe if a non-canonical, upgraded, or
  misconfigured bridge returns success after only partially consuming the allowance.
- **CREATE2 peer assumption.** `peer()` defaults to `address(this)`, assuming deterministic cross-chain deployment. Breaks if deployer address, init code, or factory nonce differs across chains. Incorrect peer = permanent fund loss (messages accepted from nobody, or routed to wrong address).
- **Controller/terminal must exist on destination chain.** `_handleClaim` calls `controllerOf(projectId).mintTokensOf()`. If the project does not exist or has no controller on the remote chain, all claims permanently revert -- funds are stuck.
- **Registry allowlisting does not verify deployer singleton provenance.** `JBSuckerRegistry.deploySuckersFor()` only checks the deployer allowlist, not the singleton implementation behind the deployer. `configureSingleton()` can point an approved deployer at any JBSucker singleton. This is a privileged-only concern (both deployer configuration and registry allowlisting require governance). Defense: validate deployer configuration during registry allowlist reviews.
- **No reentrancy guard.** The contract relies on state ordering (mark-executed-before-external-call) rather than explicit ReentrancyGuard. Correct today, but fragile to future refactors.
- **Archived (reference only — not compiled or deployed):** `JBSwapCCIPSucker` (with its swap libraries/structs `JBSwapPoolLib`, `JBSwapLib`, `JBPendingSwap`, `JBConversionRate`) and `JBCeloSucker`, plus their deployers (`JBSwapCCIPSuckerDeployer`, `JBCeloSuckerDeployer`). These live under `src/archive/` and are excluded from compilation and deployment; the active suckers are `JBSucker`, `JBOptimismSucker`, `JBBaseSucker`, `JBArbitrumSucker`, and `JBCCIPSucker`, plus `JBSuckerRegistry`. The archived analyses below are flagged `[ARCHIVED]`.

## 2. Merkle tree risks

- **Append-only guarantee is structural, not enforced by storage.** The outbox tree's `MerkleLib.Tree` struct stores `branch[32]` and `count`. Nothing prevents a privileged test helper or a storage-corrupting bug from mutating the branch array directly, which would silently invalidate all existing proofs.
- **Root divergence on nonce skip.** `fromRemote` accepts any nonce strictly greater than the current inbox nonce (not sequential). If nonce 3 arrives before nonce 2, the inbox jumps to nonce 3's root. Leaves from nonce 2's batch are still provable against nonce 3's root (append-only), but proofs generated against nonce 2's root are invalid -- off-chain systems must regenerate proofs against the current root.
- **Root atomicity gap.** Between `_sendRoot` clearing `outbox.balance` and the AMB delivering the root to the remote peer, `amountToAddToBalanceOf` is transiently inflated (contract holds tokens that the outbox no longer tracks). This is benign because tokens are only added to balance atomically during `claim()`.
- **Tree depth overflow.** The tree supports `2^32 - 1` leaves. At ~4 billion leaves this saturates, but each insertion costs ~100k gas, making it practically unreachable. The tree reverts with `MerkleLib_InsertTreeIsFull` if the cap is hit.
- **Proof invalidation on new root.** When a new root is delivered via `fromRemote`, all existing proofs computed against the old root become invalid. Users must regenerate proofs against the latest inbox root. No on-chain mechanism exists to signal this -- it depends entirely on off-chain indexers.
- **Z_HASH compatibility.** The MerkleLib uses hardcoded Z_0 through Z_32 constants. These must match the SVM implementation exactly for cross-VM suckers. A mismatch would produce different roots from identical leaf sets.

## 3. Cross-chain atomicity

- **Arbitrum non-atomic token+message delivery.** Arbitrum ERC-20 sends split the token bridge leg from the
  `fromRemote` merkle root message (`_toL2` creates independent retryables; `_toL1` uses the gateway plus
  `ArbSys.sendTxToL1`). These are processed independently with no ordering guarantee. `_addToBalance` checks actual
  token balance to prevent unbacked minting when a root arrives before tokens.
- **CCIP: no guaranteed delivery order.** CCIP does not guarantee in-order delivery. The contract handles this by accepting any nonce > current, but concurrent `toRemote` calls for the same token could result in a later root arriving first, skipping an intermediate root.
- **CCIP delivered tokens must match the received root.** Inbound CCIP root messages bind `destTokenAmounts` to the
  advertised token and amount before recording the inbox root. For native-token roots, the delivered ERC-20 must be
  the router-reported wrapped-native token so it can be unwrapped into the local native token.
- **OP Stack: generally ordered** but the L1-to-L2 message must be relayed by an off-chain actor. A delayed or dropped relay permanently blocks claims until someone retries the relay.
- **Message loss.** If an AMB silently fails (accepts the message on L1 but never delivers to L2), `numberOfClaimsSent` is incremented but the remote peer never receives the root. Those leaves are blocked from both remote claim and local emergency exit (conservative: locked, not double-spent). Recovery requires enabling the emergency hatch.
- **Aggregate balance accounting.** `amountToAddToBalanceOf(token)` computes `balanceOf(this) - outbox.balance`, making
  all contract-held tokens fungible claim backing. This is intentional: all funds serve the same project, so refunded
  ETH (from failed Arbitrum retryable tickets) and stale native deliveries correctly become project-claimable. The
  tradeoff is that an Arbitrum root whose own ERC-20 leg is delayed can become claimable once another batch's ERC-20
  leg lands, shifting claim timing between beneficiaries. The project is still the ultimate beneficiary and unbacked
  minting is blocked by the balance check.
- **`fromRemote` does not revert on stale nonce.** By design, stale/duplicate messages are silently ignored (emitting `StaleRootRejected`). This prevents fund loss on native token transfers where reverting would lose the ETH, but means monitoring must watch for this event to detect bridge issues.

## 4. Token mapping risks

- **Immutable after first use.** Once `_outboxOf[token].tree.count != 0` (first `prepare`), the remote token address cannot be changed to a different address -- only disabled (set to `bytes32(0)`). A wrong initial mapping is catastrophic: requires deploying a new sucker.
- **Per-sucker remote token uniqueness.** Within one sucker, each non-zero remote token address can be reserved by only one local terminal token. The source chain tracks outboxes and nonces by local token, but the destination chain stores received roots by `root.token` (the remote token address converted to its local address). Sharing one remote token across two local tokens inside the same sucker would merge their destination inboxes and make roots reject as stale or overwrite each other. Separate suckers have separate inbox/outbox storage, so a project can run multiple bridge lanes for the same asset pair (for example native bridge and CCIP ETH/USDC lanes) and let users choose the risk profile.
- **Disable triggers final root flush.** Setting `remoteToken = bytes32(0)` when the outbox has unsent leaves calls `_sendRoot`, which requires `transportPayment` (msg.value). If the caller does not provide sufficient msg.value, the disable transaction reverts.
- **Emergency hatch is irreversible.** Once `enableEmergencyHatchFor(token)` is called, `enabled` is set to false and `emergencyHatch` to true. There is no way to re-enable the mapping or close the hatch. This is permanent.
- **Native token mapping constraints differ by sucker.**
  - OP/Arb suckers: `NATIVE_TOKEN` can only map to `NATIVE_TOKEN` or `bytes32(0)`.
  - CCIP suckers: `NATIVE_TOKEN` can map to any remote token (for chains where ETH is an ERC-20).
  - Wrong native mapping can cause permanent loss: e.g., bridging ETH to a non-WETH ERC-20 address on the remote chain.
- **`fromRemote` accepts roots for unmapped tokens.** By design, to avoid permanent loss of already-bridged tokens. Claims against those roots fail at the mapping lookup. This means stale token data can accumulate in inbox storage indefinitely.
- **minGas too low = permanent fund loss.** If `minGas` is below the actual gas needed for the remote call, the bridge message will fail on the remote chain. The OP/CCIP implementations enforce `MESSENGER_ERC20_MIN_GAS_LIMIT` (200k), but the actual gas needed could be higher depending on the remote token implementation.
- **Cross-reference: omnichain deployer token mapping.** When suckers are deployed through `JBOmnichainDeployer`, the `MAP_SUCKER_TOKEN` permission is granted to the sucker registry with `projectId=0` (wildcard). This means the registry can map tokens for ALL projects, not just the one being deployed. See [nana-omnichain-deployers-v6 RISKS.md](../nana-omnichain-deployers-v6/RISKS.md) section 3 for the permission escalation analysis.

## 5. Fee collection risks

- **Best-effort fee collection.** `toRemoteFee` is a centralized storage variable on `JBSuckerRegistry` (ETH, in wei) — uniform across all suckers and all tokens, non-bypassable by integrators. It is paid into `FEE_PROJECT_ID` (typically project ID 1) via `terminal.pay()`. If the fee project has no primary terminal for `NATIVE_TOKEN`, or if `terminal.pay()` reverts for any reason, `toRemote()` still proceeds, but the fee ETH is retained as a refundable balance for the original caller and excluded from native add-to-balance accounting. Fee collection is therefore best-effort at the protocol-fee destination even though users still supply the fee amount.
- **Accounting sync has no registry fee.** `syncAccountingData()` is not a value/root relay and does not read or charge `toRemoteFee`. The caller still supplies any bridge transport payment required by the chain-specific implementation. It sends a gossip bundle — this chain's record plus every peer-chain record the project knows (gathered via the registry, excluding the destination chain). Duplicate accounting bundles are allowed so operators can retry delivery, but they can still consume bridge and indexer resources even when the underlying supply/surplus/balance values are unchanged, and a larger bundle (more source chains) is a larger message.
- **Renounced registry ownership risk.** If the registry owner calls `renounceOwnership()`, `setToRemoteFee()` becomes permanently uncallable and the fee is frozen at its current value across all suckers. This is a deliberate trade-off: it allows the registry owner to credibly commit to a fee level, but eliminates the ability to respond to future ETH price changes. The fee is still capped at `MAX_TO_REMOTE_FEE`, so the maximum downside is bounded.
- **Immutable fee project.** `FEE_PROJECT_ID` is set at construction and cannot be changed. If the fee project is abandoned or its terminal removed, there is no way to redirect fees without deploying new suckers.
- **Cross-reference: sucker registration path.** Suckers are deployed via `JBSuckerRegistry.deploySuckersFor`, which requires `DEPLOY_SUCKERS` permission from the project owner. The registry's `deploy` function uses `CREATE2` with a deployer-specific salt. The sucker's `peer()` address is deterministic — a misconfigured peer means the sucker accepts messages from the wrong remote address. See [nana-omnichain-deployers-v6 RISKS.md](../nana-omnichain-deployers-v6/RISKS.md) for deployer-level risks.
- **Registry aggregate views fail open.** `JBSuckerRegistry.totalRemoteBalanceOf`, `totalRemoteSurplusOf`, and `remoteTotalSupplyOf` aggregate over every (sucker, chain) pair and dedup per source chain by the freshest accepted record, because each sucker caches the entire remote chain's state per source chain — multiple (sucker, chain) pairs reporting the same source chain are redundant records, not additive shares. MAX is only a same-freshness tie-breaker and a deprecated-sucker fallback when no active sucker answers for that source chain. The views silently skip any (sucker, chain) pair that reverts — including one whose cross-currency price feed is missing, since the registry values raw contexts at read time and a missing feed reverts only that (sucker, chain). This preserves liveness for dashboards and cross-chain estimates, but it means the returned aggregate can understate remote state whenever one peer is broken, censored, missing a feed, or simply expensive to query.

## 6. Deprecation lifecycle

- **State machine: ENABLED -> DEPRECATION_PENDING -> SENDING_DISABLED -> DEPRECATED.**
  - `DEPRECATION_PENDING`: fully functional, warning only. `block.timestamp < deprecatedAfter - _maxMessagingDelay()`.
  - `SENDING_DISABLED`: no new `prepare()` or `toRemote()`. `block.timestamp >= deprecatedAfter - _maxMessagingDelay()` but `< deprecatedAfter`.
  - `DEPRECATED`: outbound sends blocked. Incoming roots are still accepted to prevent stranding already-sent tokens. Emergency exits allowed.
- **Irrecoverability once SENDING_DISABLED.** `setDeprecation` reverts in SENDING_DISABLED and DEPRECATED states. Once the sucker enters SENDING_DISABLED, there is no way to cancel or extend the deprecation.
- **Messaging delay = 14 days.** `_maxMessagingDelay()` returns 14 days for all implementations. The deprecation timestamp must be at least `block.timestamp + 14 days` in the future. This is generous for OP/Arb (minutes to hours) but may be insufficient if a bridge has an extended outage.
- **Stuck tokens during deprecation.** Tokens that were `prepare()`d but not yet `toRemote()`d before SENDING_DISABLED cannot be sent to the remote chain. They can only be recovered via emergency exit after the sucker reaches DEPRECATED state.
- **Both sides must deprecate.** The deprecation must be called on both the local and remote sucker with matching timestamps. If only one side deprecates, the other side continues accepting roots while the deprecated side blocks outbound sends. The deprecated side still accepts incoming roots, so tokens sent before deprecation can be claimed.

## 7. Emergency hatch

- **Two independent activation paths:**
  1. Per-token: `enableEmergencyHatchFor(tokens)` -- requires `SUCKER_SAFETY` permission from project owner. Allows emergency exit for specific tokens while the sucker is still ENABLED.
  2. Global: deprecation reaching SENDING_DISABLED or DEPRECATED state. Allows emergency exit for all tokens.
- **Claim vs emergency exit use separate bitmap slots.** Emergency exit uses `_executedFor[keccak256(abi.encode(terminalToken))]` while regular claims use `_executedFor[terminalToken]`. This means a leaf that was emergency-exited locally could theoretically also be claimed remotely if the root was already sent -- double-spend is prevented only by the `numberOfClaimsSent` check.
- **`numberOfClaimsSent` is the critical guard.** Emergency exit reverts if `outbox.numberOfClaimsSent != 0 && outbox.numberOfClaimsSent - 1 >= index`. The `numberOfClaimsSent != 0` precondition prevents underflow when no root has ever been sent — in that case, all leaves are available for emergency exit. This means leaves at indices below `numberOfClaimsSent` cannot be emergency-exited (they may have been sent to the remote peer). If `_sendRootOverAMB` silently fails, these leaves are permanently locked.
- **Emergency exit decrements `outbox.balance`.** If emergency exits drain the outbox balance below the amount that was already sent to the bridge, the accounting becomes inconsistent. The contract guards against this by only allowing exit for unsent leaves.
- **Emergency exit recipient is the leaf beneficiary.** `exitThroughEmergencyHatch()` refunds to `claimData.leaf.beneficiary`, not the original `prepare()` caller. The depositor chose this beneficiary when preparing the bridge; the leaf structure does not store the depositor address. If Alice prepares for Bob and the bridge fails, Bob gets the emergency refund, not Alice. This is the intended behavior: the depositor delegated their claim to the beneficiary.
- **`numberOfClaimsSent` advancement timing.** `_sendRoot()` sets `numberOfClaimsSent` before `_sendRootOverAMB()` completes. If the L1 transaction succeeds but L2 delivery fails, those leaves are blocked from emergency exit. Mitigations: Arbitrum retryable tickets can be manually re-executed on L2; Optimism messages can be re-relayed by anyone. If delivery permanently fails, `enableEmergencyHatchFor()` combined with project owner intervention can recover. Adding a rollback mechanism would introduce double-spend risk (leaf claimable on both chains). Current design is conservative: locked funds are preferable to double-spent funds.
- **Emergency hatch + minting.** Emergency exit calls `_handleClaim`, which mints project tokens via the controller. If the controller or token contract is broken/missing, emergency exits also revert -- there is no "raw withdrawal" of terminal tokens without minting.

## 8. DoS vectors

- **Large proof calldata.** Each claim requires a 32-element `bytes32[32]` proof array (1024 bytes). Batch claims (`claim(JBClaim[])`) scale linearly. A batch of 100 claims is ~100KB of calldata, approaching some L2 calldata limits.
- **Bridge gas limits.** `MESSENGER_BASE_GAS_LIMIT` is 300k and `MESSENGER_ERC20_MIN_GAS_LIMIT` is 200k. If the remote chain's gas costs increase (e.g., after an EVM upgrade), these hardcoded limits may become insufficient, causing all bridge messages to fail.
- **uint128 cap for SVM compatibility.** `_insertIntoTree` reverts if `projectTokenCount` or `terminalTokenAmount` exceeds `type(uint128).max`. This is enforced for cross-VM compatibility but limits EVM-only use cases to ~3.4e38 wei per leaf.
- **Arbitrum retryable ticket pricing.** `_toL2` uses `block.basefee` as `maxFeePerGas`. If L2 gas prices spike above L1's `block.basefee`, the retryable ticket may not auto-redeem and requires manual retry.
- **CCIP fee volatility.** `_sendRootOverAMB` checks `CCIP_ROUTER.getFee()` at call time. If fees spike between estimation and execution, the transaction reverts with `JBSucker_InsufficientMsgValue`. No retry mechanism exists.
- **Accounting-only message fee volatility.** `syncAccountingData()` uses the same bridge-specific transport fee machinery as root messages, without transporting tokens. OP/Base and Arbitrum L2->L1 reject nonzero transport payment, Arbitrum L1->L2 requires retryable-ticket payment, and CCIP may use native ETH or LINK depending on the supplied value. Both `syncAccountingData` and `toRemote` now carry a gossip bundle of per-chain accounting records, so the message is larger when the project knows more chains. **Only the CCIP variant scales its destination gas with the bundle size** — `JBCCIPSucker._ccipGasLimitFor` budgets `MESSENGER_BASE_GAS_LIMIT + contextCount * _CCIP_SOURCE_CONTEXT_GAS_LIMIT`, where `contextCount` is the total number of source contexts across *all* records in the bundle, so a wide hub-and-spoke mesh makes CCIP fees sharply larger and can hit chain-specific CCIP gas caps. The OP-stack and Arbitrum variants keep a **fixed** `MESSENGER_BASE_GAS_LIMIT` regardless of bundle size; a very large bundle that under-gasses the destination call does not revert the source send but leaves the message to be redeemed by permissionless OP message replay or Arbitrum retryable redemption. Note this asymmetry: CCIP fails-expensive at send time, OP/Arb defer to replay/retry.
- **`toRemote` fee fallback retains refundable ETH.** If the fee project's terminal is missing or `terminal.pay()` reverts, `toRemote()` keeps the fee ETH in the sucker so zero-cost bridges can still proceed with `transportPayment = msg.value - fee`. The retained fee is credited to the original caller, excluded from `amountToAddToBalanceOf(NATIVE_TOKEN)`, and can be reclaimed with `claimRetainedToRemoteFee(...)`. The retained amount per affected call is bounded by `MAX_TO_REMOTE_FEE` (currently `0.001 ether`).
- **CCIP transport payment refund failure.** If `_msgSender()` is a non-payable contract, the refund `call` fails silently. The excess ETH (transportPayment - fees) is permanently stuck in the sucker. The contract emits `TransportPaymentRefundFailed` but has no sweep mechanism.
- **Unbounded sucker count per project.** `JBSuckerRegistry._suckersOf` uses an EnumerableMap with no cap. `suckerPairsOf` iterates all suckers with external calls per iteration. Extremely large sucker counts could cause view functions to exceed gas limits.
- **Unrestricted `receive()`.** Anyone can send ETH to the sucker, inflating `amountToAddToBalanceOf`. This is by design (needed for bridge/terminal returns) but means the project can receive unexpected balance additions.

## 9. Invariants to verify

- **Nonce monotonicity.** Outbox nonce increments exactly once per `_sendRoot` call. Inbox nonce only increases (never decreases or replays). Tested in `invariant_nonceMonotonicallyIncreases`.
- **No double-claim.** `_executedFor[token].get(index)` is checked before and set before any external call. Each leaf index can be claimed exactly once. Tested in `invariant_eachLeafClaimedOnce`.
- **No double-emergency-exit.** Emergency exit uses a separate bitmap slot (`keccak256(abi.encode(token))`) but the same `_executedFor` mapping. Each leaf can be emergency-exited exactly once. Tested in `test_merkleTree_emergencyExitAtomicity`.
- **Balance accuracy across send cycles.** `outbox.balance == totalInserted - totalEmergencyExited - totalSent`. The invariant test (`invariant_outboxBalanceAccountedCorrectly`) verifies this holds across arbitrary sequences of insert/send/exit.
- **outbox.balance <= address(sucker).balance.** The tracked outbox balance never exceeds the contract's actual token balance. Tested in `invariant_outboxBalanceLteContractBalance`.
- **numberOfClaimsSent <= tree.count.** Always holds because `_sendRoot` sets `numberOfClaimsSent = tree.count`. Tested in `invariant_numberOfClaimsSentLteTreeCount`.
- **Cross-token execution isolation.** Claiming index N on token A does not mark index N as executed for token B. The `_executedFor` bitmap is keyed by terminal token address. Tested in `test_concurrentClaim_crossTokenExecutionIsolation`.
- **Claim and emergency exit slot independence.** A regular claim (inbox path) and an emergency exit (outbox path) for the same index on the same token use different bitmap keys and do not interfere. Tested in `test_merkleTree_claimAndEmergencyExitSlotIndependence`.
- **Tree count monotonically increases.** `MerkleLib.Tree.count` only increments (append-only). No operation decreases the count. Tested in `invariant_treeCountMonotonicallyIncreases`.
- **Message version gate.** `fromRemote` rejects any message where `root.version != MESSAGE_VERSION`, and `fromRemoteAccounting` applies the same gate to accounting-only snapshots. Tested in `test_merkleTree_messageVersionValidation` and peer-accounting unit coverage.

## 10. Accepted behaviors

### 10.1 Stale nonce messages silently ignored (not reverted)

`fromRemote` does not revert when receiving a message with a nonce <= the current inbox nonce. Instead, it emits `StaleRootRejected` and returns silently. This is intentional for native ETH bridges: reverting a message that carries native ETH (e.g., OP bridge `relayMessage` with value) would lose the ETH. Silent acceptance preserves bridge funds while discarding the stale root. Monitoring systems should watch for `StaleRootRejected` events as indicators of bridge message ordering issues.

### 10.2 Emergency hatch is irreversible

Once `enableEmergencyHatchFor(token)` is called, the token mapping is permanently disabled (`enabled = false`, `emergencyHatch = true`). There is no mechanism to re-enable the mapping or close the hatch. This is a conscious trade-off: reversibility would require additional access control and state transitions that could be exploited to trap tokens. The irreversibility forces a clean deployment of a new sucker when recovery is complete.

### 10.3 Registry-controlled fee with ETH price adjustability

The registry owner can adjust `toRemoteFee` via `JBSuckerRegistry.setToRemoteFee()`, up to the hard cap of `MAX_TO_REMOTE_FEE` (0.001 ether). A single call applies to all suckers globally. This mitigates ETH price risk: if ETH price changes significantly, the registry owner can adjust the fee without deploying new suckers. Because fee control is centralized, individual sucker clones have no per-clone ownership (`Ownable` has been removed from `JBSucker`) and no `transferOwnership()` or `renounceOwnership()`. If registry ownership is renounced, the fee is frozen and the only recourse is deploying a new registry and new suckers.

### 10.4 Fee is paid to the protocol project, not the sucker's project

The fee is paid to `FEE_PROJECT_ID` (the protocol project), not to the sucker's own `projectId()`. This centralizes fee collection, but it is still only best-effort: if the fee project's native terminal is missing or its `pay` call reverts, the fee ETH stays in the sucker contract as refundable caller credit. The sucker's project does not directly benefit from the anti-spam fee.

### 10.5 Registry aggregate views prioritize liveness over completeness

`JBSuckerRegistry.totalRemoteBalanceOf`, `totalRemoteSurplusOf`, and `remoteTotalSupplyOf` intentionally use `try/catch` around each (sucker, chain) pair and silently ignore pairs that revert. Each sucker is a raw, oracle-free carrier: it exposes only un-valued per-currency contexts via `peerChainContextsOf(chainId)`, resolved from raw stored contexts at read time, and the registry (which holds the `IJBPrices` reference) values them, exactly as the terminal store values local surplus. A context whose currency already matches the requested currency is taken at par via an identity short-circuit with no feed consulted; a cross-currency context is valued through the price feed, and a missing feed reverts only that (sucker, chain) (caught by the per-pair `try/catch`, so the aggregate is biased low rather than wrong). Both active and deprecated suckers can be included, with per-source-chain deduplication: the aggregate walks every (sucker, chain) pair and dedups per source chain. When multiple pairs report the same source chain (e.g., redundant bridge providers for resilience, or during a migration window), active records are deduped to the freshest accepted record because each sucker caches the entire remote chain's state per source chain (not a per-sucker share) -- SUM would double-count. MAX is only a same-freshness tie-breaker and a deprecated-sucker fallback when no active sucker answers for that source chain. This lets a project run multiple bridge lanes for the same asset pair so users can choose a risk profile, while preventing redundant active lanes from inflating aggregate remote values. This is accepted because a single bad peer should not brick every cross-chain dashboard or estimator. The trade-off is that these read surfaces are best-effort only: consumers must treat them as freshness-biased estimates, not exact reconciled totals, unless they independently verify that every active sucker responded successfully and agree with the selected records.

### [ARCHIVED] 10.6 Zero-output swap batches route to pendingSwapOf

Archived (src/archive/, not compiled or deployed) — retained for reference.

When `JBSwapCCIPSucker.ccipReceive` receives bridge tokens and the swap succeeds but returns zero local tokens (e.g., due to extreme price impact or dust amounts), the batch is routed to `pendingSwapOf` for later retry via `retrySwap`. Without this, claims would proceed with zero terminal backing, minting unbacked project tokens. The trade-off is that these batches require a manual `retrySwap` call once pool conditions improve. Anyone can call `retrySwap` — it is permissionless.

### [ARCHIVED] 10.7 Hookless V4 spot pricing is sandwich-vulnerable by design

Archived (src/archive/, not compiled or deployed) — retained for reference.

When no TWAP-capable route is available for a cross-denomination swap, a hookless V4 pool can be used as a last-resort spot-priced fallback. `_getV4Quote` then uses the instantaneous spot tick from `POOL_MANAGER.getSlot0()` instead of a TWAP oracle. This tick is manipulable via sandwich attacks, allowing an attacker to skew the `minAmountOut` and extract value from the swap. The sigmoid slippage model limits the damage but operates on a corrupted baseline. This is an accepted liveness tradeoff for the no-TWAP-route case: reverting when no TWAP is available would cause the CCIP message to fail, leaving bridged tokens stuck until manual retry. Hooked V4 pools must serve the configured TWAP window; if the hook's `observe()` reverts or lacks history, that pool is not eligible to beat a V3 TWAP route or degrade silently to spot.

### 10.8 `mapToken` and `mapTokens` refund unused ETH

`mapToken()` and `mapTokens()` only use `msg.value` when mappings are being disabled and need transport payment for the
final root flush. `_mapToken` reports whether it actually sent a root. Any ETH that was not used by a root send is
refunded to `_msgSender()`, including enable-only value, duplicate/no-op disable value, and integer-division dust. If
the refund transfer fails (e.g., the caller is a non-payable contract), the call reverts with `JBSucker_RefundFailed`.

### [ARCHIVED] 10.9 Zero-value `prepare()` is rejected (layered with zero-leaf inbox skip)

Archived (src/archive/, not compiled or deployed) — retained for reference.

The nonce-inflation DoS on swap-CCIP suckers is defended at two layers:

1. **Source-side**: `prepare()` reverts with `JBSucker_ZeroProjectTokenCount` when `projectTokenCount == 0`. The source-side revert is partial — an attacker who already holds project tokens can still pass `projectTokenCount = 1` and pay roughly the same gas to grief nonces; the floor moves from "any EOA" to "any project-token holder," but a holder with a meaningful supply can still spam at 1-wei-of-project-token-per-nonce.
2. **Destination-side**: `JBSwapCCIPSucker.ccipReceive` only writes `_batchStartOf`, `_batchEndOf`, and the `_populatedNonceByIndex` append when the incoming root has `leafTotal > 0`. Zero-leaf roots — whether shipped by a compromised peer or by the `projectTokenCount = 1` bypass cashing out to 0 terminal tokens — record nothing and cannot grow the per-token nonce list that `_findNonceForLeafIndex` walks.

Together the layers close the DoS surface: an attacker can still burn gas spamming `prepare(1) -> toRemote()`, but the remote sucker no longer pays a permanent storage cost for it. See `test/archive/SwapCCIP_PopulatedNonceDoS.t.sol` (archived) for the quantified gas curve and the destination-side closure proof (`test_Q1_real_ccipReceive_zeroValueBatchesDoNotGrowList`).

### 10.10 Suckers carry raw per-currency contexts; valuation happens at read time in the registry

A sucker is an oracle-free data carrier with a per-source-chain store. On receive, each record in the gossip bundle whose source freshness key beats the one already held for its chain rebuilds that chain's raw context set: contexts are stored verbatim, in the source chain's own token addresses, so the record can be re-gossiped faithfully. There is **no per-token currency cache**. The local-currency resolution happens at **read time** in `JBSuckerLib.foldPeerContexts`: each raw stored context resolves to its local token (mapping first, identity fallback) and the currency is derived from that resolved local token — by default the terminal's authoritative accounting-context currency, and if the terminal has been removed it falls back to the address-derived `uint32(uint160(token))` currency convention. Contexts are summed only when they match on **both currency and decimals**, and this fold runs **per source chain**; a fresher record rebuilds that chain's set (dropped contexts simply vanish). Because the amounts are raw and un-valued, same-currency contexts that differ in decimals (including ones appended by project data hooks via `IJBPeerChainAdjustedAccounts`) are kept as separate per-`(currency, decimals)` entries rather than summed across precisions; the registry decimals-adjusts each independently at read time. Optional data-hook peer adjustments are decoded defensively, so reverting, non-supporting, or malformed successful returns contribute no extra supply or contexts. The sucker exposes per-chain raw views, `peerChainContextsOf(chainId)` returning `JBPeerChainContext{currency, decimals, surplus, balance}` per currency — un-valued amounts in each currency's own units — plus `peerChainAccountsOf()` returning the raw records for re-gossiping. The sucker holds no prices/oracle reference.

The `IJBPrices` reference lives on `JBSuckerRegistry`, which does the valuation exactly as the terminal store values local surplus. The per-sucker `remoteBalanceOf(sucker, chainId, ...)` / `remoteSurplusOf(sucker, chainId, ...)` and the aggregates `totalRemoteBalanceOf` / `totalRemoteSurplusOf(projectId, currency, decimals)` decimals-adjust each context and then value it: a context whose currency already equals the requested currency is taken at par via an identity short-circuit with no feed consulted (so same-asset revnets like NANA-ETH and DEFIFA/ART-USDC never touch a price feed), while a cross-currency context is valued through the project's `JBPrices` feed. A missing cross-currency feed reverts, and the registry's per-`(sucker, chain)` `try/catch` swallows that revert — dropping just that pair, biasing the aggregate low (the safe, conservative direction) rather than returning a wrong number.

Projects that need cross-currency remote surplus and balance accounting (peer state denominated in a currency different from the one being read) should register the relevant price feed via `JBPrices`, the same feed the local terminal store would use. Same-currency remote state needs no feed at all.

The gossip mechanism extends trust transitively across a project's own same-address sucker mesh: a hub forwards sibling-spoke records, so a spoke that has no direct sucker to another spoke still learns that chain's accounting. This is not a new trust assumption on a third party — every record is built on-chain from authenticated peer state (gathered through the registry from the project's own suckers), never from caller-supplied data, so a record is only ever as trustworthy as its origin chain's own sucker, exactly the same trust already extended to the directly-paired peer.

### 10.11 Accounting-only sync updates peer state, not claim state

`syncAccountingData()` lets any caller send a gossip bundle — this chain's record plus every peer-chain record the project knows (gathered through the registry, excluding the destination chain) — without sending a Merkle root or transported value. The receiver handles this through `fromRemoteAccounting(JBAccountingSnapshot)`, which shares the same peer authentication, message-version gate, and per-source-chain freshness rule as the accounting portion of `fromRemote`. A fresh record can update `peerChainTotalSupplyOf[chainId]`, that chain's `_peerContextsOf[chainId]`, and `snapshotTimestampOf[chainId]` for the source chain it describes; records for `block.chainid` or chain 0 are dropped. None of this updates any token's inbox nonce/root or makes claims available.

Duplicate accounting bundles are allowed: the sender assigns a fresh source timestamp to its own record every time, even if the underlying supply, surplus, and balance are unchanged. This keeps accounting syncs retryable and avoids coupling them to root sends, but accepts a spam tradeoff on bridge delivery and off-chain indexing. The receiver's per-chain strict freshness gate means an older duplicate for a given chain cannot roll that chain back, and even a fresher duplicate only rewrites that source chain's accounting fields; root, nonce, claimability, and transported value stay untouched.

### [ARCHIVED] 10.12 Claim nonce lookup is bounded by received batches, not sparse nonce gaps

Archived (src/archive/, not compiled or deployed) — retained for reference.

`_findNonceForLeafIndex` in `JBSwapCCIPSucker` walks a compact `_populatedNonceByIndex` list, which is appended once for each received non-empty batch. This means sparse or out-of-order CCIP nonce delivery (for example nonce 10 arriving before nonce 2) does not force the claim path to scan empty nonce slots. The remaining cost is O(number of received batches for the token), because the populated list is insertion-ordered and each entry's `[batchStart, batchEnd)` range must be checked until the matching batch is found. This is accepted because received batches are expected to stay small for a given project/token lane, and preserving an unbounded but complete lookup avoids making older valid claims unreachable. If a lane is expected to process a very large number of batches, operators should monitor claim gas and rotate to a fresh sucker before lookup cost becomes operationally painful.
