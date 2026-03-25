# nana-suckers-v6 Changelog (v5 -> v6)

This document describes all changes between `nana-suckers` (v5, Solidity 0.8.23) and `nana-suckers-v6` (v6, Solidity 0.8.28).

## Summary

The dominant theme of this release is **cross-VM preparation for Solana/SVM** — addresses throughout the sucker architecture are widened from `address` (20 bytes) to `bytes32` (32 bytes) to support non-EVM chains.

- **`address` → `bytes32` throughout**: All cross-chain identifiers (peer addresses, beneficiaries, remote tokens) widened to `bytes32` for Solana/SVM compatibility. `uint128` amount caps added for SVM compatibility.
- **Message versioning**: New `version` field in `JBMessageRoot` prevents v5/v6 message incompatibility. v6 messages use `MESSAGE_VERSION = 1`.
- **Anti-spam redesigned**: Per-token `minBridgeAmount` replaced by a global `toRemoteFee` (max 0.001 ETH) paid to the fee project on every `toRemote()` call.
- **`MANUAL` add-to-balance mode removed**: Balance is always added atomically during `claim()`, simplifying the sucker lifecycle.
- **New Celo support**: `JBCeloSucker` handles Celo's non-ETH native gas token via WETH wrapping.

---

## 1. Breaking Changes

### 1.1 Cross-VM Address Representation (`address` -> `bytes32`)

The most pervasive breaking change in v6 is the systematic replacement of `address` types with `bytes32` for all cross-chain identifiers. This prepares the sucker architecture for non-EVM chains (e.g., Solana/SVM) where addresses are 32 bytes. Two new internal helpers (`_toAddress` and `_toBytes32`) convert between the two representations at EVM bridge API boundaries.

#### IJBSucker

| Change | v5 | v6 |
|--------|----|----|
| `peer()` return type | `returns (address)` | `returns (bytes32)` |
| `prepare()` beneficiary param | `address beneficiary` | `bytes32 beneficiary` |
| `Claimed` event `beneficiary` | `address beneficiary` | `bytes32 beneficiary` |
| `Claimed` event `autoAddedToBalance` | `bool autoAddedToBalance` | _(removed)_ |
| `InsertToOutboxTree` event `beneficiary` | `address indexed beneficiary` | `bytes32 indexed beneficiary` |

All callers of `peer()` and `prepare()` must update to use `bytes32`. For EVM-to-EVM usage, addresses are left-padded to 32 bytes via `_toBytes32(address)`.

> **Cross-repo impact**: `nana-omnichain-deployers-v6` and `nana-fee-project-deployer-v6` both updated `JBTokenMapping.remoteToken` from `address` to `bytes32`. `nana-permission-ids-v6` split `SUCKER_SAFETY` into two permissions (`SUCKER_SAFETY` + `SET_SUCKER_DEPRECATION`) to match the v6 separation.

### 1.2 Struct Field Type Changes

| Struct | Field | v5 Type | v6 Type |
|--------|-------|---------|---------|
| `JBLeaf` | `beneficiary` | `address` | `bytes32` |
| `JBMessageRoot` | `token` | `address` | `bytes32` |
| `JBMessageRoot` | (new field) `version` | N/A | `uint8` (inserted as first field) |
| `JBRemoteToken` | `addr` | `address` | `bytes32` |
| `JBRemoteToken` | `minBridgeAmount` | `uint256` | _(removed)_ |
| `JBSuckersPair` | `remote` | `address` | `bytes32` |
| `JBTokenMapping` | `remoteToken` | `address` | `bytes32` |
| `JBTokenMapping` | `minBridgeAmount` | `uint256` | _(removed)_ |

These are ABI-breaking changes. All off-chain infrastructure (indexers, relayers, frontends) must update to use `bytes32` for these fields.

### 1.3 Message Versioning (New Field in `JBMessageRoot`)

`JBMessageRoot` gained a `version` field (`uint8`). The v6 `fromRemote()` function validates `root.version == MESSAGE_VERSION` (which is `1`) and reverts with `JBSucker_InvalidMessageVersion` if it does not match. This means v5 messages (which have no version field) are incompatible with v6 suckers.

### 1.4 `setDeprecation` Permission Change

| Change | v5 | v6 |
|--------|----|----|
| `setDeprecation` required permission | `JBPermissionIds.SUCKER_SAFETY` | `JBPermissionIds.SET_SUCKER_DEPRECATION` |

`enableEmergencyHatchFor` continues to use `JBPermissionIds.SUCKER_SAFETY` in both versions.

### 1.5 Removed Interfaces

| File | Notes |
|------|-------|
| `IJBSuckerDeployerFeeless.sol` | Removed entirely. The feeless allowance sucker pattern was removed. |

### 1.6 Removed Contracts

| File | Notes |
|------|-------|
| `extensions/JBAllowanceSucker.sol` | Abstract contract for feeless cash outs via `useAllowanceFeeless`. Removed along with `IJBSuckerDeployerFeeless`. |

### 1.7 IJBSuckerDeployer Errors Moved

In v5, deployer errors were declared in `IJBSuckerDeployer` (the interface). In v6, they are declared in `JBSuckerDeployer` (the abstract contract). The errors themselves are identical:
- `JBSuckerDeployer_AlreadyConfigured()`
- `JBSuckerDeployer_DeployerIsNotConfigured()`
- `JBSuckerDeployer_InvalidLayerSpecificConfiguration()`
- `JBSuckerDeployer_LayerSpecificNotConfigured()`
- `JBSuckerDeployer_Unauthorized(address caller, address expected)`
- `JBSuckerDeployer_ZeroConfiguratorAddress()`

### 1.8 IJBSuckerRegistry `deploySuckersFor` Parameter Change

| Change | v5 | v6 |
|--------|----|----|
| `deploySuckersFor` configurations param | `JBSuckerDeployerConfig[] memory configurations` | `JBSuckerDeployerConfig[] calldata configurations` |

Changed from `memory` to `calldata` for gas efficiency.

### 1.9 Anti-Spam Mechanism: `minBridgeAmount` Replaced by `toRemoteFee`

The v5 per-token `minBridgeAmount` anti-spam mechanism has been replaced by a global `toRemoteFee` in v6. This is a fundamental design change:

| Aspect | v5 | v6 |
|--------|----|----|
| Mechanism | Per-token minimum bridge threshold (`minBridgeAmount` in `JBRemoteToken`/`JBTokenMapping`) | Global ETH fee paid on every `toRemote()` call |
| Configuration | Set per-token during `mapTokens()` | Centralized in `JBSuckerRegistry`, admin-adjustable via `setToRemoteFee()` |
| Check | `_outboxOf[token].balance < remoteToken.minBridgeAmount` reverts with `JBSucker_QueueInsufficientSize` | `msg.value < toRemoteFee` reverts with `JBSucker_InsufficientMsgValue` |
| Fee destination | N/A (no fee, just a threshold) | Paid into `FEE_PROJECT_ID` via `terminal.pay()`. Caller receives fee project tokens. |
| Cap | None | `MAX_TO_REMOTE_FEE = 0.001 ether` |

The `JBSucker` constructor gained two new parameters: `feeProjectId` (the project that receives the fee, typically project ID 1) and `registry` (typed as `IJBSuckerRegistry`, which manages the global `toRemoteFee`). These replace the `addToBalanceMode` parameter. See section 1.10 for the `addToBalanceMode` removal.

### 1.10 `MANUAL` `AddToBalanceMode` Removed

The `MANUAL` option of `JBAddToBalanceMode` has been removed entirely. In v5, suckers could be deployed with either `MANUAL` or `ON_CLAIM` mode. In v6, balance is always added atomically during `claim()` (the `ON_CLAIM` behavior). This simplifies the sucker lifecycle.

| Removed in v6 | Description |
|----------------|-------------|
| `JBAddToBalanceMode` enum | Removed. Only had `MANUAL` and `ON_CLAIM`. |
| `ADD_TO_BALANCE_MODE` immutable | Removed from `JBSucker` and `IJBSucker`. |
| `addOutstandingAmountToBalance(address token)` | Public function removed from `IJBSucker` and `JBSucker`. Was only usable in `MANUAL` mode. |
| `JBSucker_ManualNotAllowed` error | Removed (was thrown when calling `addOutstandingAmountToBalance` in non-MANUAL mode). |

Note: `amountToAddToBalanceOf(address token)` is still present in v6 -- it is used internally by the always-on-claim flow.

### 1.11 JBSucker Constructor Change

| Parameter | v5 | v6 |
|-----------|----|----|
| `addToBalanceMode` | `JBAddToBalanceMode addToBalanceMode` | _(removed)_ |
| `feeProjectId` | _(not present)_ | `uint256 feeProjectId` |
| `registry` | _(not present)_ | `IJBSuckerRegistry registry` |
| `trusted_forwarder` naming | `address trusted_forwarder` | `address trustedForwarder` (camelCase) |

All subclass constructors (`JBOptimismSucker`, `JBArbitrumSucker`, `JBCCIPSucker`, `JBBaseSucker`, `JBCeloSucker`) are updated accordingly.

### 1.12 `initialize()` ERC2771 Fix

In v5, `JBSucker.initialize()` used `msg.sender` to set the `deployer` field. In v6, this was corrected to `_msgSender()` for ERC2771 meta-transaction compatibility. This is a behavioral fix: when called through a trusted forwarder, v5 would incorrectly record the forwarder address as the deployer instead of the actual sender.

---

## 2. New Features

### 2.1 New Contracts

| Contract | Description |
|----------|-------------|
| `JBCeloSucker` | OP Stack sucker for Celo, which uses CELO as its native gas token (not ETH). Wraps native ETH to WETH before bridging as ERC-20. Overrides `_sendRootOverAMB` to always bridge as ERC-20 and never attach ETH as `msg.value` on the messenger. Overrides `_addToBalance` to unwrap WETH back to native ETH. Overrides `_validateTokenMapping` to allow `NATIVE_TOKEN` to map to any remote token. Supports chain IDs: Ethereum (1) <-> Celo (42220). |
| `JBCeloSuckerDeployer` | Deployer for `JBCeloSucker`. Extends `JBOptimismSuckerDeployer` with a `wrappedNative` address. Has its own `setChainSpecificConstants` that accepts an additional `IWrappedNativeToken` parameter. |

### 2.2 New Interfaces

| Interface | Description |
|-----------|-------------|
| `IJBCeloSuckerDeployer` | Interface for the Celo sucker deployer. Extends `IJBOpSuckerDeployer` with `wrappedNative()` view and `setChainSpecificConstants(IOPMessenger, IOPStandardBridge, IWrappedNativeToken)`. |

### 2.3 New Events

| Contract | Event | Description |
|----------|-------|-------------|
| `IJBSucker` | `StaleRootRejected(address indexed token, uint64 receivedNonce, uint64 currentNonce)` | Emitted when a received inbox root is rejected because its nonce is stale (not greater than the current nonce). Aids off-chain monitoring of out-of-order or duplicate message deliveries. |
| `IJBSuckerExtended` | `EmergencyExit(address indexed beneficiary, address indexed token, uint256 terminalTokenAmount, uint256 projectTokenCount, address caller)` | Emitted when a beneficiary exits through the emergency hatch. v5 had no event for emergency exits. |
| `JBCCIPSucker` | `TransportPaymentRefundFailed(address indexed recipient, uint256 amount)` | Emitted when a CCIP transport payment refund fails after a successful `ccipSend`. Replaces the v5 `JBCCIPSucker_FailedToRefundFee` revert to avoid reverting after the bridge message is committed. |
| `IJBSuckerRegistry` | `ToRemoteFeeChanged(uint256 oldFee, uint256 newFee, address caller)` | Emitted when the registry owner changes the global `toRemoteFee`. New in v6 (no v5 equivalent). |

### 2.4 New Errors

| Contract | Error | Description |
|----------|-------|-------------|
| `JBSucker` | `JBSucker_AmountExceedsUint128(uint256 amount)` | Thrown when `terminalTokenAmount` or `projectTokenCount` exceeds `uint128` in `_insertIntoTree`. Guards against overflow for SVM/Solana compatibility. |
| `JBSucker` | `JBSucker_InvalidMessageVersion(uint8 received, uint8 expected)` | Thrown in `fromRemote` when the message version does not match `MESSAGE_VERSION`. Prevents processing incompatible messages. |
| `JBSucker` | `JBSucker_NothingToSend()` | Thrown in `toRemote()` when the outbox has zero balance and no unsent claims. Prevents unnecessary bridge calls. |
| `CCIPHelper` | `CCIPHelper_UnsupportedChain(uint256 chainId)` | Replaces bare `revert("Unsupported chain")` strings with a typed error. |
| `JBSuckerRegistry` | `JBSuckerRegistry_FeeExceedsMax(uint256 fee, uint256 max)` | Thrown when `setToRemoteFee` is called with a fee exceeding `MAX_TO_REMOTE_FEE`. |

### 2.5 New Constants

| Contract | Constant | Description |
|----------|----------|-------------|
| `JBSucker` | `uint8 public constant MESSAGE_VERSION = 1` | The message format version. Used to reject incompatible messages from remote chains. |
| `JBSuckerRegistry` | `uint256 public constant MAX_TO_REMOTE_FEE = 0.001 ether` | The maximum ETH fee the registry owner can set via `setToRemoteFee()`. |

### 2.6 New Internal Helpers

| Contract | Function | Description |
|----------|----------|-------------|
| `JBSucker` | `_toAddress(bytes32) -> address` | Converts a `bytes32` remote address to a local EVM address (lower 20 bytes). |
| `JBSucker` | `_toBytes32(address) -> bytes32` | Converts an EVM address to a `bytes32` remote address (left-padded with zeros). |
| `JBArbitrumSucker` | `_createRetryableTicket(...)` | Helper to create the retryable ticket, extracted from `_toL2` to avoid stack-too-deep errors. |

---

## 3. Event Changes

### 3.1 New Events

See section 2.3 above.

### 3.2 Modified Events

| Contract | Event | Change |
|----------|-------|--------|
| `IJBSucker` | `Claimed` | `beneficiary` field changed from `address` to `bytes32`. `bool autoAddedToBalance` parameter removed (the `MANUAL` add-to-balance mode was removed in v6, so balance is always added on claim). |
| `IJBSucker` | `InsertToOutboxTree` | `beneficiary` indexed field changed from `address indexed` to `bytes32 indexed`. |

### 3.3 Unchanged Events

`NewInboxTreeRoot`, `RootToRemote`, `EmergencyHatchOpened`, `DeprecationTimeUpdated`, `SuckerDeployedFor`, `SuckerDeployerAllowed`, `SuckerDeployerRemoved`, `SuckerDeprecated`, and `CCIPConstantsSet` are identical between v5 and v6.

### 3.4 All Interfaces Gained NatSpec

Every interface file in v6 has comprehensive NatSpec documentation added to all functions, events, errors, and return values. This is a documentation-only change that does not affect the ABI.

---

## 4. Error Changes

### 4.1 New Errors

See section 2.4 above.

### 4.2 Modified Error Parameters (Type Changes)

| Contract | v5 | v6 |
|----------|----|----|
| `JBSucker` | `JBSucker_NotPeer(address caller)` | `JBSucker_NotPeer(bytes32 caller)` |
| `JBSucker` | `JBSucker_InvalidNativeRemoteAddress(address remoteToken)` | `JBSucker_InvalidNativeRemoteAddress(bytes32 remoteToken)` |
| `JBSucker` | `JBSucker_TokenAlreadyMapped(address localToken, address mappedTo)` | `JBSucker_TokenAlreadyMapped(address localToken, bytes32 mappedTo)` |

### 4.3 Removed Errors

| Contract | Error | Notes |
|----------|-------|-------|
| `JBArbitrumSucker` | `JBArbitrumSucker_ChainNotSupported(uint256 chainId)` | Error was declared but never used in v5. Removed. |
| `JBCCIPSucker` | `JBCCIPSucker_FailedToRefundFee()` | Replaced by `TransportPaymentRefundFailed` event. Refund failure no longer reverts. |
| `JBSucker` | `JBSucker_ManualNotAllowed(JBAddToBalanceMode mode)` | Removed along with `MANUAL` `AddToBalanceMode`. Balance is always added on claim in v6. |
| `JBSucker` | `JBSucker_QueueInsufficientSize(uint256 amount, uint256 minimumAmount)` | Removed. The per-token `minBridgeAmount` threshold was replaced by the global `toRemoteFee` mechanism. |
| `JBSuckerRegistry` | `JBSuckerRegistry_RulesetDoesNotAllowAddingSucker(uint256 projectId)` | Removed entirely (was declared but unused in v5). |

### 4.4 Moved Errors (Interface -> Contract)

| v5 Location | v6 Location | Errors |
|-------------|-------------|--------|
| `IJBSuckerDeployer` (interface) | `JBSuckerDeployer` (abstract contract) | `JBSuckerDeployer_AlreadyConfigured`, `JBSuckerDeployer_DeployerIsNotConfigured`, `JBSuckerDeployer_InvalidLayerSpecificConfiguration`, `JBSuckerDeployer_LayerSpecificNotConfigured`, `JBSuckerDeployer_Unauthorized`, `JBSuckerDeployer_ZeroConfiguratorAddress` |

### 4.5 Library Error Improvements

| Library | v5 | v6 |
|---------|----|----|
| `CCIPHelper` | `revert("Unsupported chain")` (bare string revert) | `revert CCIPHelper_UnsupportedChain(chainId)` (typed error with chain ID) |

---

## 5. Struct Changes

### 5.1 Modified Structs

| Struct | Field | v5 Type | v6 Type | Notes |
|--------|-------|---------|---------|-------|
| `JBLeaf` | `beneficiary` | `address` | `bytes32` | Cross-VM compatibility |
| `JBMessageRoot` | `token` | `address` | `bytes32` | Cross-VM compatibility |
| `JBMessageRoot` | `version` | _(not present)_ | `uint8` | New field for message versioning (first field) |
| `JBRemoteToken` | `addr` | `address` | `bytes32` | Cross-VM compatibility |
| `JBRemoteToken` | `minBridgeAmount` | `uint256` | _(removed)_ | Anti-spam moved to global `toRemoteFee` in `JBSuckerRegistry` |
| `JBSuckersPair` | `remote` | `address` | `bytes32` | Cross-VM compatibility |
| `JBTokenMapping` | `remoteToken` | `address` | `bytes32` | Cross-VM compatibility |
| `JBTokenMapping` | `minBridgeAmount` | `uint256` | _(removed)_ | Anti-spam moved to global `toRemoteFee` in `JBSuckerRegistry` |

### 5.2 Unchanged Structs

| Struct | Notes |
|--------|-------|
| `JBClaim` | Identical (but contains `JBLeaf`, which changed) |
| `JBInboxTreeRoot` | Identical |
| `JBOutboxTree` | Identical |
| `JBSuckerDeployerConfig` | Identical (but contains `JBTokenMapping`, which changed) |

---

## 6. Enum Changes

`JBLayer` and `JBSuckerState` are **identical** between v5 and v6. `JBAddToBalanceMode` has been removed — balance is now always added atomically during `claim()`.

---

## 7. Implementation Changes (Non-Interface)

### 7.1 JBSucker

| Change | Description |
|--------|-------------|
| **Message versioning** | `fromRemote()` now validates `root.version == MESSAGE_VERSION` and reverts with `JBSucker_InvalidMessageVersion` on mismatch. v5 had no version check. |
| **Stale root event** | `fromRemote()` emits `StaleRootRejected` in the else branch when a root is rejected due to a stale nonce. v5 silently ignored stale roots. |
| **Token field in `fromRemote`** | `fromRemote()` now converts `root.token` (bytes32) to a local address via `_toAddress()` for inbox lookup, since `JBMessageRoot.token` changed from `address` to `bytes32`. |
| **uint128 overflow guard** | `_insertIntoTree()` now checks that `terminalTokenAmount` and `projectTokenCount` do not exceed `uint128`, reverting with `JBSucker_AmountExceedsUint128`. Guards against overflow when bridging to SVM/Solana. |
| **Empty outbox guard** | `_sendRoot()` now returns early (no-op) if `outbox.tree.count == 0`, preventing an arithmetic underflow when computing `count - 1`. v5 did not have this guard. |
| **Emergency exit event** | `exitThroughEmergencyHatch()` now emits the `EmergencyExit` event. v5 had no event for emergency exits. |
| **`setDeprecation` permission** | Changed from `JBPermissionIds.SUCKER_SAFETY` to `JBPermissionIds.SET_SUCKER_DEPRECATION`. |
| **`_addToBalance` visibility** | Changed from `internal` to `internal virtual`, allowing subclasses (e.g., `JBCeloSucker`) to override. |
| **`peer()` return type** | Changed from `address` to `bytes32`. Default implementation returns `_toBytes32(address(this))`. |
| **`isMapped()` comparison** | Changed from `_remoteTokenFor[token].addr != address(0)` to `_remoteTokenFor[token].addr != bytes32(0)`. |
| **Private variable naming** | `localProjectId` renamed to `_localProjectId` (leading underscore convention). |
| **`mapTokens` dust refund** | `mapTokens()` now refunds the remainder from integer division of `msg.value` when disabling multiple tokens, preventing dust ETH from being stuck in the contract. |
| **`_handleClaim` beneficiary conversion** | Converts `bytes32` beneficiary to `address` via `_toAddress()` before minting project tokens. |
| **`_sendRoot` message construction** | Now includes `version: MESSAGE_VERSION` in the `JBMessageRoot` struct. |
| **`toRemoteFee` anti-spam** | `toRemote()` now charges a global ETH fee (read from `REGISTRY.toRemoteFee()`) paid into `FEE_PROJECT_ID` via `terminal.pay()`. Replaces the v5 per-token `minBridgeAmount` threshold check. Fee payment is best-effort (try-catch): if the terminal doesn't exist or the pay call reverts, the fee is returned as transport payment. |
| **New immutables** | `FEE_PROJECT_ID` (`uint256`) and `REGISTRY` (`IJBSuckerRegistry`) added. `REGISTRY` is typed as `IJBSuckerRegistry` (not a raw `address`), avoiding casts at usage sites. |
| **`MANUAL` mode removed** | `ADD_TO_BALANCE_MODE` immutable, `addOutstandingAmountToBalance()` function, and `JBSucker_ManualNotAllowed` error all removed. Balance is always added atomically during `claim()`. |
| **Constructor parameter changes** | `addToBalanceMode` parameter removed. `feeProjectId` and `registry` parameters added. `trusted_forwarder` renamed to `trustedForwarder`. |
| **`initialize()` ERC2771 fix** | `deployer = msg.sender` changed to `deployer = _msgSender()` for correct ERC2771 meta-transaction support. |
| **Named arguments** | Function calls throughout use named argument syntax (`{key: value}`) for improved readability. |

### 7.2 JBOptimismSucker

| Change | Description |
|--------|-------------|
| **`_isRemotePeer` comparison** | v5: `OPMESSENGER.xDomainMessageSender() == peer()` (address comparison). v6: `_toBytes32(OPMESSENGER.xDomainMessageSender()) == peer()` (bytes32 comparison). |
| **Bridge API calls** | `OPBRIDGE.bridgeERC20To` and `OPMESSENGER.sendMessage` now convert `bytes32` types to `address` at the OP Bridge API boundary via `_toAddress()`. |
| **`_sendRootOverAMB` visibility** | Changed from `internal override` to `internal virtual override`, allowing `JBCeloSucker` to override. |

### 7.3 JBArbitrumSucker

| Change | Description |
|--------|-------------|
| **`_isRemotePeer` comparison** | v5: compared directly with `peer()` (address). v6: converts `peer()` to address via `_toAddress()` before comparison with bridge contracts. |
| **Bridge API calls** | `IArbL2GatewayRouter.outboundTransfer`, `ArbSys.sendTxToL1`, and `IArbL1GatewayRouter.outboundTransferCustomRefund` now convert `bytes32` types to `address` via `_toAddress()`. |
| **Stack-too-deep refactor** | `_toL2` extracted `_createRetryableTicket` helper to avoid stack-too-deep. v5 inlined the `ARBINBOX.unsafeCreateRetryableTicket` call. |
| **Removed error** | `JBArbitrumSucker_ChainNotSupported` removed (was unused in v5). |

### 7.4 JBCCIPSucker

| Change | Description |
|--------|-------------|
| **Refund failure handling** | v5: reverted with `JBCCIPSucker_FailedToRefundFee()` on refund failure. v6: emits `TransportPaymentRefundFailed` event instead. This prevents reverting after `ccipSend` has already committed the bridge message, which would cause the transaction to roll back while the CCIP message is in-flight, potentially causing token loss. |
| **`ccipReceive` peer check** | v5: `revert JBSucker_NotPeer(_msgSender())` / `revert JBSucker_NotPeer(origin)`. v6: wraps in `_toBytes32()` to match the new `bytes32` error parameter. |
| **`ccipReceive` token comparison** | v5: `root.token == JBConstants.NATIVE_TOKEN`. v6: `root.token == _toBytes32(JBConstants.NATIVE_TOKEN)`, since `root.token` is now `bytes32`. |
| **CCIP message receiver** | v5: `abi.encode(peer())` (address). v6: `abi.encode(_toAddress(peer()))` (converts bytes32 back to address for CCIP EVM compatibility). |
| **`_validateTokenMapping`** | v6 enforces `minGas >= MESSENGER_ERC20_MIN_GAS_LIMIT` for ALL tokens (including native), since CCIP wraps native tokens to WETH. v5 exempted native tokens from the minGas check. |
| **Removed `CCIPHelper` import** | v6 no longer imports `CCIPHelper` in `JBCCIPSucker`. |

### 7.5 JBSuckerRegistry

| Change | Description |
|--------|-------------|
| **License** | Changed from `UNLICENSED` to `MIT`. |
| **Removed imports** | `IJBController`, `JBRuleset`, `JBRulesetMetadata` no longer imported. The v5 ruleset-based sucker restriction was removed. |
| **Removed error** | `JBSuckerRegistry_RulesetDoesNotAllowAddingSucker` removed. |
| **`suckerPairsOf`** | `sucker.peer()` now returns `bytes32`, directly assigned to `JBSuckersPair.remote` (which also changed to `bytes32`). |
| **`toRemoteFee` management** | New `toRemoteFee` storage variable (admin-adjustable ETH fee), `MAX_TO_REMOTE_FEE` constant (`0.001 ether`), `setToRemoteFee(uint256)` function (owner-only), `ToRemoteFeeChanged` event, and `JBSuckerRegistry_FeeExceedsMax` error. Defaults to `MAX_TO_REMOTE_FEE` on construction. |

### 7.6 JBSuckerDeployer

| Change | Description |
|--------|-------------|
| **Errors moved** | All deployer errors moved from `IJBSuckerDeployer` (interface) to `JBSuckerDeployer` (abstract contract). The interface is now error-free. |
| **Constructor parameter naming** | `trusted_forwarder` renamed to `trustedForwarder` (camelCase convention). |

### 7.7 JBOptimismSuckerDeployer

| Change | Description |
|--------|-------------|
| **`_layerSpecificConfigurationIsSet` operator** | v5: `address(opMessenger) != address(0) \|\| address(opBridge) != address(0)` (OR -- accepts partial config). v6: `address(opMessenger) != address(0) && address(opBridge) != address(0)` (AND -- rejects partial config). This ensures both messenger and bridge must be set, preventing misconfiguration. |
| **`_layerSpecificConfigurationIsSet` visibility** | Changed from `internal view override` to `internal view virtual override`, allowing `JBCeloSuckerDeployer` to override. |

### 7.8 CCIPHelper Library

| Change | Description |
|--------|-------------|
| **Typed error** | Bare `revert("Unsupported chain")` strings replaced with `revert CCIPHelper_UnsupportedChain(chainId)` in `routerOfChain`, `selectorOfChain`, and `wethOfChain`. |

### 7.9 Solidity Version

All contracts upgraded from `pragma solidity 0.8.23` to `pragma solidity 0.8.28`.

### 7.10 Named Arguments

Throughout the codebase, function calls were updated to use named argument syntax (e.g., `foo({bar: 1, baz: 2})`) for improved readability.

---

## 8. Migration Table

### Interfaces

| v5 | v6 | Notes |
|----|----|-------|
| `IJBSucker` | `IJBSucker` | `peer()` returns `bytes32`. `prepare()` takes `bytes32 beneficiary`. `Claimed`/`InsertToOutboxTree` events use `bytes32`. `Claimed` event `autoAddedToBalance` parameter removed. New `StaleRootRejected` event. New `JBSucker_NothingToSend` error. `ADD_TO_BALANCE_MODE()` and `addOutstandingAmountToBalance()` removed. NatSpec added. |
| `IJBSuckerExtended` | `IJBSuckerExtended` | New `EmergencyExit` event. NatSpec added. |
| `IJBSuckerRegistry` | `IJBSuckerRegistry` | `deploySuckersFor` configurations changed to `calldata`. New `toRemoteFee()`, `MAX_TO_REMOTE_FEE()`, `setToRemoteFee()`, `ToRemoteFeeChanged` event, `FeeExceedsMax` error. NatSpec added. |
| `IJBSuckerDeployer` | `IJBSuckerDeployer` | All errors removed from interface (moved to contract). NatSpec added. |
| `IJBSuckerDeployerFeeless` | (removed) | Feeless allowance sucker pattern removed. No replacement. |
| `IJBArbitrumSucker` | `IJBArbitrumSucker` | NatSpec added. No functional changes. |
| `IJBArbitrumSuckerDeployer` | `IJBArbitrumSuckerDeployer` | NatSpec added. No functional changes. |
| `IJBOptimismSucker` | `IJBOptimismSucker` | NatSpec added. No functional changes. |
| `IJBOpSuckerDeployer` | `IJBOpSuckerDeployer` | NatSpec added. No functional changes. |
| `IJBCCIPSuckerDeployer` | `IJBCCIPSuckerDeployer` | NatSpec added. No functional changes. |
| N/A | `IJBCeloSuckerDeployer` | New. Extends `IJBOpSuckerDeployer` with `wrappedNative()` and extended `setChainSpecificConstants`. |
| All other interfaces | Same name | NatSpec documentation added. No functional changes. |

### Contracts

| v5 | v6 | Notes |
|----|----|-------|
| `JBSucker` | `JBSucker` | `address` -> `bytes32` throughout, message versioning, uint128 guard, empty outbox guard, stale root event, emergency exit event, `setDeprecation` permission change, `mapTokens` dust refund, virtual `_addToBalance`. `minBridgeAmount` replaced by `toRemoteFee`. `MANUAL` mode removed. New `FEE_PROJECT_ID` + `REGISTRY` immutables. `initialize()` uses `_msgSender()`. |
| `JBOptimismSucker` | `JBOptimismSucker` | `_sendRootOverAMB` made `virtual`. Bridge calls use `_toAddress()`/`_toBytes32()`. |
| `JBBaseSucker` | `JBBaseSucker` | Explicit imports instead of wildcard. No functional changes. |
| `JBArbitrumSucker` | `JBArbitrumSucker` | Bridge calls use `_toAddress()`. `_createRetryableTicket` helper extracted. Removed unused `ChainNotSupported` error. |
| `JBCCIPSucker` | `JBCCIPSucker` | Refund failure emits event instead of reverting. `_validateTokenMapping` enforces minGas for native tokens. Bridge calls use `_toAddress()`/`_toBytes32()`. Removed `CCIPHelper` import. |
| N/A | `JBCeloSucker` | New. OP Stack sucker for Celo (custom gas token). Wraps ETH to WETH for bridging, unwraps on receipt. |
| `JBSuckerRegistry` | `JBSuckerRegistry` | Removed ruleset check and related imports/error. License changed to MIT. New `toRemoteFee` management (`setToRemoteFee`, `MAX_TO_REMOTE_FEE`, `ToRemoteFeeChanged` event). |
| `JBSuckerDeployer` | `JBSuckerDeployer` | Errors moved from interface to contract. Constructor param naming convention updated. |
| `JBOptimismSuckerDeployer` | `JBOptimismSuckerDeployer` | `_layerSpecificConfigurationIsSet` uses `&&` instead of `\|\|`. Made `virtual`. |
| N/A | `JBCeloSuckerDeployer` | New. Extends OP deployer with wrapped native token support. |
| `extensions/JBAllowanceSucker` | (removed) | Feeless allowance sucker pattern removed. |
| All deployers | Same name | Solidity version, named arguments, NatSpec. |

### Structs

| v5 | v6 | Notes |
|----|----|-------|
| `JBLeaf` | `JBLeaf` | `beneficiary`: `address` -> `bytes32` |
| `JBMessageRoot` | `JBMessageRoot` | `token`: `address` -> `bytes32`. New `version` field (`uint8`). |
| `JBRemoteToken` | `JBRemoteToken` | `addr`: `address` -> `bytes32`. `minBridgeAmount` removed. |
| `JBSuckersPair` | `JBSuckersPair` | `remote`: `address` -> `bytes32` |
| `JBTokenMapping` | `JBTokenMapping` | `remoteToken`: `address` -> `bytes32`. `minBridgeAmount` removed. |
| `JBClaim` | `JBClaim` | Unchanged (contains changed `JBLeaf`) |
| `JBInboxTreeRoot` | `JBInboxTreeRoot` | Identical |
| `JBOutboxTree` | `JBOutboxTree` | Identical |
| `JBSuckerDeployerConfig` | `JBSuckerDeployerConfig` | Unchanged (contains changed `JBTokenMapping`) |

### Enums

| v5 | v6 | Notes |
|----|----|-------|
| `JBAddToBalanceMode` | _(removed)_ | Balance always added on claim. |
| `JBLayer` | `JBLayer` | Identical |
| `JBSuckerState` | `JBSuckerState` | Identical |

### Libraries

| v5 | v6 | Notes |
|----|----|-------|
| `ARBAddresses` | `ARBAddresses` | Identical |
| `ARBChains` | `ARBChains` | Identical |
| `CCIPHelper` | `CCIPHelper` | Bare `revert("Unsupported chain")` replaced with typed `CCIPHelper_UnsupportedChain` error. |
| `MerkleLib` | `MerkleLib` | Identical |
