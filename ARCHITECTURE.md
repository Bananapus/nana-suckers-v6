# Architecture

## Purpose

`nana-suckers-v6` moves Juicebox project-token value across chains. A sucker pair lets a holder destroy or consume a local project-token position, bridge the corresponding terminal-side value plus a Merkle root, and later claim equivalent value on the remote chain.

## System Overview

`JBSucker` defines the chain-agnostic prepare, relay, and claim lifecycle. Chain-specific implementations such as `JBOptimismSucker`, `JBArbitrumSucker`, `JBCCIPSucker`, `JBSwapCCIPSucker`, `JBBaseSucker`, and `JBCeloSucker` handle transport-specific details. `JBSuckerRegistry` governs deployment inventory and shared policy, while deployers create deterministic clones for each supported transport family.

## Core Invariants

- Inbox and outbox trees must remain append-only and proof-compatible across chains.
- Token mapping is part of economic correctness; a wrong mapping is a value-loss bug.
- Deprecation or emergency controls must not break already-bridged claims.
- Roots may arrive out of order. Newer nonces replace older inbox roots, so claims must stay provable against the latest append-only tree.
- Root reception and token mapping are intentionally decoupled. Accepting a root for an unmapped token is valid if later mapping is what makes the claim redeemable.
- Transport-specific implementations may differ operationally, but they must preserve the same logical prepare-to-claim lifecycle.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBSucker` | Prepare, root management, claim verification, token mapping, deprecation | Chain-agnostic base |
| chain-specific suckers | Transport details for OP Stack, Arbitrum, CCIP, Base, and Celo | Bridge-specific subclasses |
| `JBSuckerRegistry` | Deployer allowlist, inventory, and global bridge-fee policy | Shared policy surface |
| deployers | Deterministic clone deployment and initialization | One per transport family |
| `MerkleLib` and helper libraries | Incremental tree logic and chain constants | Proof-critical |

## Trust Boundaries

- Project-token semantics and local terminal accounting remain rooted in `nana-core-v6`.
- Transport assumptions come from native bridge infrastructure for each chain family.
- Permission IDs come from `nana-permission-ids-v6`.

## Critical Flows

### Prepare, Relay, Claim

```text
holder prepares a bridge
  -> sucker cashes out or consumes the local project-token position
  -> sucker inserts a Merkle leaf into the outbox tree
  -> someone relays funds and the latest root to the remote sucker
  -> remote sucker may accept a later nonce before an earlier one, updating shared cross-chain snapshots to the freshest project-wide message
  -> claimant proves inclusion against the remote inbox tree
  -> remote sucker releases or remints destination-side value
```

## Accounting Model

The repo does not replace local treasury accounting. It owns bridge-specific claim accounting: outbox leaves, inbox roots, token mappings, replay protection, and the transition from local destruction to remote claimability.

`JBSwapCCIPSucker` adds another accounting layer on top of the base lifecycle: nonce-indexed conversion rates. A claim can be temporarily blocked while a failed swap is pending retry, and successful claims are scaled against the conversion rate recorded for that batch's nonce.

## Security Model

- Tree state, token mapping, and replay protection have cross-chain blast radius.
- Each transport backend has distinct failure modes and native-token quirks.
- Out-of-order message delivery is part of the trust model, not an exception path. Proof generation and monitoring must tolerate stale-root rejection and regenerated proofs against the newest root.
- Emergency hatch and deprecation flows are designed to preserve already-bridged exits. Post-deprecation root acceptance is intentional so in-flight messages do not strand users.
- Registry policy matters because bad deployments are hard to repair once pairs exist on multiple chains.

## Safe Change Guide

- Review every cross-chain change from both sides of the pair.
- Do not change Merkle leaf encoding casually.
- Keep registry policy, deployer configuration, and singleton initialization aligned.
- If you change root or snapshot nonce handling, re-check out-of-order delivery behavior and whether older claims remain provable against the newest root.
- If you change CCIP swap handling, re-check pending-swap claim blocking and per-batch conversion-rate lookups together.
- Test chain-specific wrapping and native-token handling separately from the abstract lifecycle.

## Canonical Checks

- peer snapshot and remote-state synchronization:
  `test/audit/codex-PeerSnapshotDesync.t.sol`
- deprecation and stranded-destination handling:
  `test/audit/DeprecatedSuckerDestination.t.sol`
- peer-chain state accounting:
  `test/unit/peer_chain_state.t.sol`

## Source Map

- `src/JBSucker.sol`
- `src/JBSuckerRegistry.sol`
- `src/deployers/`
- `src/utils/MerkleLib.sol`
- `test/audit/codex-PeerSnapshotDesync.t.sol`
- `test/audit/DeprecatedSuckerDestination.t.sol`
- `test/unit/peer_chain_state.t.sol`
