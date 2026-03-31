# Suckers Operations

## Configuration Surface

- [`src/JBSuckerRegistry.sol`](../src/JBSuckerRegistry.sol) is the first stop for deployer allowlists, shared fees, project inventory, and deprecation helpers.
- Transport-specific deployers in [`src/deployers/`](../src/deployers/) are where chain-specific constants and bridge addresses live.
- [`script/`](../script/) is where deployment-time environment wiring belongs.

## Change Checklist

- If you edit base sucker accounting, verify claim flow across at least one chain-specific implementation.
- If you edit token mapping logic, re-check the registry and deployer assumptions that feed it.
- If you edit deprecation or emergency paths, verify the intended operator workflow still works end to end.
- If you touch bridge-specific code, confirm whether the real bug is transport-side or shared accounting-side.

## Common Failure Modes

- Cross-chain issue is blamed on transport when the root or token mapping was wrong before message delivery.
- Registry configuration drifts from what a deployer or external operator expects.
- Emergency hatches or deprecation paths are stale because nobody exercises them until stress conditions arrive.

## Useful Proof Points

- [`test/audit/`](../test/audit/) for security-sensitive assumptions.
- [`script/helpers/`](../script/helpers/) when the problem is deployment wiring rather than runtime logic.
