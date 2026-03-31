# Audit Instructions

This repo bridges Juicebox project tokens and associated terminal assets across chains. Audit it as a conservation and replay-prevention system.

## Objective

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

## System Model

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

## Threat Model

Prioritize:
- out-of-order nonce arrival
- cross-sucker replay
- trusted-forwarder or messenger spoofing
- emergency-exit races
- fee fallback and bridge-payment edge cases
- deterministic deployer assumptions for peer pairing

The strongest attacker models here are:
- a caller trying to claim from the wrong root with a structurally valid proof
- a privileged actor abusing token mapping or emergency controls after users already prepared transfers
- a transport delivering messages out of order and exposing assumptions hidden in the happy path

## Hotspots

- `prepare`, `toRemote`, `fromRemote`, and `claim`
- bitmap execution tracking
- root and nonce handling
- token mapping and registry trust
- chain-specific messenger authentication
- deployer address derivation and clone setup

## Sequences Worth Replaying

1. Prepare multiple leaves -> send multiple roots -> receive them out of order -> attempt claims for each.
2. Prepare -> deprecate or enable emergency hatch -> claim and exit attempts racing each other.
3. Map token -> prepare transfer -> attempt remap or peer mismatch after value is already in flight.
4. Same logical transfer across different sucker implementations to check for replay or identity confusion.

## Finding Bar

The strongest findings here usually show one of these:
- a user can claim against value that was never actually prepared
- a valid prepare becomes permanently unclaimable without the recovery path the protocol expects
- transport-specific authentication is weaker than the shared model assumes
- a privileged mapping or safety control can rewrite the meaning of already in-flight value

## Build And Verification

Standard workflow:
- `npm install`
- `forge build`
- `forge test`

The current tests already target:
- deep attack and regression scenarios
- trusted-forwarder spoofing
- fee fallback behavior
- deterministic deployment
- chain-specific fork flows

High-value findings here show a break in conservation, replay resistance, or trusted-peer boundaries.
