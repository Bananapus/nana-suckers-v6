# Juicebox Suckers

`@bananapus/suckers-v6` provides cross-chain bridging for Juicebox project tokens and the terminal assets that back them. A pair of suckers lets users burn on one chain, move value across a bridge, and mint the same project token representation on another chain.


## Documentation

- [INVARIANTS.md](./INVARIANTS.md) — guarantees this code enforces at runtime, organized by user/operator/contract.
- [ARCHITECTURE.md](./ARCHITECTURE.md) — system layout, contract responsibilities, and the bridge-variant taxonomy.
- [ADMINISTRATION.md](./ADMINISTRATION.md) — change-management posture, Safe-controlled surfaces, and operational roles.
- [RISKS.md](./RISKS.md) — bridge-flavored risk register: AMB trust, merkle progression, mapping, deprecation, atomicity.
- [USER_JOURNEYS.md](./USER_JOURNEYS.md) — end-to-end flows for token holders, operators, and integrators.
- [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md) — scope, entrypoints, and reading order for security review.
- [SKILLS.md](./SKILLS.md) — reusable patterns and gotchas distilled from this codebase.
- [STYLE_GUIDE.md](./STYLE_GUIDE.md) — Solidity conventions used across this repo.
- [CHANGELOG.md](./CHANGELOG.md) - V5 to V6 migration changelog.

The codebase includes multiple bridge variants, but the canonical deployment and discovery tooling in this repo is narrower than the full runtime surface. Treat the deployment scripts and helper libraries as the source of truth for what is operationally supported today.

## Overview

Suckers bridge a project by tracking claims in append-only Merkle trees:

- users call `prepare` to burn tokens and create a bridge claim in the local outbox tree
- anyone can relay the current root to the peer chain with `toRemote`
- anyone can refresh or retry peer accounting with `syncAccountingData`
- claimants prove inclusion against the peer inbox tree to mint on the destination chain

The base implementation is extended for multiple bridge families so the same project model can work across different networks.

Use this repo when the requirement is canonical project-token movement across chains. Do not use it if the project is single-chain or if the bridge assumptions for the target networks are unacceptable.

The main idea is not "bridge the token contract." The main idea is "bridge a Juicebox claim plus enough information to recreate the project-token position on the remote chain."

## Key contracts

| Contract | Role |
| --- | --- |
| `JBSucker` | Base bridge logic for prepare, relay, accounting sync, claim, token mapping, and lifecycle controls. |
| `JBSuckerRegistry` | Registry for per-project sucker deployments, deployer allowlists, and shared bridge fee settings. |
| Chain-specific suckers | Transport-specific implementations for OP Stack, Arbitrum, CCIP, and related environments. |

## Mental model

Each sucker pair has three jobs:

1. destroy or lock the local economic position into a claimable message
2. recreate the remote position from a bridged Merkle root plus transported value
3. keep the peer's aggregate accounting views fresh enough for cross-chain estimates

That means every bridge path has two trust surfaces:

- the shared sucker accounting and Merkle logic
- the bridge-specific transport implementation

## Read these files first

1. `src/JBSucker.sol`
2. `src/JBSuckerRegistry.sol`
3. the chain-specific implementation under `src/`
4. the matching deployer under `src/deployers/`
5. `src/utils/MerkleLib.sol`

## Integration traps

- do not reason about suckers as if they were generic ERC-20 bridges
- root ordering and message delivery semantics matter as much as proof format
- token mapping is part of the economic invariant
- peer contexts are merged only when they share both currency and decimals; same-currency contexts with different decimals are kept separate and valued independently at read time, never summed across precisions
- `syncAccountingData` pays no registry `toRemoteFee`, but bridge-specific transport costs still apply and duplicate snapshots can still consume bridge/indexer resources
- emergency and deprecation paths are part of normal operational safety

## Where state lives

- per-claim and tree progression state: the sucker pair
- deployment inventory and shared operational config: `JBSuckerRegistry`
- bridge transport assumptions: the chain-specific implementation and its external counterparties

## High-signal tests

1. `test/unit/registry.t.sol`
2. `test/unit/multi_chain_evolution.t.sol`
3. `test/ForkClaimMainnet.t.sol`
4. `test/regression/PeerSnapshotDesync.t.sol`
5. `test/regression/ToRemoteFeeIrrecoverable.t.sol`
6. `test/regression/CCIPUntypedMessageRejected.t.sol`

## Install

```bash
npm install @bananapus/suckers-v6
```

## Development

```bash
npm install
forge build
forge test
```

Useful scripts:

- `npm run deploy:mainnets`
- `npm run deploy:testnets`
- `npm run analyze`

## Deployment notes

This package supports multiple bridge families and is intentionally split into bridge-specific deployers. Operational support is narrower than "all theoretically bridgeable chains" and should be taken from the configured deployers, helper libraries, and deployment scripts in this repo.

## Repository layout

```text
src/
  bridge implementations
  JBSucker.sol
  JBSuckerRegistry.sol
  deployers/
  enums/
  interfaces/
  libraries/
  structs/
  utils/
test/
  unit, fork, interoperability, attack, review, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks and notes

- out-of-order root delivery can make some claims unavailable until an operator uses an emergency path
- bridge-specific transport assumptions matter as much as the shared sucker logic
- token mapping and deprecation controls are governance-sensitive surfaces
- a bridge that stays live operationally still may not be economically safe for every asset or chain pair

## For AI agents

- Do not summarize this repo as a generic token bridge.
- Always separate shared sucker logic from bridge-specific transport behavior.
- Use the chain-specific implementation and matching deployer together when answering operational questions.
