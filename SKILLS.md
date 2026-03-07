# nana-suckers-v6

## Purpose

Cross-chain token and fund bridging for Juicebox V6 projects, using merkle trees to batch claims and chain-specific bridges (Chainlink CCIP, OP Stack, Arbitrum) to move assets.

## Contracts

| Contract | Role |
|----------|------|
| `JBSucker` | Abstract base with full lifecycle: prepare, toRemote, fromRemote, claim, emergency hatch, deprecation. Manages outbox/inbox merkle trees per terminal token. |
| `JBCCIPSucker` | CCIP bridge implementation. Implements `IAny2EVMMessageReceiver.ccipReceive`. Wraps/unwraps native tokens for CCIP transport. |
| `JBOptimismSucker` | OP Stack bridge implementation. Uses `IOPMessenger.sendMessage` and `IOPStandardBridge.bridgeERC20To`. |
| `JBBaseSucker` | Extends `JBOptimismSucker` with Base<->Ethereum chain ID mapping. |
| `JBArbitrumSucker` | Arbitrum bridge implementation. Uses retryable tickets (`unsafeCreateRetryableTicket`) for L1->L2, `ArbSys.sendTxToL1` for L2->L1. Handles L1/L2 address aliasing. |
| `JBSuckerRegistry` | Entry point for deploying and tracking suckers. Manages deployer allowlist. Requires `DEPLOY_SUCKERS` permission. |
| `JBSuckerDeployer` | Abstract deployer base. Uses Solady `LibClone.cloneDeterministic` to deploy suckers as minimal proxies. |
| `JBCCIPSuckerDeployer` | CCIP-specific deployer. Stores `ccipRouter`, `ccipRemoteChainId`, `ccipRemoteChainSelector`. |
| `JBOptimismSuckerDeployer` | OP-specific deployer. Stores `opMessenger`, `opBridge`. |
| `JBBaseSuckerDeployer` | Thin wrapper around `JBOptimismSuckerDeployer` for separate Base artifact. |
| `JBArbitrumSuckerDeployer` | Arbitrum-specific deployer. Stores `arbInbox`, `arbGatewayRouter`, `arbLayer`. |
| `MerkleLib` | Incremental merkle tree (depth 32). `insert` appends leaves, `root` computes current root, `branchRoot` verifies proofs. |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `prepare(projectTokenCount, beneficiary, minTokensReclaimed, token)` | `JBSucker` | Transfers project tokens from caller, cashes them out for terminal tokens, inserts a leaf into the outbox merkle tree. |
| `toRemote(token)` | `JBSucker` | Sends the outbox merkle root and accumulated funds for `token` to the peer sucker on the remote chain via the bridge. |
| `fromRemote(root)` | `JBSucker` | Receives a merkle root from the remote peer. Updates the inbox tree. Only callable by the verified remote peer. |
| `claim(claimData)` | `JBSucker` | Verifies a merkle proof against the inbox tree, mints project tokens for the beneficiary, and optionally adds terminal tokens to the project's balance. |
| `claim(claims[])` | `JBSucker` | Batch version of `claim`. |
| `mapToken(map)` | `JBSucker` | Maps a local terminal token to a remote token. Requires `MAP_SUCKER_TOKEN` permission. Setting `remoteToken` to `address(0)` disables bridging and sends remaining outbox. |
| `mapTokens(maps[])` | `JBSucker` | Batch version of `mapToken`. |
| `addOutstandingAmountToBalance(token)` | `JBSucker` | Manually adds received terminal tokens to the project's balance (only when `ADD_TO_BALANCE_MODE == MANUAL`). |
| `enableEmergencyHatchFor(tokens)` | `JBSucker` | Opens emergency hatch for specified tokens (irreversible). Requires `SUCKER_SAFETY` permission. |
| `exitThroughEmergencyHatch(claimData)` | `JBSucker` | Lets users reclaim tokens on the chain they deposited, using their outbox proof. Only works when emergency hatch is open or sucker is deprecated. |
| `setDeprecation(timestamp)` | `JBSucker` | Sets when the sucker becomes fully deprecated. Must be at least `_maxMessagingDelay()` (14 days) in the future. Requires `SUCKER_SAFETY` permission. |
| `ccipReceive(any2EvmMessage)` | `JBCCIPSucker` | CCIP entry point. Validates router + peer + chain selector, unwraps native tokens if needed, calls `fromRemote`. |
| `deploySuckersFor(projectId, salt, configurations)` | `JBSuckerRegistry` | Deploys one or more suckers for a project. Requires `DEPLOY_SUCKERS` permission. Salt must match on both chains for peer pairing. |
| `allowSuckerDeployer(deployer)` | `JBSuckerRegistry` | Adds a deployer to the allowlist. Owner-only. |
| `removeDeprecatedSucker(projectId, sucker)` | `JBSuckerRegistry` | Removes a deprecated sucker from the registry. Callable by anyone. |
| `createForSender(localProjectId, salt)` | `JBSuckerDeployer` | Clones the singleton sucker deterministically and initializes it with the project ID. |
| `setChainSpecificConstants(...)` | Deployers | One-time configuration of bridge-specific addresses. Callable only by `LAYER_SPECIFIC_CONFIGURATOR`. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `@bananapus/core-v6` | `IJBDirectory`, `IJBController`, `IJBTokens`, `IJBTerminal`, `IJBCashOutTerminal`, `IJBPayoutTerminal` | Project lookup, token minting/burning, cash-outs, `addToBalanceOf` |
| `@bananapus/core-v6` | `JBConstants` | `NATIVE_TOKEN` sentinel address |
| `@bananapus/permission-ids-v6` | `JBPermissionIds` | `MAP_SUCKER_TOKEN`, `DEPLOY_SUCKERS`, `SUCKER_SAFETY`, `MINT_TOKENS` permission IDs |
| `@chainlink/contracts-ccip` | `Client`, `IAny2EVMMessageReceiver` | CCIP message encoding/decoding, receiver interface |
| `@arbitrum/nitro-contracts` | `IInbox`, `IOutbox`, `IBridge`, `ArbSys`, `AddressAliasHelper` | Arbitrum retryable tickets, L2->L1 messages, address aliasing |
| `@openzeppelin/contracts` | `SafeERC20`, `BitMaps`, `ERC165`, `Initializable`, `Ownable`, `ERC2771Context`, `EnumerableMap` | Token safety, leaf tracking, clone init, registry ownership, meta-transactions |
| `solady` | `LibClone` | Deterministic minimal proxy deployment |
| `@prb/math` | `mulDiv` | Safe fixed-point multiplication |

## Key Types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `JBClaim` | `token`, `leaf` (`JBLeaf`), `proof` (`bytes32[32]`) | `claim`, `exitThroughEmergencyHatch` |
| `JBLeaf` | `index`, `beneficiary`, `projectTokenCount`, `terminalTokenAmount` | Merkle tree leaves (outbox/inbox) |
| `JBOutboxTree` | `nonce` (uint64), `balance`, `tree` (MerkleLib.Tree), `numberOfClaimsSent` | Per-token outbox state in `JBSucker` |
| `JBInboxTreeRoot` | `nonce` (uint64), `root` (bytes32) | Per-token inbox state in `JBSucker` |
| `JBMessageRoot` | `token`, `amount`, `remoteRoot` (`JBInboxTreeRoot`) | Cross-chain message payload |
| `JBRemoteToken` | `enabled`, `emergencyHatch`, `minGas` (uint32), `addr`, `minBridgeAmount` | Token mapping config |
| `JBTokenMapping` | `localToken`, `minGas` (uint32), `remoteToken`, `minBridgeAmount` | Input for `mapToken`/`mapTokens` |
| `JBSuckerDeployerConfig` | `deployer` (`IJBSuckerDeployer`), `mappings` (`JBTokenMapping[]`) | Input for `deploySuckersFor` |
| `JBSuckersPair` | `local`, `remote`, `remoteChainId` | Return type for `suckerPairsOf` |
| `JBAddToBalanceMode` | `MANUAL`, `ON_CLAIM` | Controls when received funds are added to project balance |
| `JBSuckerState` | `ENABLED`, `DEPRECATION_PENDING`, `SENDING_DISABLED`, `DEPRECATED` | Deprecation lifecycle |
| `JBLayer` | `L1`, `L2` | Arbitrum sucker layer identification |

## Gotchas

- `using MerkleLib for MerkleLib.Tree` is NOT inherited by derived contracts -- must redeclare in test harnesses.
- Suckers are deployed as minimal clones (`LibClone.cloneDeterministic`). The singleton's constructor calls `_disableInitializers()` so it cannot be initialized directly. Only clones can be initialized.
- For suckers to be peers, the same `salt` AND the same caller address must be used on both chains when calling `deploySuckersFor`. The registry hashes `keccak256(abi.encode(msg.sender, salt))`.
- `peer()` defaults to `address(this)` -- suckers expect to be deployed at matching addresses on both chains via deterministic deployment.
- `fromRemote` is `external payable` and does NOT revert on stale nonce or deprecated state -- it silently ignores the update to avoid losing native tokens sent along with the message.
- `JBCCIPSucker.ccipReceive` calls `this.fromRemote(root)` (external self-call) so that `_isRemotePeer` sees `msg.sender == address(this)` rather than the CCIP router.
- `_validateTokenMapping` in `JBSucker` enforces that native token (`NATIVE_TOKEN`) can only map to `NATIVE_TOKEN` or `address(0)`. `JBCCIPSucker` overrides this to relax the native token constraint (remote chain may not have native ETH).
- Emergency hatch is irreversible per-token. Once opened, the token can never be bridged again by that sucker.
- `setDeprecation` requires the timestamp to be at least `_maxMessagingDelay()` (14 days) in the future. This ensures in-flight messages arrive before the sucker stops accepting them.
- Deployer `setChainSpecificConstants` and `configureSingleton` are both one-shot functions -- they revert if called twice.
- `MESSENGER_BASE_GAS_LIMIT` is 300,000. `MESSENGER_ERC20_MIN_GAS_LIMIT` is 200,000. Token mappings must specify `minGas >= 200,000` for ERC-20s.
- `JBArbitrumSucker` uses `unsafeCreateRetryableTicket` (not `safeCreateRetryableTicket`) to avoid L2 address aliasing of the refund address.
- The outbox tree tracks `numberOfClaimsSent` separately from `tree.count`. Emergency hatch exit is only available for leaves whose index is `>= numberOfClaimsSent` (not yet sent to remote).

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
    remoteToken: WETH_CELO,  // 0xD221812de1BD094f35587EE8E174B07B6167D9Af
    minGas: 200_000,
    minBridgeAmount: 0.01 ether
})
```

**Wrong token mapping on Celo:**
```solidity
// NATIVE_TOKEN on Ethereum is ETH, but on Celo it's CELO!
JBTokenMapping({
    localToken: JBConstants.NATIVE_TOKEN,
    remoteToken: JBConstants.NATIVE_TOKEN,  // WRONG on non-ETH chains
    minGas: 200_000,
    minBridgeAmount: 0.01 ether
})
```

See also: `SECURITY.md` in this repo and INTEROP-6 in `AUDIT_FINDINGS.md`.

## Example Integration

```solidity
// Deploy suckers for project 12 using CCIP to bridge ETH between Ethereum and Optimism
JBTokenMapping[] memory mappings = new JBTokenMapping[](1);
mappings[0] = JBTokenMapping({
    localToken: JBConstants.NATIVE_TOKEN,
    minGas: 200_000,
    remoteToken: JBConstants.NATIVE_TOKEN,
    minBridgeAmount: 0.025 ether
});

JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](1);
configs[0] = JBSuckerDeployerConfig({
    deployer: IJBSuckerDeployer(ccipSuckerDeployerAddress),
    mappings: mappings
});

// Must use the same salt and caller on both chains
bytes32 salt = keccak256("my-project-suckers-v1");
address[] memory suckers = registry.deploySuckersFor(12, salt, configs);

// Grant the sucker MINT_TOKENS permission so it can mint on claim
uint256[] memory permissionIds = new uint256[](1);
permissionIds[0] = JBPermissionIds.MINT_TOKENS;
permissions.setPermissionsFor(
    projectOwner,
    JBPermissionsData({
        operator: suckers[0],
        projectId: 12,
        permissionIds: permissionIds
    })
);
```
