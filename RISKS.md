# nana-suckers-v6 — Risks

## Trust Assumptions

1. **Bridge Infrastructure** — Trusts OP Stack, Arbitrum, and CCIP bridges to deliver messages and tokens faithfully. Bridge compromise = fund loss.
2. **Remote Peer** — Each sucker trusts its configured remote peer (the sucker on the other chain). Root messages only accepted from authenticated peer.
3. **Project Owner** — Can deploy suckers, set token mappings, initiate deprecation, and enable emergency hatch. Full control over cross-chain configuration.
4. **Core Protocol** — Suckers mint tokens via JBController with special permission (0% cashout tax). Relies on controller to enforce supply rules.

## Known Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| Token mapping immutability | Once outbox tree has entries, token mapping cannot be changed (only disabled) | Verify mappings before first bridge operation |
| Emergency hatch abuse | Project owner can enable emergency hatch instantly (no timelock) to recover stuck tokens | Trust assumption on project owner |
| CCIP amount validation skip | Amount validation intentionally skipped (M-28) to prevent token lockup | Accepted risk to avoid permanent fund lock |
| Bridge liveness | If bridge goes down, tokens in transit are stuck until bridge recovers | Use deprecation lifecycle; emergency hatch for recovery |
| Surplus fragmentation | Cash-out bonding curve on each chain only sees that chain's surplus | Users must bridge to chain with more surplus for fair cash-out |

## INTEROP-6: Cross-Chain NATIVE_TOKEN Semantic Divergence

**Severity:** Medium
**Status:** Acknowledged — by design

`JBConstants.NATIVE_TOKEN` represents different real-world assets on different chains (ETH on Ethereum/OP/Base/Arbitrum, CELO on Celo, MATIC on Polygon). When a project maps `NATIVE_TOKEN → NATIVE_TOKEN` across chains where the native token differs, the protocol treats different assets as equivalent.

**Impact:**
- Issuance mispricing — payments in non-ETH native tokens priced as ETH without a price feed
- Sucker bridging failure — incompatible token operations on non-ETH chains
- Surplus fragmentation — bonding curve only sees local chain surplus

**Safe chains:** Ethereum, Optimism, Base, Arbitrum (all ETH-native)
**Affected chains:** Celo (CELO), Polygon (MATIC), Avalanche (AVAX), BNB Chain (BNB)

**Mitigation:** On non-ETH chains, use WETH ERC20 as accounting context and map `WETH → WETH` instead of `NATIVE_TOKEN → NATIVE_TOKEN`.

## Privileged Roles

| Role | Permission IDs | Scope |
|------|---------------|-------|
| Project owner | `DEPLOY_SUCKERS`, `MAP_SUCKER_TOKEN`, `SUCKER_SAFETY`, `SET_SUCKER_DEPRECATION` | Per-project |
| Remote peer | Sends merkle roots, triggers claims | Per-sucker-pair |
| Bridge messenger | Delivers cross-chain messages | Infrastructure |

## Deprecation Lifecycle
- `ENABLED` → `DEPRECATION_PENDING` → `SENDING_DISABLED` → `DEPRECATED`
- Each state progressively restricts operations
- No way to re-enable once deprecated (intentional)
