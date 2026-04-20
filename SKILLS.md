# Juicebox Suckers

## Use This File For

- Use this file when the task involves cross-chain project-token movement, Merkle-root progression, token mapping, or emergency and deprecation flows.
- Start here, then decide whether the issue is in shared sucker logic or in a bridge-specific transport implementation.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and architecture | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Shared bridge logic | [`src/JBSucker.sol`](./src/JBSucker.sol), [`src/JBSuckerRegistry.sol`](./src/JBSuckerRegistry.sol) |
| Merkle logic | [`src/utils/MerkleLib.sol`](./src/utils/MerkleLib.sol) |
| Bridge-specific behavior | the matching implementation and deployer under [`src/`](./src/) and [`src/deployers/`](./src/deployers/) |

## Purpose

Canonical cross-chain movement layer for Juicebox project positions.

## Working Rules

- Start in `JBSucker` for shared lifecycle logic.
- Separate Merkle bookkeeping from bridge-specific transport assumptions.
- Treat token mapping, deprecation, and emergency hatch behavior as core safety surfaces.
