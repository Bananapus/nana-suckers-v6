# Suckers Operations

## Configuration Surface

- [`src/JBSuckerRegistry.sol`](../src/JBSuckerRegistry.sol) is the first stop for deployer allowlists, shared fees, project inventory, and deprecation helpers.
- Transport-specific deployers in `src/deployers/` are where chain-specific constants and bridge addresses live.
- [`script/Deploy.s.sol`](../script/Deploy.s.sol) is where deployment-time environment wiring belongs.

## Change Checklist

- If you edit base sucker accounting, verify claim flow across at least one chain-specific implementation.
- If you edit token mapping logic, re-check the registry and deployer assumptions that feed it.
- If you edit token mapping semantics, verify that remapping is still impossible once outbox activity has made economic equivalence depend on permanence.
- If you edit deprecation or emergency paths, verify the intended operator workflow still works end to end.
- If you edit snapshot or claim-boundary logic, verify `numberOfClaimsSent`, peer snapshots, and emergency exit behavior together.
- If you touch bridge-specific code, confirm whether the real bug is transport-side or shared accounting-side.

## Common Failure Modes

- Cross-chain issue is blamed on transport when the root or token mapping was wrong before message delivery.
- Registry configuration drifts from what a deployer or external operator expects.
- Emergency hatches or deprecation paths are stale because nobody exercises them until stress conditions arrive.

## Useful Proof Points

- [`test/SuckerAttacks.t.sol`](../test/SuckerAttacks.t.sol), [`test/SuckerDeepAttacks.t.sol`](../test/SuckerDeepAttacks.t.sol), and [`test/TestAuditGaps.sol`](../test/TestAuditGaps.sol) for security-sensitive assumptions.
- [`test/InteropCompat.t.sol`](../test/InteropCompat.t.sol) when the problem is deployment wiring rather than runtime logic.
- [`test/unit/invariants.t.sol`](../test/unit/invariants.t.sol), [`test/unit/peer_chain_state.t.sol`](../test/unit/peer_chain_state.t.sol), and [`test/audit/codex-PeerSnapshotDesync.t.sol`](../test/audit/codex-PeerSnapshotDesync.t.sol) when shared accounting or snapshot boundaries are in doubt.
