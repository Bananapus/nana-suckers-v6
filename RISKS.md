# Suckers Risk Register

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

## 1. Trust Assumptions

- **Bridge liveness.** Each implementation delegates message authentication to an external AMB (Optimism `CrossDomainMessenger`, Arbitrum `Bridge`/`Outbox`/`ArbSys`, Chainlink CCIP `Router`). A compromised or censoring AMB can forge roots, withhold messages, or permanently block claims.
- **OP Stack (Optimism, Base, Celo):** trusts `OPMESSENGER.xDomainMessageSender()` for peer identity. A vulnerability in the OP messenger (or a malicious upgrade behind a proxy) would bypass all access control.
- **Arbitrum:** L1 side trusts `ARBINBOX.bridge().activeOutbox().l2ToL1Sender()`; L2 side trusts `AddressAliasHelper.applyL1ToL2Alias(peer)`. A compromised bridge or outbox contract breaks authentication.
- **CCIP:** trusts `CCIP_ROUTER` identity plus `any2EvmMessage.sender` and `sourceChainSelector`. The router address is immutable at deploy time -- if Chainlink rotates routers, the sucker is bricked (no upgrade path).
- **CREATE2 peer assumption.** `peer()` defaults to `address(this)`, assuming deterministic cross-chain deployment. Breaks if deployer address, init code, or factory nonce differs across chains. Incorrect peer = permanent fund loss (messages accepted from nobody, or routed to wrong address).
- **Controller/terminal must exist on destination chain.** `_handleClaim` calls `controllerOf(projectId).mintTokensOf()`. If the project does not exist or has no controller on the remote chain, all claims permanently revert -- funds are stuck.
- **Registry allowlisting does not verify deployer singleton provenance.** `JBSuckerRegistry.deploySuckersFor()` only checks the deployer allowlist, not the singleton implementation behind the deployer. `configureSingleton()` can point an approved deployer at any JBSucker singleton. This is a privileged-only concern (both deployer configuration and registry allowlisting require governance). Defense: validate deployer configuration during registry allowlist reviews.
- **No reentrancy guard.** The contract relies on state ordering (mark-executed-before-external-call) rather than explicit ReentrancyGuard. Correct today, but fragile to future refactors.

## 2. Merkle Tree Risks

- **Append-only guarantee is structural, not enforced by storage.** The outbox tree's `MerkleLib.Tree` struct stores `branch[32]` and `count`. Nothing prevents a privileged test helper or a storage-corrupting bug from mutating the branch array directly, which would silently invalidate all existing proofs.
- **Root divergence on nonce skip.** `fromRemote` accepts any nonce strictly greater than the current inbox nonce (not sequential). If nonce 3 arrives before nonce 2, the inbox jumps to nonce 3's root. Leaves from nonce 2's batch are still provable against nonce 3's root (append-only), but proofs generated against nonce 2's root are invalid -- off-chain systems must regenerate proofs against the current root.
- **Root atomicity gap.** Between `_sendRoot` clearing `outbox.balance` and the AMB delivering the root to the remote peer, `amountToAddToBalanceOf` is transiently inflated (contract holds tokens that the outbox no longer tracks). This is benign because tokens are only added to balance atomically during `claim()`.
- **Tree depth overflow.** The tree supports `2^32 - 1` leaves. At ~4 billion leaves this saturates, but each insertion costs ~100k gas, making it practically unreachable. The tree reverts with `MerkleLib_InsertTreeIsFull` if the cap is hit.
- **Proof invalidation on new root.** When a new root is delivered via `fromRemote`, all existing proofs computed against the old root become invalid. Users must regenerate proofs against the latest inbox root. No on-chain mechanism exists to signal this -- it depends entirely on off-chain indexers.
- **Z_HASH compatibility.** The MerkleLib uses hardcoded Z_0 through Z_32 constants. These must match the SVM implementation exactly for cross-VM suckers. A mismatch would produce different roots from identical leaf sets.

## 3. Cross-Chain Atomicity

- **Arbitrum non-atomic token+message delivery.** `_toL2` creates two independent retryable tickets: one for the ERC-20 bridge transfer and one for the `fromRemote` merkle root message. These are redeemed independently on L2 with no ordering guarantee. `_addToBalance` checks actual token balance to prevent unbacked minting when message arrives before tokens.
- **CCIP: no guaranteed delivery order.** CCIP does not guarantee in-order delivery. The contract handles this by accepting any nonce > current, but concurrent `toRemote` calls for the same token could result in a later root arriving first, skipping an intermediate root.
- **OP Stack: generally ordered** but the L1-to-L2 message must be relayed by an off-chain actor. A delayed or dropped relay permanently blocks claims until someone retries the relay.
- **Message loss.** If an AMB silently fails (accepts the message on L1 but never delivers to L2), `numberOfClaimsSent` is incremented but the remote peer never receives the root. Those leaves are blocked from both remote claim and local emergency exit (conservative: locked, not double-spent). Recovery requires enabling the emergency hatch.
- **Aggregate balance accounting.** `amountToAddToBalanceOf(token)` computes `balanceOf(this) - outbox.balance`, making all contract-held tokens fungible claim backing. This is intentional: all funds serve the same project, so refunded ETH (from failed Arbitrum retryable tickets) and stale native deliveries correctly become project-claimable. The tradeoff is that later roots can consume liquidity from earlier failed batches, but the project is the ultimate beneficiary in all cases.
- **`fromRemote` does not revert on stale nonce.** By design, stale/duplicate messages are silently ignored (emitting `StaleRootRejected`). This prevents fund loss on native token transfers where reverting would lose the ETH, but means monitoring must watch for this event to detect bridge issues.

## 4. Token Mapping Risks

- **Immutable after first use.** Once `_outboxOf[token].tree.count != 0` (first `prepare`), the remote token address cannot be changed to a different address -- only disabled (set to `bytes32(0)`). A wrong initial mapping is catastrophic: requires deploying a new sucker.
- **Disable triggers final root flush.** Setting `remoteToken = bytes32(0)` when the outbox has unsent leaves calls `_sendRoot`, which requires `transportPayment` (msg.value). If the caller does not provide sufficient msg.value, the disable transaction reverts.
- **Emergency hatch is irreversible.** Once `enableEmergencyHatchFor(token)` is called, `enabled` is set to false and `emergencyHatch` to true. There is no way to re-enable the mapping or close the hatch. This is permanent.
- **Native token mapping constraints differ by sucker.**
  - OP/Arb suckers: `NATIVE_TOKEN` can only map to `NATIVE_TOKEN` or `bytes32(0)`.
  - CCIP and Celo suckers: `NATIVE_TOKEN` can map to any remote token (for chains where ETH is an ERC-20).
  - Wrong native mapping can cause permanent loss: e.g., bridging ETH to a non-WETH ERC-20 address on the remote chain.
- **`fromRemote` accepts roots for unmapped tokens.** By design, to avoid permanent loss of already-bridged tokens. Claims against those roots fail at the mapping lookup. This means stale token data can accumulate in inbox storage indefinitely.
- **minGas too low = permanent fund loss.** If `minGas` is below the actual gas needed for the remote call, the bridge message will fail on the remote chain. The OP/CCIP implementations enforce `MESSENGER_ERC20_MIN_GAS_LIMIT` (200k), but the actual gas needed could be higher depending on the remote token implementation.
- **Cross-reference: omnichain deployer token mapping.** When suckers are deployed through `JBOmnichainDeployer`, the `MAP_SUCKER_TOKEN` permission is granted to the sucker registry with `projectId=0` (wildcard). This means the registry can map tokens for ALL projects, not just the one being deployed. See [nana-omnichain-deployers-v6 RISKS.md](../nana-omnichain-deployers-v6/RISKS.md) section 3 for the permission escalation analysis.

## 5. Fee Collection Risks

- **Best-effort fee collection.** `toRemoteFee` is a centralized storage variable on `JBSuckerRegistry` (ETH, in wei) — uniform across all suckers and all tokens, non-bypassable by integrators. It is paid into `FEE_PROJECT_ID` (typically project ID 1) via `terminal.pay()`. If the fee project has no primary terminal for `NATIVE_TOKEN`, or if `terminal.pay()` reverts for any reason, `toRemote()` still proceeds, but the fee ETH is retained as a refundable balance for the original caller and excluded from native add-to-balance accounting. Fee collection is therefore best-effort at the protocol-fee destination even though users still supply the fee amount.
- **Renounced registry ownership risk.** If the registry owner calls `renounceOwnership()`, `setToRemoteFee()` becomes permanently uncallable and the fee is frozen at its current value across all suckers. This is a deliberate trade-off: it allows the registry owner to credibly commit to a fee level, but eliminates the ability to respond to future ETH price changes. The fee is still capped at `MAX_TO_REMOTE_FEE`, so the maximum downside is bounded.
- **Immutable fee project.** `FEE_PROJECT_ID` is set at construction and cannot be changed. If the fee project is abandoned or its terminal removed, there is no way to redirect fees without deploying new suckers.
- **Cross-reference: sucker registration path.** Suckers are deployed via `JBSuckerRegistry.deploySuckersFor`, which requires `DEPLOY_SUCKERS` permission from the project owner. The registry's `deploy` function uses `CREATE2` with a deployer-specific salt. The sucker's `peer()` address is deterministic — a misconfigured peer means the sucker accepts messages from the wrong remote address. See [nana-omnichain-deployers-v6 RISKS.md](../nana-omnichain-deployers-v6/RISKS.md) for deployer-level risks.
- **Registry aggregate views fail open.** `JBSuckerRegistry.remoteBalanceOf`, `remoteSurplusOf`, and `remoteTotalSupplyOf` use per-chain MAX (not SUM) because each sucker caches the entire remote chain's state — multiple active suckers for the same chain report redundant snapshots. Deprecated suckers are included only when no active sucker answers for the same peer chain. The views silently skip any sucker that reverts. This preserves liveness for dashboards and cross-chain estimates, but it means the returned aggregate can understate remote state whenever one peer is broken, censored, or simply expensive to query.

## 6. Deprecation Lifecycle

- **State machine: ENABLED -> DEPRECATION_PENDING -> SENDING_DISABLED -> DEPRECATED.**
  - `DEPRECATION_PENDING`: fully functional, warning only. `block.timestamp < deprecatedAfter - _maxMessagingDelay()`.
  - `SENDING_DISABLED`: no new `prepare()` or `toRemote()`. `block.timestamp >= deprecatedAfter - _maxMessagingDelay()` but `< deprecatedAfter`.
  - `DEPRECATED`: outbound sends blocked. Incoming roots are still accepted to prevent stranding already-sent tokens. Emergency exits allowed.
- **Irrecoverability once SENDING_DISABLED.** `setDeprecation` reverts in SENDING_DISABLED and DEPRECATED states. Once the sucker enters SENDING_DISABLED, there is no way to cancel or extend the deprecation.
- **Messaging delay = 14 days.** `_maxMessagingDelay()` returns 14 days for all implementations. The deprecation timestamp must be at least `block.timestamp + 14 days` in the future. This is generous for OP/Arb (minutes to hours) but may be insufficient if a bridge has an extended outage.
- **Stuck tokens during deprecation.** Tokens that were `prepare()`d but not yet `toRemote()`d before SENDING_DISABLED cannot be sent to the remote chain. They can only be recovered via emergency exit after the sucker reaches DEPRECATED state.
- **Both sides must deprecate.** The deprecation must be called on both the local and remote sucker with matching timestamps. If only one side deprecates, the other side continues accepting roots while the deprecated side blocks outbound sends. The deprecated side still accepts incoming roots, so tokens sent before deprecation can be claimed.

## 7. Emergency Hatch

- **Two independent activation paths:**
  1. Per-token: `enableEmergencyHatchFor(tokens)` -- requires `SUCKER_SAFETY` permission from project owner. Allows emergency exit for specific tokens while the sucker is still ENABLED.
  2. Global: deprecation reaching SENDING_DISABLED or DEPRECATED state. Allows emergency exit for all tokens.
- **Claim vs emergency exit use separate bitmap slots.** Emergency exit uses `_executedFor[keccak256(abi.encode(terminalToken))]` while regular claims use `_executedFor[terminalToken]`. This means a leaf that was emergency-exited locally could theoretically also be claimed remotely if the root was already sent -- double-spend is prevented only by the `numberOfClaimsSent` check.
- **`numberOfClaimsSent` is the critical guard.** Emergency exit reverts if `outbox.numberOfClaimsSent != 0 && outbox.numberOfClaimsSent - 1 >= index`. The `numberOfClaimsSent != 0` precondition prevents underflow when no root has ever been sent — in that case, all leaves are available for emergency exit. This means leaves at indices below `numberOfClaimsSent` cannot be emergency-exited (they may have been sent to the remote peer). If `_sendRootOverAMB` silently fails, these leaves are permanently locked.
- **Emergency exit decrements `outbox.balance`.** If emergency exits drain the outbox balance below the amount that was already sent to the bridge, the accounting becomes inconsistent. The contract guards against this by only allowing exit for unsent leaves.
- **Emergency exit recipient is the leaf beneficiary.** `exitThroughEmergencyHatch()` refunds to `claimData.leaf.beneficiary`, not the original `prepare()` caller. The depositor chose this beneficiary when preparing the bridge; the leaf structure does not store the depositor address. If Alice prepares for Bob and the bridge fails, Bob gets the emergency refund, not Alice. This is the intended behavior: the depositor delegated their claim to the beneficiary.
- **`numberOfClaimsSent` advancement timing.** `_sendRoot()` sets `numberOfClaimsSent` before `_sendRootOverAMB()` completes. If the L1 transaction succeeds but L2 delivery fails, those leaves are blocked from emergency exit. Mitigations: Arbitrum retryable tickets can be manually re-executed on L2; Optimism messages can be re-relayed by anyone. If delivery permanently fails, `enableEmergencyHatchFor()` combined with project owner intervention can recover. Adding a rollback mechanism would introduce double-spend risk (leaf claimable on both chains). Current design is conservative: locked funds are preferable to double-spent funds.
- **Emergency hatch + minting.** Emergency exit calls `_handleClaim`, which mints project tokens via the controller. If the controller or token contract is broken/missing, emergency exits also revert -- there is no "raw withdrawal" of terminal tokens without minting.

## 8. DoS Vectors

- **Large proof calldata.** Each claim requires a 32-element `bytes32[32]` proof array (1024 bytes). Batch claims (`claim(JBClaim[])`) scale linearly. A batch of 100 claims is ~100KB of calldata, approaching some L2 calldata limits.
- **Bridge gas limits.** `MESSENGER_BASE_GAS_LIMIT` is 300k and `MESSENGER_ERC20_MIN_GAS_LIMIT` is 200k. If the remote chain's gas costs increase (e.g., after an EVM upgrade), these hardcoded limits may become insufficient, causing all bridge messages to fail.
- **uint128 cap for SVM compatibility.** `_insertIntoTree` reverts if `projectTokenCount` or `terminalTokenAmount` exceeds `type(uint128).max`. This is enforced for cross-VM compatibility but limits EVM-only use cases to ~3.4e38 wei per leaf.
- **Arbitrum retryable ticket pricing.** `_toL2` uses `block.basefee` as `maxFeePerGas`. If L2 gas prices spike above L1's `block.basefee`, the retryable ticket may not auto-redeem and requires manual retry.
- **CCIP fee volatility.** `_sendRootOverAMB` checks `CCIP_ROUTER.getFee()` at call time. If fees spike between estimation and execution, the transaction reverts with `JBSucker_InsufficientMsgValue`. No retry mechanism exists.
- **`toRemote` fee fallback retains refundable ETH.** If the fee project's terminal is missing or `terminal.pay()` reverts, `toRemote()` keeps the fee ETH in the sucker so zero-cost bridges can still proceed with `transportPayment = msg.value - fee`. The retained fee is credited to the original caller, excluded from `amountToAddToBalanceOf(NATIVE_TOKEN)`, and can be reclaimed with `claimRetainedToRemoteFee(...)`. The retained amount per affected call is bounded by `MAX_TO_REMOTE_FEE` (currently `0.001 ether`).
- **CCIP transport payment refund failure.** If `_msgSender()` is a non-payable contract, the refund `call` fails silently. The excess ETH (transportPayment - fees) is permanently stuck in the sucker. The contract emits `TransportPaymentRefundFailed` but has no sweep mechanism.
- **Unbounded sucker count per project.** `JBSuckerRegistry._suckersOf` uses an EnumerableMap with no cap. `suckerPairsOf` iterates all suckers with external calls per iteration. Extremely large sucker counts could cause view functions to exceed gas limits.
- **Unrestricted `receive()`.** Anyone can send ETH to the sucker, inflating `amountToAddToBalanceOf`. This is by design (needed for bridge/terminal returns) but means the project can receive unexpected balance additions.

## 9. Invariants to Verify

- **Nonce monotonicity.** Outbox nonce increments exactly once per `_sendRoot` call. Inbox nonce only increases (never decreases or replays). Tested in `invariant_nonceMonotonicallyIncreases`.
- **No double-claim.** `_executedFor[token].get(index)` is checked before and set before any external call. Each leaf index can be claimed exactly once. Tested in `invariant_eachLeafClaimedOnce`.
- **No double-emergency-exit.** Emergency exit uses a separate bitmap slot (`keccak256(abi.encode(token))`) but the same `_executedFor` mapping. Each leaf can be emergency-exited exactly once. Tested in `test_merkleTree_emergencyExitAtomicity`.
- **Balance accuracy across send cycles.** `outbox.balance == totalInserted - totalEmergencyExited - totalSent`. The invariant test (`invariant_outboxBalanceAccountedCorrectly`) verifies this holds across arbitrary sequences of insert/send/exit.
- **outbox.balance <= address(sucker).balance.** The tracked outbox balance never exceeds the contract's actual token balance. Tested in `invariant_outboxBalanceLteContractBalance`.
- **numberOfClaimsSent <= tree.count.** Always holds because `_sendRoot` sets `numberOfClaimsSent = tree.count`. Tested in `invariant_numberOfClaimsSentLteTreeCount`.
- **Cross-token execution isolation.** Claiming index N on token A does not mark index N as executed for token B. The `_executedFor` bitmap is keyed by terminal token address. Tested in `test_concurrentClaim_crossTokenExecutionIsolation`.
- **Claim and emergency exit slot independence.** A regular claim (inbox path) and an emergency exit (outbox path) for the same index on the same token use different bitmap keys and do not interfere. Tested in `test_merkleTree_claimAndEmergencyExitSlotIndependence`.
- **Tree count monotonically increases.** `MerkleLib.Tree.count` only increments (append-only). No operation decreases the count. Tested in `invariant_treeCountMonotonicallyIncreases`.
- **Message version gate.** `fromRemote` rejects any message where `root.version != MESSAGE_VERSION`. Tested in `test_merkleTree_messageVersionValidation`.

## 10. Accepted Behaviors

### 10.1 Stale nonce messages silently ignored (not reverted)

`fromRemote` does not revert when receiving a message with a nonce <= the current inbox nonce. Instead, it emits `StaleRootRejected` and returns silently. This is intentional for native ETH bridges: reverting a message that carries native ETH (e.g., OP bridge `relayMessage` with value) would lose the ETH. Silent acceptance preserves bridge funds while discarding the stale root. Monitoring systems should watch for `StaleRootRejected` events as indicators of bridge message ordering issues.

### 10.2 Emergency hatch is irreversible

Once `enableEmergencyHatchFor(token)` is called, the token mapping is permanently disabled (`enabled = false`, `emergencyHatch = true`). There is no mechanism to re-enable the mapping or close the hatch. This is a conscious trade-off: reversibility would require additional access control and state transitions that could be exploited to trap tokens. The irreversibility forces a clean deployment of a new sucker when recovery is complete.

### 10.3 Registry-controlled fee with ETH price adjustability

The registry owner can adjust `toRemoteFee` via `JBSuckerRegistry.setToRemoteFee()`, up to the hard cap of `MAX_TO_REMOTE_FEE` (0.001 ether). A single call applies to all suckers globally. This mitigates ETH price risk: if ETH price changes significantly, the registry owner can adjust the fee without deploying new suckers. Because fee control is centralized, individual sucker clones have no per-clone ownership (`Ownable` has been removed from `JBSucker`) and no `transferOwnership()` or `renounceOwnership()`. If registry ownership is renounced, the fee is frozen and the only recourse is deploying a new registry and new suckers.

### 10.4 Fee is paid to the protocol project, not the sucker's project

The fee is paid to `FEE_PROJECT_ID` (the protocol project), not to the sucker's own `projectId()`. This centralizes fee collection, but it is still only best-effort: if the fee project's native terminal is missing or its `pay` call reverts, the fee ETH stays in the sucker contract as refundable caller credit. The sucker's project does not directly benefit from the anti-spam fee.

### 10.5 Registry aggregate views prioritize liveness over completeness

`JBSuckerRegistry.remoteBalanceOf`, `remoteSurplusOf`, and `remoteTotalSupplyOf` intentionally use `try/catch` around each sucker and silently ignore peers that revert. Both active and deprecated suckers can be included, with per-chain deduplication: when multiple suckers target the same peer chain (e.g., redundant bridge providers for resilience, or during a migration window), the MAX value among active suckers is used because each sucker caches the entire remote chain's state (not a per-sucker share) — SUM would double-count. Deprecated sucker values are used only if no active sucker answers for that peer chain. This is accepted because a single bad peer should not brick every cross-chain dashboard or estimator. The trade-off is that these read surfaces are best-effort only: consumers must treat them as lower bounds, not exact reconciled totals, unless they independently verify that every active sucker responded successfully.

### 10.6 Zero-output swap batches route to pendingSwapOf

When `JBSwapCCIPSucker.ccipReceive` receives bridge tokens and the swap succeeds but returns zero local tokens (e.g., due to extreme price impact or dust amounts), the batch is routed to `pendingSwapOf` for later retry via `retrySwap`. Without this, claims would proceed with zero terminal backing, minting unbacked project tokens. The trade-off is that these batches require a manual `retrySwap` call once pool conditions improve. Anyone can call `retrySwap` — it is permissionless.

### 10.7 Hookless V4 spot pricing is sandwich-vulnerable by design

When no TWAP-capable route is available for a cross-denomination swap, a hookless V4 pool can be used as a last-resort spot-priced fallback. `_getV4Quote` then uses the instantaneous spot tick from `POOL_MANAGER.getSlot0()` instead of a TWAP oracle. This tick is manipulable via sandwich attacks, allowing an attacker to skew the `minAmountOut` and extract value from the swap. The sigmoid slippage model limits the damage but operates on a corrupted baseline. This is an accepted liveness tradeoff for the no-TWAP-route case: reverting when no TWAP is available would cause the CCIP message to fail, leaving bridged tokens stuck until manual retry. Hooked V4 pools must serve the configured TWAP window; if the hook's `observe()` reverts or lacks history, that pool is not eligible to beat a V3 TWAP route or degrade silently to spot.

### 10.8 `mapTokens` refunds ETH on enable-only batches

`mapTokens()` only uses `msg.value` when one or more mappings are being disabled and need transport payment for the final root flush. If every mapping in the batch is enable-only (`numberToDisable == 0`), the full `msg.value` is refunded to `_msgSender()`. If the refund transfer fails (e.g., the caller is a non-payable contract), the call reverts with `JBSucker_RefundFailed`. When disables are present, any dust remainder from integer division (`msg.value % numberToDisable`) is also refunded on a best-effort basis.

### 10.9 Zero-value `prepare()` is allowed

`prepare()` does not reject `projectTokenCount == 0`. A zero-value check would be trivially bypassed by passing `1` instead, so it provides no real protection against remap-window consumption. The cost to create a leaf with `projectTokenCount = 1` is negligible (1 wei of project tokens). The one-time remap window is protected by the token mapping's `enabled` flag and the outbox tree count, not by minimum deposit requirements.

### 10.10 Cross-chain currency uses standardized `JBCurrencyIds.ETH` (1), not local token addresses

Snapshot messages encode surplus and balance values using `JBCurrencyIds.ETH` (currency ID `1`) as the cross-chain currency identifier, not `uint32(uint160(JBConstants.NATIVE_TOKEN))` (currency ID `61166`). This is intentional: `NATIVE_TOKEN` (`0x000...EEEe`) is a local sentinel meaning "the native token on this chain," which may represent different assets on different networks (e.g., ETH on mainnet, MATIC on Polygon). A standardized semantic currency ID is required for cross-chain values to be comparable.

On the consuming side, contracts like `REVOwner` and `REVLoans` query sucker-reported values using `uint32(uint160(NATIVE_TOKEN))` — the local terminal convention. The `JBPrices` oracle in `JBSuckerLib.convertPeerValue` resolves the conversion between currency ID `1` (ETH) and currency ID `61166` (native token) when a price feed is registered for the pair. If no feed exists, `convertPeerValue` returns `0`, which is acceptable: it means the project has not configured cross-chain pricing for that token pair, and remote values are simply not factored into local calculations.

Projects that need accurate cross-chain surplus and supply accounting should register a price feed for the `1 ↔ 61166` pair via `JBPrices`. On chains where the native token is ETH, this is a 1:1 identity feed. On chains where the native token is not ETH, the feed should reflect the actual exchange rate.

### 10.11 Nonce reverse scan can exceed gas limit on cold cache

`_findNonceForLeafIndex` in `JBSwapCCIPSucker` scans backwards from `_highestReceivedNonce` when the cache hint and neighbor probe miss. For a long-lived sucker with hundreds of nonces, a non-sequential claim after cache invalidation could cost millions of gas. The nonce cache optimization makes sequential claims O(1), limiting this to edge cases where claims arrive far out of order after cache invalidation. Accepted because: (1) sequential claims (the common path) are O(1) via cache, (2) the expensive path requires an unlikely combination of cache miss + large nonce gap, (3) callers can warm the cache with a prior claim at a nearby index, and (4) bounding the scan would make some valid claims permanently unreachable.
