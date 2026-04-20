# User Journeys

## Repo Purpose

This repo bridges Juicebox project-token positions and their treasury-backed claim semantics across chains.
It is not a generic proxy terminal and not a generic ERC-20 bridge. The important unit is the project position and the
explicit bridge lifecycle around `prepare`, `toRemote`, and claim.

## Primary Actors

- projects that want canonical cross-chain movement of project-token positions
- operators deploying and registering sucker pairs on supported bridge families
- users bridging a project position from one chain to another
- teams responsible for bridge fees, token mappings, deprecation, and emergency controls

## Key Surfaces

- `JBSucker`: shared base lifecycle for preparing, relaying, and claiming bridge leaves
- `JBSuckerRegistry`: registry for sucker deployments, deployer allowlists, and shared fee settings
- `JBOptimismSucker`, `JBBaseSucker`, `JBCeloSucker`, `JBArbitrumSucker`, `JBCCIPSucker`, `JBSwapCCIPSucker`: bridge-family implementations

## Journey 1: Launch A Cross-Chain Sucker Pair For A Project

**Actor:** operator or deployer.

**Intent:** deploy and register the paired bridge surfaces a project will rely on across chains.

**Preconditions**
- the project exists on multiple chains or plans to
- the team has chosen the bridge family it trusts

**Main Flow**
1. Choose the chain-specific sucker implementation and deployer, such as Arbitrum, OP Stack, Celo, or CCIP.
2. Configure token mappings, bridge counterparties, and per-project registry state in `JBSuckerRegistry`.
3. Deploy the pair so each side knows its remote peer and expected transport assumptions.
4. Frontends and operators can now reason about the bridge as a known project surface instead of ad hoc per-transfer logic.

**Failure Modes**
- paired deployments disagree about counterparties or token mappings
- teams deploy the right contracts but never register the resulting pair coherently

**Postconditions**
- paired suckers are deployed, registered, and ready to transport claims between the chains they serve

## Journey 2: Bridge A Position From One Chain To Another

**Actor:** user bridging a position.

**Intent:** move project-token exposure from the source chain to the destination chain.

**Preconditions**
- a user holds project-token exposure on the source chain
- the project has a supported destination-side sucker path

**Main Flow**
1. The user calls `prepare` on the source-chain sucker to burn or lock the relevant local position into a claimable leaf.
2. The source sucker appends that leaf into its Merkle outbox tree.
3. Someone relays the new root to the remote chain using `toRemote`.
4. The claimant proves inclusion against the remote inbox tree and receives the recreated project-token position there.

**Failure Modes**
- token mappings are wrong for the project or chain pair
- transport-layer fees are missing and roots never arrive
- operators assume the bridge is generic ERC-20 transport rather than project-position transport

**Postconditions**
- the source position becomes a claim, the claim is relayed, and the destination position is minted after proof verification

## Journey 3: Map Treasury Assets And Project Tokens Correctly Across Chains

**Actor:** operator mapping assets and wrappers.

**Intent:** preserve economic meaning across chains instead of bridging into the wrong wrapped exposure.

**Preconditions**
- the project supports multiple assets or wrappers across chains
- users should be able to bridge without silent economic mismatch

**Main Flow**
1. Configure remote token metadata and mapping with the sucker pair.
2. Make sure the destination chain can mint or settle the project-token representation the bridge expects.
3. Audit chain-specific native-asset handling, especially on Celo or other non-identical environments.

**Failure Modes**
- local and remote wrappers look similar but settle into different economics
- chain-specific native-asset assumptions are copied across environments where they do not hold

**Postconditions**
- the remote claim recreates the intended exposure instead of a superficially similar but economically different asset

## Journey 4: Operate The Bridge Safely Over Time

**Actor:** bridge operator.

**Intent:** keep registry config, fees, deprecation, and bridge-family assumptions coherent after launch.

**Preconditions**
- the bridge is live and now needs operational stewardship rather than just deployment

**Main Flow**
1. Use `JBSuckerRegistry` to manage deployer allowlists and shared operational config.
2. Watch fee fallback paths and transport assumptions because delivery failure is part of the intended threat model.
3. Use deprecation or emergency surfaces when a bridge family or remote destination should no longer be used.

**Failure Modes**
- fee policy drifts from actual transport costs and claims stop delivering
- bridge-family deprecation is delayed even after counterparties or fees become unsafe

**Postconditions**
- fee policy, deprecation, trusted counterparties, and emergency paths remain coherent as conditions change

## Journey 5: Recover Value Through The Emergency Hatch When Normal Delivery Breaks

**Actor:** user or responder handling a broken delivery path.

**Intent:** recover value when the normal bridge delivery path is unavailable.

**Preconditions**
- a claim cannot complete through the normal inbox or remote-delivery path

**Main Flow**
1. Enable or enter the emergency mode the sucker pair exposes for the affected path.
2. Use `exitThroughEmergencyHatch(...)` with the relevant claim data.
3. Treat emergency execution slots as distinct state that still must not allow the same economic position to be claimed twice.

**Failure Modes**
- teams use the emergency path prematurely instead of as a documented recovery mode
- claim state is not checked carefully and responders risk inconsistent double-claim assumptions

**Postconditions**
- users can recover through the explicit emergency mechanism without double-spending the same claim

## Trust Boundaries

- this repo trusts both the shared sucker accounting logic and the selected bridge-family transport
- token mapping and registry governance are part of the economic safety model
- emergency and deprecation controls are operationally important, not just last-resort tooling

## Hand-Offs

- Use [nana-omnichain-deployers-v6](../nana-omnichain-deployers-v6/USER_JOURNEYS.md) when a project wants suckers packaged into its launch flow instead of deployed separately.
- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) or [revnet-core-v6](../revnet-core-v6/USER_JOURNEYS.md) for the treasury and runtime project behavior that suckers transport across chains.
