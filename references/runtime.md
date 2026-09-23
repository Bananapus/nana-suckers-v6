# Suckers runtime

## Core roles

- [`src/JBSucker.sol`](../src/JBSucker.sol) owns the shared prepare, relay, claim, token-mapping, and lifecycle logic.
- [`src/JBSuckerRegistry.sol`](../src/JBSuckerRegistry.sol) owns project-to-sucker inventory, deployer allowlists, owner-gated token-pair allowlists, and shared remote-fee settings.
- Chain-specific sucker contracts such as [`src/JBArbitrumSucker.sol`](../src/JBArbitrumSucker.sol), [`src/JBOptimismSucker.sol`](../src/JBOptimismSucker.sol), [`src/JBBaseSucker.sol`](../src/JBBaseSucker.sol), and [`src/JBCCIPSucker.sol`](../src/JBCCIPSucker.sol) own transport-specific delivery and verification. [`src/archive/JBCeloSucker.sol`](../src/archive/JBCeloSucker.sol) is archived (reference only — not compiled or deployed).
- Matching deployers under `src/deployers/` own clone and transport configuration.

## Runtime path

1. Local state is prepared into a claimable Merkle leaf.
2. A root is relayed to the peer chain through the bridge-specific transport.
3. The remote side records the root in its inbox state and stores the freshest accounting record per source chain from the message's gossip bundle.
4. Accounting-only snapshots can also be relayed or retried with `syncAccountingData` without sending a new root.
5. Claimants prove inclusion and recreate their position on the destination chain.

## High-risk areas

- Token mapping: mapping mistakes break economic equivalence, not just UX. Native/native and different-address mappings require route-scoped registry-owner approval before a project can choose them.
- Root ordering and replay protection: message sequencing is part of correctness.
- Emergency and deprecation paths: these are operational safety surfaces that must remain reliable.
- Shared accounting vs transport logic: many incidents stem from confusing these layers.
- Peer snapshots and `numberOfClaimsSent`: these guard against double-spend at the cost of conservative locking when timing goes wrong.
- Accounting-only messages: these must never mutate token-local inbox roots or claimable value.

## Tests to trust first

- [`test/ForkMainnet.t.sol`](../test/ForkMainnet.t.sol), [`test/ForkArbitrum.t.sol`](../test/ForkArbitrum.t.sol), and [`test/ForkOPStack.t.sol`](../test/ForkOPStack.t.sol) for real transport assumptions. [`test/archive/ForkCelo.t.sol`](../test/archive/ForkCelo.t.sol) is archived (not compiled).
- [`test/ForkClaimMainnet.t.sol`](../test/ForkClaimMainnet.t.sol) and [`test/SuckerRegressions.t.sol`](../test/SuckerRegressions.t.sol) for pinned cross-chain edge cases. [`test/archive/ForkSwap.t.sol`](../test/archive/ForkSwap.t.sol) covers the archived swap-CCIP sucker (not compiled).
- [`test/unit/invariants.t.sol`](../test/unit/invariants.t.sol), [`test/unit/peer_chain_state.t.sol`](../test/unit/peer_chain_state.t.sol), and [`test/unit/registry.t.sol`](../test/unit/registry.t.sol) for shared-accounting invariants.
- [`test/SuckerAttacks.t.sol`](../test/SuckerAttacks.t.sol), [`test/SuckerDeepAttacks.t.sol`](../test/SuckerDeepAttacks.t.sol), [`test/regression/PeerSnapshotDesync.t.sol`](../test/regression/PeerSnapshotDesync.t.sol), [`test/regression/CCIPUntypedMessageRejected.t.sol`](../test/regression/CCIPUntypedMessageRejected.t.sol), and [`test/regression/PeerDeterminism.t.sol`](../test/regression/PeerDeterminism.t.sol) when the bug could involve base logic, registry behavior, or a specific bridge implementation.
