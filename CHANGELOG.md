# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. It compares `nana-suckers-v5` in `../../v5/evm` with the current `nana-suckers-v6` repo.

## Current V6 Surface

- `JBSucker`
- `JBSuckerRegistry`
- chain-specific sucker and deployer contracts for Arbitrum, Base, CCIP, and Optimism
- sucker interfaces, libraries, and structs under `src/`
- archived Celo and swap-CCIP implementations under `src/archive`

## Summary

- Remote identifiers moved from `address` to `bytes32` for cross-VM compatibility. This affects peer addresses, beneficiaries, and remote-token data.
- Cross-chain message payloads are versioned and carry explicit metadata. Leaf hashes and event payloads are not V5-compatible.
- Remote surplus and balance aggregation moved toward registry-level, per-context reads. Suckers expose raw peer-chain contexts; the registry values and deduplicates them.
- The registry adds a global `toRemoteFee`, all-sucker lookup, and remote total balance/surplus helpers.
- Claim batching is more resilient. A failed leaf can emit `ClaimFailed` while other leaves continue.
- Explicit sucker peer configuration is permission-sensitive in V6.

## ABI, Event, and Error Changes

- Changed functions:
  - `peer()` returns `bytes32` instead of `address`.
  - `prepare(...)` accepts a `bytes32 beneficiary`.
  - `deploySuckersFor(...)` uses the V6 deployer config with `bytes32` peer fields.
- Added functions:
  - `executedLeafHashOf(address,uint256)`
  - `allSuckersOf(uint256)`
  - `peerChainContextsOf()`
  - `peerChainTotalSupplyValue()`
  - `snapshotTimestamp()`
  - `toRemoteFee()`
  - `setToRemoteFee(uint256)`
  - `totalRemoteBalanceOf(uint256,uint256,uint256)`
  - `totalRemoteSurplusOf(uint256,uint256,uint256)`
- Removed or no-longer-primary V5 assumptions:
  - `ADD_TO_BALANCE_MODE()` is not part of the current minimal sucker interface.
  - V5 `address` beneficiary/peer decoding is invalid for V6 leaves.
- Changed events:
  - `Claimed` uses `bytes32 beneficiary` and adds `bytes32 metadata`.
  - `InsertToOutboxTree` uses `bytes32 beneficiary` and adds `bytes32 metadata`.
  - registry deployment/fee events include current V6 config and caller fields.
- Added events:
  - `ClaimFailed`
  - `StaleRootRejected`
  - `ToRemoteFeeChanged`
- Structs to regenerate:
  - `JBClaim`
  - `JBLeaf`
  - `JBMessageRoot`
  - `JBRemoteToken`
  - `JBTokenMapping`
  - `JBSuckerDeployerConfig`
  - `JBPeerChainContext`
  - `JBPeerChainValue`
  - `JBSourceContext`

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts, filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: `nana-suckers-v5`.
- Own-source ABI artifacts compared: V6 `52`, V5 `31`.
- Contract/interface coverage: `21` added, `0` removed, `17` shared names with ABI changes, `14` shared names ABI-identical.
- Shared-name ABI item deltas: `342` added, `160` removed, `19` modified.

Added V6 ABI artifacts:
- `IGeomeanOracle` from `src/interfaces/IGeomeanOracle.sol`: `1` functions, `0` events, `0` errors.
- `IJBPeerChainAdjustedAccounts` from `src/interfaces/IJBPeerChainAdjustedAccounts.sol`: `1` functions, `0` events, `0` errors.
- `IL1ArbitrumGateway` from `src/interfaces/IL1ArbitrumGateway.sol`: `1` functions, `0` events, `0` errors.
- `JBCCIPLib` from `src/libraries/JBCCIPLib.sol`: `1` functions, `0` events, `1` errors.
- `JBClaim` from `src/structs/JBClaim.sol`: `0` functions, `0` events, `0` errors.
- `JBInboxTreeRoot` from `src/structs/JBInboxTreeRoot.sol`: `0` functions, `0` events, `0` errors.
- `JBLayer` from `src/enums/JBLayer.sol`: `0` functions, `0` events, `0` errors.
- `JBLeaf` from `src/structs/JBLeaf.sol`: `0` functions, `0` events, `0` errors.
- `JBMessageRoot` from `src/structs/JBMessageRoot.sol`: `0` functions, `0` events, `0` errors.
- `JBOutboxTree` from `src/structs/JBOutboxTree.sol`: `0` functions, `0` events, `0` errors.
- `JBPeerChainContext` from `src/structs/JBPeerChainContext.sol`: `0` functions, `0` events, `0` errors.
- `JBPeerChainValue` from `src/structs/JBPeerChainValue.sol`: `0` functions, `0` events, `0` errors.
- `JBRelayBeneficiary` from `src/libraries/JBRelayBeneficiary.sol`: `0` functions, `0` events, `0` errors.
- `JBRemoteToken` from `src/structs/JBRemoteToken.sol`: `0` functions, `0` events, `0` errors.
- `JBSourceContext` from `src/structs/JBSourceContext.sol`: `0` functions, `0` events, `0` errors.
- `JBSuckerDeployerConfig` from `src/structs/JBSuckerDeployerConfig.sol`: `0` functions, `0` events, `0` errors.
- `JBSuckerLib` from `src/libraries/JBSuckerLib.sol`: `3` functions, `0` events, `0` errors.
- `JBSuckerState` from `src/enums/JBSuckerState.sol`: `0` functions, `0` events, `0` errors.
- `JBSuckersPair` from `src/structs/JBSuckersPair.sol`: `0` functions, `0` events, `0` errors.
- `JBTokenMapping` from `src/structs/JBTokenMapping.sol`: `0` functions, `0` events, `0` errors.
- `PeerValueScratch` from `src/structs/PeerValueScratch.sol`: `0` functions, `0` events, `0` errors.

Shared ABI artifacts with changes:
- `CCIPHelper`: `21` added, `0` removed, `0` modified ABI items.
- `IJBSucker`: `15` added, `10` removed, `2` modified ABI items.
- `IJBSuckerDeployer`: `1` added, `7` removed, `0` modified ABI items.
- `IJBSuckerExtended`: `27` added, `11` removed, `2` modified ABI items.
- `IJBSuckerRegistry`: `10` added, `2` removed, `0` modified ABI items.
- `JBArbitrumSucker`: `43` added, `19` removed, `3` modified ABI items.
- `JBArbitrumSuckerDeployer`: `6` added, `6` removed, `0` modified ABI items.
- `JBBaseSucker`: `43` added, `19` removed, `3` modified ABI items.
- `JBBaseSuckerDeployer`: `6` added, `6` removed, `0` modified ABI items.
- `JBCCIPSucker`: `49` added, `20` removed, `3` modified ABI items.
- `JBCCIPSuckerDeployer`: `6` added, `7` removed, `0` modified ABI items.
- `JBOptimismSucker`: `43` added, `19` removed, `3` modified ABI items.
- `JBOptimismSuckerDeployer`: `6` added, `6` removed, `0` modified ABI items.
- `JBSucker`: `43` added, `19` removed, `2` modified ABI items.
- `JBSuckerDeployer`: `6` added, `6` removed, `0` modified ABI items.
- `JBSuckerRegistry`: `16` added, `2` removed, `1` modified ABI items.
- `MerkleLib`: `1` added, `1` removed, `0` modified ABI items.

Generated event/error name deltas:
- Event names added:
  - `ClaimFailed`, `Claimed`, `EmergencyExit`, `InsertToOutboxTree`, `RetainedToRemoteFee`, `RetainedToRemoteFeeClaimed`, `RetainedTransportPaymentRefund`, `RetainedTransportPaymentRefundClaimed`.
  - `StaleRootRejected`, `SuckerDeployedFor`, `ToRemoteFeeChanged`, `TransportPaymentRefundFailed`.
- Event names removed or replaced:
  - `Claimed`, `InsertToOutboxTree`, `StaleRootRejected`, `SuckerDeployedFor`, `TransportPaymentRefundFailed`.
- Error names added:
  - `JBCCIPSucker_PositiveRootWithoutDelivery`, `JBCCIPSucker_UnderDeliveredAmount`, `JBCCIPSucker_UnexpectedDeliveredTokens`, `JBCCIPSucker_UnknownMessageType`, `JBCCIPSucker_WrongDeliveredToken`, `JBSuckerDeployer_AlreadyConfigured`, `JBSuckerDeployer_DeployerIsNotConfigured`, `JBSuckerDeployer_InvalidLayerSpecificConfiguration`.
  - `JBSuckerDeployer_LayerSpecificNotConfigured`, `JBSuckerDeployer_ZeroConfiguratorAddress`, `JBSuckerRegistry_FeeExceedsMax`, `JBSuckerRegistry_ZeroPeerChainId`, `JBSucker_Deprecated`, `JBSucker_ExpectedMsgValue`, `JBSucker_IndexOutOfRange`, `JBSucker_NoRetainedToRemoteFee`.
  - `JBSucker_NoRetainedTransportPaymentRefund`, `JBSucker_NothingToSend`, `JBSucker_RefundFailed`, `JBSucker_RemoteTokenAlreadyMapped`, `JBSucker_ZeroBeneficiary`, `JBSucker_ZeroERC20Token`, `JBSucker_ZeroProjectTokenCount`, `MerkleLib_InsertTreeIsFull`.
  - `PRBMath_MulDiv_Overflow`, `SafeERC20FailedOperation`.
- Error names removed or replaced:
  - `JBCCIPSuckerDeployer_InvalidCCIPRouter`, `JBSuckerDeployer_AlreadyConfigured`, `JBSuckerDeployer_DeployerIsNotConfigured`, `JBSuckerDeployer_InvalidLayerSpecificConfiguration`, `JBSuckerDeployer_LayerSpecificNotConfigured`, `JBSuckerDeployer_Unauthorized`, `JBSuckerDeployer_ZeroConfiguratorAddress`, `JBSucker_Deprecated`.
  - `JBSucker_ExpectedMsgValue`, `JBSucker_ManualNotAllowed`, `JBSucker_QueueInsufficientSize`, `JBSucker_ZeroBeneficiary`, `JBSucker_ZeroERC20Token`, `MerkleLib_InsertTreeIsFull`.

Shared ABI artifacts checked with no ABI item changes:
- `ARBAddresses`, `ARBChains`, `IArbGatewayRouter`, `IArbL1GatewayRouter`, `IArbL2GatewayRouter`, `ICCIPRouter`, `IJBArbitrumSucker`, `IJBArbitrumSuckerDeployer`.
- `IJBCCIPSuckerDeployer`, `IJBOpSuckerDeployer`, `IJBOptimismSucker`, `IOPMessenger`, `IOPStandardBridge`, `IWrappedNativeToken`.

## Migration Notes

- Treat every remote `address` field as a schema migration to `bytes32`.
- Rebuild merkle leaf, claim, and event decoders from V6 structs.
- If you aggregate omnichain supply/surplus, read the registry helpers and account for skipped/reverting stale peer contexts.
- Update permission grants for explicit peer deployments and sucker deprecation.
