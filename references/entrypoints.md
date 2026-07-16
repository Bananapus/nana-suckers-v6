# Sucker Entry Points

Use this file when you already know the task is in `nana-suckers-v6` and need the concrete contract/function surface to open next.

> V6 is testnet-only. Deployed sucker, registry, and deployer addresses live in `deploy-all-v6`'s address output, not here.

## Purpose

A sucker bridges a Juicebox project's token economy between two chains. Cashed-out positions are committed to a local outbox merkle tree, the root is relayed to the peer sucker on the remote chain, and beneficiaries prove inclusion against the inbox root to recreate their position on the destination chain. The `JBSucker` base owns the shared flow; chain-specific subclasses (`JBArbitrumSucker`, `JBOptimismSucker`, `JBCCIPSucker`, `JBBaseSucker`) own transport delivery and verification.

## Contracts

| Contract | Role |
|----------|------|
| `JBSucker` | Abstract base. Owns the prepare/relay/claim/token-mapping/deprecation/emergency flow and dual merkle (outbox/inbox) state. |
| `JBArbitrumSucker` | Arbitrum bridge transport. |
| `JBOptimismSucker` | OP Stack bridge transport. |
| `JBCCIPSucker` | Chainlink CCIP transport. |
| `JBBaseSucker` | Base/OP Stack transport. |
| `JBSuckerRegistry` | Project-to-sucker inventory, deployer allowlist, owner-gated token-pair allowlist, shared `toRemote` fee, deprecation removal, cross-chain surplus/supply aggregation. |

`IJBSucker` is the minimal interface; `IJBSuckerExtended` adds the deprecation, emergency-hatch, and retained-fee surface.

## Structs

### `JBTokenMapping` (argument to `mapToken` / `mapTokens`)

| Field | Type | Meaning |
|-------|------|---------|
| `localToken` | `address` | The local token address. |
| `minGas` | `uint32` | The minimum gas to use when bridging this token. |
| `remoteToken` | `bytes32` | The remote token address (bytes32 for cross-VM compatibility). For OP Stack and Arbitrum ERC-20 lanes, this must be the exact bridge-registered counterpart delivered on the destination, not merely an economically equivalent canonical token. |

### `JBClaim` (argument to `claim` / `exitThroughEmergencyHatch`)

| Field | Type | Meaning |
|-------|------|---------|
| `token` | `address` | The local terminal token to claim. |
| `leaf` | `JBLeaf` | The leaf to claim from (see below). |
| `proof` | `bytes32[32]` | The merkle proof. Must be of length `JBSucker._TREE_DEPTH` (32). |

### `JBLeaf` (the `leaf` field of `JBClaim`)

| Field | Type | Meaning |
|-------|------|---------|
| `index` | `uint256` | The leaf's index in the tree. |
| `beneficiary` | `bytes32` | The beneficiary (bytes32 for cross-VM compatibility). |
| `projectTokenCount` | `uint256` | The number of project tokens to claim. |
| `terminalTokenAmount` | `uint256` | The amount of terminal tokens to claim. |
| `metadata` | `bytes32` | Opaque, caller-defined payload covered by the leaf hash. `bytes32(0)` when no extra context. |

### `JBAccountingSnapshot` (argument to `fromRemoteAccounting`)

A cross-chain accounting gossip bundle: the sending chain's own record plus every peer-chain record it currently holds.

| Field | Type | Meaning |
|-------|------|---------|
| `version` | `uint8` | Message format version. Must match `MESSAGE_VERSION`. |
| `accounts` | `JBChainAccounting[]` | One accounting record per source chain known to the sender (its own chain plus forwarded peers), each carrying its origin chain id and freshness key. The receiver stores the freshest record per source chain. |

The same `JBChainAccounting[] accounts` bundle is also carried by the root message `JBMessageRoot` (alongside `token`, `amount`, and `remoteRoot`), so a `toRemote` send propagates accounting too.

### `JBChainAccounting` (one source chain's record in a bundle)

| Field | Type | Meaning |
|-------|------|---------|
| `chainId` | `uint256` | The source chain this record describes. A receiver ignores a record for its own chain or chain 0. |
| `totalSupply` | `uint256` | Source-chain project-token supply, including reserved tokens. |
| `contexts` | `JBSourceContext[]` | Raw source-chain surplus and balance contexts, un-valued (in the source chain's own token addresses and decimals). |
| `timestamp` | `uint256` | Monotonic source-chain freshness key, gated independently per source chain. |

## Key functions

### JBSucker — bridge flow (`IJBSucker`)

| Function | What it does |
|----------|--------------|
| `prepare(uint256 projectTokenCount, bytes32 beneficiary, uint256 minTokensReclaimed, address token, bytes32 metadata)` | Cash out `projectTokenCount` project tokens into `token` and insert a leaf for `beneficiary` into the outbox tree for bridging. `minTokensReclaimed` bounds slippage; `metadata` is an opaque attribution payload carried in the leaf hash (`bytes32(0)` for a plain bridge). |
| `toRemote(address token) payable` | Send the current outbox tree root and bridged assets for `token` to the remote peer through the chain-specific transport. `payable` to fund the transport message and the registry's `toRemoteFee`. |
| `syncAccountingData() payable` | Send the cross-chain accounting gossip bundle — this chain's own record plus every peer-chain record it holds (gathered across the project's suckers via the registry, minus the destination) — without sending an outbox root or paying the registry `toRemoteFee`. Can be retried with unchanged data; `payable` only funds bridge transport. |
| `fromRemoteAccounting(JBAccountingSnapshot calldata snapshot)` | Authenticated receive path for an accounting-only gossip bundle. Stores the freshest record per source chain, without touching any token-local inbox root. |
| `claim(JBClaim calldata claimData)` | Claim bridged project tokens for the leaf's beneficiary by proving inclusion against the inbox root. |
| `claim(JBClaim[] calldata claims)` | Claim multiple leaves in one call. Each leaf is routed through an external `this.claim` sub-call, so one failing leaf emits `ClaimFailed` and is reverted in isolation while the rest of the batch proceeds; the failed leaf stays claimable later. |
| `mapToken(JBTokenMapping calldata map) payable` | Map a single local token to a remote token for bridging. Mappings are immutable once the outbox tree has entries (can only be disabled, not remapped). Requires `MAP_SUCKER_TOKEN` permission (initial mappings are applied at deploy under `DEPLOY_SUCKERS`). Native/native mappings and different-address mappings must also be approved by the registry owner for this sucker's peer chain. Mapping and registry checks do not validate an external native bridge's ERC-20 pair; OP Stack and Arbitrum routes must be verified against the live bridge in both directions before use. |
| `mapTokens(JBTokenMapping[] calldata maps) payable` | Map multiple local tokens to remote tokens in one call. |

### JBSucker — deprecation & emergency (`IJBSuckerExtended`)

| Function | What it does |
|----------|--------------|
| `setDeprecation(uint40 timestamp)` | Set or update the deprecation timestamp. Drives the `JBSuckerState` lifecycle: `ENABLED` → `DEPRECATION_PENDING` → `SENDING_DISABLED` → `DEPRECATED`. Requires `SET_SUCKER_DEPRECATION` permission. |
| `enableEmergencyHatchFor(address[] calldata tokens)` | Open the emergency hatch for the given tokens, allowing direct claims without bridging when transport is unavailable. Requires `SUCKER_SAFETY` permission (project owner). |
| `exitThroughEmergencyHatch(JBClaim calldata claimData)` | Claim a leaf directly through an open emergency hatch when bridging cannot complete. |
| `claimRetainedToRemoteFee(address payable beneficiary)` | Withdraw ETH from a `toRemote` fee payment that previously failed and was retained for the caller. |
| `claimRetainedTransportPaymentRefund(address payable beneficiary)` | Withdraw ETH from a transport-payment refund that previously failed and was retained for the caller. |

### JBSucker — key views (`IJBSucker` / `IJBSuckerExtended`)

| Function | What it does |
|----------|--------------|
| `state()` | Returns the current `JBSuckerState` (deprecation lifecycle stage). |
| `peer()` | Returns the peer sucker address on the remote chain (bytes32). |
| `peerChainId()` | Returns the remote peer chain ID. |
| `projectId()` | Returns the local project ID this sucker serves. |
| `isMapped(address token)` | Whether a token has been mapped for bridging. |
| `remoteTokenFor(address token)` | The `JBRemoteToken` info a local token maps to. |
| `inboxOf(address token)` | The inbox merkle tree root (`JBInboxTreeRoot`) for a token. |
| `outboxOf(address token)` | The outbox merkle tree (`JBOutboxTree`) for a token. |
| `amountToAddToBalanceOf(address token)` | Tokens received from bridging that are waiting to be added to the project's terminal balance. |
| `executedLeafHashOf(address token, uint256 index)` | The committed leaf hash at `(token, index)`, or `bytes32(0)` if unexecuted. Beneficiary contracts re-derive this to authenticate a settlement that a front-runner's direct `claim` already executed. |
| `peerChainIds(bool includeVirtual)` | The peer chains this sucker reports accounting for: its directly-connected peer, plus — when `includeVirtual` is true — every chain learned about through gossip. The registry aggregates the `includeVirtual: true` set. |
| `peerChainAccountsOf()` | The raw, un-valued `JBChainAccounting[]` record this sucker holds for every known peer chain. The registry reads this to gather a project's cross-chain knowledge and re-gossip it. |
| `peerChainContextsOf(uint256 chainId)` | Per-context surplus and balance for one peer chain, resolved to local currencies and folded at read time. Un-valued; returned with the chain's freshness key. |
| `peerChainTotalSupplyOf(uint256 chainId)` | The last-known total token supply on one peer chain (the registry sums these to compute effective cross-chain supply). |
| `peerChainTotalSupplyValue(uint256 chainId)` | One peer chain's total supply bundled with its chain id and freshness key (`JBPeerChainValue`). |
| `snapshotTimestampOf(uint256 chainId)` | The freshness key of the latest accepted record for one peer chain. |
| `retainedToRemoteFeeOf(address account)` | ETH owed to `account` from a failed `toRemote` fee payment. |
| `retainedTransportPaymentRefundOf(address account)` | ETH owed to `account` from a failed transport-payment refund. |

### JBSuckerRegistry (`IJBSuckerRegistry`)

| Function | What it does |
|----------|--------------|
| `deploySuckersFor(uint256 projectId, bytes32 salt, JBSuckerDeployerConfig[] calldata configurations)` | Deploy one or more suckers for a project and apply each config's initial token mappings. Requires `DEPLOY_SUCKERS`. Returns the deployed sucker addresses. |
| `removeDeprecatedSucker(uint256 projectId, address sucker)` | Remove a fully deprecated sucker from a project's inventory. |
| `allowSuckerDeployer(address deployer)` / `allowSuckerDeployers(address[] calldata deployers)` | Add deployer(s) to the allowlist. Owner-only. |
| `removeSuckerDeployer(address deployer)` | Remove a deployer from the allowlist. Owner-only. |
| `allowTokenMapping(address localToken, uint256 remoteChainId, bytes32 remoteToken)` / `allowTokenMappings(address[] calldata localTokens, uint256[] calldata remoteChainIds, bytes32[] calldata remoteTokens)` | Add route-scoped approvals for native/native or different-address local/remote token mappings. Owner-only. |
| `removeTokenMapping(address localToken, uint256 remoteChainId, bytes32 remoteToken)` / `removeTokenMappings(address[] calldata localTokens, uint256[] calldata remoteChainIds, bytes32[] calldata remoteTokens)` | Remove route-scoped token-mapping approvals. Owner-only. |
| `requireTokenMappingAllowed(address localToken, uint256 remoteChainId, bytes32 remoteToken)` | Revert unless the mapping can be chosen. Disabled mappings and non-native same-address mappings pass directly; native/native and different-address mappings require route approval. |
| `tokenMappingIsAllowed(address localToken, uint256 remoteChainId, bytes32 remoteToken)` | Stored owner approval for an owner-gated token route. |
| `setToRemoteFee(uint256 fee)` | Set the ETH fee (wei) paid into the fee project on each `toRemote` call. Reverts if `fee > MAX_TO_REMOTE_FEE`. Owner-only. |
| `suckersOf(uint256 projectId)` | All active suckers for a project. |
| `allSuckersOf(uint256 projectId)` | Every sucker ever registered for a project, including deprecated ones. |
| `suckerPairsOf(uint256 projectId)` | The local/remote sucker pairs (`JBSuckersPair[]`) for a project. |
| `isSuckerOf(uint256 projectId, address addr)` | Whether `addr` is a registry-deployed sucker for the project. |
| `suckerDeployerIsAllowed(address deployer)` | Whether a deployer is on the allowlist. |
| `peerChainAccountsOf(uint256 projectId, uint256 exceptChainId)` | The freshest accounting record per source chain across all of a project's suckers, deduped and minus `exceptChainId` — the peer set a sucker forwards when re-gossiping. |
| `remoteTotalSupplyOf(uint256 projectId)` | Combined peer-chain total supply across all remote chains (aggregates every (sucker, chain) pair, deduped per source chain by freshest record). |
| `totalRemoteSurplusOf(uint256 projectId, uint256 currency, uint256 decimals)` | Combined peer-chain surplus valued into `currency`. Matching-currency contexts taken at par; a missing cross-currency feed skips that (sucker, chain) (conservative). |
| `totalRemoteBalanceOf(uint256 projectId, uint256 currency, uint256 decimals)` | Combined peer-chain balance valued into `currency`, same valuation rules as above. |
| `toRemoteFee()` / `MAX_TO_REMOTE_FEE()` | The current `toRemote` fee and its hardcoded ceiling. |
