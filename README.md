# nana-suckers-v5

Cross-chain bridging for Juicebox V5 projects. Suckers let users burn project tokens on one chain and receive the same amount on another, moving the backing funds across via merkle-tree-based claims and chain-specific bridges.

## Architecture

| Contract | Description |
|----------|-------------|
| `JBSucker` | Abstract base. Manages outbox/inbox merkle trees, `prepare`/`toRemote`/`claim` lifecycle, token mapping, deprecation, and emergency hatch. Deployed as clones via `Initializable`. |
| `JBCCIPSucker` | Extends `JBSucker`. Bridges via Chainlink CCIP (`ccipSend`/`ccipReceive`). Supports any CCIP-connected chain. Handles native token wrapping/unwrapping. |
| `JBOptimismSucker` | Extends `JBSucker`. Bridges via OP Standard Bridge + OP Messenger. Supports Ethereum<->Optimism. |
| `JBBaseSucker` | Thin wrapper around `JBOptimismSucker` with Base chain IDs. Ethereum<->Base. |
| `JBArbitrumSucker` | Extends `JBSucker`. Bridges via Arbitrum Inbox + Gateway Router. Handles L1<->L2 retryable tickets. |
| `JBAllowanceSucker` | Abstract extension of `JBSucker`. Pulls backing assets via overflow allowance (`useAllowanceFeeless`) instead of cash-outs. |
| `JBSuckerRegistry` | Tracks all suckers per project. Manages deployer allowlist. Entry point for `deploySuckersFor`. |
| `JBSuckerDeployer` | Abstract base deployer. Clones a singleton sucker via `LibClone.cloneDeterministic` and initializes it. |
| `JBCCIPSuckerDeployer` | Deployer for `JBCCIPSucker`. Stores CCIP router, remote chain ID, and chain selector. |
| `JBOptimismSuckerDeployer` | Deployer for `JBOptimismSucker`. Stores OP Messenger and OP Bridge addresses. |
| `JBBaseSuckerDeployer` | Thin wrapper around `JBOptimismSuckerDeployer` for Base. |
| `JBArbitrumSuckerDeployer` | Deployer for `JBArbitrumSucker`. Stores Arbitrum Inbox, Gateway Router, and layer (L1/L2). |
| `MerkleLib` | Incremental merkle tree (depth 32, modeled on eth2 deposit contract). Used for outbox/inbox trees. |
| `CCIPHelper` | CCIP router addresses, chain selectors, and WETH addresses per chain. |
| `ARBAddresses` | Arbitrum bridge contract addresses (Inbox, Gateway Router) for mainnet and Sepolia. |
| `ARBChains` | Arbitrum chain ID constants. |

## Bridging Flow

```
Chain A                              Chain B
  |                                    |
  |  1. prepare(tokenCount, ...)       |
  |     - transfers project tokens     |
  |     - cashes out for terminal tkn  |
  |     - inserts leaf into outbox     |
  |                                    |
  |  2. toRemote(token)                |
  |     - sends merkle root + funds -->|
  |                                    |
  |                          3. fromRemote(root)
  |                             - updates inbox tree
  |                                    |
  |                          4. claim(proof)
  |                             - verifies merkle proof
  |                             - mints project tokens
  |                             - adds funds to balance
```

## Install

```bash
npm install @bananapus/suckers-v5
```

Or with forge:

```bash
forge install Bananapus/nana-suckers-v5
```

## Develop

Prerequisites: [Node.js](https://nodejs.org/) (>=20) and [Foundry](https://github.com/foundry-rs/foundry).

```bash
npm ci && forge install
```

| Command | Description |
|---------|-------------|
| `forge build` | Compile contracts |
| `forge test` | Run tests |
| `forge test -vvvv` | Run tests with full traces |
| `forge fmt` | Lint |
| `forge coverage` | Generate test coverage report |
| `forge build --sizes` | Get contract sizes |
| `forge clean` | Remove build artifacts and cache |
