# User Journeys

Step-by-step flows for every major user interaction with the sucker bridging system.

## 1. Deploy Suckers

A project owner deploys a pair of suckers to bridge tokens between Ethereum and Optimism.

**Actors:** Project owner, JBSuckerRegistry, JBOptimismSuckerDeployer

**Steps:**

1. Registry owner has previously called `JBSuckerRegistry.allowSuckerDeployer(optimismDeployerAddress)`.

2. Project owner calls `JBSuckerRegistry.deploySuckersFor(projectId, salt, configurations)` on Ethereum.
   - `salt` must be the same value on both chains for CREATE2 address matching.
   - `configurations` contains one entry: `JBSuckerDeployerConfig{deployer: optimismDeployer, mappings: [...]}`.

3. Registry enforces `DEPLOY_SUCKERS` permission from the project owner.

4. Registry computes `salt = keccak256(abi.encode(_msgSender(), salt))` (sender-specific determinism).

5. For each configuration:
   - Validates the deployer is in the allowlist.
   - Calls `deployer.createForSender(projectId, salt)` which deploys a clone of `JBOptimismSucker` via CREATE2.
   - The clone's `initialize(projectId)` is called, setting `_localProjectId` and `deployer`.
   - Registry stores the sucker address in `_suckersOf[projectId]`.
   - Calls `sucker.mapTokens(configuration.mappings)` to set initial token mappings.

6. Project owner repeats step 2 on Optimism with the **same salt and same sender address** to deploy the matching peer sucker.

**Result:** Two suckers exist at matching CREATE2 addresses. Each recognizes the other as its `peer()`. Token mappings are configured for bridging.

## 2. Map Token

A project owner maps a local terminal token to its remote counterpart.

**Actors:** Project owner, JBSucker

**Steps:**

1. Project owner calls `JBSucker.mapToken(JBTokenMapping{localToken: USDC, minGas: 200_000, remoteToken: bytes32(remoteUSDC)})`.

2. The sucker enforces `MAP_SUCKER_TOKEN` permission from the project owner.

3. `_validateTokenMapping()` checks:
   - For non-native tokens: `minGas >= MESSENGER_ERC20_MIN_GAS_LIMIT` (200,000).
   - For native tokens (base class): remote must be `NATIVE_TOKEN` or `bytes32(0)`.
   - CCIP/Celo suckers override to allow native-to-ERC20 mapping.

4. Immutability check: if `_outboxOf[USDC].tree.count != 0` (outbox has entries) AND the current mapping exists AND the new remote differs, reverts with `TokenAlreadyMapped`.

5. Stores the mapping: `_remoteTokenFor[USDC] = JBRemoteToken{enabled: true, emergencyHatch: false, minGas: 200_000, addr: bytes32(remoteUSDC)}`.

**Result:** USDC is now bridgeable. Users can call `prepare()` with USDC as the terminal token.

**Disabling a mapping:** Call `mapToken(JBTokenMapping{localToken: USDC, ..., remoteToken: bytes32(0), ...})`. If the outbox has unsent entries, `_sendRoot()` is called first to flush them. The mapping is disabled (`enabled = false`) but `addr` retains the original remote address (for re-enabling later).

## 3. Prepare (Bridge Out)

A user prepares project tokens to be bridged to the remote chain.

**Actors:** Token holder, JBSucker, JBMultiTerminal, JBController

**Steps:**

1. User approves the sucker to spend their project tokens.

2. User calls `JBSucker.prepare(projectTokenCount: 1000, beneficiary: bytes32(userAddressOnRemote), minTokensReclaimed: 950, token: NATIVE_TOKEN)`.

3. Validation:
   - `beneficiary != bytes32(0)` (would revert on remote mint).
   - Project has a deployed ERC-20 token.
   - `_remoteTokenFor[NATIVE_TOKEN].enabled == true`.
   - Sucker state is `ENABLED` or `DEPRECATION_PENDING` (not `SENDING_DISABLED` or `DEPRECATED`).

4. Transfers 1000 project tokens from user to the sucker.

5. `_pullBackingAssets()`:
   - Gets the project's primary terminal for `NATIVE_TOKEN`.
   - Calls `terminal.cashOutTokensOf(address(this), projectId, 1000, NATIVE_TOKEN, 950, payable(address(this)), "")`.
   - The sucker cashes out with 0% cashOutTaxRate (configured by JBOmnichainDeployer as data hook).
   - Records `balanceBefore`, asserts `reclaimedAmount == balanceAfter - balanceBefore`.
   - Returns `reclaimedAmount` (e.g., 0.5 ETH).

6. `_insertIntoTree()`:
   - Guards: `terminalTokenAmount` and `projectTokenCount` fit in `uint128`.
   - Builds leaf hash: `keccak256(abi.encode(1000, 500000000000000000, beneficiary))`.
   - Inserts into `_outboxOf[NATIVE_TOKEN].tree` via `MerkleLib.insert()`.
   - Updates `_outboxOf[NATIVE_TOKEN].balance += 0.5 ETH`.

7. Emits `InsertToOutboxTree` with the leaf details and updated root.

**Result:** The user's project tokens are burned (via cash out), the backing ETH is held by the sucker, and a leaf is recorded in the outbox merkle tree. The user waits for someone to call `toRemote()`.

## 4. Bridge (toRemote)

Anyone triggers the bridge to send the outbox root and backing assets to the remote chain.

**Actors:** Relayer (anyone), JBSucker, Bridge infrastructure

**Steps:**

1. Relayer calls `JBSucker.toRemote{value: transportPayment}(NATIVE_TOKEN)`.
   - `transportPayment` is 0 for OP bridges, non-zero for Arbitrum L1->L2 and CCIP.

2. Validation:
   - Emergency hatch not enabled for this token.
   - "Nothing to send" guard: reverts if `outbox.balance == 0 && outbox.tree.count == outbox.numberOfClaimsSent`.
   - If `TO_REMOTE_FEE != 0`: deducts the fee from `msg.value` and pays it into the fee project (`FEE_PROJECT_ID`, typically project ID 1) via `terminal.pay()`. The caller (relayer) receives project tokens. Best-effort: if the fee project has no native token terminal or `terminal.pay()` reverts, proceeds without collecting the fee. Remainder is passed as `transportPayment`.
   - Sucker not deprecated/sending-disabled.

3. `_sendRoot()`:
   - Reads `outbox.tree.count` and `outbox.balance` (e.g., 2.5 ETH across multiple prepares).
   - Clears `outbox.balance = 0`.
   - Increments `outbox.nonce`.
   - Computes `outbox.tree.root()`.
   - Sets `outbox.numberOfClaimsSent = tree.count` (used for emergency exit bounds).
   - Builds `JBMessageRoot{version: 1, token: remoteTokenAddr, amount: 2.5 ETH, remoteRoot: {nonce, root}}`.

4. `_sendRootOverAMB()` (chain-specific):
   - **OP Stack**: Bridges ETH via `OPMESSENGER.sendMessage{value: 2.5 ETH}()` to `peer()`. Message encodes `JBSucker.fromRemote(messageRoot)`.
   - **Arbitrum L1->L2**: Bridges ERC-20 via gateway router (retryable ticket 1), sends merkle root message via inbox (retryable ticket 2). Two independent tickets.
   - **CCIP**: Wraps native ETH to WETH, calls `CCIP_ROUTER.ccipSend()` with token amounts and message data.

**Result:** The merkle root and backing assets are in transit to the remote chain. The bridge delivers them according to its own timeline (minutes to hours depending on the bridge).

## 5. Claim (Bridge In)

A beneficiary claims their bridged tokens on the destination chain.

**Actors:** Beneficiary (or anyone on their behalf), JBSucker (destination), JBController

**Steps:**

1. Bridge delivers the message. The bridge messenger calls `JBSucker.fromRemote(JBMessageRoot)`.

2. `fromRemote()` validates:
   - `_isRemotePeer(_msgSender())` -- verifies the bridge messenger represents the authenticated peer.
   - `root.version == MESSAGE_VERSION` (1).
   - `root.remoteRoot.nonce > inbox.nonce` -- only accepts newer roots.
   - Sucker state is not `DEPRECATED`.

3. Updates `_inboxOf[localToken].root = root.remoteRoot.root` and `_inboxOf[localToken].nonce = root.remoteRoot.nonce`.

4. Off-chain: a relayer computes the merkle proof for the beneficiary's leaf against the inbox root. This requires knowing all leaves in the tree (from `InsertToOutboxTree` events on the source chain).

5. Beneficiary (or anyone) calls `JBSucker.claim(JBClaim{token: ETH, leaf: {index: 3, beneficiary: userAddr, projectTokenCount: 1000, terminalTokenAmount: 0.5 ETH}, proof: [...]})`.

6. `_validate()`:
   - Checks `_executedFor[ETH].get(3)` is false (not already claimed).
   - Sets `_executedFor[ETH].set(3)` (marks as claimed).
   - Builds leaf hash: `keccak256(abi.encode(1000, 500000000000000000, beneficiary))`.
   - Computes root via `MerkleLib.branchRoot(hash, proof, 3)`.
   - Compares to `_inboxOf[ETH].root` -- reverts with `InvalidProof` if mismatch.

7. `_handleClaim()`:
   - If `terminalTokenAmount > 0`:
     - Calls `_addToBalance(ETH, 0.5 ETH)` which forwards to `terminal.addToBalanceOf{value: 0.5 ETH}(projectId, ...)`.
   - Mints 1000 project tokens for the beneficiary via `controller.mintTokensOf(projectId, 1000, beneficiary, "", false)`.
     - `useReservedPercent = false` -- sucker mints bypass the reserved percent.

**Result:** The beneficiary receives 1000 project tokens on the destination chain. The 0.5 ETH backing is added to the project's terminal balance.

## 6. Deprecate Sucker

A project owner deprecates a sucker pair, progressively disabling operations.

**Actors:** Project owner, JBSucker

**Steps:**

1. Project owner calls `JBSucker.setDeprecation(timestamp)` on both chains, ideally with matching timestamps.

2. Validation:
   - Sucker state is `ENABLED` or `DEPRECATION_PENDING` (cannot change if already `SENDING_DISABLED` or `DEPRECATED`).
   - `SET_SUCKER_DEPRECATION` permission from project owner.
   - `timestamp == 0` (cancel) OR `timestamp >= block.timestamp + _maxMessagingDelay()` (14 days minimum).

3. Sets `deprecatedAfter = timestamp`.

4. State progression over time:
   - **Now -> timestamp - 14 days**: `DEPRECATION_PENDING`. All operations work normally. Users are warned.
   - **timestamp - 14 days -> timestamp**: `SENDING_DISABLED`. `prepare()` and `toRemote()` revert. `fromRemote()` still accepts roots. `claim()` still works.
   - **After timestamp**: `DEPRECATED`. `fromRemote()` rejects new roots. `claim()` still works for existing inbox roots. `exitThroughEmergencyHatch()` works.

5. **Cancellation**: Project owner calls `setDeprecation(0)` before reaching `SENDING_DISABLED` state.

6. **Registry cleanup**: Anyone calls `JBSuckerRegistry.removeDeprecatedSucker(projectId, suckerAddress)` after the sucker reaches `DEPRECATED` state.

**Result:** The sucker is gracefully wound down. Users have 14+ days to claim pending bridges. No new bridges can be initiated.

## 7. Enable Emergency Hatch

A project owner enables the emergency exit for tokens stuck in a broken bridge.

**Actors:** Project owner, JBSucker, affected token holders

**Steps:**

1. A bridge becomes non-functional (e.g., OP Stack bridge bug, token incompatibility). Tokens are stuck in the sucker's outbox.

2. Project owner calls `JBSucker.enableEmergencyHatchFor([NATIVE_TOKEN, USDC])`.

3. Validation:
   - `SUCKER_SAFETY` permission from project owner.
   - For each token: sets `_remoteTokenFor[token].enabled = false` and `_remoteTokenFor[token].emergencyHatch = true`.
   - **Irreversible**: Once the emergency hatch is enabled for a token, it cannot be disabled.

4. Affected users call `JBSucker.exitThroughEmergencyHatch(JBClaim{...})` with their prepare data.

5. `_validateForEmergencyExit()`:
   - Confirms emergency hatch is enabled for the token (or sucker is deprecated/sending-disabled).
   - Checks `index >= numberOfClaimsSent` or `numberOfClaimsSent == 0` (the leaf was NOT sent to the remote peer).
   - Uses a separate bitmap slot (derived from `keccak256(abi.encode(terminalToken))`) to prevent collision with regular claims.
   - Validates the merkle proof against the **outbox** tree root (not inbox).

6. Decreases `_outboxOf[token].balance -= terminalTokenAmount`.

7. `_handleClaim()`:
   - Adds terminal tokens back to the project's balance.
   - Mints project tokens for the beneficiary.

**Result:** Users recover their tokens locally without the bridge. Only leaves that were NOT already sent to the remote peer can be emergency-exited (leaves that were sent must be claimed on the remote chain).

**Important limitation:** If `_sendRoot()` was called (incrementing `numberOfClaimsSent`) but the bridge message was never delivered, leaves with `index < numberOfClaimsSent` are blocked from emergency exit even though they cannot be claimed remotely. This is a conservative failure mode (funds locked, not double-spent). The deprecation flow provides an alternative exit path.

## 8. Register Sucker Deployer

The registry owner adds a new sucker deployer implementation.

**Actors:** Registry owner (initially JuiceboxDAO / project #1), JBSuckerRegistry

**Steps:**

1. A new sucker deployer contract is deployed (e.g., `JBCCIPSuckerDeployer` for a new chain).

2. Registry owner calls `JBSuckerRegistry.allowSuckerDeployer(deployerAddress)`.
   - Only the registry `owner` (Ownable) can call this.

3. Sets `suckerDeployerIsAllowed[deployerAddress] = true`.

4. Projects can now use this deployer in `deploySuckersFor()` configurations.

**Removing a deployer:** Registry owner calls `removeSuckerDeployer(deployerAddress)`. Sets `suckerDeployerIsAllowed[deployerAddress] = false`. Existing suckers deployed by this deployer are unaffected -- they continue operating.

**Result:** A new bridge implementation is available for projects to deploy suckers with.
