# User Journeys

Step-by-step flows for every major user interaction with the sucker bridging system.

---

## 1. Deploy Suckers

**Entry point**: `JBSuckerRegistry.deploySuckersFor(uint256 projectId, bytes32 salt, JBSuckerDeployerConfig[] configurations)`

**Who can call**: The project owner, or any address with the owner's `DEPLOY_SUCKERS` permission.

**Parameters**:
- `projectId` -- The ID of the project deploying suckers
- `salt` -- A user-chosen salt for CREATE2 deterministic deployment; must match on both chains
- `configurations` -- Array of `JBSuckerDeployerConfig` structs, each containing:
  - `deployer` -- The allowed deployer contract (e.g., `JBOptimismSuckerDeployer`)
  - `mappings` -- Array of `JBTokenMapping` structs for initial token mappings

**State changes**:
1. Registry enforces `DEPLOY_SUCKERS` permission from the project owner.
2. Computes `salt = keccak256(abi.encode(_msgSender(), salt))` (sender-specific determinism). Note: the deployer also hashes the salt again with its own `_msgSender()` via `keccak256(abi.encodePacked(_msgSender(), salt))`, so the final CREATE2 salt is double-hashed (registry + deployer).
3. For each configuration:
   - Validates the deployer is in the allowlist; reverts with `JBSuckerRegistry_InvalidDeployer` if not.
   - Calls `deployer.createForSender(projectId, salt)` which deploys a clone via CREATE2 and internally calls `initialize(projectId)` on the clone (setting `_localProjectId` and `deployer`). There is no separate `initialize()` call -- it happens inside `createForSender`.
   - Stores the sucker address in `_suckersOf[projectId]`.
   - Calls `sucker.mapTokens(configuration.mappings)` to set initial token mappings.
4. Project owner repeats on the remote chain with the **same salt and same sender address** to deploy the matching peer sucker.

**Events**: `SuckerDeployedFor(projectId, sucker, configuration, caller)` -- emitted once per configuration entry.

**Edge cases**:
- If the deployer is not in the allowlist, reverts with `JBSuckerRegistry_InvalidDeployer`.
- The same sender address must call on both chains for CREATE2 addresses to match; otherwise the suckers will not recognize each other as peers.
- An empty `configurations` array is a no-op.

---

## 2. Map Token

**Entry point**: `JBSucker.mapToken(JBTokenMapping map)` (single) or `JBSucker.mapTokens(JBTokenMapping[] maps)` (batch)

**Who can call**: The project owner, or any address with the owner's `MAP_SUCKER_TOKEN` permission.

**Parameters** (per `JBTokenMapping`):
- `localToken` -- The terminal token address on the local chain
- `remoteToken` -- The corresponding token on the remote chain (`bytes32` for cross-VM compatibility); set to `bytes32(0)` to disable
- `minGas` -- Minimum gas for the bridge message; must be >= `MESSENGER_ERC20_MIN_GAS_LIMIT` (200,000) for non-native tokens
- `minBridgeAmount` -- Minimum amount of terminal tokens to bridge

**State changes**:
1. Validates the emergency hatch is not enabled for the token; reverts with `JBSucker_TokenHasInvalidEmergencyHatchState` if so.
2. `_validateTokenMapping()` checks native-token and min-gas rules.
3. Enforces `MAP_SUCKER_TOKEN` permission from the project owner.
4. Immutability check: if `_remoteTokenFor[token].addr != bytes32(0)` AND the new `remoteToken` differs from the current mapping AND `remoteToken != bytes32(0)` AND `_outboxOf[token].tree.count != 0`, reverts with `JBSucker_TokenAlreadyMapped`. All four conditions must be true for the revert -- notably, the mapping is only considered immutable when both the current remote address is set and the outbox has entries.
5. If disabling a mapping (`remoteToken == bytes32(0)`) and the outbox has unsent entries, `_sendRoot()` is called first to flush them.
6. Stores the mapping: `_remoteTokenFor[token] = JBRemoteToken{enabled: true/false, emergencyHatch: false, minGas, addr: remoteToken}`.

**Events**: None emitted directly by `mapToken`. When disabling triggers a root flush, the `RootToRemote` event is emitted by `_sendRoot()`.

**Edge cases**:
- Once a token has outbox entries, it cannot be remapped to a *different* remote token -- only disabled (mapped to `bytes32(0)`) or re-enabled to the same address.
- For native tokens: `remoteToken` must be `NATIVE_TOKEN` or `bytes32(0)`. CCIP/Celo suckers override this to allow native-to-ERC20 mapping.
- Disabling a mapping that has unsent outbox entries requires `msg.value` for transport payment (to flush the root).
- Re-enabling a previously disabled mapping (same remote address) is allowed even after outbox activity.

---

## 3. Prepare (Bridge Out)

**Entry point**: `JBSucker.prepare(uint256 projectTokenCount, bytes32 beneficiary, uint256 minTokensReclaimed, address token)`

**Who can call**: Anyone (the caller must hold project tokens and have approved the sucker to transfer them).

**Parameters**:
- `projectTokenCount` -- Number of project tokens to bridge (18 decimals)
- `beneficiary` -- Recipient on the remote chain (`bytes32` for cross-VM compatibility; left-padded EVM address or full Solana pubkey)
- `minTokensReclaimed` -- Slippage protection: minimum terminal tokens from cash out; reverts if less
- `token` -- Terminal token to cash out for (e.g., `NATIVE_TOKEN` for ETH)

**State changes**:
1. Validates `beneficiary != bytes32(0)`; reverts with `JBSucker_ZeroBeneficiary` if zero.
2. Validates the project has a deployed ERC-20 token; reverts with `JBSucker_ZeroERC20Token` if not.
3. Validates `_remoteTokenFor[token].enabled == true`; reverts with `JBSucker_TokenNotMapped` if disabled.
4. Validates sucker state is `ENABLED` or `DEPRECATION_PENDING`; reverts with `JBSucker_Deprecated` otherwise.
5. Transfers `projectTokenCount` project tokens from caller to the sucker via `safeTransferFrom`.
6. `_pullBackingAssets()`: calls `terminal.cashOutTokensOf()` with `beneficiary: payable(address(this))` (the sucker itself receives the reclaimed tokens) at 0% cashOutTaxRate (set by JBOmnichainDeployer as data hook). Records the reclaimed amount and asserts the balance delta matches.
7. `_insertIntoTree()`: builds a leaf hash, inserts into `_outboxOf[token].tree`, and increments `_outboxOf[token].balance`.

**Events**: `InsertToOutboxTree(beneficiary, token, hashed, index, root, projectTokenCount, terminalTokenAmount, caller)`

**Edge cases**:
- `projectTokenCount` and `terminalTokenAmount` must each fit in `uint128` (for SVM/Solana compatibility).
- The 0% cashOutTaxRate is enforced by the JBOmnichainDeployer data hook, not by the sucker itself.
- If `minTokensReclaimed` is not met, the cash-out reverts inside the terminal.
- Multiple `prepare()` calls accumulate in the same outbox tree until `toRemote()` is called.

---

## 4. Bridge (toRemote)

**Entry point**: `JBSucker.toRemote{value: transportPayment}(address token)`

**Who can call**: Anyone (typically a relayer). The caller pays for bridge transport and any `toRemoteFee`.

**Parameters**:
- `token` -- The terminal token whose outbox tree to bridge
- `msg.value` -- Must cover `REGISTRY.toRemoteFee()` plus any bridge-specific transport cost

**State changes**:
1. Validates emergency hatch is not enabled for the token; reverts with `JBSucker_TokenHasInvalidEmergencyHatchState`.
2. Validates the outbox has something to send; reverts with `JBSucker_NothingToSend` if `outbox.balance == 0 && outbox.tree.count == outbox.numberOfClaimsSent`.
3. Validates `msg.value >= REGISTRY.toRemoteFee()`; reverts with `JBSucker_InsufficientMsgValue` if insufficient. This check is a hard revert -- it happens before any best-effort logic.
4. Fee deduction: deducts `toRemoteFee` from `msg.value` to compute `transportPayment = msg.value - toRemoteFee`. Then attempts to pay the fee into the fee project (ID 1) via `terminal.pay()`. The fee payment itself is best-effort: if the fee project has no native-token terminal or `pay()` reverts (via try-catch), the fee is returned to `transportPayment` and the call proceeds. Only the bridge transport cost uses the remaining `transportPayment`.
5. `_sendRoot()`:
   - Reads `outbox.tree.count` and `outbox.balance`.
   - Clears `outbox.balance = 0`.
   - Increments `outbox.nonce`.
   - Computes `outbox.tree.root()`.
   - Sets `outbox.numberOfClaimsSent = tree.count`.
6. `_sendRootOverAMB()` (chain-specific): bridges assets and merkle root message to the remote peer.

**Events**: `RootToRemote(root, token, index, nonce, caller)`

**Edge cases**:
- `transportPayment` is 0 for OP bridges, non-zero for Arbitrum L1->L2 and CCIP.
- The `toRemoteFee` is global across all suckers, set by the registry owner via `JBSuckerRegistry.setToRemoteFee()`, capped at `MAX_TO_REMOTE_FEE` (0.001 ether).
- The caller (relayer) receives fee-project tokens in return for paying the fee.
- Bridge delivery time varies: minutes to hours depending on the bridge infrastructure.
- **OP Stack**: Bridges ETH via `OPMESSENGER.sendMessage{value: amount}()`.
- **Arbitrum L1->L2**: Two independent retryable tickets -- one for ERC-20 via gateway router, one for the merkle root message via inbox.
- **CCIP**: Wraps native ETH to WETH, calls `CCIP_ROUTER.ccipSend()` with token amounts and message data.

---

## 5. Claim (Bridge In)

**Entry point**: `JBSucker.claim(JBClaim claimData)` or `JBSucker.claim(JBClaim[] claims)` (batch)

**Who can call**: Anyone (permissionless -- typically the beneficiary or a relayer acting on their behalf).

**Parameters** (per `JBClaim`):
- `token` -- The terminal token on this chain
- `leaf.index` -- The leaf's position in the merkle tree (0-based)
- `leaf.beneficiary` -- The recipient address (`bytes32`)
- `leaf.projectTokenCount` -- Number of project tokens to mint
- `leaf.terminalTokenAmount` -- Amount of terminal tokens to add to balance
- `proof` -- Merkle proof (array of `bytes32` sibling hashes)

**Prerequisite**: The bridge must have delivered the message first. `JBSucker.fromRemote(JBMessageRoot root)` is called by the bridge messenger, which:
1. Validates `_isRemotePeer(_msgSender())` -- the bridge messenger represents the authenticated peer.
2. Validates `root.version == MESSAGE_VERSION` (1).
3. Validates `root.remoteRoot.nonce > inbox.nonce` and sucker is not `DEPRECATED`.
4. Updates `_inboxOf[localToken].root` and `_inboxOf[localToken].nonce`.

**State changes** (claim):
1. `_validate()`: checks `_executedFor[token].get(index)` is false (not already claimed); marks it as executed.
2. Builds leaf hash and computes root via `MerkleLib.branchRoot(hash, proof, index)`.
3. Compares to `_inboxOf[token].root`; reverts with `InvalidProof` if mismatch.
4. `_handleClaim()`:
   - If `terminalTokenAmount > 0`: calls `terminal.addToBalanceOf{value: amount}(projectId, ...)` to add backing assets.
   - Mints `projectTokenCount` project tokens for the beneficiary via `controller.mintTokensOf()` with `useReservedPercent = false` (bypasses reserved percent).

**Events**:
- `fromRemote` path: `NewInboxTreeRoot(token, nonce, root, caller)` on success, or `StaleRootRejected(token, receivedNonce, currentNonce)` if the nonce is not newer OR if the sucker is `DEPRECATED` (even with a valid newer nonce, deprecated suckers reject new roots to prevent double-spend with emergency hatch withdrawals).
- `claim` path: `Claimed(beneficiary, token, projectTokenCount, terminalTokenAmount, index, caller)`

**Edge cases**:
- Off-chain step required: a relayer must compute the merkle proof from `InsertToOutboxTree` events on the source chain.
- Batch `claim(JBClaim[])` iterates and claims each individually; a single invalid proof reverts the entire batch.
- If nonces arrive out of order (e.g., CCIP), the inbox root is set to the latest nonce's root. Earlier proofs need to be regenerated against the new root (the tree is append-only, so all leaves remain provable).
- `fromRemote()` accepts roots for unmapped tokens. Claims will fail at the token mapping lookup, but accepting prevents permanent loss of bridged tokens (a future mapping enables claims).

---

## 6. Deprecate Sucker

**Entry point**: `JBSucker.setDeprecation(uint40 timestamp)`

**Who can call**: The project owner, or any address with the owner's `SET_SUCKER_DEPRECATION` permission. Must be called while sucker state is `ENABLED` or `DEPRECATION_PENDING`.

**Parameters**:
- `timestamp` -- The time after which the sucker will be deprecated. Must be `>= block.timestamp + _maxMessagingDelay()` (14 days). Set to `0` to cancel a pending deprecation.

**State changes**:
1. Validates sucker state is `ENABLED` or `DEPRECATION_PENDING`; reverts with `JBSucker_Deprecated` if `SENDING_DISABLED` or `DEPRECATED`.
2. Enforces `SET_SUCKER_DEPRECATION` permission from the project owner.
3. Validates `timestamp == 0` (cancel) or `timestamp >= block.timestamp + _maxMessagingDelay()`; reverts with `JBSucker_DeprecationTimestampTooSoon` if too soon.
4. Sets `deprecatedAfter = timestamp`.
5. State progression over time:
   - **Now -> timestamp - 14 days**: `DEPRECATION_PENDING`. All operations work normally.
   - **timestamp - 14 days -> timestamp**: `SENDING_DISABLED`. `prepare()` and `toRemote()` revert. `fromRemote()` and `claim()` still work.
   - **After timestamp**: `DEPRECATED`. `fromRemote()` rejects new roots. `claim()` still works for existing inbox roots. `exitThroughEmergencyHatch()` becomes available.

**Events**: `DeprecationTimeUpdated(timestamp, caller)`

**Registry cleanup**: Anyone calls `JBSuckerRegistry.removeDeprecatedSucker(projectId, suckerAddress)` after the sucker reaches `DEPRECATED` state. Emits `SuckerDeprecated(projectId, sucker, caller)`.

**Edge cases**:
- Cancellation: call `setDeprecation(0)` before reaching `SENDING_DISABLED` state.
- Both sides of the sucker pair should be deprecated with matching timestamps; mismatched deprecation can leave one side operational.
- `removeDeprecatedSucker` reverts with `JBSuckerRegistry_SuckerIsNotDeprecated` if the sucker has not fully reached `DEPRECATED` state.
- `removeDeprecatedSucker` reverts with `JBSuckerRegistry_SuckerDoesNotBelongToProject` if the sucker is not registered for the given project.

---

## 7. Enable Emergency Hatch

**Entry point**: `JBSucker.enableEmergencyHatchFor(address[] tokens)`

**Who can call**: The project owner, or any address with the owner's `SUCKER_SAFETY` permission.

**Parameters**:
- `tokens` -- Array of terminal token addresses to enable the emergency hatch for

**State changes**:
1. Enforces `SUCKER_SAFETY` permission from the project owner.
2. For each token: sets `_remoteTokenFor[token].enabled = false` and `_remoteTokenFor[token].emergencyHatch = true`.
3. **Irreversible**: once the emergency hatch is enabled for a token, it cannot be disabled or remapped.

**Events**: `EmergencyHatchOpened(tokens, caller)`

**Emergency exit** (`exitThroughEmergencyHatch(JBClaim claimData)`):

Anyone can call for a valid leaf. `_validateForEmergencyExit()`:
1. Confirms emergency hatch is enabled for the token (or sucker is `DEPRECATED`/`SENDING_DISABLED`).
2. Checks `index >= numberOfClaimsSent` or `numberOfClaimsSent == 0` (the leaf was NOT sent to the remote peer).
3. Uses a separate bitmap slot (derived from `keccak256(abi.encode(terminalToken))`) to prevent collision with regular claims.
4. Validates the merkle proof against the **outbox** tree root (not inbox).
5. Decreases `_outboxOf[token].balance -= terminalTokenAmount`.
6. `_handleClaim()`: adds terminal tokens back to the project's balance and mints project tokens for the beneficiary.

**Events** (emergency exit): `EmergencyExit(beneficiary, token, terminalTokenAmount, projectTokenCount, caller)`

**Edge cases**:
- Only leaves with `index >= numberOfClaimsSent` can be emergency-exited. Leaves that were already sent via `toRemote()` must be claimed on the remote chain.
- If `_sendRoot()` was called but the bridge message was never delivered, leaves with `index < numberOfClaimsSent` are blocked from emergency exit even though they cannot be claimed remotely. This is a conservative failure mode (funds locked, not double-spent). The deprecation flow provides an alternative exit path once the sucker reaches `DEPRECATED` state.
- The emergency hatch cannot be enabled if the token's mapping has already been disabled via `mapToken` with `remoteToken == bytes32(0)` and the hatch was not set -- the hatch requires explicit activation.

---

## 8. Register Sucker Deployer

**Entry point**: `JBSuckerRegistry.allowSuckerDeployer(address deployer)` or `JBSuckerRegistry.allowSuckerDeployers(address[] deployers)` (batch)

**Who can call**: The registry `owner` only (Ownable).

**Parameters**:
- `deployer` / `deployers` -- Address(es) of the sucker deployer contract(s) to allowlist

**State changes**:
1. Sets `suckerDeployerIsAllowed[deployer] = true` for each deployer.
2. Projects can now use this deployer in `deploySuckersFor()` configurations.

**Events**: `SuckerDeployerAllowed(deployer, caller)` -- emitted once per deployer.

**Removing a deployer**: Registry owner calls `removeSuckerDeployer(address deployer)`. Sets `suckerDeployerIsAllowed[deployer] = false`. Emits `SuckerDeployerRemoved(deployer, caller)`. Existing suckers deployed by this deployer are unaffected -- they continue operating.

**Setting the toRemote fee**: Registry owner calls `setToRemoteFee(uint256 fee)`. Reverts with `JBSuckerRegistry_FeeExceedsMax` if `fee > MAX_TO_REMOTE_FEE`. Emits `ToRemoteFeeChanged(oldFee, newFee, caller)`.

**Edge cases**:
- Only the registry owner can manage deployers; there is no permission-based delegation for this action.
- Removing a deployer does not affect already-deployed suckers.
- The batch `allowSuckerDeployers` emits one `SuckerDeployerAllowed` event per deployer in the array.
