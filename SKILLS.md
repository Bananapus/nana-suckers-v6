# Juicebox Suckers

## Use this file for

- Use this file when the task involves cross-chain project-token movement, Merkle-root progression, token mapping, or emergency and deprecation flows.
- Start here, then decide whether the issue is in shared sucker logic or in a bridge-specific transport implementation.

## Read this next

| If you need... | Open this next |
|---|---|
| Repo overview and architecture | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Shared bridge logic | [`src/JBSucker.sol`](./src/JBSucker.sol), [`src/JBSuckerRegistry.sol`](./src/JBSuckerRegistry.sol) |
| Merkle logic | [`src/utils/MerkleLib.sol`](./src/utils/MerkleLib.sol) |
| Bridge-specific behavior | the matching implementation and deployer under [`src/`](./src/) and [`src/deployers/`](./src/deployers/) |

## Purpose

Canonical cross-chain movement layer for Juicebox project positions.

## Working rules

- Start in `JBSucker` for shared lifecycle logic.
- Separate Merkle bookkeeping from bridge-specific transport assumptions.
- Treat token mapping, deprecation, and emergency hatch behavior as core safety surfaces.
- Treat the multi-chain accounting gossip as a first-class surface, distinct from Merkle/claim flow. Each sucker keeps a per-source-chain store, and both `toRemote` (root) and `syncAccountingData` carry a gossip bundle of per-chain records (`JBChainAccounting[]`). Every record is gated independently per source chain on a strictly-newer freshness key in `JBSucker._storeChainAccounting`; records for `block.chainid` and chain 0 are dropped. When reasoning about a chain's stored surplus/balance, walk the per-chain freshness merge, not a single scalar snapshot.
- Remember the send path is registry-mediated: `JBSuckerRegistry.peerChainAccountsOf` is the only place a hub chain's per-peer suckers are visible together, so a hub gathers sibling-sucker records and forwards them — letting accounting reach spokes that have no direct sucker to each other. Currency is resolved at read time in `JBSuckerLib.foldPeerContexts` (no cache), per source chain.
