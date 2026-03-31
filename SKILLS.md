# Juicebox Suckers

## Purpose

Cross-chain token and fund bridging for Juicebox V6 projects, using merkle trees to batch claims and chain-specific bridges (Chainlink CCIP, OP Stack, Arbitrum) to move assets. Suckers are deployed in pairs on two chains -- each one cashes out project tokens locally, batches claims into a merkle tree, bridges the root and funds to its peer, and lets beneficiaries claim minted project tokens on the remote chain.

## Contracts

| Contract | Role |
|----------|------|
| `JBSucker` | Abstract base with full lifecycle: prepare, toRemote, fromRemote, claim, emergency hatch, deprecation. Manages outbox/inbox merkle trees per terminal token. Uses `ERC2771Context` for meta-transactions. Deployed as minimal clones via `Initializable`. Has immutable `FEE_PROJECT_ID` (typically project ID 1) and immutable `REGISTRY` (`IJBSuckerRegistry`). Reads the global `toRemoteFee` from the registry via `REGISTRY.toRemoteFee()` -- fee administration is centralized in `JBSuckerRegistry`, not per-clone. |
| `JBCCIPSucker` | CCIP bridge implementation. Implements `IAny2EVMMessageReceiver.ccipReceive`. Wraps native ETH to WETH before bridging (CCIP only transports ERC-20s), unwraps on receive. Overrides `_validateTokenMapping` to allow `NATIVE_TOKEN` mapping to ERC-20 addresses (for chains where ETH is not native). Refunds excess transport payment after `ccipSend` via low-level call (does not revert on refund failure). |
| `JBOptimismSucker` | OP Stack bridge implementation. Uses `IOPMessenger.sendMessage` for merkle roots and `IOPStandardBridge.bridgeERC20To` for ERC-20s. No transport payment required (`msg.value` must be 0 for ERC-20 bridging). Native tokens are sent as `msg.value` on `sendMessage`. |
| `JBBaseSucker` | Extends `JBOptimismSucker` with Base<->Ethereum chain ID mapping (1<->8453, 11155111<->84532). |
| `JBCeloSucker` | Extends `JBOptimismSucker` for Celo (OP Stack, custom gas token CELO). Wraps native ETH → WETH before bridging as ERC-20. Unwraps received WETH → native ETH via `_addToBalance` override. Removes `NATIVE_TOKEN → NATIVE_TOKEN` restriction. Sends messenger messages with `nativeValue = 0` (Celo's native token is CELO, not ETH). |
| `JBArbitrumSucker` | Arbitrum bridge implementation. Uses `unsafeCreateRetryableTicket` for L1->L2 (avoids address aliasing of refund address), `ArbSys.sendTxToL1` for L2->L1. Uses `IArbL1GatewayRouter.outboundTransferCustomRefund` for L1->L2 ERC-20 bridging, `IArbL2GatewayRouter.outboundTransfer` for L2->L1. Requires `msg.value` for L1->L2 transport. Verifies remote peer via Arbitrum bridge outbox on L1, via `AddressAliasHelper` on L2. |
| `JBSuckerRegistry` | Entry point for deploying and tracking suckers. Manages deployer allowlist (owner-only). Requires `DEPLOY_SUCKERS` permission to deploy. Tracks suckers via `EnumerableMap`. Can remove deprecated suckers via `removeDeprecatedSucker` (callable by anyone). Owns the global `toRemoteFee` (ETH fee in wei, capped at `MAX_TO_REMOTE_FEE` = 0.001 ether), adjustable by the registry owner via `setToRemoteFee()`. Initialized to `MAX_TO_REMOTE_FEE` at construction. All suckers read the fee from the registry -- one call changes the fee everywhere. |
| `JBSuckerDeployer` | Abstract deployer base. Uses Solady `LibClone.cloneDeterministic` to deploy suckers as minimal proxies. Two-phase setup: `setChainSpecificConstants` (bridge addresses) then `configureSingleton` (sucker implementation). Both are one-shot calls restricted to `LAYER_SPECIFIC_CONFIGURATOR`. |
| `JBCCIPSuckerDeployer` | CCIP-specific deployer. Stores `ccipRouter` (`ICCIPRouter`), `ccipRemoteChainId` (`uint256`), `ccipRemoteChainSelector` (`uint64`). |
| `JBOptimismSuckerDeployer` | OP-specific deployer. Stores `opMessenger` (`IOPMessenger`), `opBridge` (`IOPStandardBridge`). |
| `JBBaseSuckerDeployer` | Thin wrapper around `JBOptimismSuckerDeployer` for separate Base artifact. |
| `JBCeloSuckerDeployer` | Extends `JBOptimismSuckerDeployer` with `wrappedNative` (`IWrappedNativeToken`) for the local chain's WETH. Extended `setChainSpecificConstants` accepts messenger, bridge, and wrapped native token. |
| `JBArbitrumSuckerDeployer` | Arbitrum-specific deployer. Stores `arbInbox` (`IInbox`), `arbGatewayRouter` (`IArbGatewayRouter`), `arbLayer` (`JBLayer`). |
| `MerkleLib` | Incremental merkle tree (depth 32, max 2^32 - 1 leaves). `insert` appends leaves, `root` computes current root (gas-optimized assembly), `branchRoot` verifies proofs (assembly). Modeled on eth2 deposit contract. |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `prepare(projectTokenCount, beneficiary, minTokensReclaimed, token)` | `JBSucker` | Transfers project tokens (ERC-20) from caller via `safeTransferFrom`, cashes them out at the project's primary terminal for the specified terminal token, inserts a leaf into the outbox merkle tree. `beneficiary` is `bytes32` for cross-VM compatibility. Amounts are capped at `uint128` for SVM compatibility. Reverts if token not mapped, sucker deprecated/sending-disabled, beneficiary is zero, or project has no ERC-20 token. |
| `toRemote(token)` | `JBSucker` | Sends the outbox merkle root and accumulated funds for `token` to the peer sucker via the bridge. Deducts `toRemoteFee` from `msg.value` (paid into fee project), passes remainder as transport payment. Increments outbox nonce and updates `numberOfClaimsSent`. Reverts if outbox is empty or emergency hatch is open. |
| `setToRemoteFee(fee)` | `JBSuckerRegistry` | Sets the global `toRemoteFee` for all suckers. Restricted to the registry owner via OpenZeppelin `Ownable` (`onlyOwner`). The fee must be <= `MAX_TO_REMOTE_FEE` (0.001 ether). Emits `ToRemoteFeeChanged`. |
| `fromRemote(root)` | `JBSucker` | Receives a merkle root from the remote peer. Validates `MESSAGE_VERSION` (reverts on mismatch). Updates inbox tree only if received nonce > current inbox nonce. Accepts roots in all states including `DEPRECATED` to prevent stranding already-sent tokens. Does NOT revert on stale nonce -- emits `StaleRootRejected` instead (to avoid losing native tokens sent with the message). |
| `claim(claimData)` | `JBSucker` | Verifies a merkle proof against the inbox tree, marks the leaf as executed (prevents double-spend), mints project tokens for the beneficiary via `IJBController.mintTokensOf` (with `useReservedPercent: false`), and adds terminal tokens to the project's balance. |
| `claim(claims[])` | `JBSucker` | Batch version -- iterates and calls `claim(JBClaim)` for each. |
| `mapToken(map)` | `JBSucker` | Maps a local terminal token to a remote token. Requires `MAP_SUCKER_TOKEN` permission. Setting `remoteToken` to `bytes32(0)` disables bridging and sends a final root to flush remaining outbox. Cannot remap to a different remote token once outbox has entries (prevents double-spend). Can re-enable a previously disabled token to the same remote address. Reverts if emergency hatch is active for the token. |
| `mapTokens(maps[])` | `JBSucker` | Batch version of `mapToken`. Splits `msg.value` evenly across mappings that need a final root flush (disable with pending outbox entries). Refunds any remainder (dust) from integer division back to the caller on a best-effort basis (L-47). |
| `enableEmergencyHatchFor(tokens)` | `JBSucker` | Opens emergency hatch for specified tokens (irreversible). Sets `emergencyHatch = true` and `enabled = false` on each token's `JBRemoteToken`. Requires `SUCKER_SAFETY` permission from the project owner. |
| `exitThroughEmergencyHatch(claimData)` | `JBSucker` | Lets users reclaim tokens on the chain they deposited, using their **outbox** proof (not inbox). Only works when emergency hatch is open for the token OR sucker is `SENDING_DISABLED`/`DEPRECATED`. Only allows exit for leaves with index >= `numberOfClaimsSent` (leaves not yet sent to remote). Decreases `outbox.balance`. Uses a separate execution bitmap slot (derived from `keccak256(abi.encode(terminalToken))`) to avoid collision with inbox claim tracking. |
| `setDeprecation(timestamp)` | `JBSucker` | Sets when the sucker becomes fully deprecated. Must be at least `_maxMessagingDelay()` (14 days) in the future. Set to `0` to cancel pending deprecation. Reverts if already in `SENDING_DISABLED` or `DEPRECATED` state. Requires `SET_SUCKER_DEPRECATION` permission from the project owner. |
| `ccipReceive(any2EvmMessage)` | `JBCCIPSucker` | CCIP entry point. Validates `msg.sender == CCIP_ROUTER`, decodes sender and verifies it matches `peer()` and `REMOTE_CHAIN_SELECTOR`. Unwraps WETH to native ETH if `root.token == NATIVE_TOKEN`. Calls `this.fromRemote(root)` (external self-call so `_isRemotePeer` sees `msg.sender == address(this)`). |
| `deploySuckersFor(projectId, salt, configs)` | `JBSuckerRegistry` | Deploys one or more suckers for a project. Requires `DEPLOY_SUCKERS` permission. Salt is hashed with `msg.sender`: `keccak256(abi.encode(msg.sender, salt))`. For each config, clones via the deployer, maps tokens, and tracks the sucker. |
| `allowSuckerDeployer(deployer)` | `JBSuckerRegistry` | Adds a deployer to the allowlist. Owner-only (`onlyOwner`). |
| `allowSuckerDeployers(deployers[])` | `JBSuckerRegistry` | Batch version. Owner-only. |
| `removeDeprecatedSucker(projectId, sucker)` | `JBSuckerRegistry` | Removes a deprecated sucker from the registry. Callable by anyone. Reverts if sucker state is not `DEPRECATED`. |
| `removeSuckerDeployer(deployer)` | `JBSuckerRegistry` | Removes a deployer from the allowlist. Owner-only. |
| `createForSender(localProjectId, salt)` | `JBSuckerDeployer` | Clones the singleton sucker deterministically (salt = `keccak256(abi.encodePacked(msg.sender, salt))`) and initializes it with the project ID. |
| `configureSingleton(singleton)` | `JBSuckerDeployer` | One-time configuration of the sucker implementation to clone. Must be called by `LAYER_SPECIFIC_CONFIGURATOR` after `setChainSpecificConstants`. |
| `setChainSpecificConstants(...)` | Deployers | One-time configuration of bridge-specific addresses. Callable only by `LAYER_SPECIFIC_CONFIGURATOR`. Varies by deployer type. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `@bananapus/core-v6` | `IJBDirectory`, `IJBController`, `IJBTokens`, `IJBTerminal`, `IJBCashOutTerminal` | Project lookup (`controllerOf`, `primaryTerminalOf`), token minting (`mintTokensOf`), cash-outs (`cashOutTokensOf`), `addToBalanceOf` |
| `@bananapus/core-v6` | `JBConstants` | `NATIVE_TOKEN` sentinel address (`0x000...EEEe`) |
| `@bananapus/permission-ids-v6` | `JBPermissionIds` | `MAP_SUCKER_TOKEN`, `DEPLOY_SUCKERS`, `SUCKER_SAFETY`, `SET_SUCKER_DEPRECATION`, `MINT_TOKENS` |
| `@chainlink/contracts-ccip` | `Client`, `IAny2EVMMessageReceiver` | CCIP message encoding/decoding (`EVM2AnyMessage`, `Any2EVMMessage`), receiver interface |
| `@arbitrum/nitro-contracts` | `IInbox`, `IOutbox`, `IBridge`, `ArbSys`, `AddressAliasHelper` | Arbitrum retryable tickets, L2->L1 messages, L1/L2 address aliasing verification |
| `@openzeppelin/contracts` | `SafeERC20`, `BitMaps`, `ERC165`, `Initializable`, `Ownable`, `ERC2771Context`, `EnumerableMap` | Token safety, leaf execution tracking, clone initialization, registry ownership and fee administration, meta-transactions, sucker enumeration. Note: `Ownable` is used by `JBSuckerRegistry` (not `JBSucker`). |
| `solady` | `LibClone` | Deterministic minimal proxy deployment (`cloneDeterministic`) |

## Key Types

| Struct/Enum | Fields | Used In |
|-------------|--------|---------|
| `JBClaim` | `token` (address), `leaf` (`JBLeaf`), `proof` (`bytes32[32]`) | `claim`, `exitThroughEmergencyHatch` |
| `JBLeaf` | `index` (uint256), `beneficiary` (bytes32), `projectTokenCount` (uint256), `terminalTokenAmount` (uint256) | Merkle tree leaves -- hash is `keccak256(abi.encode(projectTokenCount, terminalTokenAmount, beneficiary))` |
| `JBOutboxTree` | `nonce` (uint64), `balance` (uint256), `tree` (MerkleLib.Tree), `numberOfClaimsSent` (uint256) | Per-token outbox state in `JBSucker` |
| `JBInboxTreeRoot` | `nonce` (uint64), `root` (bytes32) | Per-token inbox state in `JBSucker` |
| `JBMessageRoot` | `version` (uint8), `token` (bytes32), `amount` (uint256), `remoteRoot` (`JBInboxTreeRoot`) | Cross-chain message payload sent via bridge |
| `JBRemoteToken` | `enabled` (bool), `emergencyHatch` (bool), `minGas` (uint32), `addr` (bytes32) | Token mapping config stored in `_remoteTokenFor[token]` |
| `JBTokenMapping` | `localToken` (address), `minGas` (uint32), `remoteToken` (bytes32) | Input for `mapToken`/`mapTokens` |
| `JBSuckerDeployerConfig` | `deployer` (`IJBSuckerDeployer`), `mappings` (`JBTokenMapping[]`) | Input for `deploySuckersFor` |
| `JBSuckersPair` | `local` (address), `remote` (bytes32), `remoteChainId` (uint256) | Return type for `suckerPairsOf` |
| `JBSuckerState` | `ENABLED` (0), `DEPRECATION_PENDING` (1), `SENDING_DISABLED` (2), `DEPRECATED` (3) | Deprecation lifecycle states |
| `JBLayer` | `L1` (0), `L2` (1) | Arbitrum sucker layer identification |

## Constants

| Name | Value | Context |
|------|-------|---------|
| `FEE_PROJECT_ID` | Set at construction (typically `1`) | The project that receives `toRemoteFee` payments via `terminal.pay()`. Immutable on `JBSucker`. |
| `REGISTRY` | Set at construction | The `IJBSuckerRegistry` that manages the global `toRemoteFee`. Immutable on `JBSucker`. |
| `toRemoteFee` | Storage variable on `JBSuckerRegistry`, initialized to `MAX_TO_REMOTE_FEE` | ETH fee (in wei) paid into the fee project on each `toRemote()` call. Adjustable by the registry owner via `setToRemoteFee()`, capped at `MAX_TO_REMOTE_FEE`. Global -- applies to all suckers. |
| `MAX_TO_REMOTE_FEE` | `0.001 ether` | Hard cap on what `toRemoteFee` can be set to. Constant on `JBSuckerRegistry`. |
| `MESSENGER_BASE_GAS_LIMIT` | `300_000` | Minimum gas for cross-chain `fromRemote` call |
| `MESSENGER_ERC20_MIN_GAS_LIMIT` | `200_000` | Minimum gas for ERC-20 transfer on remote chain |
| `_TREE_DEPTH` | `32` | Merkle tree depth (max ~4B leaves) |
| `MESSAGE_VERSION` | `1` | Message format version for cross-chain compatibility |
| `_maxMessagingDelay()` | `14 days` | Minimum deprecation lead time (virtual, can be overridden) |

## Permissions

| Permission ID | Used By | Required For |
|---------------|---------|-------------|
| `DEPLOY_SUCKERS` | `JBSuckerRegistry.deploySuckersFor` | Deploying suckers for a project |
| `MAP_SUCKER_TOKEN` | `JBSucker.mapToken`, `JBSucker.mapTokens` | Mapping/unmapping token pairs |
| `SUCKER_SAFETY` | `JBSucker.enableEmergencyHatchFor` | Opening the emergency hatch for tokens |
| `SET_SUCKER_DEPRECATION` | `JBSucker.setDeprecation` | Setting the deprecation timestamp |
| `MINT_TOKENS` | Needed on the sucker address | Sucker must have this to mint project tokens on claim |

## Errors

| Error | Contract | When |
|-------|----------|------|
| `JBSucker_AmountExceedsUint128` | `JBSucker` | `projectTokenCount` or `terminalTokenAmount` exceeds `uint128` (SVM cap) |
| `JBSucker_BelowMinGas` | `JBSucker` | Token mapping `minGas` is below `MESSENGER_ERC20_MIN_GAS_LIMIT` |
| `JBSucker_Deprecated` | `JBSucker` | `prepare` or `toRemote` called when sucker is `SENDING_DISABLED` or `DEPRECATED` |
| `JBSucker_DeprecationTimestampTooSoon` | `JBSucker` | `setDeprecation` timestamp is less than `_maxMessagingDelay()` in the future |
| `JBSucker_ExpectedMsgValue` | `JBSucker` | `toRemote` called without required `msg.value` for transport payment |
| `JBSucker_IndexOutOfRange` | `JBSucker` | Leaf index exceeds tree depth (`>= 2^32`) in `_validate` or `_validateForEmergencyExit` |
| `JBSucker_InsufficientBalance` | `JBSucker` | Emergency hatch exit amount exceeds outbox balance |
| `JBSucker_InsufficientMsgValue` | `JBSucker` | `msg.value` is less than the `toRemoteFee` |
| `JBSucker_InvalidMessageVersion` | `JBSucker` | `fromRemote` receives a message with wrong `MESSAGE_VERSION` |
| `JBSucker_InvalidNativeRemoteAddress` | `JBSucker` | `NATIVE_TOKEN` mapped to a non-native, non-zero remote address (base validation) |
| `JBSucker_InvalidProof` | `JBSucker` | Merkle proof does not match the inbox root |
| `JBSucker_LeafAlreadyExecuted` | `JBSucker` | `claim` or emergency exit for a leaf that was already processed |
| `JBSucker_NoTerminalForToken` | `JBSucker` | Project has no terminal for the specified token |
| `JBSucker_NotPeer` | `JBSucker` | `fromRemote` called by an address that is not the recognized peer |
| `JBSucker_NothingToSend` | `JBSucker` | `toRemote` called when outbox has no pending entries |
| `JBSucker_TokenAlreadyMapped` | `JBSucker` | Attempting to remap a token to a different remote address when outbox has entries |
| `JBSucker_TokenHasInvalidEmergencyHatchState` | `JBSucker` | Operation incompatible with the token's emergency hatch state |
| `JBSucker_TokenNotMapped` | `JBSucker` | `prepare` called for a token that has no mapping |
| `JBSucker_UnexpectedMsgValue` | `JBSucker` | `msg.value` sent when not expected |
| `JBSucker_ZeroBeneficiary` | `JBSucker` | `prepare` called with `bytes32(0)` beneficiary |
| `JBSucker_ZeroERC20Token` | `JBSucker` | `prepare` called but project has no ERC-20 token deployed |
| `JBCCIPSucker_InvalidRouter` | `JBCCIPSucker` | Zero address passed as `CCIP_ROUTER` at construction time |
| `JBArbitrumSucker_NotEnoughGas` | `JBArbitrumSucker` | `msg.value` insufficient for Arbitrum retryable ticket cost |
| `JBSuckerRegistry_FeeExceedsMax` | `JBSuckerRegistry` | `setToRemoteFee` called with fee > `MAX_TO_REMOTE_FEE` |
| `JBSuckerRegistry_InvalidDeployer` | `JBSuckerRegistry` | Deployer not on the allowlist |
| `JBSuckerRegistry_SuckerDoesNotBelongToProject` | `JBSuckerRegistry` | Sucker is not registered for the given project |
| `JBSuckerRegistry_SuckerIsNotDeprecated` | `JBSuckerRegistry` | `removeDeprecatedSucker` called on a non-deprecated sucker |
| `JBSuckerDeployer_AlreadyConfigured` | `JBSuckerDeployer` | `configureSingleton` or `setChainSpecificConstants` called a second time |
| `JBSuckerDeployer_DeployerIsNotConfigured` | `JBSuckerDeployer` | `createForSender` called before singleton is configured |
| `JBSuckerDeployer_InvalidLayerSpecificConfiguration` | `JBSuckerDeployer` | Invalid bridge addresses passed to `setChainSpecificConstants` |
| `JBSuckerDeployer_LayerSpecificNotConfigured` | `JBSuckerDeployer` | `configureSingleton` called before `setChainSpecificConstants` |
| `JBSuckerDeployer_Unauthorized` | `JBSuckerDeployer` | Caller is not `LAYER_SPECIFIC_CONFIGURATOR` |
| `JBSuckerDeployer_ZeroConfiguratorAddress` | `JBSuckerDeployer` | Constructor passed `address(0)` for configurator |
| `JBCCIPSuckerDeployer_InvalidCCIPRouter` | `JBCCIPSuckerDeployer` | Zero address passed as CCIP router |
| `CCIPHelper_UnsupportedChain` | `CCIPHelper` | Chain ID has no known CCIP chain selector mapping |
| `MerkleLib_InsertTreeIsFull` | `MerkleLib` | Tree has reached max capacity (2^32 - 1 leaves) |

## Gotchas

- **`remoteToken` is `bytes32`, not `address`.** All remote token addresses in `JBTokenMapping`, `JBRemoteToken`, and `JBMessageRoot` are `bytes32` for cross-VM compatibility (e.g., Solana). Convert EVM addresses with `bytes32(uint256(uint160(addr)))`.
- **`JBLeaf.beneficiary` is `bytes32`, not `address`.** Same cross-VM reasoning. The `prepare` function takes `bytes32 beneficiary`.
- `using MerkleLib for MerkleLib.Tree` is NOT inherited by derived contracts -- must redeclare in test harnesses.
- Suckers are deployed as minimal clones (`LibClone.cloneDeterministic`). The singleton's constructor calls `_disableInitializers()` so it cannot be initialized directly. Only clones can be initialized.
- For suckers to be peers, the same `salt` AND the same caller address must be used on both chains when calling `deploySuckersFor`. The registry hashes `keccak256(abi.encode(msg.sender, salt))`, and the deployer hashes `keccak256(abi.encodePacked(msg.sender, salt))` again.
- `peer()` defaults to `bytes32(uint256(uint160(address(this))))` -- suckers expect to be deployed at matching addresses on both chains via deterministic deployment. Can be overridden for cross-VM peers (e.g., Solana PDA addresses).
- `JBCCIPSucker` and `JBCeloSucker` override `_validateTokenMapping` to only enforce minimum gas, allowing `NATIVE_TOKEN` to map to any remote address (the remote chain may not have native ETH). Base `JBSucker` restricts `NATIVE_TOKEN` to mapping only to `NATIVE_TOKEN` or `bytes32(0)`.
- Emergency hatch is irreversible per-token. Once opened, the token can never be bridged again by that sucker. Invariant: `emergencyHatch == true` implies `enabled == false`.
- `MESSENGER_BASE_GAS_LIMIT` is 300,000. `MESSENGER_ERC20_MIN_GAS_LIMIT` is 200,000. Token mappings must specify `minGas >= 200,000` for ERC-20s. `JBCCIPSucker` requires `minGas >= 200,000` for ALL tokens (including native) because CCIP wraps native to WETH.
- `JBArbitrumSucker` uses `unsafeCreateRetryableTicket` (not `safeCreateRetryableTicket`) to avoid L2 address aliasing of the refund address.
- The outbox tree tracks `numberOfClaimsSent` separately from `tree.count`. Emergency hatch exit is only available for leaves whose index >= `numberOfClaimsSent` (not yet sent to remote). A `numberOfClaimsSent` of 0 means no root has ever been sent, so all leaves can be emergency-exited.
- Both `projectTokenCount` and `terminalTokenAmount` are capped at `uint128` in `_insertIntoTree` for SVM (Solana) compatibility.
- Nonce ordering is non-sequential: `fromRemote` accepts any nonce strictly greater than the current inbox nonce. Out-of-order nonces (from CCIP) cause earlier nonces to be silently skipped, making their claims permanently unclaimable on that chain. The sender must use the emergency hatch on the source chain to recover.
- `toRemote` fee payment is best-effort: if the fee project has no native token terminal or `terminal.pay()` reverts, `toRemote` proceeds without collecting the fee. The caller still receives project tokens from the fee payment when it succeeds.
- `JBCCIPSucker` transport payment refund uses a low-level `call` that does NOT revert on failure. If the refund fails (e.g., caller is a non-payable contract), the excess ETH is permanently stuck. The `TransportPaymentRefundFailed` event provides observability.
- The sucker has an unrestricted `receive()` function -- it must accept ETH from bridges, WETH unwrapping, and terminal cash-outs. Excess ETH increases `amountToAddToBalanceOf` for the project (not a double-spend risk).
- `fromRemote()` validates the peer using `msg.sender`, not `_msgSender()`. Using `_msgSender()` would allow a trusted ERC-2771 forwarder to spoof the bridge peer address. Never use a meta-tx forwarder as a relay for `fromRemote` calls.
- `ccipReceive()` validates the CCIP router using `msg.sender`, not `_msgSender()`, for the same reason. A trusted forwarder could append the router address via the ERC-2771 calldata suffix and fully control the `Any2EVMMessage` struct.

### CRITICAL: NATIVE_TOKEN Mismatch on Non-ETH Chains

`JBConstants.NATIVE_TOKEN` (`0x000...EEEe`) represents whatever is native on the current chain -- ETH on Ethereum/Optimism/Base/Arbitrum, but CELO on Celo, MATIC on Polygon, etc.

**Mapping `NATIVE_TOKEN -> NATIVE_TOKEN` across chains with different native assets is dangerous:**

- The sucker bridges raw amounts without exchange rate conversion
- 1 CELO bridged as if it were 1 ETH massively overvalues the payment
- Project issuance (`baseCurrency=1`, i.e. ETH) treats CELO at 1:1 with ETH

**Safe chains** (ETH is native): Ethereum, Optimism, Base, Arbitrum -- `NATIVE_TOKEN -> NATIVE_TOKEN` works correctly.

**Unsafe chains** (non-ETH native): Celo, Polygon, Avalanche, BNB -- use ERC-20 WETH or USDC as the terminal accounting context, NOT `NATIVE_TOKEN`.

**Correct token mapping on Celo:**
```solidity
// Map WETH (ERC-20) on Ethereum to WETH (ERC-20) on Celo
JBTokenMapping({
    localToken: WETH_ETHEREUM,
    minGas: 200_000,
    remoteToken: bytes32(uint256(uint160(WETH_CELO)))
})
```

**Wrong token mapping on Celo:**
```solidity
// NATIVE_TOKEN on Ethereum is ETH, but on Celo it's CELO!
JBTokenMapping({
    localToken: JBConstants.NATIVE_TOKEN,
    minGas: 200_000,
    remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))  // WRONG
})
```

See also: `RISKS.md` in this repo.

## Deprecation Lifecycle

```
ENABLED --> DEPRECATION_PENDING --> SENDING_DISABLED --> DEPRECATED
```

| State | Condition | prepare | toRemote | fromRemote | claim | emergency exit |
|-------|-----------|---------|----------|------------|-------|----------------|
| `ENABLED` | `deprecatedAfter == 0` | yes | yes | yes | yes | per-token only |
| `DEPRECATION_PENDING` | `now < deprecatedAfter - 14 days` | yes | yes | yes | yes | per-token only |
| `SENDING_DISABLED` | `now < deprecatedAfter` | no | no | yes | yes | all tokens |
| `DEPRECATED` | `now >= deprecatedAfter` | no | no | yes | yes | all tokens |

## Example Integration

```solidity
// Deploy suckers for project 12 using CCIP to bridge ETH between Ethereum and Optimism

// 1. Grant MAP_SUCKER_TOKEN permission to the registry
uint256[] memory mapPermIds = new uint256[](1);
mapPermIds[0] = JBPermissionIds.MAP_SUCKER_TOKEN;
permissions.setPermissionsFor(
    projectOwner,
    JBPermissionsData({
        operator: address(registry),
        projectId: 12,
        permissionIds: mapPermIds
    })
);

// 2. Configure the token mapping (remoteToken is bytes32!)
JBTokenMapping[] memory mappings = new JBTokenMapping[](1);
mappings[0] = JBTokenMapping({
    localToken: JBConstants.NATIVE_TOKEN,
    minGas: 200_000,
    remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
});

// 3. Deploy the sucker
JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](1);
configs[0] = JBSuckerDeployerConfig({
    deployer: IJBSuckerDeployer(ccipSuckerDeployerAddress),
    mappings: mappings
});

// Must use the same salt and caller on both chains
bytes32 salt = keccak256("my-project-suckers-v1");
address[] memory suckers = registry.deploySuckersFor(12, salt, configs);

// 4. Grant the sucker MINT_TOKENS permission so it can mint on claim
uint256[] memory mintPermIds = new uint256[](1);
mintPermIds[0] = JBPermissionIds.MINT_TOKENS;
permissions.setPermissionsFor(
    projectOwner,
    JBPermissionsData({
        operator: suckers[0],
        projectId: 12,
        permissionIds: mintPermIds
    })
);

// 5. Repeat on the other chain with matching salt and caller
```
