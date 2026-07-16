# User Journeys

## Repo purpose

This repo lets a Juicebox project move a claimable project-token position from one chain to another. It owns the bridge-facing lifecycle around prepare, relay, claim, deprecation, and emergency recovery; it does not make bridge counterparties trustless.

## Primary actors

- holders bridging project-token positions
- relayers sending accepted roots or accounting snapshots to peer chains
- project owners and delegates managing token mappings and recovery paths
- registry operators managing deployer allowlists, owner-gated token-pair approvals, and shared fees
- auditors checking Merkle progression, peer authentication, and bridge-specific delivery

## Key surfaces

- `JBSucker`: shared bridge lifecycle and project accounting
- `JBSuckerRegistry`: deployment inventory, owner-gated token-pair approvals, fees, and aggregate remote-state views
- chain-specific suckers and deployers: transport authentication, gas, fee, and peer wiring
- `MerkleLib` and `JBSuckerLib`: proof and snapshot helpers used by runtime paths

## Journey 1: Prepare a cross-chain claim

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

## Journey 2: Relay a root to the peer chain

**Actor:** relayer or any account willing to pay transport costs.

**Intent:** deliver the current outbox root and transported backing value to the remote sucker.

**Preconditions**
- at least one prepared claim exists for the token
- transport-specific fee and gas requirements are satisfied
- the peer sucker and token mapping match the intended destination

**Main Flow**
1. A caller invokes `toRemote(...)` for the mapped token.
2. The chain-specific implementation packages the root, value transfer, and a per-source-chain accounting gossip bundle (this chain's record plus every peer-chain record the project knows, gathered via the registry, excluding the destination chain) for its bridge.
3. The remote sucker authenticates the sender, records the inbox root if its freshness key is newer, and stores each bundle record whose source freshness key beats the one it already holds for that chain.

**Failure Modes**
- bridge messages are censored, delayed, underfunded, or malformed
- a stale root arrives after a newer root and is rejected
- asset transport succeeds while message execution must be retried through bridge-specific tooling

**Postconditions**
- the remote chain can verify claims against the accepted inbox root

## Journey 3: Refresh peer accounting

**Actor:** relayer, integration, or any account willing to pay transport costs.

**Intent:** propagate per-source-chain total supply, surplus, and balance across the sucker mesh without sending a new claim root.

**Preconditions**
- the sucker is still allowed to send outbound messages
- transport-specific fee and gas requirements are satisfied

**Main Flow**
1. A caller invokes `syncAccountingData()`.
2. The sucker builds a gossip bundle: its own chain's record (current project supply plus raw per-context surplus and balance) plus every peer-chain record the project knows, gathered via the registry, each stamped with its origin chain's freshness key and excluding the destination chain.
3. The chain-specific implementation sends only that accounting bundle to the peer.
4. The peer authenticates the sender and, per source chain, records each bundle record whose source freshness key is newer than the one it already holds (dropping records for its own chain and chain 0).

**Failure Modes**
- the bridge message is delayed, underfunded, or malformed
- a stale record for a given source chain arrives after a fresher root or accounting bundle and is ignored for that chain

**Postconditions**
- registry aggregate views can use the freshest record per source chain
- one sync round from a hub propagates every chain's accounting to every spoke
- token-local inbox roots and claimable value are unchanged

## Journey 4: Claim on the destination chain

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

## Journey 4a: Approve an owner-gated token route

**Actor:** registry operator.

**Intent:** let projects choose a native/native mapping or different-address local/remote token pair only after route review.

**Preconditions**
- the intended local and remote tokens have been checked for asset semantics, decimals, issuer risk, and terminal behavior
- the route's peer chain is known
- for an OP Stack or Arbitrum ERC-20 lane, the exact bridge-registered pair has been verified in both directions and the destination terminal accounts for the token the bridge actually delivers

**Main Flow**
1. The registry owner calls `allowTokenMapping(...)` or `allowTokenMappings(...)` for the exact `(localToken, remoteChainId, remoteToken)` route.
2. A project owner or delegate can then choose that mapping through `mapToken`, `mapTokens`, or deploy-time mappings.

**Failure Modes**
- approval is granted for the wrong peer chain
- a native/native route is assumed to be automatically safe even though the native sentinel may represent different assets
- a canonical ERC-20 is approved because it is economically equivalent even though the native bridge delivers or burns a different paired token
- governance approval is mistaken for an oracle guarantee of token value equivalence

**Postconditions**
- the approved route can be selected by projects; unrelated peer-chain routes remain unapproved

## Journey 5: Recover from a bad or deprecated bridge path

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

## Trust boundaries

- shared sucker logic and bridge-specific transport behavior are separate review surfaces
- non-atomic cross-chain delivery is normal and must be modeled explicitly
- registry aggregate views are estimates for discovery and dashboards, not settlement guarantees: they aggregate over every (sucker, chain) pair and dedup per source chain by the freshest accepted record, skipping any pair that reverts (so they bias low)
- accounting propagates as a per-source-chain gossip bundle across the project's own same-address sucker mesh; a record is only ever as trustworthy as its origin chain's own sucker, the same trust already extended to a directly-paired peer

## Hand-offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for local terminal, token, and cash-out accounting.
- Use [nana-omnichain-deployers-v6](../nana-omnichain-deployers-v6/USER_JOURNEYS.md) for higher-level multi-chain deployment orchestration.
