# nana-suckers-v5

Cross-chain bridging for Juicebox V5 projects. Suckers let users burn project tokens on one chain and receive the same amount on another, moving the backing funds across via merkle-tree-based claims and chain-specific bridges.

_If you're having trouble understanding this contract, take a look at the [core protocol contracts](https://github.com/Bananapus/nana-core) and the [documentation](https://docs.juicebox.money/) first. If you have questions, reach out on [Discord](https://discord.com/invite/ErQYmth4dS)._

## What are Suckers?

Suckers bridge project tokens and backing funds across EVM chains. They are deployed in pairs — one on each network — and use merkle trees to track claims. When a user wants to move tokens from Chain A to Chain B:

1. **Prepare**: The user calls `prepare(...)` on Chain A's sucker, which burns their project tokens, cashes them out for terminal tokens, and inserts a claim into the outbox merkle tree.
2. **Bridge**: Anyone calls `toRemote(token)` to bridge the outbox tree and funds to the peer chain.
3. **Claim**: On Chain B, the user provides a merkle proof to `claim(...)`, which mints project tokens and adds the bridged funds to the project's balance.

Each sucker maintains two merkle trees per supported terminal token: an **outbox tree** (local claims waiting to bridge) and an **inbox tree** (claims bridged from the peer chain). Trees are append-only — bridging updates the remote inbox with the latest root.

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

## Launching Suckers

Requirements for deploying a sucker pair:

1. **Projects on both chains.** Project IDs don't have to match.
2. **100% cash out rate.** Both projects must have `cashOutTaxRate` of `JBConstants.MAX_CASH_OUT_TAX_RATE` so suckers can fully cash out project tokens for terminal tokens.
3. **Owner minting enabled.** Both projects must have `allowOwnerMinting` set to `true` so suckers can mint bridged project tokens.
4. **ERC-20 project token.** Both projects must have a deployed ERC-20 token (via `JBController.deployERC20For(...)`).

Deploy through `JBSuckerRegistry.deploySuckersFor(...)` on each chain. The registry needs `MAP_SUCKER_TOKEN` permission (ID 28) to map local tokens to remote tokens. The deployed sucker needs `MINT_TOKENS` permission (ID 9) to mint bridged tokens.

**For suckers to be peers, the `salt` must match on both chains and the same address must call `deploySuckersFor(...)` on each chain.**

## Managing Suckers

### Disable a token

If a bridge change affects only certain tokens, call `mapToken(...)` with `remoteToken` set to `address(0)` to disable that token. If the bridge won't allow a final transfer, activate the `EmergencyHatch` for affected tokens. The emergency hatch lets depositors withdraw their funds on the chain where they deposited. Once opened for a token, that token can never be bridged by this sucker again (deploy a new sucker instead).

### Deprecate the suckers

If the bridging infrastructure will no longer work, deprecate the sucker to begin shutdown. After a minimum duration (implementation-dependent, ensures no funds/roots are lost in transit), all tokens allow exit through the `EmergencyHatch` and no new messages are accepted. This protects against future fake/malicious bridge messages.

When deprecating, ensure no pending bridge messages need retrying — once deprecation completes, those messages will be rejected.

**Always perform these actions on BOTH sides of the sucker pair.**

## Using the Relayer

Bridging from L2 to L1 on OP Stack networks requires extra steps (proving and finalizing the withdrawal). The [`bananapus-sucker-relayer`](https://github.com/Bananapus/bananapus-sucker-relayer) automates this using [OpenZeppelin Defender](https://www.openzeppelin.com/defender). Project creators set up a Defender account, configure a relayer, and fund it with ETH for gas.

## Resources

- [`MerkleLib`](src/utils/MerkleLib.sol) — Incremental merkle tree based on Nomad's implementation and the eth2 deposit contract.
- [`juicerkle`](https://github.com/Bananapus/juicerkle) — Service that returns available claims for a beneficiary (generates merkle proofs). Includes a Go merkle tree implementation.
- [`juicerkle-tester`](https://github.com/Bananapus/juicerkle-tester) — End-to-end bridging test: deploys projects, tokens, and suckers, then bridges between them.

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
