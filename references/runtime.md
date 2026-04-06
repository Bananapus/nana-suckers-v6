# Suckers Runtime

## Core Roles

- [`src/JBSucker.sol`](../src/JBSucker.sol) owns the shared prepare, relay, claim, token-mapping, and lifecycle logic.
- [`src/JBSuckerRegistry.sol`](../src/JBSuckerRegistry.sol) owns project-to-sucker inventory, deployer allowlists, and shared remote-fee settings.
- Chain-specific sucker contracts under [`src/`](../src/) own the transport-specific message delivery and verification path.
- Matching deployers under [`src/deployers/`](../src/deployers/) own clone and transport configuration.

## Runtime Path

1. Local state is prepared into a claimable Merkle leaf.
2. A root is relayed to the peer chain through the bridge-specific transport.
3. The remote side records the root in its inbox state.
4. Claimants prove inclusion and recreate their position on the destination chain.

## High-Risk Areas

- Token mapping: mapping mistakes break economic equivalence, not just UX.
- Root ordering and replay protection: message sequencing is part of correctness.
- Emergency and deprecation paths: these are operational safety surfaces that must remain reliable.
- Shared accounting vs transport logic: many incidents stem from confusing these layers.

## Tests To Trust First

- [`test/fork/`](../test/fork/) for real transport assumptions.
- [`test/regression/`](../test/regression/) for pinned cross-chain edge cases.
- [`test/`](../test/) broadly when the bug could involve base logic, registry behavior, or a specific bridge implementation.
