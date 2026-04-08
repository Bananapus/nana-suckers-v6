# Juicebox Suckers

`@bananapus/suckers-v6` provides cross-chain bridging for Juicebox project tokens and the terminal assets that back them. A pair of suckers lets users burn on one chain, move value across a bridge, and mint the same project token representation on another chain.

Docs: <https://docs.juicebox.money>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)

The codebase includes multiple bridge variants, but the canonical deployment and discovery tooling in this repo is narrower than the full runtime surface. Treat the deployment scripts and helper libraries as the source of truth for what is operationally supported today.

## Overview

Suckers bridge a project by tracking claims in append-only Merkle trees:

- users call `prepare` to burn tokens and create a bridge claim in the local outbox tree
- anyone can relay the current root to the peer chain with `toRemote`
- claimants prove inclusion against the peer inbox tree to mint on the destination chain

The base implementation is extended for multiple bridge families so the same project model can work across different networks.

Use this repo when the requirement is canonical project-token movement across chains. Do not use it if the project is single-chain or if the bridge assumptions for the target networks are unacceptable.

The main idea is not "bridge the token contract." The main idea is "bridge a Juicebox cash-out claim plus enough information to recreate the project-token position on the remote chain."

## Key Contracts

| Contract | Role |
| --- | --- |
| `JBSucker` | Base bridge logic for prepare, relay, claim, token mapping, and lifecycle controls. |
| `JBSuckerRegistry` | Registry for per-project sucker deployments, deployer allowlists, and shared bridge fee settings. |
| `JBOptimismSucker` | OP Stack bridge implementation. |
| `JBBaseSucker` | Base-flavored OP Stack implementation. |
| `JBCeloSucker` | OP Stack implementation adapted for Celo's native asset behavior. |
| `JBArbitrumSucker` | Arbitrum bridge implementation. |
| `JBCCIPSucker` | Chainlink CCIP-based implementation for CCIP-connected chains. |

## Mental Model

Each sucker pair has two jobs:

1. destroy or lock the local economic position into a claimable message
2. recreate the remote position from a bridged Merkle root plus transported value

That means every bridge path has two trust surfaces:

- the shared sucker accounting and Merkle logic
- the bridge-specific transport implementation

The shortest useful reading order is:

| Contract | Description |
|----------|-------------|
| [`JBSucker`](src/JBSucker.sol) | Abstract base. Manages outbox/inbox merkle trees, `prepare`/`toRemote`/`claim` lifecycle, token mapping, deprecation, and emergency hatch. Deployed as clones via `Initializable`. Uses `ERC2771Context` for meta-transactions. Has immutable `FEE_PROJECT_ID` (typically project ID 1) and immutable `REGISTRY` reference. Reads the `toRemoteFee` from the registry via `REGISTRY.toRemoteFee()` on each `toRemote()` call. |
| [`JBCCIPSucker`](src/JBCCIPSucker.sol) | Extends `JBSucker`. Bridges via Chainlink CCIP (`ccipSend`/`ccipReceive`). Supports any CCIP-connected chain pair. Wraps native ETH to WETH before bridging (CCIP only transports ERC-20s) and unwraps on the receiving end. Can map `NATIVE_TOKEN` to ERC-20 addresses on the remote chain (unlike OP/Arbitrum suckers). |
| [`JBOptimismSucker`](src/JBOptimismSucker.sol) | Extends `JBSucker`. Bridges via OP Standard Bridge + OP Messenger. No `msg.value` required for transport. |
| [`JBBaseSucker`](src/JBBaseSucker.sol) | Thin wrapper around `JBOptimismSucker` with Base chain IDs (Ethereum 1 <-> Base 8453, Sepolia 11155111 <-> Base Sepolia 84532). |
| [`JBCeloSucker`](src/JBCeloSucker.sol) | Extends `JBOptimismSucker` for Celo (OP Stack, custom gas token CELO). Wraps native ETH → WETH before bridging as ERC-20. Unwraps received WETH → native ETH via `_addToBalance` override. Removes `NATIVE_TOKEN → NATIVE_TOKEN` restriction. Sends messenger messages with `nativeValue = 0` (Celo's native token is CELO, not ETH). |
| [`JBArbitrumSucker`](src/JBArbitrumSucker.sol) | Extends `JBSucker`. Bridges via Arbitrum Inbox + Gateway Router. Uses `unsafeCreateRetryableTicket` for L1->L2 (to avoid address aliasing of refund address) and `ArbSys.sendTxToL1` for L2->L1. Requires `msg.value` for L1->L2 transport payment. |
| [`JBSuckerRegistry`](src/JBSuckerRegistry.sol) | Tracks all suckers per project. Manages deployer allowlist (owner-only). Entry point for `deploySuckersFor`. Can remove deprecated suckers via `removeDeprecatedSucker`. Owns the global `toRemoteFee` (ETH fee in wei, capped at `MAX_TO_REMOTE_FEE` = 0.001 ether), adjustable by the registry owner via `setToRemoteFee()`. All sucker clones read this fee from the registry. Existing-project deployments are deploy-and-map operations, so the registry also needs to be arranged as an authorized `MAP_SUCKER_TOKEN` operator for those projects. |
| [`JBSuckerDeployer`](src/JBSuckerDeployer.sol) | Abstract base deployer. Clones a singleton sucker via `LibClone.cloneDeterministic` and initializes it. Two-phase setup: `setChainSpecificConstants` then `configureSingleton`. |
| [`JBCCIPSuckerDeployer`](src/deployers/JBCCIPSuckerDeployer.sol) | Deployer for `JBCCIPSucker`. Stores CCIP router, remote chain ID, and CCIP chain selector. |
| [`JBOptimismSuckerDeployer`](src/deployers/JBOptimismSuckerDeployer.sol) | Deployer for `JBOptimismSucker`. Stores OP Messenger and OP Bridge addresses. |
| [`JBBaseSuckerDeployer`](src/deployers/JBBaseSuckerDeployer.sol) | Thin wrapper around `JBOptimismSuckerDeployer` for Base. |
| [`JBCeloSuckerDeployer`](src/deployers/JBCeloSuckerDeployer.sol) | Deployer for `JBCeloSucker`. Extends `JBOptimismSuckerDeployer` with `wrappedNative` (`IWrappedNativeToken`) storage for the local chain's WETH address. |
| [`JBArbitrumSuckerDeployer`](src/deployers/JBArbitrumSuckerDeployer.sol) | Deployer for `JBArbitrumSucker`. Stores Arbitrum Inbox, Gateway Router, and layer (`JBLayer.L1` or `JBLayer.L2`). |
| [`MerkleLib`](src/utils/MerkleLib.sol) | Incremental merkle tree (depth 32, max ~4 billion leaves, modeled on eth2 deposit contract). Used for outbox/inbox trees. `insert` and `root` operate directly on `Tree storage` (not memory copies) to avoid redundant SLOAD/SSTORE round-trips. Gas-optimized with inline assembly for `root()` and `branchRoot()`. |
| [`CCIPHelper`](src/libraries/CCIPHelper.sol) | CCIP router addresses, chain selectors, and WETH addresses per chain. Covers Ethereum, Optimism, Arbitrum, Base, Polygon, Avalanche, and BNB Chain (mainnet and testnets). |
| [`ARBAddresses`](src/libraries/ARBAddresses.sol) | Arbitrum bridge contract addresses (Inbox, Gateway Router) for mainnet and Sepolia. |
| [`ARBChains`](src/libraries/ARBChains.sol) | Arbitrum chain ID constants. |

## Read These Files First

1. `src/JBSucker.sol`
2. `src/JBSuckerRegistry.sol`
3. the chain-specific implementation under `src/`
4. the matching deployer under `src/deployers/`
5. `src/utils/MerkleLib.sol`

## Integration Traps

- do not reason about suckers as if they were generic ERC-20 bridges; they are project-token plus treasury-state bridges
- root ordering and message delivery semantics matter as much as the claim proof format
- token mapping is part of the economic invariant, not just a convenience config
- emergency and deprecation paths are not edge tooling; they are part of normal operational safety

## Where State Lives

- per-claim and tree progression state live in the sucker pair itself
- deployment inventory and shared operational config live in `JBSuckerRegistry`
- bridge transport assumptions live in the chain-specific implementation and its external counterparties

When reviewing a bridge incident, check local state transition correctness before blaming the transport layer.

## Install

```bash
npm install @bananapus/suckers-v6
```

## Development

```bash
npm install
forge build
forge test
```

Useful scripts:

- `npm run deploy:mainnets`
- `npm run deploy:testnets`
- `npm run analyze`

## Deployment Notes

This package supports multiple bridge families and is intentionally split into bridge-specific deployers. It is commonly used directly and through the Omnichain and Revnet deployer packages.

## Repository Layout

```text
src/
  bridge implementations
  JBSucker.sol
  JBSuckerRegistry.sol
  deployers/
  enums/
  interfaces/
  libraries/
  structs/
  utils/
test/
  unit, fork, interoperability, attack, audit, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks And Notes

- out-of-order root delivery can make some claims unclaimable until an operator uses an emergency path
- bridge-specific transport assumptions matter as much as the shared sucker logic
- token mapping and deprecation controls are governance-sensitive surfaces
- a bridge that stays live operationally still may not be economically safe for every asset or chain pair

When debugging a bad cross-chain outcome, first decide whether the failure is in claim construction, message transport, inbox/outbox root progression, or remote settlement. Those are different bug classes.
