# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Registry-managed sucker deployment plus project-local bridge mapping, deprecation, and safety control |
| Control posture | Mixed registry-owner, project-owner, and one-time deployer-configurator control |
| Highest-risk actions | Wrong token mapping, emergency hatch activation, unsafe deprecation handling, and misconfigured bridge constants |
| Recovery posture | Recovery usually means replacement sucker paths or deployers rather than in-place reversal |

## Purpose

`nana-suckers-v6` has a layered control plane: registry ownership, project-local permissioned actions, and one-time deployer configuration for each bridge family. The most dangerous admin actions are token mapping, deprecation, emergency hatch activation, and deployer bridge-constant setup.

## Control Model

- `JBSuckerRegistry` is globally `Ownable`.
- Project-local authority flows through `JBPermissions`.
- `MAP_SUCKER_TOKEN`, `DEPLOY_SUCKERS`, `SUCKER_SAFETY`, and `SET_SUCKER_DEPRECATION` are the critical project-level permissions.
- Bridge deployers have a one-time configurator role for singleton and chain constants.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Registry owner | `Ownable(initialOwner)` | Global | Controls approved deployers and global `toRemoteFee` |
| Project owner | `JBProjects.ownerOf(projectId)` | Per project | May delegate project-local sucker permissions |
| Project operator | `JBPermissions` grant | Per project | Typically `DEPLOY_SUCKERS`, `MAP_SUCKER_TOKEN`, `SUCKER_SAFETY`, `SET_SUCKER_DEPRECATION` |
| Deployer configurator | Constructor `configurator` | Per deployer | One-time setup role for chain constants and singleton |

## Privileged Surfaces

| Contract | Function | Who Can Call | Effect |
| --- | --- | --- | --- |
| `JBSuckerRegistry` | `allowSuckerDeployer(...)`, `removeSuckerDeployer(...)`, `setToRemoteFee(...)` | Registry owner | Controls global deployer allowlist and fee |
| `JBSuckerRegistry` | `deploySuckersFor(...)` | Project owner or `DEPLOY_SUCKERS` delegate | Deploys sucker pairs for a project |
| `JBSucker` | `mapToken(...)`, `mapTokens(...)` | Project owner or `MAP_SUCKER_TOKEN` delegate | Sets or disables token mappings |
| `JBSucker` | `enableEmergencyHatchFor(...)` | Project owner or `SUCKER_SAFETY` delegate | Irreversibly opens emergency exit for tokens |
| `JBSucker` | `setDeprecation(...)` | Project owner or `SET_SUCKER_DEPRECATION` delegate | Starts or cancels deprecation while allowed |
| `JBSuckerDeployer` variants | `configureSingleton(...)`, `setChainSpecificConstants(...)` | Configurator | One-time deployer setup |

## Immutable And One-Way

- Emergency hatch is irreversible for the affected token mapping.
- Deployer singleton and chain-constant setup are one-time.
- Deprecation becomes irreversible once the sucker reaches the disabled phase.
- Token mapping is constrained once outbox activity exists for that token.

## Operational Notes

- Map remote tokens carefully before meaningful bridge traffic accumulates.
- Use deprecation to create a controlled shutdown window instead of abrupt disablement.
- Treat emergency hatch as a last resort.
- Verify deployer singleton and chain constants before approving or using a deployer operationally.
- Treat fee-payment and bridge-send paths as best-effort in some variants; certain failures degrade into retained funds or local fallback claims rather than clean global rollback.

## Machine Notes

- Do not assume registry ownership implies control over project-local mapping or emergency actions.
- Treat `src/JBSucker.sol`, `src/JBSuckerRegistry.sol`, and `src/deployers/` as the minimum admin source set.
- If live leaves, token mappings, or deprecation phase disagree with the planned action, stop and re-evaluate the recovery path.
- If a sucker variant uses try/catch around fee payment or inbound swaps, inspect the variant-specific recovery behavior before assuming failed bridge-side actions fully reverted.

## Recovery

- The normal recovery path is a new sucker path or a new deployer, not trying to re-enable an unsafe one.
- Emergency-hatched tokens recover through the defined local exit flow.
- Bad bridge-constant configuration generally means replacement deployers or replacement sucker instances.
- Some failure modes intentionally preserve liveness over strict rollback, so recovery may mean reconciling retained funds or retryable local claims rather than undoing the original send.

## Admin Boundaries

- Registry owners cannot override project-local mapping or safety decisions directly.
- Project operators cannot reverse an emergency hatch.
- Project operators cannot force already sent leaves through the emergency hatch path.
- Nobody can mutate constructor immutables on live suckers or deployers.

## Source Map

- `src/JBSucker.sol`
- `src/JBSuckerRegistry.sol`
- `src/deployers/`
- `src/utils/MerkleLib.sol`
- `test/`
