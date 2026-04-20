# User Journeys

## Repo Purpose

This repo lets a Juicebox project move a claimable position from one chain to another.

## Primary Actors

- users bridging project positions
- operators relaying roots and managing emergency or deprecation flows
- auditors checking Merkle progression and token mapping correctness

## Journey 1: Prepare And Relay A Claim

**Actor:** user or relayer.

**Intent:** burn locally and make the position claimable remotely.

**Main Flow**
1. A user calls `prepare`.
2. The claim enters the local outbox tree.
3. A relayer sends the current root to the peer chain with `toRemote`.

## Journey 2: Claim Remotely

**Actor:** claimant.

**Intent:** prove inclusion on the remote chain and mint the corresponding position.

**Main Flow**
1. Fetch a proof against the current inbox root.
2. Call the remote claim path.
3. The remote side verifies the proof and recreates the intended position.

## Journey 3: Use Emergency Or Deprecation Paths

**Actor:** operator or project authority.

**Intent:** recover from broken or deprecated bridge conditions.

**Main Flow**
1. Enable the relevant emergency or deprecation path.
2. Stop relying on the broken route.
3. Recover only through the allowed recovery surface.

## Trust Boundaries

- shared claim logic and transport behavior are separate concerns
- non-atomic cross-chain flows are normal, not exceptional

