# Audit Instructions

This repo bridges Juicebox project tokens and associated terminal assets across chains. Audit it as a conservation and replay-prevention system.

## Audit Objective

Find issues that:
- allow double claim, replay, or claim on the wrong destination
- lose or strand bridged backing assets
- let deprecated or emergency paths violate intended safety rules
- mis-handle root ordering, especially across asynchronous bridge transports
- grant mapping or safety privileges more broadly than intended

## Scope

In scope:
- all Solidity under `src/`
- deployer contracts under `src/deployers/`
- `src/utils/MerkleLib.sol`
- libraries, enums, interfaces, and structs under `src/`
- deployment scripts in `script/`

## Start Here

Read in this order:
- the shared flow in `JBSucker`
- claim validation and execution tracking
- token mapping and emergency-hatch logic
- one native bridge implementation
- `JBCCIPSucker`
- deployers and registry assumptions

That order gets you from the shared conservation model to the transport-specific deviations.

## Security Model

The bridge flow is:
- burn or prepare project-token value on source chain
- record a leaf into an outbox tree
- send a merkle root and backing assets over a chain-specific transport
- receive the root on the remote chain
- claim by proving inclusion against the current inbox root

This repo supports multiple transport implementations:
- OP Stack variants
- Arbitrum
- CCIP
- related deployers and registries

One non-obvious property to audit explicitly:
- roots and assets do not always arrive in a perfectly ordered, synchronous way
- the system is intentionally designed to survive some transport mismatch without deadlocking
- those recovery choices are exactly where conservation bugs tend to hide

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Source-side caller | Prepare and bridge value to a remote chain | Must not create more claimable value than was prepared |
| Remote peer and messenger | Install new roots and deliver assets | Must be authenticated per transport |
| Emergency authority | Deprecate paths or enable recovery exits | Must not be able to steal in-flight funds |

## Integration Assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| Bridge transport | Delivers only authenticated peer messages | Anyone can spoof remote state |
| Token mapping and registry state | Remote asset identity stays stable | Users claim the wrong asset or wrong meaning |

## Critical Invariants

1. Cross-chain conservation
For any prepared transfer, destination claimable value must not exceed what the source side actually prepared and backed.

2. Single execution
Each bridged leaf must be claimable at most once on the destination and at most once via emergency exit.

3. Peer authenticity
Only the intended remote peer and messenger path may update inbox roots.

4. Deprecation safety
Deprecation and emergency-hatch controls must not let callers bypass intended restrictions or steal in-flight funds.

5. Token mapping integrity
Remote token mappings must be immutable or mutable only exactly where the design allows.

6. Nonce progression is monotonic in the way each transport expects
Later roots must not silently invalidate earlier user claims unless the protocol explicitly intends that recovery path.

## Attack Surfaces

- `prepare`, `toRemote`, `fromRemote`, and `claim`
- bitmap execution tracking
- root and nonce handling
- token mapping and registry trust
- chain-specific messenger authentication
- deployer address derivation and clone setup

Replay these sequences:
1. prepare multiple leaves, send multiple roots, receive them out of order, and attempt each claim
2. prepare, deprecate or enable emergency hatch, then race claim and exit paths
3. map a token, prepare a transfer, then attempt remap or peer mismatch after value is in flight
4. replay the same logical transfer across different sucker implementations

## Accepted Risks Or Behaviors

- Out-of-order arrival is part of the intended model, not an edge case.

## Verification

- `npm install`
- `forge build`
- `forge test`
