# Juicebox Suckers

## Use This File For

- Use this file when the task involves cross-chain project-token bridging, token mapping, Merkle claim flow, bridge-specific transport logic, or sucker registry behavior.
- Start here, then decide whether the issue is in shared accounting, message authentication, token mapping, or operator/deprecation controls. Those concerns live in different layers.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and bridge model | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Shared bridge logic | [`src/JBSucker.sol`](./src/JBSucker.sol), [`src/JBSuckerRegistry.sol`](./src/JBSuckerRegistry.sol) |
| Chain-specific transport behavior | [`src/JBArbitrumSucker.sol`](./src/JBArbitrumSucker.sol), [`src/JBOptimismSucker.sol`](./src/JBOptimismSucker.sol), [`src/JBCCIPSucker.sol`](./src/JBCCIPSucker.sol), [`src/JBCeloSucker.sol`](./src/JBCeloSucker.sol) |
| Deployer and transport setup | [`src/deployers/`](./src/deployers/) |
| Merkle and helper logic | [`src/utils/`](./src/utils/), [`src/libraries/`](./src/libraries/) |
| Interop and chain-specific fork coverage | [`test/ForkMainnet.t.sol`](./test/ForkMainnet.t.sol), [`test/ForkArbitrum.t.sol`](./test/ForkArbitrum.t.sol), [`test/ForkCelo.t.sol`](./test/ForkCelo.t.sol), [`test/ForkOPStack.t.sol`](./test/ForkOPStack.t.sol), [`test/InteropCompat.t.sol`](./test/InteropCompat.t.sol) |
| Swap, claim, attack, and regression coverage | [`test/ForkSwap.t.sol`](./test/ForkSwap.t.sol), [`test/ForkClaimMainnet.t.sol`](./test/ForkClaimMainnet.t.sol), [`test/SuckerAttacks.t.sol`](./test/SuckerAttacks.t.sol), [`test/SuckerDeepAttacks.t.sol`](./test/SuckerDeepAttacks.t.sol), [`test/SuckerRegressions.t.sol`](./test/SuckerRegressions.t.sol), [`test/TestAuditGaps.sol`](./test/TestAuditGaps.sol) |

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
- `JBSucker` explicitly does not support fee-on-transfer or rebasing tokens. If a bug report involves those assets, treat it as an unsupported-path question first.
- Root progression, peer supply, and peer surplus snapshots are part of economic correctness, not just bridge bookkeeping.
- Token mapping is intentionally one-way after real activity starts. Disabling a mapping is allowed; remapping to a different remote asset is not.
- Peer symmetry depends on deployer and salt assumptions as well as runtime code. A bridge bug can start in deployment shape before it appears in message flow.
- Treat token mapping, root progression, and emergency/deprecation controls as first-class runtime behavior, not admin-only side tooling.
- When debugging a bridge incident, separate accounting correctness from transport correctness before patching.
- Message authentication is delegated to bridge-specific subclasses. When reviewing a new transport, `_isRemotePeer` is one of the first things to inspect.
- Emergency exit and deprecation behavior are intentionally conservative. Some failure modes lock funds rather than risking double-spend.
- If a task touches project deployment shape, check whether the real source is `nana-omnichain-deployers-v6` or `revnet-core-v6` instead of the sucker implementation itself.
