# nana-suckers-v6 -- User Journeys

All user paths through the Juicebox V6 sucker bridging system. For each journey: entry point, key parameters, state changes, events, and edge cases.

---

## 1. Deploy Suckers

**Entry point**: `JBSuckerRegistry.deploySuckersFor(uint256 projectId, bytes32 salt, JBSuckerDeployerConfig[] configurations)`

**Who can call**: The project owner, or any address with the project owner's `DEPLOY_SUCKERS` permission.

**Parameters**:
- `projectId` -- The ID of the project to deploy suckers for
- `salt` -- A salt for CREATE2 deterministic deployment. Must be the same value on both chains for the suckers to be peers
- `configurations` -- Array of `JBSuckerDeployerConfig` structs, each containing:
  - `deployer` -- An `IJBSuckerDeployer` address that must be on the registry's allowlist
  - `mappings` -- Array of `JBTokenMapping` structs for initial token mappings

**State changes**:
1. `salt = keccak256(abi.encode(_msgSender(), salt))` -- Sender-specific determinism computed
2. For each configuration:
   1. `configuration.deployer.createForSender(projectId, salt)` -- Deploys a sucker clone via CREATE2
   2. `sucker.initialize(projectId)` -- Sets `_localProjectId` and `deployer` on the new clone
   3. `_suckersOf[projectId].set(address(sucker), _SUCKER_EXISTS)` -- Registers the sucker in the registry
   4. `sucker.mapTokens(configuration.mappings)` -- Sets initial token mappings on the new sucker

**Events**: `SuckerDeployedFor(projectId, sucker, configuration, caller)` -- One per deployed sucker

**Edge cases**:
- Reverts with `JBSuckerRegistry_InvalidDeployer` if any deployer is not on the allowlist
- The sender must be the same address on both chains for CREATE2 addresses to match (peer recognition)
- Project owner repeats the call on the remote chain with the **same salt and same sender** to deploy the matching peer

---

## 2. Map Token

**Entry point**: `JBSucker.mapToken(JBTokenMapping map)` (payable)

**Who can call**: The project owner, or any address with the project owner's `MAP_SUCKER_TOKEN` permission.

**Parameters**:
- `map` -- A `JBTokenMapping` struct containing:
  - `localToken` -- The local terminal token address (e.g., `NATIVE_TOKEN` or an ERC-20)
  - `minGas` -- Minimum gas for bridging; must be >= `MESSENGER_ERC20_MIN_GAS_LIMIT` (200,000) for non-native tokens
  - `remoteToken` -- The remote token address as `bytes32`. Set to `bytes32(0)` to disable bridging

**State changes**:
1. `_validateTokenMapping(map)` -- Validates native token constraints and minimum gas
2. Immutability check: if `_outboxOf[token].tree.count != 0` and current mapping exists and new remote differs, reverts
3. If disabling (`remoteToken == bytes32(0)`) and outbox has unsent entries: `_sendRoot()` is called to flush the outbox
4. `_remoteTokenFor[token] = JBRemoteToken{enabled: remoteToken != bytes32(0), emergencyHatch: false, minGas: map.minGas, addr: ...}` -- Stores or updates the mapping. When disabling, `addr` retains the original remote address for re-enabling

**Events**: None directly from `mapToken`. If a root flush occurs during disable, emits `RootToRemote(root, token, index, nonce, caller)`.

**Edge cases**:
- Reverts with `JBSucker_TokenAlreadyMapped` if the outbox has entries and remapping to a different remote token
- Reverts with `JBSucker_TokenHasInvalidEmergencyHatchState` if the emergency hatch is already enabled for the token
- Reverts with `JBSucker_InvalidNativeRemoteAddress` if mapping native token to a non-native, non-zero remote
- Reverts with `JBSucker_BelowMinGas` if `minGas < MESSENGER_ERC20_MIN_GAS_LIMIT` for non-native tokens
- Re-enabling a previously disabled mapping (to the same remote token) is supported
- CCIP and Celo suckers override `_validateTokenMapping` to allow native-to-ERC20 mapping
- `msg.value` is used as `transportPayment` when flushing the outbox during disable

**Bulk variant**: `JBSucker.mapTokens(JBTokenMapping[] maps)` -- Maps multiple tokens. Splits `msg.value` evenly across mappings that require a root flush. Refunds remainder from integer division.

---

## 3. Prepare (Bridge Out)

**Entry point**: `JBSucker.prepare(uint256 projectTokenCount, bytes32 beneficiary, uint256 minTokensReclaimed, address token)`

**Who can call**: Anyone. The caller must have approved the sucker to transfer `projectTokenCount` of their project ERC-20 tokens.

**Parameters**:
- `projectTokenCount` -- Number of project tokens to cash out and bridge
- `beneficiary` -- Recipient on the remote chain (`bytes32` for cross-VM compatibility; EVM addresses are left-padded to 32 bytes, Solana uses full 32-byte public keys)
- `minTokensReclaimed` -- Minimum terminal tokens to receive from the cash out (slippage protection)
- `token` -- The terminal token to cash out into (e.g., `NATIVE_TOKEN` or an ERC-20)

**State changes**:
1. `projectToken.safeTransferFrom(caller, sucker, projectTokenCount)` -- Transfers project tokens from user to sucker
2. `_pullBackingAssets()`:
   1. Calls `terminal.cashOutTokensOf(sucker, projectId, projectTokenCount, token, minTokensReclaimed, sucker, "")` -- Cashes out with 0% cashOutTaxRate (configured by JBOmnichainDeployer as data hook)
   2. Returns `reclaimedAmount` (balance diff verified via assertion)
3. `_insertIntoTree()`:
   1. `_outboxOf[token].tree = outbox.tree.insert(leafHash)` -- Inserts leaf into the outbox merkle tree
   2. `_outboxOf[token].balance += terminalTokenAmount` -- Adds reclaimed amount to the outbox balance

**Events**: `InsertToOutboxTree(beneficiary, token, hashed, index, root, projectTokenCount, terminalTokenAmount, caller)`

**Edge cases**:
- Reverts with `JBSucker_ZeroBeneficiary` if `beneficiary == bytes32(0)`
- Reverts with `JBSucker_ZeroERC20Token` if the project has no deployed ERC-20 token
- Reverts with `JBSucker_TokenNotMapped` if the token mapping is not enabled
- Reverts with `JBSucker_Deprecated` if sucker state is `SENDING_DISABLED` or `DEPRECATED`
- Reverts with `JBSucker_AmountExceedsUint128` if `terminalTokenAmount` or `projectTokenCount` exceeds `uint128` (SVM compatibility)
- The project tokens are burned via the cash out, and the backing assets are held by the sucker until `toRemote()` is called

---

## 4. Bridge (toRemote)

**Entry point**: `JBSucker.toRemote(address token)` (payable)

**Who can call**: Anyone. Typically called by a relayer. Requires `msg.value >= REGISTRY.toRemoteFee()` plus any bridge-specific transport payment.

**Parameters**:
- `token` -- The terminal token whose outbox tree root and backing assets should be sent to the remote chain

**State changes**:
1. Fee deduction: if `REGISTRY.toRemoteFee() != 0`, deducts fee from `msg.value` and pays it into `FEE_PROJECT_ID` (typically project 1) via `terminal.pay()`. The caller receives fee project tokens in return. Best-effort: if fee payment fails, the full `msg.value` becomes `transportPayment`.
2. `_sendRoot()`:
   1. `outbox.balance = 0` -- Clears the outbox balance (amount now in transit)
   2. `outbox.nonce++` -- Increments the outbox nonce
   3. `outbox.numberOfClaimsSent = tree.count` -- Marks all current leaves as sent
   4. Computes `outbox.tree.root()` -- The current merkle root
3. `_sendRootOverAMB()` -- Bridge-specific logic transfers assets and sends the merkle root message to the peer:
   - **OP Stack**: `OPMESSENGER.sendMessage{value: amount}()` bridges ETH and encodes `JBSucker.fromRemote(messageRoot)`
   - **Arbitrum**: Two retryable tickets -- one for ERC-20 via gateway router, one for the merkle root message via inbox
   - **CCIP**: Wraps native ETH to WETH, calls `CCIP_ROUTER.ccipSend()` with token amounts and message data

**Events**: `RootToRemote(root, token, index, nonce, caller)`

**Edge cases**:
- Reverts with `JBSucker_TokenHasInvalidEmergencyHatchState` if the emergency hatch is enabled for this token
- Reverts with `JBSucker_NothingToSend` if `outbox.balance == 0 && outbox.tree.count == outbox.numberOfClaimsSent`
- Reverts with `JBSucker_InsufficientMsgValue` if `msg.value < REGISTRY.toRemoteFee()`
- Reverts with `JBSucker_Deprecated` if sucker state is `SENDING_DISABLED` or `DEPRECATED`
- If the outbox tree is empty (`count == 0`), `_sendRoot` returns early without sending
- The `toRemoteFee` is global across all suckers, set by the registry owner via `setToRemoteFee()`, capped at `MAX_TO_REMOTE_FEE` (0.001 ether)
- Transport payment (0 for OP bridges, non-zero for Arbitrum L1->L2 and CCIP) is the remainder after fee deduction

---

## 5. Receive Root (fromRemote)

**Entry point**: `JBSucker.fromRemote(JBMessageRoot root)` (payable)

**Who can call**: Only the authenticated bridge messenger representing the remote peer. Validated via `_isRemotePeer(_msgSender())`.

**Parameters**:
- `root` -- A `JBMessageRoot` struct containing:
  - `version` -- Message format version (must equal `MESSAGE_VERSION`, currently 1)
  - `token` -- The remote token address as `bytes32` (converted to local address for inbox lookup)
  - `amount` -- The amount of terminal tokens being delivered
  - `remoteRoot` -- A `JBInboxTreeRoot` with `nonce` and `root` (the merkle root)

**State changes**:
1. If `root.remoteRoot.nonce > inbox.nonce` AND state is not `DEPRECATED`:
   1. `_inboxOf[localToken].nonce = root.remoteRoot.nonce` -- Updates the inbox nonce
   2. `_inboxOf[localToken].root = root.remoteRoot.root` -- Updates the inbox merkle root

**Events**:
- On success: `NewInboxTreeRoot(token, nonce, root, caller)`
- On rejection (stale or deprecated): `StaleRootRejected(token, receivedNonce, currentNonce)`

**Edge cases**:
- Reverts with `JBSucker_NotPeer` if the sender is not the authenticated remote peer
- Reverts with `JBSucker_InvalidMessageVersion` if `root.version != MESSAGE_VERSION`
- Does NOT revert for stale nonces -- emits `StaleRootRejected` instead (because reverting could lose native tokens delivered with the message)
- Accepts roots for unmapped tokens (rejecting would permanently lose bridged tokens; future mapping enables claims)
- Nonce gaps are expected -- some bridges (e.g., CCIP) do not guarantee in-order delivery
- Deprecated suckers reject new roots to prevent double-spend (project owner may have enabled emergency hatch for local withdrawals)

---

## 6. Claim (Bridge In)

**Entry point**: `JBSucker.claim(JBClaim claimData)` or `JBSucker.claim(JBClaim[] claims)` for batch

**Who can call**: Anyone. The beneficiary receives the tokens regardless of who calls.

**Parameters**:
- `claimData` -- A `JBClaim` struct containing:
  - `token` -- The local terminal token address
  - `leaf` -- A `JBLeaf` struct with `index`, `beneficiary` (bytes32), `projectTokenCount`, `terminalTokenAmount`
  - `proof` -- A `bytes32[32]` merkle proof (32 = `_TREE_DEPTH`)

**State changes**:
1. `_validate()`:
   1. `_executedFor[token].get(index)` -- Checks leaf not already claimed
   2. `_executedFor[token].set(index)` -- Marks leaf as claimed
   3. Computes `MerkleLib.branchRoot(leafHash, proof, index)` and compares to `_inboxOf[token].root`
2. `_handleClaim()`:
   1. If `terminalTokenAmount > 0`: calls `terminal.addToBalanceOf{value: amount}(projectId, token, amount, false, "", "")` -- Adds backing assets to the project's terminal balance
   2. `controller.mintTokensOf(projectId, projectTokenCount, beneficiary, "", false)` -- Mints project tokens for the beneficiary with `useReservedPercent = false` (suckers bypass reserved percent)

**Events**: `Claimed(beneficiary, token, projectTokenCount, terminalTokenAmount, index, caller)`

**Edge cases**:
- Reverts with `JBSucker_LeafAlreadyExecuted` if the leaf at `index` was already claimed
- Reverts with `JBSucker_InvalidProof` if the merkle proof does not match the inbox root
- Reverts if the project's controller is misconfigured or the project doesn't exist on the destination chain (permanently blocks claims -- a deployment concern)
- Off-chain: a relayer must compute the merkle proof from `InsertToOutboxTree` events on the source chain
- If nonces arrive out of order, users need regenerated proofs against the current root (the merkle tree is append-only, so all leaves remain provable)
- Batch `claim(JBClaim[])` simply loops over each claim

---

## 7. Deprecate Sucker

**Entry point**: `JBSucker.setDeprecation(uint40 timestamp)`

**Who can call**: The project owner, or any address with the project owner's `SET_SUCKER_DEPRECATION` permission.

**Parameters**:
- `timestamp` -- The time after which the sucker is deprecated. Must be `0` (cancel deprecation) or `>= block.timestamp + _maxMessagingDelay()` (14 days minimum). Type is `uint40`.

**State changes**:
1. `deprecatedAfter = timestamp` -- Sets or clears the deprecation timestamp

**Events**: `DeprecationTimeUpdated(timestamp, caller)`

**State progression over time**:
- **Now -> timestamp - 14 days**: `DEPRECATION_PENDING`. All operations work normally. Users are warned.
- **timestamp - 14 days -> timestamp**: `SENDING_DISABLED`. `prepare()` and `toRemote()` revert. `fromRemote()` still accepts roots. `claim()` still works.
- **After timestamp**: `DEPRECATED`. `fromRemote()` rejects new roots. `claim()` still works for existing inbox roots. `exitThroughEmergencyHatch()` works.

**Edge cases**:
- Reverts with `JBSucker_Deprecated` if state is already `SENDING_DISABLED` or `DEPRECATED`
- Reverts with `JBSucker_DeprecationTimestampTooSoon` if `timestamp != 0` and `timestamp < block.timestamp + _maxMessagingDelay()`
- Cancellation: call `setDeprecation(0)` before reaching `SENDING_DISABLED` state

**Registry cleanup**: Anyone calls `JBSuckerRegistry.removeDeprecatedSucker(uint256 projectId, address sucker)` after the sucker reaches `DEPRECATED` state. This removes the sucker from `_suckersOf[projectId]` and emits `SuckerDeprecated(projectId, sucker, caller)`. Reverts with `JBSuckerRegistry_SuckerDoesNotBelongToProject` if the sucker is not registered, or `JBSuckerRegistry_SuckerIsNotDeprecated` if not yet deprecated.

---

## 8. Enable Emergency Hatch

**Entry point**: `JBSucker.enableEmergencyHatchFor(address[] tokens)`

**Who can call**: The project owner, or any address with the project owner's `SUCKER_SAFETY` permission.

**Parameters**:
- `tokens` -- Array of terminal token addresses to enable the emergency hatch for

**State changes**:
1. For each token:
   1. `_remoteTokenFor[token].enabled = false` -- Disables bridging for the token
   2. `_remoteTokenFor[token].emergencyHatch = true` -- Enables emergency exit

**Events**: `EmergencyHatchOpened(tokens, caller)`

**Edge cases**:
- **Irreversible**: Once the emergency hatch is enabled for a token, it cannot be disabled
- No explicit revert for empty array (no-op)
- Does not require the sucker to be in any particular state

---

## 9. Exit Through Emergency Hatch

**Entry point**: `JBSucker.exitThroughEmergencyHatch(JBClaim claimData)`

**Who can call**: Anyone. The beneficiary receives the tokens regardless of who calls.

**Parameters**:
- `claimData` -- A `JBClaim` struct containing:
  - `token` -- The local terminal token address
  - `leaf` -- A `JBLeaf` struct with `index`, `beneficiary` (bytes32), `projectTokenCount`, `terminalTokenAmount`
  - `proof` -- A `bytes32[32]` merkle proof against the **outbox** tree root (not inbox)

**State changes**:
1. `_validateForEmergencyExit()`:
   1. Checks emergency hatch is enabled for the token (or sucker is `DEPRECATED`/`SENDING_DISABLED`)
   2. Checks `index >= numberOfClaimsSent` or `numberOfClaimsSent == 0` (the leaf was NOT sent to the remote peer)
   3. Uses a separate bitmap slot (`address(bytes20(keccak256(abi.encode(token))))`) to prevent collision with regular claims
   4. Marks the leaf as executed in the emergency exit bitmap
   5. Validates the merkle proof against `_outboxOf[token].tree.root()`
2. `_outboxOf[token].balance -= terminalTokenAmount` -- Decreases the outbox balance
3. `_handleClaim()`:
   1. If `terminalTokenAmount > 0`: `terminal.addToBalanceOf(projectId, token, amount, ...)` -- Adds tokens back to project balance
   2. `controller.mintTokensOf(projectId, projectTokenCount, beneficiary, "", false)` -- Mints project tokens for the beneficiary

**Events**: `EmergencyExit(beneficiary, token, terminalTokenAmount, projectTokenCount, caller)`

**Edge cases**:
- Reverts with `JBSucker_TokenHasInvalidEmergencyHatchState` if emergency hatch is not enabled AND sucker is not `DEPRECATED`/`SENDING_DISABLED`
- Reverts with `JBSucker_LeafAlreadyExecuted` if `index < numberOfClaimsSent` (leaf was already sent to remote peer) or if already emergency-exited
- Reverts with `JBSucker_InvalidProof` if the merkle proof does not match the outbox root
- **Important limitation**: If `_sendRoot()` was called (incrementing `numberOfClaimsSent`) but the bridge message was never delivered, leaves with `index < numberOfClaimsSent` are blocked from emergency exit even though they cannot be claimed remotely. This is a conservative failure mode (funds locked, not double-spent). The deprecation flow provides an alternative exit path.
- Only leaves NOT already sent to the remote peer can be emergency-exited

---

## 10. Register Sucker Deployer

**Entry point**: `JBSuckerRegistry.allowSuckerDeployer(address deployer)` or `JBSuckerRegistry.allowSuckerDeployers(address[] deployers)` for batch

**Who can call**: Only the registry `owner` (Ownable). Initially JuiceboxDAO / project #1.

**Parameters**:
- `deployer` -- The address of the sucker deployer contract to add to the allowlist
- `deployers` (batch variant) -- Array of deployer addresses

**State changes**:
1. `suckerDeployerIsAllowed[deployer] = true` -- Adds the deployer to the allowlist

**Events**: `SuckerDeployerAllowed(deployer, caller)` -- One per deployer

**Edge cases**:
- Reverts with `OwnableUnauthorizedAccount` if caller is not the owner
- Idempotent: calling again on an already-allowed deployer is a no-op (re-sets to `true`)

**Removing a deployer**: `JBSuckerRegistry.removeSuckerDeployer(address deployer)` -- Sets `suckerDeployerIsAllowed[deployer] = false`. Emits `SuckerDeployerRemoved(deployer, caller)`. Existing suckers deployed by this deployer continue operating.

---

## 11. Set toRemote Fee

**Entry point**: `JBSuckerRegistry.setToRemoteFee(uint256 fee)`

**Who can call**: Only the registry `owner` (Ownable).

**Parameters**:
- `fee` -- The new ETH fee in wei, paid into the fee project on each `toRemote()` call

**State changes**:
1. `toRemoteFee = fee` -- Updates the global fee

**Events**: `ToRemoteFeeChanged(oldFee, fee, caller)`

**Edge cases**:
- Reverts with `JBSuckerRegistry_FeeExceedsMax` if `fee > MAX_TO_REMOTE_FEE` (0.001 ether)
- The fee is initialized to `MAX_TO_REMOTE_FEE` in the constructor
- Setting to 0 effectively disables the fee
