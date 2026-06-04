# Architecture

## Purpose

`nana-suckers-v6` bridges Juicebox project positions across chains by turning a local cash-out into a claimable remote mint. It does not behave like a generic ERC-20 bridge: the bridged object is a Juicebox claim plus the backing terminal-token value needed to honor it on the peer chain.

## System overview

`JBSucker` owns shared project-token burn, outbox, inbox, claim, token-mapping, deprecation, and emergency-exit logic. `JBSuckerRegistry` owns project-to-sucker inventory, deployer allowlists, shared bridge fees, and best-effort aggregate remote-state views. Chain-specific suckers handle transport authentication and asset delivery for OP Stack, Arbitrum, CCIP, and related environments. Deployers bind those implementations to the external bridge addresses and peer-chain configuration used at runtime. Archived (reference only — not compiled or deployed): `JBSwapCCIPSucker` (+ its swap libs/structs) and `JBCeloSucker`; see `src/archive/`.

## Core invariants

- Merkle trees remain append-only and claims cannot be replayed.
- Source freshness keys only move forward, so stale peer snapshots cannot roll back remote state.
- Token mappings stay coherent once outbox activity depends on them.
- The transported terminal-token value matches the claimable project-token position.
- Emergency exits and deprecation paths recover value without enabling double claims.
- Registry aggregate views never double-count redundant same-peer snapshots.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBSucker` | Shared prepare, relay, claim, token mapping, deprecation, and emergency behavior | Runtime core |
| `JBSuckerRegistry` | Deployment inventory, deployer allowlists, remote fees, and aggregate remote-state views | Governance and discovery surface |
| `JBOptimismSucker` / `JBBaseSucker` | OP Stack message and token bridging | Uses messenger and standard bridge |
| `JBArbitrumSucker` | Arbitrum retryable-ticket and gateway flow | Transport-specific fee sizing matters |
| `JBCCIPSucker` | Chainlink CCIP delivery and optional LINK fee mode | Higher external dependency surface |
| `JBSuckerDeployer` variants | Clone and configure chain-specific suckers | Deployment wiring is part of correctness |
| `MerkleLib` / `JBSuckerLib` | Merkle and bytecode-heavy accounting helpers | Shared by runtime paths |
| `JBSwapCCIPSucker` (+ swap libs/structs) / `JBCeloSucker` | Swap-assisted CCIP bridging / Celo-oriented native-token handling | Archived (reference only — not compiled or deployed); see `src/archive/` |

## Trust boundaries

- Core terminal accounting, project ownership, prices, and token supply come from `nana-core-v6`.
- Transport authentication comes from the selected bridge or CCIP router, not from `JBSucker`.
- Token mapping is permissioned project configuration and becomes economically sticky after sends.
- Registry owner decisions affect which deployers can create suckers and what shared fee is charged.
- Data-hook peer adjustments are optional and must fail closed into the baseline project snapshot.

## Critical flows

### Prepare and send

```text
holder cashes out locally
  -> sucker builds a Merkle leaf and appends it to the outbox
  -> local terminal-token backing is held or bridged
  -> toRemote sends the current root and transported value through the selected bridge
  -> peer sucker records the root and latest source snapshot
```

### Claim

```text
claimant provides leaf and proof
  -> peer sucker verifies the proof against an accepted inbox root
  -> claim state is marked consumed
  -> project tokens are minted or funds are delivered according to the mapped token
```

### Migration or recovery

```text
project authority schedules deprecation or enables emergency hatch
  -> new outbound sends stop after the delay boundary
  -> claims sent before deprecation remain recoverable
  -> operators can remove deprecated suckers from active registry listings without erasing aggregate visibility
```

## Accounting model

The local sucker snapshots project supply plus a per-currency set of raw surplus and balance amounts before sending roots. The peer sucker stores these as oracle-free contexts and never prices them itself; valuation happens at read time in `JBSuckerRegistry`, which holds the prices reference and converts each context into a requested currency exactly as the terminal store values local surplus — taking a context already in the requested currency at par with no feed, and valuing a different-currency context through the project's price feed. Registry aggregate views are intentionally best-effort: they skip reverting suckers (including any whose cross-currency feed is missing) and dedupe active same-peer lanes by the freshest accepted snapshot, with deprecated lanes used only when no active lane answers for that peer chain.

## Security model

- Shared sucker bugs can affect every bridge family.
- Bridge-specific bugs can strand or misdeliver value even when shared accounting is correct.
- `prepare`, `toRemote`, `claim`, `mapToken`, `setDeprecation`, and registry deploy/remove paths are the primary review targets.
- Low-level fee, gas, and calldata sizing details are security-critical because sends are cross-chain and non-atomic.

## Safe change guide

- Review `JBSucker` and the matching chain-specific implementation together when changing send or receive behavior.
- Re-check token mapping, outbox balance, source snapshot, and emergency-exit behavior together.
- Treat registry aggregate changes as user-facing estimator changes, not harmless view refactors.
- If a change touches bridge fees or gas limits, verify the real transport API rather than only local mocks.

## Canonical checks

- Registry and aggregate behavior:
  `test/unit/registry.t.sol`
  `test/unit/multi_chain_evolution.t.sol`
- Shared accounting invariants:
  `test/unit/invariants.t.sol`
  `test/unit/peer_chain_state.t.sol`
- Cross-chain and transport edges:
  `test/ForkMainnet.t.sol`
  `test/ForkArbitrum.t.sol`
  `test/ForkOPStack.t.sol`
  `test/ForkClaimMainnet.t.sol`
  `test/archive/ForkCelo.t.sol` (archived — not compiled or deployed)
- Regression and attack coverage:
  `test/SuckerAttacks.t.sol`
  `test/SuckerDeepAttacks.t.sol`
  `test/regression/PeerSnapshotDesync.t.sol`

## Source map

- `src/JBSucker.sol`
- `src/JBSuckerRegistry.sol`
- `src/deployers/`
- `src/libraries/JBSuckerLib.sol`
- `src/utils/MerkleLib.sol`
- Archived (reference only — not compiled or deployed; see `src/archive/`):
  - `src/archive/JBSwapCCIPSucker.sol` and its swap libs/structs (`JBSwapPoolLib`, `JBSwapLib`, `JBPendingSwap`, `JBConversionRate`)
  - `src/archive/JBCeloSucker.sol`
