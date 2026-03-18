# nana-suckers-v6 — Architecture

## Purpose

Cross-chain token bridging for Juicebox V6. Allows project tokens and funds to move between EVM chains via Optimism, Arbitrum, and Chainlink CCIP bridges. Uses dual merkle trees (outbox/inbox) for claim verification.

## Contract Map

```
src/
├── JBSucker.sol            — Abstract base: merkle tree management, prepare/claim logic, FEE_PROJECT_ID, admin-adjustable toRemoteFee (Ownable)
├── JBBaseSucker.sol        — OP Stack base (Optimism, Base)
├── JBOptimismSucker.sol    — Optimism/Base bridge implementation
├── JBArbitrumSucker.sol    — Arbitrum bridge implementation
├── JBCCIPSucker.sol        — Chainlink CCIP bridge implementation
├── JBSuckerRegistry.sol    — Registry of suckers per project, deployment permissions
├── deployers/
│   ├── JBOptimismSuckerDeployer.sol
│   ├── JBArbitrumSuckerDeployer.sol
│   └── JBCCIPSuckerDeployer.sol
├── enums/
│   └── JBSuckerState.sol   — ENABLED → DEPRECATION_PENDING → SENDING_DISABLED → DEPRECATED
├── libraries/
│   ├── JBAddressBytes.sol  — Address/bytes32 conversion
│   └── MerkleLib.sol       — Merkle tree operations
└── structs/                — Token mappings, sucker pairs, claims
```

## Key Data Flows

### Outbound (Prepare + Bridge)
```
User → JBSucker.prepare()
  → Cash out project tokens (0% tax via sucker privilege)
  → Insert {beneficiary, token, amount} into outbox merkle tree
  → When tree is full or manually triggered:
    → Bridge tokens via OP/Arb/CCIP messenger
    → Send merkle root to remote sucker
```

### Inbound (Claim)
```
Remote root arrives → stored in inbox tree
User → JBSucker.claim(proof)
  → Verify merkle proof against inbox root
  → Check leaf not already claimed (bitmap)
  → Mint project tokens to beneficiary (or transfer bridged tokens)
  → Mark leaf as executed
```

### Deprecation Lifecycle
```
ENABLED → DEPRECATION_PENDING → SENDING_DISABLED → DEPRECATED
  (owner)    (pending period)     (no new outbox)    (fully disabled)
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Bridge transport | Chain-specific sucker | OP, Arb, CCIP implementations |
| Sucker deployer | `IJBSuckerDeployer` | Factory for new suckers |
| Registry | `IJBSuckerRegistry` | Discovery and access control |

## Dependencies
- `@bananapus/core-v6` — Terminal, controller, token interfaces
- `@bananapus/permission-ids-v6` — DEPLOY_SUCKERS, MAP_SUCKER_TOKEN, etc.
- `@arbitrum/nitro-contracts` — Arbitrum bridge interfaces
- `@chainlink/contracts-ccip` — CCIP router interfaces
- `@openzeppelin/contracts` — MerkleProof, SafeERC20
- `solady` — LibBitmap
