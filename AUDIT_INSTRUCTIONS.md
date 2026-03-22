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
src/JBSuckerRegistry.sol                # Deployer registry and tracking (~282 lines)
src/deployers/                          # JBSuckerDeployer, JB{Optimism,Base,Celo,Arbitrum,CCIP}SuckerDeployer
src/utils/MerkleLib.sol                 # Incremental merkle tree (eth2-style) (~1,030 lines)
src/structs/                            # JBMessageRoot, JBLeaf, JBClaim, JBOutboxTree, etc.
src/enums/                              # JBSuckerState, JBLayer
src/libraries/                          # ARBChains, ARBAddresses, CCIPHelper
```

**Out of scope:** Test files (`test/`), OpenZeppelin/Arbitrum/CCIP dependencies (assume correct), forge-std.

## Architecture

### JBSucker (src/JBSucker.sol) -- Abstract Base

The core bridging logic. Each sucker instance is associated with one project and deployed as a clone via `Initializable`. Suckers are deployed in pairs (one per chain) with matching CREATE2 addresses so `peer()` returns `_toBytes32(address(this))` by default.

**Immutables:** `DIRECTORY`, `TOKENS`.

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

**Key internal functions:**
- `_insertIntoTree(projectTokenCount, token, terminalTokenAmount, beneficiary)` -- Builds leaf hash, inserts into outbox merkle tree, updates balance.
- `_validate(projectTokenCount, terminalToken, terminalTokenAmount, beneficiary, index, leaves)` -- Verifies merkle proof against inbox root, marks leaf as executed in bitmap.
- `_validateForEmergencyExit(...)` -- Validates against outbox root, checks `numberOfClaimsSent` bounds, uses separate bitmap slot.
- `_validateBranchRoot(expectedRoot, ...)` -- Computes `MerkleLib.branchRoot()` and compares to expected root.
- `_sendRoot(transportPayment, token, remoteToken)` -- Builds `JBMessageRoot`, clears outbox balance, increments nonce, delegates to `_sendRootOverAMB()`.
- `_pullBackingAssets(projectToken, count, token, minTokensReclaimed)` -- Cashes out project tokens via the primary terminal.
- `_handleClaim(terminalToken, terminalTokenAmount, projectTokenAmount, beneficiary)` -- Adds terminal tokens to balance and mints project tokens for beneficiary.
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
  - **L1 -> L2**: Creates two independent retryable tickets (one for ERC-20 bridge, one for merkle root message). Non-atomic: tickets are redeemed independently on L2 with no guaranteed ordering. `_addToBalance` checks actual token balance to prevent unbacked minting when message arrives before tokens.
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
  +--> Validate: emergency hatch not enabled, nothing-to-send guard, deduct toRemoteFee (if set, read from JBSuckerRegistry via REGISTRY.toRemoteFee(), set globally by registry owner via setToRemoteFee(), capped at MAX_TO_REMOTE_FEE = 0.001 ether), sucker not deprecated
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
  |      _addToBalance(terminalToken, terminalTokenAmount)
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
| 7 | **Arbitrum non-atomic bridging** | L1->L2 creates two independent retryable tickets. Verify: `_addToBalance()` checks `amountToAddToBalanceOf()` which depends on actual token balance, preventing unbacked minting when message arrives before tokens. |
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

## Error Reference

33 custom errors across source files:

| Error | Contract | Trigger |
|-------|----------|---------|
| `JBSucker_AmountExceedsUint128` | JBSucker | `projectTokenCount` or `terminalTokenAmount` exceeds `uint128` during `_insertIntoTree` |
| `JBSucker_BelowMinGas` | JBSucker | Token mapping `minGas` is below `MESSENGER_ERC20_MIN_GAS_LIMIT` |
| `JBSucker_Deprecated` | JBSucker | `prepare`, `toRemote`, or `_sendRoot` called when sucker is `SENDING_DISABLED` or `DEPRECATED` |
| `JBSucker_DeprecationTimestampTooSoon` | JBSucker | `setDeprecation` timestamp is earlier than `block.timestamp + _maxMessagingDelay()` |
| `JBSucker_ExpectedMsgValue` | JBArbitrumSucker, JBCCIPSucker | Transport payment is 0 when bridge requires msg.value (Arbitrum L1, CCIP) |
| `JBSucker_InsufficientBalance` | JBSucker | `_addToBalance` amount exceeds `amountToAddToBalanceOf` (actual token balance minus outbox balance) |
| `JBSucker_InsufficientMsgValue` | JBSucker | `msg.value` is less than the `toRemoteFee` in `toRemote` |
| `JBSucker_InvalidMessageVersion` | JBSucker | `fromRemote` receives a root with mismatched `MESSAGE_VERSION` |
| `JBSucker_InvalidNativeRemoteAddress` | JBSucker | Native token mapped to non-native, non-zero remote address (base class restriction) |
| `JBSucker_InvalidProof` | JBSucker | Merkle proof does not reconstruct the stored inbox root during `_validate` |
| `JBSucker_LeafAlreadyExecuted` | JBSucker | Leaf index already claimed in bitmap during `_validate` or `_validateForEmergencyExit` |
| `JBSucker_NoTerminalForToken` | JBSucker | No primary terminal registered for the token when pulling backing assets or adding to balance |
| `JBSucker_NotPeer` | JBSucker | `fromRemote` caller fails `_isRemotePeer` authentication |
| `JBSucker_NothingToSend` | JBSucker | `toRemote` called when emergency hatch is enabled or outbox has no unsent entries |
| `JBSucker_TokenAlreadyMapped` | JBSucker | Attempt to remap a token after outbox tree has entries (immutability enforcement) |
| `JBSucker_TokenHasInvalidEmergencyHatchState` | JBSucker | Emergency hatch state conflict during `toRemote`, `_mapToken`, or `_validateForEmergencyExit` |
| `JBSucker_TokenNotMapped` | JBSucker | `prepare` or `_sendRoot` called for an unmapped token |
| `JBSucker_UnexpectedMsgValue` | JBArbitrumSucker, JBOptimismSucker, JBCeloSucker | Non-zero transport payment on bridges that don't accept it (Arbitrum L2, OP Stack, Celo) |
| `JBSucker_ZeroBeneficiary` | JBSucker | `prepare` called with zero-address beneficiary |
| `JBSucker_ZeroERC20Token` | JBSucker | `prepare` called when project has no ERC-20 token |
| `JBArbitrumSucker_NotEnoughGas` | JBArbitrumSucker | Transport payment insufficient for retryable ticket gas cost |
| `JBCCIPSucker_InvalidRouter` | JBCCIPSucker | `ccipReceive` called by address other than `CCIP_ROUTER` |
| `JBSuckerRegistry_FeeExceedsMax` | JBSuckerRegistry | `setToRemoteFee` exceeds `MAX_TO_REMOTE_FEE` |
| `JBSuckerRegistry_InvalidDeployer` | JBSuckerRegistry | Deployer not in allowlist during `deploySuckersFor` |
| `JBSuckerRegistry_SuckerDoesNotBelongToProject` | JBSuckerRegistry | `removeDeprecatedSucker` called for sucker not belonging to the project |
| `JBSuckerRegistry_SuckerIsNotDeprecated` | JBSuckerRegistry | `removeDeprecatedSucker` called for a non-deprecated sucker |
| `JBCCIPSuckerDeployer_InvalidCCIPRouter` | JBCCIPSuckerDeployer | Zero-address CCIP router in constructor |
| `JBSuckerDeployer_AlreadyConfigured` | JBSuckerDeployer | `configureSucker` called on an already-configured sucker |
| `JBSuckerDeployer_DeployerIsNotConfigured` | JBSuckerDeployer | `createFor` called before deployer is configured |
| `JBSuckerDeployer_InvalidLayerSpecificConfiguration` | JBSuckerDeployer | Layer-specific configuration validation fails |
| `JBSuckerDeployer_LayerSpecificNotConfigured` | JBSuckerDeployer | Layer-specific configuration not set when required |
| `JBSuckerDeployer_Unauthorized` | JBSuckerDeployer | Caller is not the expected configurator |
| `JBSuckerDeployer_ZeroConfiguratorAddress` | JBSuckerDeployer | Zero-address configurator in constructor |
| `CCIPHelper_UnsupportedChain` | CCIPHelper | Chain ID has no CCIP chain selector mapping |
| `MerkleLib_InsertTreeIsFull` | MerkleLib | Merkle tree reached max capacity (`2^32 - 1` leaves) |

## Previous Audit Findings

No prior formal audit with finding IDs has been conducted on this codebase. All risk analysis is internal. See [RISKS.md](./RISKS.md) for known risks and trust assumptions.

## Anti-Patterns to Hunt

| Pattern | Where to Look | Why It's Dangerous |
|---------|--------------|-------------------|
| Non-atomic bridging (Arbitrum L1→L2) | `JBArbitrumSucker._sendRootOverAMB()` | Two independent retryable tickets: tokens and merkle root arrive separately. If message arrives before tokens, `_handleClaim` could mint unbacked tokens. Mitigated by `amountToAddToBalanceOf()` check -- verify this is sufficient. |
| Self-call pattern (CCIP) | `JBCCIPSucker.ccipReceive()` calls `this.fromRemote()` | The self-call bypasses the `_isRemotePeer` check since `msg.sender == address(this)`. All authentication happens in `ccipReceive`. Verify no path can call `fromRemote()` directly. |
| Emergency hatch with no timelock | `enableEmergencyHatchFor()` | Project owner can enable emergency exit instantly. No delay, no multisig requirement. If the owner's key is compromised, they can emergency-exit tokens that are legitimately in transit. |
| uint128 truncation | `_insertIntoTree()` | Amounts are cast to uint128 for SVM compatibility. If a project token amount exceeds uint128, it silently truncates. Verify the cast reverts on overflow. |
| Bitmap slot collision | `_executedFor[token]` vs emergency exit bitmap | Emergency exit uses `address(bytes20(keccak256(abi.encode(terminalToken))))` as a separate bitmap key. Verify this cannot collide with any legitimate token address. |
| Root flush on disable | `_mapToken()` with `bytes32(0)` | Disabling a token calls `_sendRoot()` to flush unsent entries. If the bridge is down, this flush reverts and the token cannot be disabled. |
| CCIP amount validation skip | `JBCCIPSucker._sendRootOverAMB()` | Amount validation is intentionally skipped (reverting would lock tokens). If CCIP delivers fewer tokens than expected, claims are underfunded. |
| Nonce gap acceptance | `fromRemote()` | Inbox nonce only requires `> current`, not `== current + 1`. For CCIP where messages can arrive out of order, intermediate roots are lost. |

## Coverage Gaps

The test suite covers core flows but these areas have limited or no coverage:

- **CCIP amount mismatch handling**: CCIP intentionally skips amount validation (reverting would lock tokens). No tests verify behavior when the delivered token amount differs from the amount encoded in the merkle root.
- **Arbitrum retryable ticket redemption ordering**: L1->L2 creates two independent retryable tickets (one for tokens, one for merkle root). No tests simulate the message arriving before tokens, verifying that `_addToBalance` correctly checks `amountToAddToBalanceOf` to prevent unbacked minting.
- **Multi-hop Celo WETH wrapping**: Celo wraps native ETH to WETH before bridging and unwraps on the other side. No tests cover edge cases like partial WETH unwrap failures or WETH contract balance manipulation.
- **Emergency exit under active bridging**: No tests for the scenario where a user calls `prepare()`, tokens are in the outbox, `toRemote()` is called (sending the root), and then emergency hatch is enabled -- verifying that `numberOfClaimsSent` correctly prevents double-spend across both chains.
- **Concurrent deprecation and bridging**: No tests for the timing window between `SENDING_DISABLED` and `DEPRECATED` states where `fromRemote()` can still accept roots but `prepare()`/`toRemote()` are blocked.
- **Token mapping flush under reentrancy**: `_mapToken` calls `_sendRoot()` when disabling a token with unsent outbox entries. No tests verify this flush is safe under reentrancy from the bridge callback.

## Compiler and Version Info

- **Solidity**: 0.8.26
- **EVM target**: Cancun
- **Optimizer**: via-IR, 200 runs
- **Dependencies**: OpenZeppelin 5.x, Arbitrum SDK, Chainlink CCIP, nana-core-v6
- **Build**: `forge build` (Foundry)

## How to Report Findings

For each finding:

1. **Title** -- one line, starts with severity (CRITICAL/HIGH/MEDIUM/LOW)
2. **Affected contract(s)** -- exact file path and line numbers
3. **Description** -- what is wrong, in plain language
4. **Trigger sequence** -- step-by-step, minimal steps to reproduce (include which chain each step happens on)
5. **Impact** -- what an attacker gains, what a user loses (with numbers if possible)
6. **Proof** -- code trace showing the exact execution path, or a Foundry test
7. **Fix** -- minimal code change that resolves the issue

**Severity guide:**
- **CRITICAL**: Double-claim, unbacked minting, bridge fund loss. Exploitable with no preconditions.
- **HIGH**: Conditional fund loss, authentication bypass, or broken cross-chain invariant.
- **MEDIUM**: Value leakage, griefing, stuck tokens (recoverable via emergency hatch).
- **LOW**: Informational, edge-case-only with no material impact.
