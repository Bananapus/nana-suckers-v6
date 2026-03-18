# RISKS.md -- nana-suckers-v6

Forward-looking risk catalog for the JBSucker cross-chain bridging system.

---

## 1. Trust Assumptions

- **Bridge liveness.** Each implementation delegates message authentication to an external AMB (Optimism `CrossDomainMessenger`, Arbitrum `Bridge`/`Outbox`/`ArbSys`, Chainlink CCIP `Router`). A compromised or censoring AMB can forge roots, withhold messages, or permanently block claims.
- **OP Stack (Optimism, Base, Celo):** trusts `OPMESSENGER.xDomainMessageSender()` for peer identity. A vulnerability in the OP messenger (or a malicious upgrade behind a proxy) would bypass all access control.
- **Arbitrum:** L1 side trusts `ARBINBOX.bridge().activeOutbox().l2ToL1Sender()`; L2 side trusts `AddressAliasHelper.applyL1ToL2Alias(peer)`. A compromised bridge or outbox contract breaks authentication.
- **CCIP:** trusts `CCIP_ROUTER` identity plus `any2EvmMessage.sender` and `sourceChainSelector`. The router address is immutable at deploy time -- if Chainlink rotates routers, the sucker is bricked (no upgrade path).
- **CREATE2 peer assumption.** `peer()` defaults to `address(this)`, assuming deterministic cross-chain deployment. Breaks if deployer address, init code, or factory nonce differs across chains. Incorrect peer = permanent fund loss (messages accepted from nobody, or routed to wrong address).
- **Controller/terminal must exist on destination chain.** `_handleClaim` calls `controllerOf(projectId).mintTokensOf()`. If the project does not exist or has no controller on the remote chain, all claims permanently revert -- funds are stuck.
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

## 5. Fee Collection Risks

- **Best-effort fee collection.** `toRemoteFee` is a per-clone storage variable (ETH, in wei) — uniform across all tokens on that clone, non-bypassable by integrators. It is paid into `FEE_PROJECT_ID` (typically project ID 1) via `terminal.pay()`. If the fee project has no primary terminal for `NATIVE_TOKEN`, or if `terminal.pay()` reverts for any reason, `toRemote()` silently proceeds without collecting the fee. This means fee collection is best-effort — it can fail if the fee project's terminal is misconfigured, paused, or removed — but the fee amount cannot be set to 0 by users calling `toRemote()`.
- **Admin-adjustable fee.** The clone's owner (set from `_INITIAL_FEE_OWNER` during `initialize()`) can adjust `toRemoteFee` via `setToRemoteFee()`, up to the hard cap of `MAX_TO_REMOTE_FEE` (0.001 ether). This mitigates the ETH price risk present in the previous immutable design: if ETH price changes significantly, the owner can adjust the fee without deploying new singletons. Ownership is per-clone and transferable via OpenZeppelin `Ownable`'s `transferOwnership()`.
- **Renounced ownership risk.** If the clone's owner calls `renounceOwnership()`, `setToRemoteFee()` becomes permanently uncallable and the fee is frozen at its current value. This is a deliberate trade-off: it allows the owner to credibly commit to a fee level, but eliminates the ability to respond to future ETH price changes. The fee is still capped at `MAX_TO_REMOTE_FEE`, so the maximum downside is bounded.
- **Immutable fee project.** `FEE_PROJECT_ID` is set at construction and cannot be changed. If the fee project is abandoned or its terminal removed, there is no way to redirect fees without deploying new suckers.
- **Fee does not protect the sucker's own project.** The fee is paid to `FEE_PROJECT_ID` (the protocol project), not to the sucker's own `projectId()`. This is by design — the protocol project always has a native token terminal — but means the sucker's project does not directly benefit from the anti-spam fee.
- **ETH price risk (mitigated).** `toRemoteFee` is denominated in wei but is now adjustable by the clone's owner (up to `MAX_TO_REMOTE_FEE`). A significant ETH price increase can be mitigated by lowering the fee; a significant decrease can be mitigated by raising it. If ownership has been renounced, the fee is frozen and the only recourse is deploying new singletons.

## 6. Deprecation Lifecycle

- **State machine: ENABLED -> DEPRECATION_PENDING -> SENDING_DISABLED -> DEPRECATED.**
  - `DEPRECATION_PENDING`: fully functional, warning only. `block.timestamp < deprecatedAfter - _maxMessagingDelay()`.
  - `SENDING_DISABLED`: no new `prepare()` or `toRemote()`. `block.timestamp >= deprecatedAfter - _maxMessagingDelay()` but `< deprecatedAfter`.
  - `DEPRECATED`: fully shut down. No new inbox roots accepted. Emergency exits allowed.
- **Irrecoverability once SENDING_DISABLED.** `setDeprecation` reverts in SENDING_DISABLED and DEPRECATED states. Once the sucker enters SENDING_DISABLED, there is no way to cancel or extend the deprecation.
- **Messaging delay = 14 days.** `_maxMessagingDelay()` returns 14 days for all implementations. The deprecation timestamp must be at least `block.timestamp + 14 days` in the future. This is generous for OP/Arb (minutes to hours) but may be insufficient if a bridge has an extended outage.
- **Stuck tokens during deprecation.** Tokens that were `prepare()`d but not yet `toRemote()`d before SENDING_DISABLED cannot be sent to the remote chain. They can only be recovered via emergency exit after the sucker reaches DEPRECATED state.
- **Both sides must deprecate.** The deprecation must be called on both the local and remote sucker with matching timestamps. If only one side deprecates, the other side continues accepting roots while the deprecated side blocks sends -- tokens become unreachable on the non-deprecated side.

## 7. Emergency Hatch

- **Two independent activation paths:**
  1. Per-token: `enableEmergencyHatchFor(tokens)` -- requires `SUCKER_SAFETY` permission from project owner. Allows emergency exit for specific tokens while the sucker is still ENABLED.
  2. Global: deprecation reaching SENDING_DISABLED or DEPRECATED state. Allows emergency exit for all tokens.
- **Claim vs emergency exit use separate bitmap slots.** Emergency exit uses `_executedFor[keccak256(abi.encode(terminalToken))]` while regular claims use `_executedFor[terminalToken]`. This means a leaf that was emergency-exited locally could theoretically also be claimed remotely if the root was already sent -- double-spend is prevented only by the `numberOfClaimsSent` check.
- **`numberOfClaimsSent` is the critical guard.** Emergency exit reverts if `outbox.numberOfClaimsSent - 1 >= index`. This means leaves at indices below `numberOfClaimsSent` cannot be emergency-exited (they may have been sent to the remote peer). If `_sendRootOverAMB` silently fails, these leaves are permanently locked.
- **Emergency exit decrements `outbox.balance`.** If emergency exits drain the outbox balance below the amount that was already sent to the bridge, the accounting becomes inconsistent. The contract guards against this by only allowing exit for unsent leaves.
- **Emergency hatch + minting.** Emergency exit calls `_handleClaim`, which mints project tokens via the controller. If the controller or token contract is broken/missing, emergency exits also revert -- there is no "raw withdrawal" of terminal tokens without minting.

## 8. DoS Vectors

- **Large proof calldata.** Each claim requires a 32-element `bytes32[32]` proof array (1024 bytes). Batch claims (`claim(JBClaim[])`) scale linearly. A batch of 100 claims is ~100KB of calldata, approaching some L2 calldata limits.
- **Bridge gas limits.** `MESSENGER_BASE_GAS_LIMIT` is 300k and `MESSENGER_ERC20_MIN_GAS_LIMIT` is 200k. If the remote chain's gas costs increase (e.g., after an EVM upgrade), these hardcoded limits may become insufficient, causing all bridge messages to fail.
- **uint128 cap for SVM compatibility.** `_insertIntoTree` reverts if `projectTokenCount` or `terminalTokenAmount` exceeds `type(uint128).max`. This is enforced for cross-VM compatibility but limits EVM-only use cases to ~3.4e38 wei per leaf.
- **Arbitrum retryable ticket pricing.** `_toL2` uses `block.basefee` as `maxFeePerGas`. If L2 gas prices spike above L1's `block.basefee`, the retryable ticket may not auto-redeem and requires manual retry.
- **CCIP fee volatility.** `_sendRootOverAMB` checks `CCIP_ROUTER.getFee()` at call time. If fees spike between estimation and execution, the transaction reverts with `JBSucker_InsufficientMsgValue`. No retry mechanism exists.
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
