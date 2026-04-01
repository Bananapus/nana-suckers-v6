# Administration

Admin privileges and their scope in nana-suckers-v6.

## Roles

### Registry Owner

- **How assigned:** Set at `JBSuckerRegistry` construction via the `initialOwner` parameter. Transferable via OpenZeppelin `Ownable`.
- **Scope:** Controls which sucker deployer contracts are approved for use by the registry, and sets the global `toRemoteFee` applied to all suckers. Initially expected to be JuiceboxDAO (project ID 1).
- **Permission ID:** None (uses `onlyOwner` modifier from OpenZeppelin `Ownable`).

### Project Owner

- **How assigned:** Owner of the ERC-721 project NFT in `JBProjects`. All project-scoped permissions are checked against `PROJECTS.ownerOf(projectId)` or `DIRECTORY.PROJECTS().ownerOf(projectId)`.
- **Scope:** Controls sucker deployment, token mapping, deprecation, and emergency hatch for their project. Can delegate any of these permissions to other addresses via `JBPermissions`.
- **Permission ID:** N/A (is the root authority that grants the permission IDs below).

### Sucker Deployer (delegated role)

- **How assigned:** Granted `DEPLOY_SUCKERS` permission by the project owner via `JBPermissions`.
- **Scope:** Can deploy new suckers for a specific project through the registry.
- **Permission ID:** `JBPermissionIds.DEPLOY_SUCKERS`

### Token Mapper (delegated role)

- **How assigned:** Granted `MAP_SUCKER_TOKEN` permission by the project owner via `JBPermissions`. Commonly granted to the `JBSuckerRegistry` address so it can call `mapTokens` during deployment.
- **Scope:** Can map or disable local-to-remote token pairs on a specific sucker.
- **Permission ID:** `JBPermissionIds.MAP_SUCKER_TOKEN`

For existing-project deployments, this permission is part of the same operational path as `DEPLOY_SUCKERS`: the registry deploys the sucker and then immediately calls `mapTokens` on it. If the project delegates deployment without arranging mapping authority for the registry, the single deployment transaction will revert during configuration.

### Safety Admin (delegated role)

- **How assigned:** Granted `SUCKER_SAFETY` permission by the project owner via `JBPermissions`.
- **Scope:** Can open the emergency hatch for specific tokens on a sucker. This is an irreversible action.
- **Permission ID:** `JBPermissionIds.SUCKER_SAFETY`

### Deprecation Admin (delegated role)

- **How assigned:** Granted `SET_SUCKER_DEPRECATION` permission by the project owner via `JBPermissions`.
- **Scope:** Can set or cancel the deprecation timestamp on a sucker.
- **Permission ID:** `JBPermissionIds.SET_SUCKER_DEPRECATION`

### Layer-Specific Configurator

- **How assigned:** Set at deployer construction via the `configurator` parameter. Stored as the immutable `LAYER_SPECIFIC_CONFIGURATOR` address on each `JBSuckerDeployer`.
- **Scope:** Can call `setChainSpecificConstants` and `configureSingleton` exactly once each on the deployer. These are one-time setup functions that configure bridge-specific addresses (messenger, bridge, router, inbox) and the singleton implementation used for cloning.
- **Permission ID:** None (uses direct `_msgSender()` check against `LAYER_SPECIFIC_CONFIGURATOR`).

## Privileged Functions

### JBSuckerRegistry

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|--------------|
| `allowSuckerDeployer(deployer)` | Registry Owner | N/A (`onlyOwner`) | Global | Adds a deployer contract to the allowlist, enabling it to be used when deploying suckers. |
| `allowSuckerDeployers(deployers)` | Registry Owner | N/A (`onlyOwner`) | Global | Batch version: adds multiple deployer contracts to the allowlist. |
| `removeSuckerDeployer(deployer)` | Registry Owner | N/A (`onlyOwner`) | Global | Removes a deployer contract from the allowlist, preventing future sucker deployments through it. |
| `setToRemoteFee(fee)` | Registry Owner | N/A (`onlyOwner`) | Global | Sets the `toRemoteFee` applied to all suckers. The fee must be <= `MAX_TO_REMOTE_FEE` (0.001 ether). Emits `ToRemoteFeeChanged`. |
| `deploySuckersFor(projectId, salt, configs)` | Project Owner | `DEPLOY_SUCKERS` | Per-project | Deploys one or more suckers for a project using allowlisted deployers. Hashes salt with `_msgSender()` (which equals `msg.sender` for direct calls, or the relayed sender for ERC-2771 meta-transactions) for deterministic cross-chain addresses. Also calls `mapTokens` on each newly created sucker, so the registry must be able to satisfy the corresponding `MAP_SUCKER_TOKEN` checks for the project. |
| `removeDeprecatedSucker(projectId, sucker)` | Anyone | None | Per-project | Removes a fully `DEPRECATED` sucker from the registry. Permissionless but only succeeds if the sucker is in the `DEPRECATED` state. |

### JBSucker

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|--------------|
| `mapToken(map)` | Project Owner | `MAP_SUCKER_TOKEN` | Per-sucker | Maps a local terminal token to a remote token, enabling bridging. Setting `remoteToken` to `bytes32(0)` disables bridging and sends a final root to flush remaining outbox entries. |
| `mapTokens(maps)` | Project Owner | `MAP_SUCKER_TOKEN` | Per-sucker | Batch version: maps multiple local-to-remote token pairs. Each mapping requires the same permission. |
| `enableEmergencyHatchFor(tokens)` | Project Owner | `SUCKER_SAFETY` | Per-sucker | Opens the emergency hatch for specified tokens (irreversible). Sets `emergencyHatch = true` and `enabled = false` on each token's remote mapping. Allows users to exit through the outbox on the chain they deposited on. |
| `setDeprecation(timestamp)` | Project Owner | `SET_SUCKER_DEPRECATION` | Per-sucker | Sets the timestamp after which the sucker becomes fully deprecated. Must be at least `_maxMessagingDelay()` (14 days) in the future. Set to `0` to cancel a pending deprecation. Reverts if already in `SENDING_DISABLED` or `DEPRECATED` state. |

### JBSuckerDeployer (base and all subclasses)

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|--------------|
| `configureSingleton(singleton)` | Layer-Specific Configurator | N/A (direct address check) | Per-deployer | Sets the singleton implementation contract used to clone suckers via `LibClone`. Can only be called once. |
| `setChainSpecificConstants(...)` | Layer-Specific Configurator | N/A (direct address check) | Per-deployer | Configures bridge-specific addresses (messenger, bridge, router, inbox, etc.) for the deployer. Can only be called once. Parameters vary by bridge type. |

## Deprecation Lifecycle

The sucker deprecation lifecycle progresses through four states, controlled by `setDeprecation(timestamp)`:

```
ENABLED --> DEPRECATION_PENDING --> SENDING_DISABLED --> DEPRECATED
```

| State | Condition | Behavior |
|-------|-----------|----------|
| `ENABLED` | `deprecatedAfter == 0` | Fully functional. No deprecation is set. |
| `DEPRECATION_PENDING` | `block.timestamp < deprecatedAfter - _maxMessagingDelay()` | Fully functional but a warning to users that deprecation is coming. |
| `SENDING_DISABLED` | `block.timestamp < deprecatedAfter` (but past the messaging delay window) | `prepare()` and `toRemote()` revert. No new outbox entries or root sends. Incoming roots from the remote peer are still accepted. Users can `claim()` incoming tokens and `exitThroughEmergencyHatch()`. |
| `DEPRECATED` | `block.timestamp >= deprecatedAfter` | Fully shut down. No new inbox roots are accepted (`fromRemote` skips the update). Users can still `claim()` against previously accepted inbox roots and `exitThroughEmergencyHatch()` against outbox entries that were never sent. |

**Who controls transitions:**
- The project owner (or holder of `SET_SUCKER_DEPRECATION` permission) sets the `deprecatedAfter` timestamp via `setDeprecation(timestamp)`.
- The timestamp must be at least `_maxMessagingDelay()` (14 days) in the future to allow in-flight messages to arrive.
- A pending deprecation can be cancelled by calling `setDeprecation(0)`, but only while in `ENABLED` or `DEPRECATION_PENDING` state.
- Once `SENDING_DISABLED` or `DEPRECATED`, the deprecation cannot be reversed.

**Removing from registry:** Once a sucker reaches `DEPRECATED`, anyone can call `JBSuckerRegistry.removeDeprecatedSucker(projectId, sucker)` to remove it from the project's sucker list.

## Emergency Hatch

The emergency hatch is a per-token escape mechanism for when a bridge becomes non-functional for specific tokens.

**Activation:** The project owner (or holder of `SUCKER_SAFETY` permission) calls `enableEmergencyHatchFor(tokens)` on the sucker. This is irreversible -- once opened for a token, that token can never be bridged by this sucker again.

**Effect:** Sets `emergencyHatch = true` and `enabled = false` on each specified token's `JBRemoteToken` mapping. This:
- Prevents new `prepare()` calls for the token (the token is no longer mapped/enabled).
- Prevents `toRemote()` calls for the token (reverts with `JBSucker_TokenHasInvalidEmergencyHatchState`).
- Prevents `mapToken()` from remapping or re-enabling the token (reverts with `JBSucker_TokenHasInvalidEmergencyHatchState`).
- Enables `exitThroughEmergencyHatch()` for users whose outbox entries were never sent to the remote peer (entries with `index >= numberOfClaimsSent`).

**Who can exit:** Any user with a valid outbox merkle proof for a leaf that was never sent over the bridge. The exit mints project tokens to the beneficiary and returns the terminal tokens to the project's terminal balance. The beneficiary can then cash out the minted project tokens through the normal Juicebox mechanism if desired.

**Safety constraint:** Only leaves that were never communicated to the remote peer (i.e., `index >= outbox.numberOfClaimsSent`) can be emergency-exited. Leaves already sent over the bridge (index < `numberOfClaimsSent`) cannot be emergency-exited because they may have already been claimed on the remote chain.

## Immutable Configuration

The following values are set at deploy time and cannot be changed:

| Property | Contract | Set By | Description |
|----------|----------|--------|-------------|
| `DIRECTORY` | `JBSucker`, `JBSuckerRegistry`, all deployers | Constructor | The Juicebox directory contract. |
| `FEE_PROJECT_ID` | `JBSucker` | Constructor | The project that receives `toRemoteFee` payments via `terminal.pay()` on each `toRemote()` call. Typically project ID 1 (the protocol project). Best-effort: fee is silently skipped if the fee project has no native token terminal or if `terminal.pay()` reverts. |
| `REGISTRY` | `JBSucker` | Constructor | The `JBSuckerRegistry` that this sucker reads the `toRemoteFee` from. |
| `MAX_TO_REMOTE_FEE` | `JBSuckerRegistry` | Constant | Hard cap on what `toRemoteFee` can be set to (0.001 ether). Prevents the registry owner from setting an excessively high fee. |
| `TOKENS` | `JBSucker`, all deployers | Constructor | The Juicebox token management contract. |
| `PROJECTS` | `JBSuckerRegistry` | Derived from `DIRECTORY.PROJECTS()` | The ERC-721 project ownership contract. |
| `OPBRIDGE` | `JBOptimismSucker`, `JBBaseSucker`, `JBCeloSucker` | Constructor (from deployer callback) | The OP Standard Bridge address. |
| `OPMESSENGER` | `JBOptimismSucker`, `JBBaseSucker`, `JBCeloSucker` | Constructor (from deployer callback) | The OP Cross-Domain Messenger address. |
| `ARBINBOX` | `JBArbitrumSucker` | Constructor (from deployer callback) | The Arbitrum Inbox address. |
| `GATEWAYROUTER` | `JBArbitrumSucker` | Constructor (from deployer callback) | The Arbitrum Gateway Router address. |
| `LAYER` | `JBArbitrumSucker` | Constructor (from deployer callback) | Whether this is an L1 or L2 sucker. |
| `CCIP_ROUTER` | `JBCCIPSucker` | Constructor (from deployer callback) | The Chainlink CCIP Router address. |
| `REMOTE_CHAIN_ID` | `JBCCIPSucker` | Constructor (from deployer callback) | The remote chain's chain ID. |
| `REMOTE_CHAIN_SELECTOR` | `JBCCIPSucker` | Constructor (from deployer callback) | The CCIP chain selector for the remote chain. |
| `WRAPPED_NATIVE` | `JBCeloSucker` | Constructor (from deployer callback) | The wrapped native token (WETH) on the local chain. |
| `LAYER_SPECIFIC_CONFIGURATOR` | All deployers | Constructor | The address authorized to call one-time setup functions. |
| `peer()` | `JBSucker` | Deterministic (returns `bytes32` via `_toBytes32(address(this))`) | The remote peer sucker address as `bytes32`. Defaults to the local address, relying on CREATE2 giving the same address on both chains. |
| `deployer` | `JBSucker` | Set once in `initialize()` by `msg.sender` | The address that deployed this sucker clone (the deployer contract). |
| `projectId()` | `JBSucker` | Set once in `initialize()` | The local project ID this sucker serves. |
| Bridge/messenger/router addresses | All deployers | `setChainSpecificConstants()` (one-time) | Bridge infrastructure addresses, set once by the configurator. |
| Singleton implementation | All deployers | `configureSingleton()` (one-time) | The singleton contract used as the clone template. |

## Admin Boundaries

What admins **cannot** do:

- **Cannot remap tokens after outbox activity.** Once a token has outbox tree entries (`_outboxOf[token].tree.count != 0`), it cannot be remapped to a different remote token. It can only be disabled (set to `bytes32(0)`) or re-enabled to the same remote address. This prevents double-spending across two different remote tokens.

- **Cannot reverse an emergency hatch.** Once `enableEmergencyHatchFor` is called for a token, `emergencyHatch` is permanently `true`. The token can never be re-enabled for bridging on this sucker. A new sucker must be deployed if bridging needs to resume.

- **Cannot reverse deprecation past `SENDING_DISABLED`.** Once the sucker enters `SENDING_DISABLED` or `DEPRECATED` state, `setDeprecation()` reverts. The deprecation cannot be cancelled.

- **Cannot bypass bridge security.** Cross-chain message authentication is enforced by each bridge implementation's `_isRemotePeer()` check. The project owner has no way to override this -- only messages from the legitimate remote peer (verified by the OP Messenger, Arbitrum Bridge/Outbox, or CCIP Router) are accepted by `fromRemote()`.

- **Cannot reconfigure deployers.** `setChainSpecificConstants()` and `configureSingleton()` can each only be called once per deployer. Bridge addresses and the singleton implementation are permanent after initial configuration.

- **Cannot steal user funds via emergency hatch.** Emergency exit only returns tokens to the original beneficiary specified in the outbox merkle tree, and only for leaves that were never sent over the bridge (index >= `numberOfClaimsSent`). Leaves already bridged cannot be double-claimed.

- **Cannot claim on behalf of others.** While `claim()` and `exitThroughEmergencyHatch()` are permissionless (anyone can call them), the project tokens are always minted to the beneficiary encoded in the merkle tree leaf, not to the caller.

- **Cannot change the peer address.** The peer is determined by deterministic deployment (CREATE2 with sender-specific salt). There is no admin function to change which remote address is trusted.

- **Cannot change the project ID.** The `projectId` is set once during `initialize()` and is immutable thereafter (enforced by OpenZeppelin `Initializable`).

- **Cannot change the fee project.** `FEE_PROJECT_ID` is set at construction and is immutable. If the fee project's terminal changes or is removed, fee payments silently stop (best-effort design), but `toRemote()` still works.

- **Can adjust the fee amount, within bounds.** The registry owner can call `setToRemoteFee()` on `JBSuckerRegistry` to adjust the fee globally for all suckers, but it is capped at `MAX_TO_REMOTE_FEE` (0.001 ether).

## Bridge Infrastructure Risks

Sucker security ultimately depends on the underlying bridge infrastructure (OP Cross-Domain Messenger, Arbitrum Inbox/Outbox, CCIP Router). Each sucker's `_isRemotePeer()` check trusts these bridges to faithfully report the sender of cross-chain messages. If a bridge itself is compromised, an attacker could forge messages that pass the peer check, potentially minting unbacked project tokens on the destination chain.

**Mitigations available to project owners:**

- **Emergency hatch.** If a bridge is suspected to be compromised for a specific token, the project owner (or `SUCKER_SAFETY` delegate) can call `enableEmergencyHatchFor()` to immediately disable bridging for that token and allow users to exit with their outbox entries locally.
- **Deprecation.** If the bridge is broadly compromised, the project owner (or `SET_SUCKER_DEPRECATION` delegate) can deprecate the entire sucker via `setDeprecation()`, shutting down all new outbound and eventually inbound activity.

**Fee delivery is best-effort.** The `toRemoteFee` is collected by calling `terminal.pay()` to the fee project during `toRemote()`. If this call reverts (e.g., the fee project has no native token terminal or its terminal is misconfigured), the fee is silently skipped and `toRemote()` proceeds normally. This ensures bridging availability is never blocked by fee infrastructure issues, but it also means fee revenue can be lost without any on-chain signal.
