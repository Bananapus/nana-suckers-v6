# Architecture

## Purpose

`nana-suckers-v6` bridges Juicebox project positions across chains by turning a local cash-out into a claimable remote mint. It does not behave like a generic ERC-20 bridge: the bridged object is a Juicebox claim plus the backing terminal-token value needed to honor it on the peer chain.

## System overview

`JBSucker` owns shared project-token burn, outbox, inbox, claim, peer-accounting sync, token-mapping, deprecation, and emergency-exit logic. `JBSuckerRegistry` owns project-to-sucker inventory, deployer allowlists, shared bridge fees, and best-effort aggregate remote-state views. Chain-specific suckers handle transport authentication and asset delivery for OP Stack, Arbitrum, CCIP, and related environments. Deployers bind those implementations to the external bridge addresses and peer-chain configuration used at runtime. Archived (reference only — not compiled or deployed): `JBSwapCCIPSucker` (+ its swap libs/structs) and `JBCeloSucker`; see `src/archive/`.

## Core invariants

- Merkle trees remain append-only and claims cannot be replayed.
- Each source chain's freshness key only moves forward independently, so a stale record for one chain cannot roll back that chain's stored accounting.
- Accounting-only messages can update per-source-chain supply/context state but cannot update token-local inbox roots.
- Token mappings stay coherent once outbox activity depends on them.
- The transported terminal-token value matches the claimable project-token position.
- Emergency exits and deprecation paths recover value without enabling double claims.
- Registry aggregate views never double-count redundant records for the same source chain across a project's suckers.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBSucker` | Shared prepare, relay, claim, token mapping, deprecation, and emergency behavior | Runtime core |
| `JBSuckerRegistry` | Deployment inventory, deployer allowlists, remote fees, and aggregate remote-state views | Governance and discovery surface |
| `JBOptimismSucker` / `JBBaseSucker` | OP Stack message and token bridging | Uses messenger and standard bridge |
| `JBArbitrumSucker` | Arbitrum retryable-ticket and gateway flow | Transport-specific fee sizing matters |
| `JBCCIPSucker` | Chainlink CCIP delivery and optional LINK fee mode | Higher external dependency surface |
| `JBSuckerDeployer` variants | Clone and configure chain-specific suckers | Deployment wiring is part of correctness |
| `MerkleLib` / `JBSuckerLib` / `JBPeerChainAdjustedAccountsLib` | Merkle and bytecode-heavy accounting helpers (gossip-bundle assembly, raw-context folding to a local currency at read time), plus defensive optional-hook return decoding | Shared by runtime paths |
| `JBSwapCCIPSucker` (+ swap libs/structs) / `JBCeloSucker` | Swap-assisted CCIP bridging / Celo-oriented native-token handling | Archived (reference only — not compiled or deployed); see `src/archive/` |

## Trust boundaries

- Core terminal accounting, project ownership, prices, and token supply come from `nana-core-v6`.
- Transport authentication comes from the selected bridge or CCIP router, not from `JBSucker`.
- Token mapping is permissioned project configuration and becomes economically sticky after sends.
- Registry owner decisions affect which deployers can create suckers and what shared fee is charged.
- Data-hook peer adjustments are optional and must fail closed into the baseline project snapshot, including malformed
  successful return data.

## Critical flows

### Prepare and send

```text
holder cashes out locally
  -> sucker builds a Merkle leaf and appends it to the outbox
  -> local terminal-token backing is held or bridged
  -> toRemote gathers this chain's own record plus every peer-chain record the project knows (via the registry) into a gossip bundle, excluding the destination chain
  -> toRemote sends the current root, transported value, and that bundle through the selected bridge
  -> peer sucker records the root and stores the freshest record per source chain (ignoring its own chain and chain 0)
```

### Accounting sync

```text
project accounting should be refreshed or retried without a new root send
  -> any caller invokes syncAccountingData to refresh or retry the accounting gossip bundle
  -> the bundle carries this chain's own record plus every peer-chain record the project knows, each stamped with its origin chain's freshness key, excluding the destination chain
  -> the selected bridge transports only supply, surplus, balance, and per-chain freshness data — no inbox root
  -> peer sucker stores each record whose source freshness key is strictly newer than the one it already holds for that chain, without changing any inbox root
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

Each sucker keeps a per-source-chain accounting store: for every chain it has heard about, the freshest record of project supply plus a set of raw surplus and balance contexts, gated independently per chain on a strictly-newer freshness key. Outbound messages carry a gossip bundle — an array of `JBChainAccounting` records, one per source chain the project knows (its own chain plus every peer-chain record gathered through the registry, which is the only contract that sees a hub chain's per-peer suckers together), each stamped with its origin chain's freshness key and excluding the destination chain. This lets a project's accounting propagate across a hub-and-spoke sucker mesh (L2s bridged only through mainnet) without a direct sucker between every pair of chains: one sync round from the hub forwards every chain's record to every spoke. The receiving sucker stores each record whose freshness key beats the one it already holds for that source chain, ignoring any record for its own chain (`block.chainid`) or chain 0. When a context token matches the receiver's remote-to-local token mapping, the receiver stores the context under its local token key while preserving the source amount and decimals; unmapped tokens stay unchanged. `peerChainContextsOf` folds those stored keys to local currencies for valuation, and `peerChainAccountsOf` returns the already-localized records for registry re-gossip. This hop-by-hop normalization means a spoke receiving a sibling's record from a hub only needs its mapping to the hub token, not the sibling token address. Valuation into a requested currency happens in `JBSuckerRegistry`, which holds the prices reference and values each context exactly as the terminal store values local surplus — a context already in the requested currency folds in at par with no feed, and a different-currency context is valued through the project's price feed. `syncAccountingData` sends only this gossip bundle, pays no registry `toRemoteFee`, and can be retried if an operator wants a fresh transport attempt. Registry aggregate views are intentionally best-effort: they skip reverting suckers (including any whose cross-currency feed is missing) and dedupe per source chain across every (sucker, chain) pair by the freshest accepted record, with deprecated suckers used only when no active sucker answers for that source chain.

## Security model

- Shared sucker bugs can affect every bridge family.
- Bridge-specific bugs can strand or misdeliver value even when shared accounting is correct.
- `prepare`, `toRemote`, `syncAccountingData`, `claim`, `mapToken`, `setDeprecation`, and registry deploy/remove paths are the primary review targets.
- Low-level fee, gas, and calldata sizing details are security-critical because sends are cross-chain and non-atomic.

## Safe change guide

- Review `JBSucker` and the matching chain-specific implementation together when changing send or receive behavior.
- Re-check token mapping, outbox balance, the per-source-chain accounting store and its gossip-bundle assembly, and emergency-exit behavior together.
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
