# Security Considerations

## [INTEROP-6] Cross-Chain Accounting Mismatch: NATIVE_TOKEN Semantic Divergence

**Severity:** Medium
**Status:** Acknowledged — by design, not fixable without oracle dependencies

### Description

`JBConstants.NATIVE_TOKEN` represents different real-world assets on different chains:

| Chain | Native Token | Value |
|-------|-------------|-------|
| Ethereum, Optimism, Base, Arbitrum | ETH | ~$X |
| Celo | CELO | ~$Y |
| Polygon | MATIC | ~$Z |

When a project deploys suckers that map `NATIVE_TOKEN → NATIVE_TOKEN` across chains where the native token differs, the protocol treats different assets as equivalent. There is no on-chain mechanism that distinguishes ETH from CELO at the sucker level.

### How Suckers Bridge Tokens

1. Source chain: sucker wraps `NATIVE_TOKEN` → WETH (via `CCIPHelper.wethOfChain()`)
2. CCIP bridges the WETH to the destination chain
3. Destination chain: sucker unwraps WETH → `NATIVE_TOKEN`

On ETH-native chains (Ethereum, OP, Base, Arbitrum), this works correctly because WETH wraps/unwraps ETH.

On Celo, `NATIVE_TOKEN` is CELO. The sucker would attempt to wrap CELO into WETH, which is a different operation — WETH on Celo (`0xD221812de1BD094f35587EE8E174B07B6167D9Af`) wraps ETH bridged to Celo, not CELO itself.

### Impact

1. **Issuance mispricing** — Payments in CELO through a `NATIVE_TOKEN` terminal are priced as ETH-equivalent without a CELO/ETH price feed.
2. **Sucker bridging failure** — `NATIVE_TOKEN → NATIVE_TOKEN` mapping causes the CCIP sucker to attempt incompatible token operations.
3. **Surplus fragmentation** — Cash-out bonding curve on each chain only sees that chain's surplus. Users must bridge project tokens to the chain with more surplus to get fair cash-out values.

### Why the Matching Hash Doesn't Catch This

The REVDeployer matching hash (used to verify both sides of a sucker deployment match) includes economic parameters (baseCurrency, stages, issuance, cash-out tax) but does NOT include terminal configurations, accounting contexts, or token mappings. Two deployments can produce identical hashes with incompatible asset configurations.

### Recommended Mitigation (Operational)

For non-ETH-native chains (Celo, Polygon, Avalanche, BNB Chain):

1. **Use WETH (ERC20) as the accounting context** — not `NATIVE_TOKEN`. This avoids the semantic ambiguity about what "native" means.
2. **Set sucker token mappings as `WETH → WETH`** (ERC20 to ERC20) — not `NATIVE_TOKEN → NATIVE_TOKEN`.
3. **Use USDC as a second accounting context** — USDC is the same asset cross-chain, no conversion needed.
4. **Ensure `JBPrices` has working price feeds** for accepted tokens on each chain.

### Safe Chains (ETH-native)

OP Stack L2s where native token IS ETH are unaffected: Ethereum, Optimism, Base, Arbitrum.

### Affected Chains

Any chain where the native token is not ETH: Celo (CELO), Polygon (MATIC), Avalanche (AVAX), BNB Chain (BNB).
