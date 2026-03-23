# nana-suckers-v6 — Architecture

## Purpose

Cross-chain token bridging for Juicebox V6. Allows project tokens and funds to move between EVM chains via Optimism, Base, Celo (OP Stack), Arbitrum, and Chainlink CCIP bridges. Uses dual merkle trees (outbox/inbox) for claim verification.

## Contract Map

```
src/
├── JBSucker.sol            — Abstract base: merkle tree management, prepare/claim logic, FEE_PROJECT_ID, reads toRemoteFee from REGISTRY (immutable IJBSuckerRegistry)
├── JBOptimismSucker.sol    — OP Stack bridge implementation (Optimism, Base, Celo)
├── JBBaseSucker.sol        — Base chain sucker (extends JBOptimismSucker, overrides peerChainId for Base ↔ Ethereum)
├── JBCeloSucker.sol        — Celo sucker (extends JBOptimismSucker, wraps ETH → WETH for bridging, custom gas token handling)
├── JBArbitrumSucker.sol    — Arbitrum bridge implementation
├── JBCCIPSucker.sol        — Chainlink CCIP bridge implementation
├── JBSuckerRegistry.sol    — Registry of suckers per project, deployment permissions, centralized toRemoteFee (owner-controlled, applies to all suckers)
├── deployers/
│   ├── JBSuckerDeployer.sol        — Abstract base deployer (LibClone, singleton pattern)
│   ├── JBOptimismSuckerDeployer.sol
│   ├── JBBaseSuckerDeployer.sol
│   ├── JBCeloSuckerDeployer.sol
│   ├── JBArbitrumSuckerDeployer.sol
│   └── JBCCIPSuckerDeployer.sol
├── enums/
│   ├── JBSuckerState.sol   — ENABLED → DEPRECATION_PENDING → SENDING_DISABLED → DEPRECATED
│   └── JBLayer.sol         — L1 / L2 indicator (used by JBArbitrumSucker)
├── interfaces/             — IJBSucker, IJBSuckerRegistry, IJBSuckerDeployer, bridge-specific interfaces (OP, Arb, CCIP)
├── libraries/
│   ├── ARBAddresses.sol    — Arbitrum precompile/contract addresses
│   ├── ARBChains.sol       — Arbitrum chain ID constants
│   └── CCIPHelper.sol      — CCIP chain selector lookups
├── structs/                — JBClaim, JBLeaf, JBTokenMapping, JBRemoteToken, JBOutboxTree, JBMessageRoot, etc.
└── utils/
    └── MerkleLib.sol       — Append-only merkle tree operations
```

## Key Data Flows

### Outbound (Prepare + Bridge)
```
User → JBSucker.prepare()
  → Cash out project tokens (0% tax via sucker privilege)
  → Insert {beneficiary, token, amount} into outbox merkle tree

User → JBSucker.toRemote{value}(token)
  → Pay toRemoteFee (ETH) to fee project via terminal.pay() — caller gets fee project tokens
  → Remaining msg.value forwarded as transport payment to the bridge
  → Send merkle root + bridged tokens to remote sucker via OP/Arb/CCIP messenger
```

The `toRemoteFee` is a global ETH fee (max 0.001 ETH) set by the registry owner via `setToRemoteFee()`. The caller must send at least `toRemoteFee` as `msg.value` (reverts otherwise). The fee is paid into `FEE_PROJECT_ID` (typically project 1) through the project's primary native-token terminal. If the `pay()` call reverts or no terminal exists, the fee is silently added to the transport payment instead (best-effort).

### Inbound (Claim)
```
Remote root arrives → stored in inbox tree
User → JBSucker.claim(proof)
  → Check leaf not already claimed (bitmap), mark as executed
  → Verify merkle proof against inbox root
  → Add bridged terminal tokens to project balance (via terminal.addToBalanceOf)
  → Mint project tokens to beneficiary (via controller.mintTokensOf)
```

### Deprecation Lifecycle
```
ENABLED → DEPRECATION_PENDING → SENDING_DISABLED → DEPRECATED
  (owner)    (pending period)     (no new outbox)    (fully disabled)
```

## Token Mapping

Token mappings link a local terminal token to a remote token address, enabling bridging for that pair. Mappings are managed via `mapToken()` / `mapTokens()` (requires `MAP_SUCKER_TOKEN` permission).

**Immutability constraint:** Once a token has outbox tree entries (`_outboxOf[token].tree.count != 0`), it cannot be remapped to a *different* remote token — it can only be disabled by mapping to `address(0)`. This prevents double-spending: if remapping were allowed after outbox activity, the same local funds could be claimed against two different remote tokens on the remote chain.

A disabled mapping can be re-enabled to the *same* remote token. A misconfigured mapping requires deploying a new sucker.

When a mapping is disabled (set to `address(0)`) and unsent leaves remain in the outbox, the sucker automatically flushes the remaining root to the remote chain to settle outstanding claims.

## Emergency Hatch

The emergency hatch allows users to reclaim their tokens on the chain they deposited on when the bridge is no longer functional.

**Who can enable it:** The project owner (or an address with the `SUCKER_SAFETY` permission) calls `enableEmergencyHatchFor(address[] tokens)`.

**What it does:** Sets `emergencyHatch = true` and `enabled = false` for each token's remote mapping. This is irreversible — once the emergency hatch is enabled for a token, it cannot be disabled or remapped.

**How users exit:** Users call `exitThroughEmergencyHatch(JBClaim claimData)` with a merkle proof against the *outbox* tree. The sucker validates:
1. The emergency hatch is enabled for that token (or the sucker is in `DEPRECATED` / `SENDING_DISABLED` state).
2. The leaf has not already been sent to the remote chain (`index >= numberOfClaimsSent`). Leaves whose roots were already bridged cannot be emergency-exited, since they could also be claimed remotely.
3. The leaf has not already been claimed (bitmap check).

The sucker then adds the terminal tokens back to the project's balance (via `terminal.addToBalanceOf`) and mints project tokens to the beneficiary on the local chain.

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Bridge transport | Chain-specific sucker | OP, Arb, CCIP implementations |
| Sucker deployer | `IJBSuckerDeployer` | Factory for new suckers |
| Registry | `IJBSuckerRegistry` | Discovery and access control |

## Design Decisions

**Dual merkle trees instead of direct bridging.** Each sucker maintains separate outbox and inbox merkle trees per token. Outbound transfers are batched into the outbox tree via `prepare()`, and a single `toRemote()` call bridges the root and accumulated funds together. This amortizes bridge costs across many users — only one cross-chain message per batch rather than one per transfer. The inbox tree on the receiving side lets users self-serve claims with merkle proofs at their own pace.

**Bitmap for claim tracking.** Each leaf index is tracked in an OpenZeppelin `BitMaps.BitMap` (`_executedFor`), which packs 256 booleans per storage slot. This is far cheaper than a `mapping(uint256 => bool)` for dense sequential indices, and the merkle tree's sequential leaf indices are a natural fit.

**Immutable token mappings once outbox has entries.** After a token mapping has been used (outbox tree count > 0), remapping to a different remote token is blocked. Without this, an attacker could prepare tokens mapped to token A, then remap to token B before `toRemote()` is called, allowing the same local funds to be claimed against both tokens on the remote chain. Disabling (mapping to `address(0)`) is still allowed since it flushes remaining outbox entries and stops new ones.

**`uint128` amount cap for SVM compatibility.** Both `terminalTokenAmount` and `projectTokenCount` are capped at `type(uint128).max` in `_insertIntoTree()`. This ensures the leaf data is compatible with Solana's SVM, where token amounts are `u64`/`u128`. The `bytes32` beneficiary field similarly accommodates 32-byte Solana public keys alongside 20-byte EVM addresses.

**Best-effort fee payment.** The `toRemoteFee` payment to the fee project is wrapped in a try-catch. If the fee project's terminal doesn't exist or the `pay()` call reverts, the bridge proceeds without the fee. This prevents a misconfigured or paused fee project from blocking all cross-chain transfers.

## Dependencies
- `@bananapus/core-v6` — Terminal, controller, token interfaces
- `@bananapus/permission-ids-v6` — DEPLOY_SUCKERS, MAP_SUCKER_TOKEN, etc.
- `@arbitrum/nitro-contracts` — Arbitrum bridge interfaces (IInbox, IOutbox, IBridge, ArbSys, AddressAliasHelper)
- `@chainlink/contracts-ccip` — CCIP router and message interfaces
- `@openzeppelin/contracts` — BitMaps, SafeERC20, ERC165, Initializable, ERC2771Context, Ownable, EnumerableMap
- `solady` — LibClone (deterministic clone deployment for sucker deployers)
