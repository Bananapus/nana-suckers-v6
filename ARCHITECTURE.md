# Architecture

## Purpose

`nana-suckers-v6` moves Juicebox project token value across chains. A sucker pair lets a holder burn or cash out locally, bridge the resulting terminal token plus the latest merkle root, and then claim equivalent project-token value on the remote chain.

## Boundaries

- `JBSucker` owns the chain-agnostic lifecycle.
- Chain-specific subclasses own transport details for OP Stack, Arbitrum, CCIP, and Celo variants.
- The registry and deployers own pair creation and global policy.
- Core protocol accounting still happens through project terminals on each chain.

## Main Components

| Component | Responsibility |
| --- | --- |
| `JBSucker` | Prepare, root management, claim verification, token mapping, and deprecation controls |
| chain-specific suckers | Bridge transport and token-wrapping details for each supported network family |
| `JBSuckerRegistry` | Tracks deployed suckers, allowlists deployers, and stores global bridge-fee policy |
| deployers | Clone and initialize deterministic sucker instances |
| `MerkleLib` and helper libraries | Incremental tree logic plus chain-specific constants |

## Runtime Model

```text
holder prepares a bridge
  -> sucker cashes out or consumes the local project-token position
  -> sucker inserts a merkle leaf into the outbox tree
  -> someone bridges funds and the latest root to the remote sucker
  -> claimant proves inclusion against the remote inbox tree
  -> remote sucker releases or remints the destination-side value
```

## Critical Invariants

- Inbox and outbox tree updates must remain append-only and proof-compatible across chains.
- Token mapping is part of bridge correctness; a wrong remote token mapping is a value-loss bug.
- Deprecation and emergency controls must not compromise already-bridged claims.
- The chain-specific transport layers may differ, but they must preserve the same logical prepare-to-claim lifecycle.

## Where Complexity Lives

- The abstract lifecycle is simple, but every transport backend has its own failure modes and native-token quirks.
- Tree state, token mapping, and claim replay protection all carry cross-chain blast radius.
- Registry policy matters because deployment mistakes are hard to repair after pairs exist on multiple chains.

## Dependencies

- `nana-core-v6` terminals and project-token semantics
- Native bridge infrastructure for OP Stack, Arbitrum, CCIP, and supported variants
- `nana-permission-ids-v6` for deploy, map, safety, and deprecation permissions

## Safe Change Guide

- Review every cross-chain change from both sides of the pair.
- Do not change merkle leaf encoding casually; proofs and remote compatibility depend on it.
- Keep registry policy, deployer configuration, and singleton logic aligned.
- Test chain-specific native-token wrapping paths separately from the abstract lifecycle.
- Assume bridge-edge behavior is the primary review target, not the happy path.
