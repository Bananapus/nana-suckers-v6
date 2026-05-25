# User Journeys

## Repo Purpose

This repo lets a Juicebox project move a claimable project-token position from one chain to another. It owns the bridge-facing lifecycle around prepare, relay, claim, deprecation, and emergency recovery; it does not make bridge counterparties trustless.

## Primary Actors

- holders bridging project-token positions
- relayers sending accepted roots to peer chains
- project owners and delegates managing token mappings and recovery paths
- registry operators managing deployer allowlists and shared fees
- auditors checking Merkle progression, peer authentication, and bridge-specific delivery

## Key Surfaces

- `JBSucker`: shared bridge lifecycle and project accounting
- `JBSuckerRegistry`: deployment inventory, fees, and aggregate remote-state views
- chain-specific suckers and deployers: transport authentication, gas, fee, and peer wiring
- `MerkleLib` and `JBSuckerLib`: proof and snapshot helpers used by runtime paths

## Journey 1: Prepare A Cross-Chain Claim

**Actor:** holder.

**Intent:** burn or lock a local project-token position and make it claimable on the peer chain.

**Preconditions**
- the token is mapped for the sucker pair
- the holder understands the selected bridge's delay and failure model
- the sucker is not sending-disabled or fully deprecated

**Main Flow**
1. The holder calls `prepare(...)` with the project-token amount, destination beneficiary, mapped token, and minimum reclaim expectation.
2. The sucker cashes out locally and appends a claim leaf to the outbox Merkle tree.
3. The outbox balance and source snapshot update for the token being bridged.

**Failure Modes**
- token mapping is missing, disabled, or points at the wrong remote token
- local cash-out or terminal accounting reverts
- the caller underestimates bridge delay or remote claim requirements

**Postconditions**
- the position is queued in the local outbox and can be included in the next root sent to the peer

## Journey 2: Relay A Root To The Peer Chain

**Actor:** relayer or any account willing to pay transport costs.

**Intent:** deliver the current outbox root and transported backing value to the remote sucker.

**Preconditions**
- at least one prepared claim exists for the token
- transport-specific fee and gas requirements are satisfied
- the peer sucker and token mapping match the intended destination

**Main Flow**
1. A caller invokes `toRemote(...)` for the mapped token.
2. The chain-specific implementation packages the root, source snapshot, and value transfer for its bridge.
3. The remote sucker authenticates the sender and records the inbox root if its freshness key is newer.

**Failure Modes**
- bridge messages are censored, delayed, underfunded, or malformed
- a stale root arrives after a newer root and is rejected
- asset transport succeeds while message execution must be retried through bridge-specific tooling

**Postconditions**
- the remote chain can verify claims against the accepted inbox root

## Journey 3: Claim On The Destination Chain

**Actor:** claimant or integration acting for a claimant.

**Intent:** prove inclusion in the inbox tree and recreate the bridged position.

**Preconditions**
- the destination sucker accepted the relevant inbox root
- the claimant has the leaf data and Merkle proof
- the claim was not already consumed

**Main Flow**
1. The claimant submits the leaf and proof.
2. The sucker verifies the leaf against the current inbox state.
3. The claim is marked consumed, and the destination-side project-token position is minted or released.

**Failure Modes**
- proof is built against an old or wrong root
- source and destination token mappings do not describe the same economic asset
- destination-side accounting lacks the expected transported value

**Postconditions**
- the claim is consumed exactly once and the remote position is recreated for the beneficiary

## Journey 4: Recover From A Bad Or Deprecated Bridge Path

**Actor:** project authority, registry operator, or affected claimant.

**Intent:** stop new sends and preserve recovery for already-sent positions.

**Preconditions**
- a bridge lane is unsafe, broken, being migrated, or intentionally retired
- the project authority can use the relevant permissioned controls

**Main Flow**
1. Schedule deprecation on both sides with enough messaging-delay margin.
2. Stop relying on the deprecated lane for new sends once sending is disabled.
3. Keep claim and emergency paths available for value already in flight.
4. Remove deprecated suckers from active registry listings when the migration no longer needs them.

**Failure Modes**
- only one side is deprecated, leaving asymmetric send/claim expectations
- root delivery is delayed past operator assumptions
- dashboards treat best-effort aggregate views as exact reconciled state

**Postconditions**
- new sends use a safer lane, while historical claims remain recoverable through the allowed path

## Trust Boundaries

- shared sucker logic and bridge-specific transport behavior are separate review surfaces
- non-atomic cross-chain delivery is normal and must be modeled explicitly
- registry aggregate views are estimates for discovery and dashboards, not settlement guarantees

## Hand-Offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for local terminal, token, and cash-out accounting.
- Use [nana-omnichain-deployers-v6](../nana-omnichain-deployers-v6/USER_JOURNEYS.md) for higher-level multi-chain deployment orchestration.
