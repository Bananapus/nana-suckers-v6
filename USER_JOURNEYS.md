# User Journeys

## Who This Repo Serves

- project teams offering cross-chain mobility for their token holders
- holders moving exposure from one chain to another
- operators managing bridge lifecycle, token mappings, and emergency controls

## Journey 1: Launch A Cross-Chain Sucker Pair For A Project

**Starting state:** the project exists on the relevant chains and the team knows which bridge family fits that chain pair.

**Success:** holders can use registry-tracked sucker deployments to move supported project exposure between chains.

**Flow**
1. Deploy the appropriate bridge-specific suckers through an allowed deployer and track them in `JBSuckerRegistry`.
2. Verify the peer relationships and chain pairing the registry now reports.
3. Configure token mappings for the chain pair.
4. Verify the lifecycle controls before exposing the bridge publicly.

**Bridge choice matters:** OP-stack, Arbitrum, CCIP, and chain-specific variants do not share identical transport assumptions.

## Journey 2: Bridge From One Chain To Another

**Starting state:** the bridge pair is live and the token the user wants to move is mapped.

**Success:** the user exits on the source chain and receives the corresponding position on the destination chain.

**Flow**
1. On the source chain, call `prepare(...)` to burn or redeem into the bridgeable claim and append it to the outbox tree.
2. Relay the current root to the peer chain with `toRemote(...)`.
3. On the destination chain, call `claim(...)` with the proof against the imported inbox root.
4. The destination sucker verifies the claim and mints or releases the remote-side representation.

## Journey 3: Operate The Bridge Safely Over Time

**Starting state:** the bridge is live and real users depend on it.

**Success:** operators can respond to changing risk without corrupting prior claims.

**Flow**
1. Disable token mappings when an asset should stop being bridgeable.
2. Deprecate a sucker when the bridge path should shut down for new use.
3. Use emergency or recovery paths if root ordering or transport failures leave claims temporarily stuck.
4. Communicate bridge-family-specific downtime or economic risk clearly, because transport liveness is not the same as asset safety.

## Hand-Offs

- Use [nana-omnichain-deployers-v6](../nana-omnichain-deployers-v6/USER_JOURNEYS.md) or [revnet-core-v6](../revnet-core-v6/USER_JOURNEYS.md) when suckers are part of a larger deployment flow rather than a standalone bridge setup.
