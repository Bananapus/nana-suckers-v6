# Audit Instructions

You are auditing the Juicebox V6 suckers -- a cross-chain bridging system that lets project token holders move their tokens between chains by cashing out on one chain and minting on another. Dual incremental merkle trees (outbox on source, inbox on destination) track token movements, with chain-specific bridges (OP Stack, Arbitrum, CCIP) transporting the merkle roots and backing assets. Your goal is to find bugs that enable double-claiming, lose bridged funds, or bypass the deprecation lifecycle.

Read [RISKS.md](./RISKS.md) for known risks and trust assumptions. Then come back here.

## Scope

**In scope -- all Solidity in `src/`:**
```
src/JBSucker.sol                        # Abstract base (~1,196 lines)
src/JBOptimismSucker.sol                # OP Stack bridge implementation (~141 lines)
src/JBBaseSucker.sol                    # Base (OP Stack variant) (~48 lines)
src/JBCeloSucker.sol                    # Celo (OP Stack + WETH wrapping) (~196 lines)
src/JBArbitrumSucker.sol                # Arbitrum bridge implementation (~322 lines)
src/JBCCIPSucker.sol                    # Chainlink CCIP implementation (~306 lines)
src/JBSuckerRegistry.sol                # Deployer registry and tracking (~260 lines)
src/deployers/                          # JBSuckerDeployer, JB{Optimism,Base,Celo,Arbitrum,CCIP}SuckerDeployer
src/utils/MerkleLib.sol                 # Incremental merkle tree (eth2-style) (~1,030 lines)
src/structs/                            # JBMessageRoot, JBLeaf, JBClaim, JBOutboxTree, etc.
src/enums/                              # JBSuckerState, JBAddToBalanceMode, JBLayer
src/libraries/                          # ARBChains, ARBAddresses, CCIPHelper
```

**Out of scope:** Test files (`test/`), OpenZeppelin/Arbitrum/CCIP dependencies (assume correct), forge-std.

## Architecture

### JBSucker (src/JBSucker.sol) -- Abstract Base

The core bridging logic. Each sucker instance is associated with one project and deployed as a clone via `Initializable`. Suckers are deployed in pairs (one per chain) with matching CREATE2 addresses so `peer()` returns `_toBytes32(address(this))` by default.

**Immutables:** `DIRECTORY`, `TOKENS`, `ADD_TO_BALANCE_MODE` (ON_CLAIM or MANUAL).

**Key state:**
- `_outboxOf[token]` -- `JBOutboxTree`: merkle tree, balance, nonce, numberOfClaimsSent per token
- `_inboxOf[token]` -- `JBInboxTreeRoot`: root hash and nonce per token
- `_remoteTokenFor[token]` -- `JBRemoteToken`: remote address, enabled flag, emergency hatch, min gas, min bridge amount
- `_executedFor[token]` -- `BitMap`: tracks which leaf indices have been claimed (prevents double-spend)
- `deprecatedAfter` -- timestamp for deprecation lifecycle

**Key functions:**
- `initialize(projectId)` -- One-time initialization of the clone with the project ID.
- `prepare(projectTokenCount, beneficiary, minTokensReclaimed, token)` -- Cash out project tokens, insert a leaf into the outbox merkle tree.
- `toRemote(token)` -- Send the outbox root and backing assets to the remote chain via the bridge.
- `fromRemote(JBMessageRoot)` -- Receive a merkle root from the remote peer. Only callable by the authenticated bridge messenger.
- `claim(JBClaim)` / `claim(JBClaim[])` -- Verify a merkle proof against the inbox root and mint project tokens for the beneficiary.
- `mapToken(JBTokenMapping)` / `mapTokens(JBTokenMapping[])` -- Map local tokens to remote tokens. Requires `MAP_SUCKER_TOKEN` permission.
- `exitThroughEmergencyHatch(JBClaim)` -- Reclaim tokens locally when the bridge is broken. Validates against the outbox tree (not inbox).
- `enableEmergencyHatchFor(address[])` -- Project owner enables emergency exit for specific tokens. Requires `SUCKER_SAFETY` permission.
- `setDeprecation(uint40 timestamp)` -- Set or clear the deprecation timestamp. Requires `SET_SUCKER_DEPRECATION` permission.
- `addOutstandingAmountToBalance(token)` -- Manually add received tokens to the project balance (only in MANUAL mode).

**Key internal functions:**
- `_insertIntoTree(projectTokenCount, token, terminalTokenAmount, beneficiary)` -- Builds leaf hash, inserts into outbox merkle tree, updates balance.
- `_validate(projectTokenCount, terminalToken, terminalTokenAmount, beneficiary, index, leaves)` -- Verifies merkle proof against inbox root, marks leaf as executed in bitmap.
- `_validateForEmergencyExit(...)` -- Validates against outbox root, checks `numberOfClaimsSent` bounds, uses separate bitmap slot.
- `_validateBranchRoot(expectedRoot, ...)` -- Computes `MerkleLib.branchRoot()` and compares to expected root.
- `_sendRoot(transportPayment, token, remoteToken)` -- Builds `JBMessageRoot`, clears outbox balance, increments nonce, delegates to `_sendRootOverAMB()`.
- `_pullBackingAssets(projectToken, count, token, minTokensReclaimed)` -- Cashes out project tokens via the primary terminal.
- `_handleClaim(terminalToken, terminalTokenAmount, projectTokenAmount, beneficiary)` -- Optionally adds to balance (ON_CLAIM mode), mints project tokens for beneficiary.
- `_mapToken(map, transportPaymentValue)` -- Token mapping with immutability enforcement (cannot remap once outbox has entries).
- `_addToBalance(token, amount)` -- Adds terminal tokens to the project's balance via the primary terminal.
- `_isRemotePeer(sender)` -- Abstract. Verifies the caller is the authenticated bridge messenger representing the remote peer.
- `_sendRootOverAMB(...)` -- Abstract. Chain-specific bridge logic.

### JBOptimismSucker (src/JBOptimismSucker.sol)

OP Stack implementation. Uses `IOPMessenger` for messages and `IOPStandardBridge` for token bridging.

- `_isRemotePeer(sender)`: Checks `sender == OPMESSENGER && OPMESSENGER.xDomainMessageSender() == peer()`.
- `_sendRootOverAMB(...)`: Bridges ERC-20 via `OPBRIDGE.bridgeERC20To()`, sends message via `OPMESSENGER.sendMessage()`. Native ETH sent as `msg.value` on the messenger call. Transport payment must be 0 (OP bridge is free).

### JBBaseSucker (src/JBBaseSucker.sol)

Extends `JBOptimismSucker` with Base chain ID mappings. Same bridge logic.

### JBCeloSucker (src/JBCeloSucker.sol)

Extends `JBOptimismSucker` for Celo (OP Stack chain with CELO as native gas token, not ETH).

- Wraps native ETH to WETH before bridging as ERC-20.
- Removes the `NATIVE_TOKEN -> NATIVE_TOKEN` restriction so native ETH can map to a remote ERC-20.
- `_addToBalance()` override: unwraps WETH -> native ETH before adding to project balance.
- Messenger message sent with `nativeValue = 0` (no ETH attached on Celo).

### JBArbitrumSucker (src/JBArbitrumSucker.sol)

Arbitrum implementation. Uses `IInbox` for retryable tickets and `IArbGatewayRouter` for token bridging.

- `_isRemotePeer(sender)`:
  - **L1 side**: Checks `sender == ARBINBOX.bridge() && IOutbox(bridge.activeOutbox()).l2ToL1Sender() == peer()`.
  - **L2 side**: Checks `sender == AddressAliasHelper.applyL1ToL2Alias(peer())`.
- `_sendRootOverAMB(...)`:
  - **L1 -> L2**: Creates two independent retryable tickets (one for ERC-20 bridge, one for merkle root message). Non-atomic: tickets are redeemed independently on L2 with no guaranteed ordering. Constructor enforces `ON_CLAIM` mode to prevent unbacked minting (reverts with `JBArbitrumSucker_ManualModeUnsafe` if `MANUAL` is passed).
  - **L2 -> L1**: Uses `ArbSys.sendTxToL1()` for message, `IArbL2GatewayRouter.outboundTransfer()` for tokens.
- Transport payment required from L1 (covers retryable ticket gas).

### JBCCIPSucker (src/JBCCIPSucker.sol)

Chainlink CCIP implementation. Uses `ICCIPRouter` for cross-chain messaging with token transfer.

- `_isRemotePeer(sender)`: Checks `sender == address(this)` (CCIP calls `ccipReceive` which then calls `this.fromRemote()`).
- `ccipReceive(Client.Any2EVMMessage)`: Entry point from CCIP router. Validates `msg.sender == CCIP_ROUTER`, `origin == peer()`, `sourceChainSelector == REMOTE_CHAIN_SELECTOR`. Unwraps WETH to ETH when `root.token == NATIVE_TOKEN`. Calls `this.fromRemote(root)`.
- `_sendRootOverAMB(...)`: Wraps native ETH to WETH (CCIP only transports ERC-20s). Builds `Client.EVM2AnyMessage`, gets fee quote, calls `CCIP_ROUTER.ccipSend{value: fees}()`. Refunds excess transport payment (best-effort, does not revert on failure).
- Amount validation intentionally skipped (CCIP guarantees delivery). Reverting on mismatch would lock tokens.

### JBSuckerRegistry (src/JBSuckerRegistry.sol)

Manages sucker deployment and tracking.

**Key functions:**
- `deploySuckersFor(projectId, salt, configurations[])` -- Deploys suckers via allowed deployers. Requires `DEPLOY_SUCKERS` permission. Salt includes sender address for deterministic cross-chain deployment.
- `allowSuckerDeployer(deployer)` / `removeSuckerDeployer(deployer)` -- Owner-only allowlist management.
- `removeDeprecatedSucker(projectId, sucker)` -- Anyone can remove a fully deprecated sucker from the registry.
- `isSuckerOf(projectId, addr)` -- Check if a sucker belongs to a project.
- `suckersOf(projectId)` / `suckerPairsOf(projectId)` -- List project suckers with remote peer info.

### MerkleLib (src/utils/MerkleLib.sol)

Incremental merkle tree modeled on the eth2 deposit contract. Depth-32, max `2^32 - 1` leaves.

**Key functions:**
- `insert(Tree, node)` -- Insert a leaf. Returns updated tree. Reverts if full.
- `root(Tree storage)` -- Compute the current root from storage (assembly-optimized).
- `branchRoot(item, branch, index)` -- Compute root from a leaf, proof branch, and index (assembly-optimized). Used for claim verification.

## Key Flows

### Prepare (Bridge Out -- Source Chain)

```
User calls prepare(projectTokenCount, beneficiary, minTokensReclaimed, token)
  |
  +--> Validate: beneficiary != 0, project has ERC-20, token is mapped and enabled, sucker not deprecated
  +--> Transfer project tokens from user to sucker
  +--> _pullBackingAssets():
  |      Cash out project tokens via terminal.cashOutTokensOf()
  |      Sucker gets 0% cashOutTaxRate (special permission from JBOmnichainDeployer)
  |      Assert: balance delta matches returned reclaimedAmount
  |
  +--> _insertIntoTree():
  |      Guard: amounts fit in uint128 (SVM compatibility)
  |      Build leaf hash: keccak256(abi.encode(projectTokenCount, terminalTokenAmount, beneficiary))
  |      Insert into outbox merkle tree
  |      Update outbox balance
  |
  +--> Emit InsertToOutboxTree(beneficiary, token, hash, index, root, counts)
```

### Bridge (Transport -- Source Chain)

```
Anyone calls toRemote(token)
  |
  +--> Validate: emergency hatch not enabled, outbox balance >= minBridgeAmount, sucker not deprecated
  +--> _sendRoot():
  |      Read outbox tree count and balance
  |      Clear outbox balance (set to 0)
  |      Increment nonce
  |      Compute outbox tree root
  |      Update numberOfClaimsSent = tree.count
  |      Build JBMessageRoot(version, remoteToken.addr, amount, JBInboxTreeRoot(nonce, root))
  |
  +--> _sendRootOverAMB() [chain-specific]:
         OP:  bridgeERC20To() + OPMESSENGER.sendMessage()
         ARB: IArbGatewayRouter.outboundTransfer() + ARBINBOX.createRetryableTicket()
         CCIP: CCIP_ROUTER.ccipSend() with token amounts
```

### Claim (Bridge In -- Destination Chain)

```
Bridge delivers message -> fromRemote(JBMessageRoot) is called
  |
  +--> Validate: caller is authenticated remote peer, message version matches
  +--> If root.remoteRoot.nonce > inbox.nonce && state != DEPRECATED:
  |      Update inbox root and nonce
  |

Later, anyone calls claim(JBClaim) for a beneficiary:
  |
  +--> _validate():
  |      Check _executedFor[token].get(index) is false (not already claimed)
  |      Set _executedFor[token].set(index)
  |      Build leaf hash from claim data
  |      Compute root via MerkleLib.branchRoot(hash, proof, index)
  |      Compare to _inboxOf[token].root -- revert if mismatch
  |
  +--> _handleClaim():
  |      If ON_CLAIM mode: _addToBalance(terminalToken, terminalTokenAmount)
  |      Mint project tokens for beneficiary via controller.mintTokensOf()
  |        (useReservedPercent = false -- sucker mints bypass reserved percent)
```

### Deprecation Lifecycle

```
ENABLED (normal operation)
  |  setDeprecation(timestamp) where timestamp > block.timestamp + _maxMessagingDelay()
  v
DEPRECATION_PENDING (warning, all operations still work)
  |  block.timestamp reaches (deprecatedAfter - _maxMessagingDelay)
  v
SENDING_DISABLED (prepare and toRemote blocked, claims still work)
  |  block.timestamp reaches deprecatedAfter
  v
DEPRECATED (fromRemote rejects new roots, claims still work, emergency exit works)
```

## Merkle Tree Proof System

### Outbox Tree Construction

Each `prepare()` call inserts a leaf into the outbox tree:

```
leaf = keccak256(abi.encode(projectTokenCount, terminalTokenAmount, beneficiary))
```

The tree is an incremental merkle tree (eth2 deposit contract pattern) with depth 32 and max `2^32 - 1` leaves. Leaves are inserted in order; the tree is append-only.

### Inbox Root Verification

When `fromRemote()` receives a `JBMessageRoot`, it stores the merkle root in `_inboxOf[token].root`. The nonce must be strictly greater than the current inbox nonce (non-sequential ordering is accepted for CCIP compatibility).

### Claim Verification

To claim, a user provides:
- `JBLeaf`: `(index, beneficiary, projectTokenCount, terminalTokenAmount)`
- `bytes32[32] proof`: the 32-element merkle proof branch

`_validate()` rebuilds the leaf hash, computes the root via `MerkleLib.branchRoot()`, and compares it to the stored inbox root. The leaf index is marked in a bitmap to prevent double-claiming.

### Emergency Exit Verification

`_validateForEmergencyExit()` validates against the **outbox** tree (not inbox). It additionally checks:
- Emergency hatch is enabled for the token, OR the sucker is deprecated/sending-disabled.
- `index >= numberOfClaimsSent` (the leaf was NOT part of a root already sent to the remote peer). This prevents double-spending where a leaf could be claimed on both chains.
- Uses a separate bitmap slot: `address(bytes20(keccak256(abi.encode(terminalToken))))` to avoid collision with the regular claim bitmap.

## Token Mapping

- **Immutable once outbox has entries**: If `_outboxOf[token].tree.count != 0`, the token can only be disabled (mapped to `bytes32(0)`), not remapped to a different remote token. This prevents double-spending.
- **Re-enabling supported**: A disabled token (remote = 0) can be re-enabled back to its original remote token.
- **Disabling triggers root flush**: When mapping to `bytes32(0)` with unsent outbox entries (`numberOfClaimsSent != tree.count`), `_sendRoot()` is called to flush remaining entries before disabling.
- **Validation**: Base class requires native token to map only to native token or zero. `JBCCIPSucker` and `JBCeloSucker` override this to allow native-to-ERC20 mapping. All implementations enforce `minGas >= MESSENGER_ERC20_MIN_GAS_LIMIT` for ERC-20 tokens.

## Priority Audit Areas

| Priority | Target | Why |
|----------|--------|-----|
| 1 | **Merkle proof verification** (`_validate`, `_validateForEmergencyExit`, `MerkleLib.branchRoot`) | Double-claim or invalid-claim is the highest-impact bug. Verify: leaf hash construction matches insertion, bitmap prevents replay, proof verification is correct, emergency exit uses separate bitmap and checks numberOfClaimsSent bounds. |
| 2 | **fromRemote authentication** (`_isRemotePeer` in each implementation) | If an attacker can call `fromRemote()` with a crafted root, they can mint arbitrary tokens. Verify each bridge's authentication: OP (xDomainMessageSender), Arbitrum (L1 outbox / L2 alias), CCIP (router + origin + chain selector). |
| 3 | **Token conservation across bridge** | Verify: outbox balance cleared in `_sendRoot()` matches what the bridge transfers, inbox `_handleClaim()` only distributes `terminalTokenAmount` that was actually received. For CCIP: amount validation is intentionally skipped. For Arbitrum L1->L2: two independent retryable tickets create a non-atomic window. |
| 4 | **Emergency exit safety** | `numberOfClaimsSent` determines which leaves are safe to emergency-exit. Verify: it's updated only in `_sendRoot()`, accurately tracks what was sent, and the `>= index` comparison is correct (count vs 0-based index). |
| 5 | **Deprecation lifecycle** | State transitions are timestamp-based. Verify: `_maxMessagingDelay()` provides enough time for in-flight messages, `SENDING_DISABLED` blocks `prepare()` and `toRemote()` but allows `claim()` and `fromRemote()`, `DEPRECATED` blocks `fromRemote()` new roots. |
| 6 | **Token mapping immutability** | Verify: once `_outboxOf[token].tree.count != 0`, remapping to a different remote token reverts. Disabling triggers root flush. Re-enabling back to the same address works. |
| 7 | **Arbitrum non-atomic bridging** | L1->L2 creates two independent retryable tickets. Constructor enforces `ON_CLAIM` mode (reverts `JBArbitrumSucker_ManualModeUnsafe` on `MANUAL`). Verify: `_addToBalance()` checks `amountToAddToBalanceOf()` which depends on actual token balance, preventing unbacked minting when message arrives before tokens. |
| 8 | **CCIP-specific: ccipReceive** | Must never revert after CCIP delivers tokens. Verify: WETH unwrap safety, `this.fromRemote()` self-call pattern, transport payment refund (best-effort, stuck ETH accepted). |
| 9 | **Reentrancy surfaces** | `_pullBackingAssets()` calls `terminal.cashOutTokensOf()` which triggers hooks. `_handleClaim()` calls `terminal.addToBalanceOf()` and `controller.mintTokensOf()`. No ReentrancyGuard. Verify: state is updated before external calls, bitmap prevents re-entry exploits. |

## Invariants to Verify

1. **No double-claim**: Each leaf index can only be claimed once per token (bitmap enforcement).
2. **No cross-chain double-spend**: Emergency exit only allows leaves with `index >= numberOfClaimsSent` (not already sent to remote).
3. **Token conservation**: `outbox.balance` (before `_sendRoot()`) == amount bridged to remote peer == amount available for claims on remote.
4. **Nonce monotonicity**: Inbox nonce only increases. A stale nonce is rejected.
5. **Mapping immutability**: After first outbox insertion, token cannot be remapped (only disabled).
6. **Deprecation irreversibility**: Once `SENDING_DISABLED` or `DEPRECATED`, the sucker cannot return to `ENABLED`.
7. **Balance accounting**: `amountToAddToBalanceOf(token) = contract.balance(token) - outboxOf[token].balance` is always non-negative.
8. **Peer symmetry**: `peer()` returns the same address on both chains (CREATE2 determinism).

## How to Run Tests

```bash
cd nana-suckers-v6
npm install
forge build
forge test

# Run with high verbosity for debugging
forge test -vvvv --match-test testExploitName

# Write a PoC
forge test --match-path test/audit/ExploitPoC.t.sol -vvv

# Specific test suites
forge test --match-contract SuckerAttacks       # Attack scenarios
forge test --match-contract SuckerDeepAttacks    # Deep attack vectors
forge test --match-contract SuckerRegressions    # Regression tests
forge test --match-contract InteropCompat        # Cross-chain compatibility
forge test --match-path test/unit/               # Unit tests
forge test --match-path test/regression/         # Regression tests

# Fork tests (require RPC URLs)
forge test --match-contract Fork --fork-url $ETH_RPC_URL
forge test --match-contract ForkCelo --fork-url $CELO_RPC_URL
forge test --match-contract ForkMainnet --fork-url $ETH_RPC_URL

# Gas analysis
forge test --gas-report
```
