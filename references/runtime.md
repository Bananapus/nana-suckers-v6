# Suckers Runtime

## Core Roles

- [`src/JBSucker.sol`](../src/JBSucker.sol) owns the shared prepare, relay, claim, token-mapping, and lifecycle logic.
- [`src/JBSuckerRegistry.sol`](../src/JBSuckerRegistry.sol) owns project-to-sucker inventory, deployer allowlists, and shared remote-fee settings.
- Chain-specific sucker contracts such as [`src/JBArbitrumSucker.sol`](../src/JBArbitrumSucker.sol), [`src/JBOptimismSucker.sol`](../src/JBOptimismSucker.sol), [`src/JBCCIPSucker.sol`](../src/JBCCIPSucker.sol), and [`src/JBCeloSucker.sol`](../src/JBCeloSucker.sol) own transport-specific delivery and verification.
- Matching deployers under `src/deployers/` own clone and transport configuration.

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
- Peer snapshots and `numberOfClaimsSent`: these guard against double-spend at the cost of conservative locking when timing goes wrong.

## Tests To Trust First

- [`test/ForkMainnet.t.sol`](../test/ForkMainnet.t.sol), [`test/ForkArbitrum.t.sol`](../test/ForkArbitrum.t.sol), [`test/ForkCelo.t.sol`](../test/ForkCelo.t.sol), and [`test/ForkOPStack.t.sol`](../test/ForkOPStack.t.sol) for real transport assumptions.
- [`test/ForkSwap.t.sol`](../test/ForkSwap.t.sol), [`test/ForkClaimMainnet.t.sol`](../test/ForkClaimMainnet.t.sol), and [`test/SuckerRegressions.t.sol`](../test/SuckerRegressions.t.sol) for pinned cross-chain edge cases.
- [`test/unit/invariants.t.sol`](../test/unit/invariants.t.sol), [`test/unit/peer_chain_state.t.sol`](../test/unit/peer_chain_state.t.sol), and [`test/unit/registry.t.sol`](../test/unit/registry.t.sol) for shared-accounting invariants.
- [`test/SuckerAttacks.t.sol`](../test/SuckerAttacks.t.sol), [`test/SuckerDeepAttacks.t.sol`](../test/SuckerDeepAttacks.t.sol), [`test/audit/PeerSnapshotDesync.t.sol`](../test/audit/PeerSnapshotDesync.t.sol), and [`test/audit/PeerDeterminism.t.sol`](../test/audit/PeerDeterminism.t.sol) when the bug could involve base logic, registry behavior, or a specific bridge implementation.
