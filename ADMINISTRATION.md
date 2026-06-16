# Administration

## At a glance

| Item | Details |
| --- | --- |
| Scope | Cross-chain sucker deployment, token mapping, shared fees, deprecation, and emergency recovery |
| Control posture | Mixed registry-owner, project-permission, and bridge-counterparty trust |
| Highest-risk actions | Adding deployers, approving token pairs, mapping tokens, changing shared fees, deploying with wrong peers, and retiring lanes |
| Recovery posture | Conservative and often one-way once roots or transported assets are in flight |

## Purpose

`nana-suckers-v6` splits authority across the registry, project owners or delegates, and the selected bridge. Admin review should focus on whether a control can change economic equivalence between the local position and the remote claim.

## Control model

- registry owner controls deployer allowlists, owner-gated token-pair allowlists, and the shared `toRemoteFee`
- project permissions control token mapping, sucker deployment through the registry, deprecation, and emergency paths
- chain-specific deployers encode bridge addresses, peer-chain IDs, gas settings, and CCIP selectors
- bridge counterparties control message delivery guarantees outside this repo

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Registry owner | Registry ownership | Global | Adds/removes deployers, approves owner-gated token pairs, and sets shared fees |
| Project owner/delegate | Juicebox permissions | Per project | Maps tokens, deploys suckers, and uses recovery controls |
| Sucker deployer | Registry allowlist | Per bridge family | Creates configured sucker pairs |
| Relayer | Permissionless caller | Per send | Pays transport costs and triggers root delivery |
| Bridge counterparty | External protocol | Per transport | Authenticates and delivers messages/assets |

## Privileged surfaces

- `JBSuckerRegistry.allowSuckerDeployer(...)`
- `JBSuckerRegistry.allowTokenMapping(...)`
- `JBSuckerRegistry.allowTokenMappings(...)`
- `JBSuckerRegistry.removeTokenMapping(...)`
- `JBSuckerRegistry.removeTokenMappings(...)`
- `JBSuckerRegistry.setToRemoteFee(...)`
- `JBSuckerRegistry.deploySuckersFor(...)`
- `JBSucker.mapToken(...)`
- `JBSucker.setDeprecation(...)`
- `JBSucker.enableEmergencyHatchFor(...)`
- `JBSuckerRegistry.removeDeprecatedSucker(...)`

## Immutable and one-way

- Token mappings become hard to change safely after outbox activity exists.
- Native/native mappings and different-address local/remote token mappings require registry-owner approval for the specific `(localToken, remoteChainId, remoteToken)` route before a project can choose them.
- Sucker peer addresses and bridge configuration are deployment-time assumptions.
- Deprecation is designed to stop new sends without blocking historical claims.
- Removing a deprecated sucker from active listings does not erase its historical aggregate relevance.

## Operational notes

- Map tokens only after checking both local and remote token semantics, decimals, terminal behavior, and any required route-specific registry approval. Non-native same-address mappings and disabled mappings bypass the owner allowlist; native/native mappings do not, because the native sentinel can represent different assets on different chains.
- Deprecate both sides of a pair with matching timestamps and enough messaging-delay margin.
- Treat CCIP LINK-fee mode and native-fee mode as different operational flows.
- Verify bridge-specific gas and calldata sizing against the real transport API.
- Do not treat `totalRemoteBalanceOf`, `totalRemoteSurplusOf`, or `remoteTotalSupplyOf` as exact settlement data: they aggregate over every (sucker, chain) pair and report the freshest accepted record per source chain, silently skipping any pair that reverts — trust them only when every source chain is independently confirmed healthy and fresh.

## Machine notes

- Start with `JBSuckerRegistry` for inventory, deployer, fee, and aggregate-view questions.
- Start with `JBSucker` for prepare, claim, token mapping, deprecation, and emergency behavior.
- Always pair a chain-specific implementation with its deployer before making deployment claims.
- If a bridge problem is reported, separate transport authentication from shared Merkle/accounting behavior before summarizing.

## Recovery

- Emergency hatch paths exist to recover from invalid or stranded claim conditions.
- Deprecation stops new outbound sends after the delay boundary while preserving claims already sent.
- Broken deployment wiring usually requires a new sucker pair and registry migration, not in-place repair.

## Admin boundaries

- Registry controls cannot make an external bridge honest or live.
- Project permissions cannot rewrite already-consumed claims.
- Bridge-specific deployers do not prove a lane is operationally supported for every chain the external bridge can theoretically reach.

## Source map

- `src/JBSuckerRegistry.sol`
- `src/JBSucker.sol`
- `src/deployers/`
- `src/interfaces/IJBSuckerRegistry.sol`
- `src/interfaces/IJBSuckerExtended.sol`
