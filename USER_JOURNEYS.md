# User Journeys

## Who This Repo Serves

- projects that want canonical cross-chain movement of project-token positions
- operators deploying and registering sucker pairs on supported bridge families
- users bridging a project position from one chain to another
- teams responsible for bridge fees, token mappings, deprecation, and emergency controls

## Journey 1: Launch A Cross-Chain Sucker Pair For A Project

**Starting state:** the project exists on multiple chains or plans to, and the team has chosen the bridge family it trusts.

**Success:** paired suckers are deployed, registered, and ready to transport claims between the chains they serve.

**Flow**
1. Choose the chain-specific sucker implementation and deployer, such as Arbitrum, OP Stack, Celo, or CCIP.
2. Configure token mappings, bridge counterparties, and per-project registry state in `JBSuckerRegistry`.
3. Deploy the pair so each side knows its remote peer and expected transport assumptions.
4. Frontends and operators can now reason about the bridge as a known project surface instead of ad hoc per-transfer logic.

## Journey 2: Bridge A Position From One Chain To Another

**Starting state:** a user holds project-token exposure on the source chain and wants the corresponding position on the destination chain.

**Success:** the source position becomes a claim, the claim is relayed, and the destination position is minted after proof verification.

**Flow**
1. The user calls `prepare` on the source-chain sucker to burn or lock the relevant local position into a claimable leaf.
2. The source sucker appends that leaf into its Merkle outbox tree.
3. Someone relays the new root to the remote chain using `toRemote`.
4. The claimant proves inclusion against the remote inbox tree and receives the recreated project-token position there.

**Failure cases that matter:** wrong token mappings, transport-layer fee shortages, root ordering mistakes, and assuming the bridge is generic ERC-20 transport when it is really project-position transport.

## Journey 3: Map Treasury Assets And Project Tokens Correctly Across Chains

**Starting state:** the project supports multiple assets or wrappers across chains and wants users to bridge without silent economic mismatch.

**Success:** the remote claim recreates the intended exposure instead of a superficially similar but economically different asset.

**Flow**
1. Configure remote token metadata and mapping with the sucker pair.
2. Make sure the destination chain can mint or settle the project-token representation the bridge expects.
3. Audit chain-specific native-asset handling, especially on Celo or other non-identical environments.

## Journey 4: Operate The Bridge Safely Over Time

**Starting state:** the bridge is live and now needs operational stewardship rather than just deployment.

**Success:** fee policy, deprecation, trusted counterparties, and emergency paths remain coherent as conditions change.

**Flow**
1. Use `JBSuckerRegistry` to manage deployer allowlists and shared operational config.
2. Watch fee fallback paths and transport assumptions because delivery failure is part of the intended threat model.
3. Use deprecation or emergency surfaces when a bridge family or remote destination should no longer be used.

## Journey 5: Recover Value Through The Emergency Hatch When Normal Delivery Breaks

**Starting state:** a claim cannot complete through the normal inbox or remote-delivery path.

**Success:** users can recover through the explicit emergency mechanism without double-spending the same claim.

**Flow**
1. Enable or enter the emergency mode the sucker pair exposes for the affected path.
2. Use `exitThroughEmergencyHatch(...)` with the relevant claim data.
3. Treat emergency execution slots as distinct state that still must not allow the same economic position to be claimed twice.

## Hand-Offs

- Use [nana-omnichain-deployers-v6](../nana-omnichain-deployers-v6/USER_JOURNEYS.md) when a project wants suckers packaged into its launch flow instead of deployed separately.
- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) or [revnet-core-v6](../revnet-core-v6/USER_JOURNEYS.md) for the treasury and runtime project behavior that suckers transport across chains.
