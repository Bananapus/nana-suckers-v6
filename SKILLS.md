# Juicebox Suckers

## Use This File For

- Use this file when the task involves cross-chain project-token bridging, token mapping, Merkle claim flow, bridge-specific transport logic, or sucker registry behavior.
- Start here, then open the base sucker, registry, chain-specific implementation, or deployer depending on which leg of the bridge path is under review.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and bridge model | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Shared bridge logic | [`src/JBSucker.sol`](./src/JBSucker.sol), [`src/JBSuckerRegistry.sol`](./src/JBSuckerRegistry.sol) |
| Chain-specific transport behavior | [`src/`](./src/), [`src/deployers/`](./src/deployers/) |
| Merkle and helper logic | [`src/utils/`](./src/utils/), [`src/libraries/`](./src/libraries/) |
| Attack, interoperability, or regression coverage | [`test/`](./test/), [`test/regression/`](./test/regression/), [`test/fork/`](./test/fork/) |

## Repo Map

| Area | Where to look |
|---|---|
| Base contracts | [`src/JBSucker.sol`](./src/JBSucker.sol), [`src/JBSuckerRegistry.sol`](./src/JBSuckerRegistry.sol) |
| Chain-specific implementations and deployers | [`src/`](./src/), [`src/deployers/`](./src/deployers/) |
| Libraries, utils, and types | [`src/libraries/`](./src/libraries/), [`src/utils/`](./src/utils/), [`src/interfaces/`](./src/interfaces/), [`src/structs/`](./src/structs/), [`src/enums/`](./src/enums/) |
| Scripts | [`script/`](./script/) |
| Tests | [`test/`](./test/) |

## Purpose

Cross-chain bridge layer for Juicebox project tokens and the terminal assets that back them. Suckers package local burn or claim state into Merkle roots, relay those roots across bridge transports, and let users recreate the position on the remote chain.

## Reference Files

- Open [`references/runtime.md`](./references/runtime.md) when you need the base claim flow, registry role, token mapping model, or the main bridge invariants.
- Open [`references/operations.md`](./references/operations.md) when you need deployer and transport-selection guidance, deprecation and emergency behavior, or the common stale-data traps around bridge configuration.

## Working Rules

- Start in [`src/JBSucker.sol`](./src/JBSucker.sol) for shared accounting and claim flow, then move to the chain-specific implementation only after you know the base path is correct.
- Treat token mapping, root progression, and emergency/deprecation controls as first-class runtime behavior, not admin-only side tooling.
- When debugging a bridge incident, separate accounting correctness from transport correctness before patching.
- If a task touches project deployment shape, check whether the real source is `nana-omnichain-deployers-v6` or `revnet-core-v6` instead of the sucker implementation itself.
