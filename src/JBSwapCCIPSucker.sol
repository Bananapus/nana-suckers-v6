// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Core JB imports.
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
// CCIP imports.
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

// OpenZeppelin imports.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap V3 imports.
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

// Uniswap V4 imports.
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

// Local: contracts.
import {JBCCIPSucker} from "./JBCCIPSucker.sol";

// Local: deployers.
import {JBSwapCCIPSuckerDeployer} from "./deployers/JBSwapCCIPSuckerDeployer.sol";

// Local: interfaces (alphabetized).
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";
import {IJBSwapCCIPSuckerDeployer} from "./interfaces/IJBSwapCCIPSuckerDeployer.sol";
import {IWrappedNativeToken} from "./interfaces/IWrappedNativeToken.sol";

// Local: libraries.
import {CCIPHelper} from "./libraries/CCIPHelper.sol";
import {JBCCIPLib} from "./libraries/JBCCIPLib.sol";
import {JBSwapPoolLib} from "./libraries/JBSwapPoolLib.sol";

// Local: structs (alphabetized).
import {JBClaim} from "./structs/JBClaim.sol";
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBRemoteToken} from "./structs/JBRemoteToken.sol";

/// @notice A `JBCCIPSucker` extension that swaps between local and bridge tokens using the best
/// Uniswap V3 or V4 pool before/after CCIP bridging.
/// @dev Enables cross-currency bridging: e.g., ETH on Ethereum <-> USDC on Tempo.
/// Discovers the most liquid pool across V3 fee tiers and V4 pool configurations,
/// then applies TWAP-based quoting with sigmoid slippage protection.
///
/// **Cross-denomination claim scaling:** Because the merkle tree leaf amounts are denominated in the
/// source chain's terminal token, the receiving chain must scale each claim proportionally. This contract
/// stores an immutable conversion rate per nonce (one per received root batch). The `claim` override
/// sets the leaf index context, and `_addToBalance` uses it to look up the correct nonce and rate:
/// `scaledAmount = leafAmount * batchLocal / batchLeaf`. This is ordering-independent — out-of-order
/// CCIP delivery cannot cause one batch's rate to be applied to another batch's claims.
///
/// Flow (Ethereum -> Tempo, ETH -> USDC):
///   prepare(ETH) -> burn project tokens, cash out ETH from terminal
///   toRemote(ETH) -> swap ETH->USDC on best V3/V4 pool -> CCIP bridge USDC -> Tempo receives USDC
///
/// Flow (Tempo -> Ethereum, USDC -> ETH):
///   prepare(USDC) -> burn project tokens, cash out USDC from terminal
///   toRemote(USDC) -> CCIP bridge USDC -> Ethereum receives USDC -> swap USDC->ETH on best V3/V4 pool
///
/// **Gas limit configuration**: When mapping tokens for swap suckers via `mapToken`, set
/// `JBTokenMapping.minGas` to at least 600,000. Combined with the base `MESSENGER_BASE_GAS_LIMIT`
/// of 300,000, this provides ~900,000 gas for `ccipReceive` — sufficient for V3/V4 swap execution,
/// TWAP oracle consultation, and slippage computation. Insufficient gas causes the CCIP message to
/// fail on delivery, requiring manual re-execution via CCIP's ManualExecution mechanism.
///
/// **Inbound swap resilience**: If a swap reverts during `ccipReceive` (due to insufficient
/// liquidity, stale TWAP observations, or extreme price impact), the CCIP message still succeeds.
/// The unswapped bridge tokens are stored in a `PendingSwap` and the merkle root is recorded
/// normally. Claims for the affected batch are gated until `retrySwap` is called successfully.
/// Anyone can call `retrySwap` once swap conditions improve.
///
/// **No caller-controlled slippage**: Unlike the router terminal (where the caller spends their own
/// funds and can accept any slippage), here the swap output determines the conversion rate for ALL
/// claimers of the batch. Caller-controlled `minAmountOut` would allow sandwich attacks that lock
/// in bad rates for everyone. All swaps (outbound and retry) use TWAP quoting exclusively.
contract JBSwapCCIPSucker is JBCCIPSucker, IUnlockCallback, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBSwapCCIPSucker_BatchNotReceived(uint64 nonce);
    error JBSwapCCIPSucker_CallerNotPoolManager(address caller);
    error JBSwapCCIPSucker_DuplicateBatch(uint64 nonce);
    error JBSwapCCIPSucker_InvalidBridgeToken(address bridgeToken, address wrappedNativeToken);
    error JBSwapCCIPSucker_NoPendingSwap(address localToken, uint64 nonce, bool retrySwapLocked);
    error JBSwapCCIPSucker_OnlySelf(address caller, address expected);
    error JBSwapCCIPSucker_PositiveRootWithoutDelivery(uint256 rootAmount);
    error JBSwapCCIPSucker_SwapFailed(address tokenIn, address tokenOut, uint256 amountIn);
    error JBSwapCCIPSucker_SwapPending(uint64 nonce);
    error JBSwapCCIPSucker_UnexpectedDeliveredTokens(uint256 count);
    error JBSwapCCIPSucker_WrongDeliveredToken(address delivered, address expected);

    //*********************************************************************//
    // ------------------------------ events ----------------------------- //
    //*********************************************************************//

    /// @notice Emitted when a previously failed inbound swap is successfully retried.
    /// @param localToken The local token that the bridge tokens were swapped into.
    /// @param nonce The nonce of the batch whose swap was retried.
    /// @param bridgeAmount The amount of bridge tokens that were swapped.
    /// @param localAmount The amount of local tokens received from the retry swap.
    /// @param caller The address that retried the swap.
    event SwapRetried(
        address indexed localToken, uint64 indexed nonce, uint256 bridgeAmount, uint256 localAmount, address caller
    );

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The ERC-20 token used for CCIP bridging (e.g., USDC). Must exist on both chains.
    IERC20 public immutable BRIDGE_TOKEN;

    /// @notice The Uniswap V4 PoolManager. Can be address(0) if V4 is unavailable on this chain.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice The Uniswap V4 hook address for pool discovery (optional).
    address public immutable UNIV4_HOOK;

    /// @notice The Uniswap V3 factory for pool discovery and callback verification. Can be address(0).
    IUniswapV3Factory public immutable V3_FACTORY;

    /// @notice The ERC-20 wrapper for the chain's native token (e.g. WETH on Ethereum, WCELO on Celo). Used for V3
    /// native swaps.
    IWrappedNativeToken public immutable WRAPPED_NATIVE_TOKEN;

    //*********************************************************************//
    // ------------------- internal stored properties -------------------- //
    //*********************************************************************//

    /// @notice Bridge tokens from a failed inbound swap, stored for later retry via `retrySwap`.
    /// @custom:member bridgeToken The bridge token received from CCIP.
    /// @custom:member bridgeAmount Amount of bridge tokens to swap.
    /// @custom:member leafTotal Original leaf-denomination total (for conversion rate).
    struct PendingSwap {
        address bridgeToken;
        uint256 bridgeAmount;
        uint256 leafTotal;
    }

    /// @notice Pending (failed) inbound swaps, keyed by local token and batch nonce.
    /// @dev Populated when `ccipReceive` swap fails; cleared when `retrySwap` succeeds.
    /// @custom:param localToken The local token the swap targets.
    /// @custom:param nonce The CCIP nonce identifying the batch.
    mapping(address localToken => mapping(uint64 nonce => PendingSwap)) public pendingSwapOf;

    /// @notice Immutable conversion rate for one received root batch, keyed by nonce.
    /// @dev Each batch stores its total leaf and local amounts. Individual claims compute their
    /// scaled amount as `claimLeafAmount * localTotal / leafTotal` — no mutable state changes.
    /// @custom:member leafTotal Total leaf-denomination (source chain) amount for this batch.
    /// @custom:member localTotal Total local-denomination (after swap) amount for this batch.
    struct ConversionRate {
        uint256 leafTotal;
        uint256 localTotal;
    }

    /// @notice End leaf index (exclusive) for each received root batch, keyed by token and nonce.
    /// @custom:param token The local token address.
    /// @custom:param nonce The CCIP nonce identifying the batch.
    mapping(address token => mapping(uint64 nonce => uint256)) internal _batchEndOf;

    /// @notice Start leaf index for each received root batch, keyed by token and nonce.
    /// @dev Together with `_batchEndOf`, defines the half-open range [start, end) of leaf indices in each batch.
    /// Self-describing per nonce — no sequential dependency for out-of-order CCIP delivery.
    /// @custom:param token The local token address.
    /// @custom:param nonce The CCIP nonce identifying the batch.
    mapping(address token => mapping(uint64 nonce => uint256)) internal _batchStartOf;

    /// @notice Conversion rate for each received root batch, keyed by token and nonce.
    /// @custom:param token The local token address.
    /// @custom:param nonce The CCIP nonce identifying the batch.
    mapping(address token => mapping(uint64 nonce => ConversionRate)) internal _conversionRateOf;

    /// @notice Count of populated batch nonces per token. Appended exactly once per batch in
    /// `ccipReceive`, so it equals the number of received batches independent of CCIP ordering.
    /// @custom:param token The local token address.
    mapping(address token => uint64) internal _populatedNonceCount;

    /// @notice Populated batch nonces per token, indexed by insertion order.
    /// @dev `_findNonceForLeafIndex` walks this list directly. That bounds lookup by the number of
    /// received batches, not by the highest nonce, so sparse or out-of-order CCIP delivery cannot
    /// force the claim path to scan empty nonce slots.
    /// @custom:param token The local token address.
    /// @custom:param index The insertion index in [0, _populatedNonceCount[token]).
    mapping(address token => mapping(uint64 index => uint64 nonce)) internal _populatedNonceByIndex;

    /// @notice Cumulative leaf count at the last `_sendRootOverAMB` call, per token.
    /// @dev Used on the sender side to derive the batch start index for the next send.
    /// @custom:param token The local token address.
    mapping(address token => uint256) internal _lastSentCount;

    //*********************************************************************//
    // ------------------- transient stored properties ------------------- //
    //*********************************************************************//

    /// @dev Reentrancy guard for the initial `ccipReceive` swap. Prevents claims from consuming newly received
    /// swap output before the batch's conversion rate has been recorded.
    bool transient _ccipReceiveSwapLocked;

    /// @notice Leaf index + 1 of the claim currently in progress (set by the `claim` override).
    /// @dev Transient storage — auto-resets to 0 each transaction, saving ~9,800 gas per claim vs SSTORE.
    /// Value 0 means no active claim (bypass scaling); non-zero means leafIndex = value - 1.
    uint256 transient _currentClaimLeafIndex;

    /// @dev Reentrancy guard for `retrySwap`. Prevents claims from executing during the swap window
    /// (between delete pendingSwapOf and writing the conversion rate), which would allow zero-backed
    /// minting. Also prevents re-entry into `retrySwap` itself. Transient — auto-resets each tx.
    bool transient _retrySwapLocked;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param deployer The deployer that stores chain-specific configuration.
    /// @param directory The directory of terminals and controllers for projects.
    /// @param permissions The permissions contract.
    /// @param prices The price oracle used to convert peer-chain balances and surplus.
    /// @param tokens The contract that manages token minting and burning.
    /// @param feeProjectId The project ID that receives bridge fees.
    /// @param registry The sucker registry.
    /// @param trustedForwarder The trusted forwarder for ERC-2771 meta-transactions.
    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBPrices prices,
        IJBTokens tokens,
        uint256 feeProjectId,
        IJBSuckerRegistry registry,
        address trustedForwarder
    )
        JBCCIPSucker(deployer, directory, permissions, prices, tokens, feeProjectId, registry, trustedForwarder)
    {
        IJBSwapCCIPSuckerDeployer swapDeployer = IJBSwapCCIPSuckerDeployer(address(deployer));
        BRIDGE_TOKEN = swapDeployer.bridgeToken();
        POOL_MANAGER = swapDeployer.poolManager();
        V3_FACTORY = swapDeployer.v3Factory();
        UNIV4_HOOK = swapDeployer.univ4Hook();
        WRAPPED_NATIVE_TOKEN = IWrappedNativeToken(swapDeployer.wrappedNativeToken());

        if (address(BRIDGE_TOKEN) == address(0)) {
            revert JBSwapCCIPSucker_InvalidBridgeToken({
                bridgeToken: address(BRIDGE_TOKEN), wrappedNativeToken: address(WRAPPED_NATIVE_TOKEN)
            });
        }
        // BRIDGE_TOKEN must not be the wrapped native token — wrapping and CCIP ERC-20 bridging conflict.
        if (address(BRIDGE_TOKEN) == address(WRAPPED_NATIVE_TOKEN) && address(WRAPPED_NATIVE_TOKEN) != address(0)) {
            revert JBSwapCCIPSucker_InvalidBridgeToken({
                bridgeToken: address(BRIDGE_TOKEN), wrappedNativeToken: address(WRAPPED_NATIVE_TOKEN)
            });
        }
        // NOTE: V3_FACTORY and POOL_MANAGER can both be address(0) on chains where the local terminal token
        // IS the bridge token (e.g., USDC on Tempo). No swap is ever needed in that case. If a swap IS attempted
        // without swap infra, _discoverPool / _executeSwap will revert at runtime with JBSwapCCIPSucker_NoPool.
    }

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Allow this contract to receive native tokens (from V4 swaps, wrapped-native-token unwrap, and CCIP
    /// refunds).
    receive() external payable override {}

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Override CCIP receive to swap bridge tokens into local tokens and track denomination conversion.
    /// @dev Preserves the parent's typed message discrimination and adds swap logic for ROOT messages.
    /// For ROOT messages: swaps received bridge tokens to local tokens and tracks the leaf-to-local conversion ratio.
    /// @param any2EvmMessage The CCIP message received from the remote chain.
    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage) external override {
        // Use msg.sender (not _msgSender()) to prevent ERC2771 spoofing.
        if (msg.sender != address(CCIP_ROUTER)) revert JBSucker_NotPeer(_toBytes32(msg.sender));

        address origin = abi.decode(any2EvmMessage.sender, (address));

        if (origin != _toAddress(peer()) || any2EvmMessage.sourceChainSelector != REMOTE_CHAIN_SELECTOR) {
            revert JBSucker_NotPeer({caller: _toBytes32(origin)});
        }

        // Decode the typed message: abi.encode(uint8 type, bytes payload).
        (uint8 messageType, bytes memory payload) = JBCCIPLib.decodeTypedMessage(any2EvmMessage.data);

        if (messageType == _CCIP_MSG_TYPE_ROOT) {
            // ROOT message — swap bridge tokens to local tokens before storing the merkle root.
            // Decode the root and batch range [batchStart, batchEnd).
            (JBMessageRoot memory root, uint256 batchStart, uint256 batchEnd) =
                abi.decode(payload, (JBMessageRoot, uint256, uint256));

            address localToken = _toAddress(root.token);
            uint64 nonce = root.remoteRoot.nonce;
            uint256 leafTotal = root.amount;
            uint256 localAmount;
            bool swapFailed;
            // Cache the single delivered entry once so subsequent branches reuse it without re-indexing
            // calldata. `deliveredAmount > 0` later implies a delivery was present.
            address deliveredToken;
            uint256 deliveredAmount;
            {
                // Send-side guarantees: at most one entry in `destTokenAmounts` (length 0 for zero-value
                // batches, length 1 for value-bearing batches), and when present the delivered token is
                // `BRIDGE_TOKEN`. Refuse anything that deviates so a peer compromise or a malformed CCIP
                // delivery cannot register positive root accounting against zero or wrong-token backing.
                uint256 deliveryCount = any2EvmMessage.destTokenAmounts.length;
                if (deliveryCount > 1) {
                    revert JBSwapCCIPSucker_UnexpectedDeliveredTokens(deliveryCount);
                }
                if (deliveryCount == 0) {
                    if (leafTotal > 0) revert JBSwapCCIPSucker_PositiveRootWithoutDelivery(leafTotal);
                } else {
                    Client.EVMTokenAmount calldata delivered = any2EvmMessage.destTokenAmounts[0];
                    deliveredToken = delivered.token;
                    deliveredAmount = delivered.amount;
                    if (deliveredToken != address(BRIDGE_TOKEN)) {
                        revert JBSwapCCIPSucker_WrongDeliveredToken({
                            delivered: deliveredToken, expected: address(BRIDGE_TOKEN)
                        });
                    }
                    // Zero delivery alongside a positive root is structurally indistinguishable from
                    // "no delivery + positive root" — both leave the local sucker with nothing to back
                    // the leaves the root advertises. Reject so a peer cannot mint a claimable rate
                    // that records `leafTotal=N, localTotal=0` and lets later claims withdraw against
                    // unrelated balance.
                    if (leafTotal > 0 && deliveredAmount == 0) {
                        revert JBSwapCCIPSucker_PositiveRootWithoutDelivery(leafTotal);
                    }
                }
            }

            // Detect an already-processed batch before the swap path. The inbox nonce alone cannot be used here:
            // CCIP can deliver nonce 2 before nonce 1, and nonce 1 still needs its self-described batch metadata.
            if (
                _batchEndOf[localToken][nonce] != 0 || _conversionRateOf[localToken][nonce].leafTotal != 0
                    || pendingSwapOf[localToken][nonce].bridgeAmount != 0
            ) {
                if (deliveredAmount != 0) {
                    revert JBSwapCCIPSucker_DuplicateBatch({nonce: nonce});
                }

                return;
            }

            // After the validation block above, `deliveredToken != address(0)` iff a delivery was present,
            // because the invariants ensure it equals `BRIDGE_TOKEN` (a non-zero ERC-20) whenever there is one.
            if (deliveredToken != address(0)) {
                if (localToken == address(BRIDGE_TOKEN) || localToken == deliveredToken) {
                    // No swap needed — bridge token IS the local token.
                    localAmount = deliveredAmount;
                } else {
                    // Swap bridge token -> local token via best V3/V4 pool.
                    // Wrapped in try-catch so a swap failure doesn't revert the entire CCIP message
                    // (which would leave tokens stuck in the OffRamp). On failure, bridge tokens are
                    // stored for later retry via `retrySwap` (written below, after nonce validation).
                    _ccipReceiveSwapLocked = true;
                    try this.executeSwapExternal({
                        tokenIn: deliveredToken, tokenOut: localToken, amount: deliveredAmount
                    }) returns (
                        uint256 swapped
                    ) {
                        _ccipReceiveSwapLocked = false;
                        localAmount = swapped;
                    } catch {
                        _ccipReceiveSwapLocked = false;
                        swapFailed = true;
                        // localAmount stays 0 — pendingSwapOf and conversion rate are written
                        // below, after fromRemote validates the nonce.
                    }
                }
            }

            // Store the inbox merkle root for later claims.
            // Must be called BEFORE writing batch metadata and conversion rates so that stale
            // (duplicate/replayed) roots that fromRemote silently rejects do not overwrite
            // metadata from the original accepted delivery.
            this.fromRemote(root);

            // Write batch metadata if this nonce hasn't been seen before.
            // Decoupled from nonce advancement to support out-of-order CCIP delivery:
            // if nonce 2 arrives before nonce 1, fromRemote only advances the inbox for nonce 2,
            // but we still need to record nonce 1's batch metadata when it arrives later.
            // The Merkle tree is append-only, so nonce 1's leaves are provable against nonce 2's root.
            //
            // Detect "already seen" without extra storage: a nonce has been processed if it has
            // either a batch range (batchEnd > 0) or a conversion rate / pending swap recorded.
            // Record the batch range so _findNonceForLeafIndex can resolve leaf ownership
            // independently of nonce ordering. Each nonce is self-describing: [start, end).
            if (batchEnd > 0) {
                // Record this batch's half-open leaf range `[batchStart, batchEnd)`. Self-
                // describing per-nonce — no implicit chain across nonces — so out-of-order
                // delivery can still resolve a leaf to its batch.
                _batchStartOf[localToken][nonce] = batchStart;
                _batchEndOf[localToken][nonce] = batchEnd;

                // Append `nonce` to the populated-nonce list for this token. The duplicate guard
                // above fires at most once per (token, nonce), so each populated nonce is appended
                // exactly once — the array stays duplicate-free without extra checks.
                //
                // Reading `_populatedNonceCount[localToken]` first into a local lets us write
                // the new slot and the new count in a single read-modify-write pair (one
                // SLOAD, two SSTOREs to distinct slots). The `unchecked` increment is safe:
                // `priorCount` is bounded by the total number of populated nonces, which is
                // upper-bounded by the CCIP nonce space (`uint64`) — overflow requires more
                // batches than `uint64.max`, which the inbox can never produce.
                uint64 priorCount = _populatedNonceCount[localToken];
                _populatedNonceByIndex[localToken][priorCount] = nonce;
                unchecked {
                    _populatedNonceCount[localToken] = priorCount + 1;
                }
            }

            // Store pendingSwapOf for failed swaps now that nonce is validated.
            if (swapFailed) {
                pendingSwapOf[localToken][nonce] =
                    PendingSwap({bridgeToken: deliveredToken, bridgeAmount: deliveredAmount, leafTotal: leafTotal});
            }

            // Zero-output swap guard: When a swap succeeds but returns zero local tokens, the
            // batch must NOT be marked claimable. Without this guard, `_addToBalance` would see
            // `pendingSwapOf.bridgeAmount == 0` (no pending swap stored) and allow claims to
            // proceed — minting the full bridged project-token amount while adding zero terminal
            // backing, breaking cross-chain solvency.
            //
            // Route zero-output swaps into `pendingSwapOf` so the swap can be retried via
            // `retrySwap` once pool conditions improve. Only store the conversion rate when
            // the swap produced a positive local amount.
            if (leafTotal > 0 && !swapFailed) {
                if (localAmount == 0 && deliveredAmount > 0) {
                    pendingSwapOf[localToken][nonce] =
                        PendingSwap({bridgeToken: deliveredToken, bridgeAmount: deliveredAmount, leafTotal: leafTotal});
                } else {
                    _conversionRateOf[localToken][nonce] =
                        ConversionRate({leafTotal: leafTotal, localTotal: localAmount});
                }
            }
        } else {
            revert JBCCIPSucker_UnknownMessageType({messageType: messageType});
        }
    }

    /// @notice Uniswap V3 swap callback — delegates to JBSwapPoolLib (via DELEGATECALL) to reduce bytecode.
    /// @param amount0Delta The amount of token0 used for the swap.
    /// @param amount1Delta The amount of token1 used for the swap.
    /// @param data Encoded (originalTokenIn, normalizedTokenIn, normalizedTokenOut).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        JBSwapPoolLib.executeV3SwapCallback({
            v3Factory: V3_FACTORY, amount0Delta: amount0Delta, amount1Delta: amount1Delta, data: data
        });
    }

    /// @notice Uniswap V4 unlock callback — delegates to JBSwapPoolLib (via DELEGATECALL) to reduce bytecode.
    /// @param data Encoded swap parameters from PoolManager.unlock().
    /// @return Encoded output amount.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert JBSwapCCIPSucker_CallerNotPoolManager(msg.sender);
        return JBSwapPoolLib.executeV4UnlockCallback({poolManager: POOL_MANAGER, data: data});
    }

    /// @notice External swap entry point callable ONLY by this contract. Exists so `ccipReceive` can
    /// wrap the swap in a try-catch (Solidity requires an external call target for try-catch).
    /// @param tokenIn The input token address.
    /// @param tokenOut The output token address.
    /// @param amount The amount of input tokens to swap.
    /// @return amountOut The amount of output tokens received.
    function executeSwapExternal(
        address tokenIn,
        address tokenOut,
        uint256 amount
    )
        external
        returns (uint256 amountOut)
    {
        if (msg.sender != address(this)) {
            revert JBSwapCCIPSucker_OnlySelf({caller: msg.sender, expected: address(this)});
        }
        return _executeSwap({tokenIn: tokenIn, tokenOut: tokenOut, amount: amount});
    }

    /// @notice Retry a previously failed inbound swap. Anyone can call this once swap conditions improve.
    /// @dev On success, updates the conversion rate so claims for this nonce's batch can proceed.
    /// Always uses TWAP quoting — no caller-provided `minAmountOut`. Unlike the router terminal (where the
    /// caller is spending their own funds and can accept any slippage they choose), here the swap output
    /// determines the conversion rate for ALL claimers of this batch. Allowing a caller-controlled minimum
    /// would let an attacker sandwich the swap with `minAmountOut = 1` and lock in a bad rate for everyone.
    /// @param localToken The local token that the bridge tokens should be swapped into.
    /// @param nonce The nonce of the batch whose swap failed.
    function retrySwap(address localToken, uint64 nonce) external {
        // Reentrancy guard: prevents re-entry into retrySwap AND prevents claims from executing
        // during the swap window (which would see the stale {leafTotal > 0, localTotal: 0} rate
        // and mint project tokens backed by zero terminal tokens).
        if (_retrySwapLocked) {
            revert JBSwapCCIPSucker_NoPendingSwap({
                localToken: localToken, nonce: nonce, retrySwapLocked: _retrySwapLocked
            });
        }
        _retrySwapLocked = true;

        PendingSwap memory pending = pendingSwapOf[localToken][nonce];
        if (pending.bridgeAmount == 0) {
            revert JBSwapCCIPSucker_NoPendingSwap({
                localToken: localToken, nonce: nonce, retrySwapLocked: _retrySwapLocked
            });
        }

        uint256 localAmount =
            _executeSwapOrRevert({tokenIn: pending.bridgeToken, tokenOut: localToken, amount: pending.bridgeAmount});

        // Update the conversion rate so claims can proceed, then clear the pending swap.
        _conversionRateOf[localToken][nonce] = ConversionRate({leafTotal: pending.leafTotal, localTotal: localAmount});
        delete pendingSwapOf[localToken][nonce];

        _retrySwapLocked = false;
        emit SwapRetried({
            localToken: localToken,
            nonce: nonce,
            bridgeAmount: pending.bridgeAmount,
            localAmount: localAmount,
            caller: _msgSender()
        });
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Override single claim to set the leaf index context for `_addToBalance` scaling.
    /// @dev The batch `claim(JBClaim[])` calls this in a loop, so it works automatically.
    /// Stores leafIndex + 1 (0 = no active claim sentinel). No reset needed — transient storage auto-clears.
    /// @param claimData The claim data containing the leaf and proof.
    function claim(JBClaim calldata claimData) public override {
        // Block claims during retrySwap to prevent zero-backed minting via reentrancy.
        if (_retrySwapLocked || _ccipReceiveSwapLocked) revert JBSwapCCIPSucker_SwapPending(0);
        _currentClaimLeafIndex = claimData.leaf.index + 1;
        super.claim(claimData);
        // Clear stale transient context to prevent leaking into same-tx emergency exits.
        _currentClaimLeafIndex = 0;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Override to scale claim amounts from source-chain denomination to local-chain denomination.
    /// @dev When cross-currency bridging, merkle tree leaf amounts are in the source chain's terminal token
    /// denomination. This override converts them proportionally using the nonce-indexed conversion rate
    /// populated during `ccipReceive`.
    ///
    /// **Per-batch isolation**: Each received root stores an immutable conversion rate keyed by nonce.
    /// The `claim` override sets `_currentClaimLeafIndex`, which this function uses to look up the
    /// correct nonce (and thus the correct rate) for the claim. This prevents out-of-order CCIP
    /// delivery from applying the wrong batch's rate to a claim.
    /// @param token The local token address.
    /// @param amount The claim amount in source-chain denomination.
    /// @param cachedProjectId The project ID (cached for gas efficiency).
    function _addToBalance(address token, uint256 amount, uint256 cachedProjectId) internal override {
        if (_currentClaimLeafIndex != 0) {
            uint64 nonce = _findNonceForLeafIndex({token: token, leafIndex: _currentClaimLeafIndex - 1});
            if (nonce != 0) {
                // Gate on pending swaps — if a swap failed and hasn't been retried yet,
                // claims must wait. This check must come BEFORE the leafTotal gate so that
                // failed swaps (where _conversionRateOf was never written) still block claims.
                if (pendingSwapOf[token][nonce].bridgeAmount > 0) {
                    revert JBSwapCCIPSucker_SwapPending({nonce: nonce});
                }
                ConversionRate storage rate = _conversionRateOf[token][nonce];
                if (rate.leafTotal > 0) {
                    amount = amount * rate.localTotal / rate.leafTotal;
                }
            }
        }

        super._addToBalance({token: token, amount: amount, cachedProjectId: cachedProjectId});
    }

    /// @notice Override to swap local tokens into bridge tokens before CCIP bridging.
    /// @dev Does NOT modify `suckerMessage.amount` — keeps the original leaf-denomination total so the
    /// receiving chain can use it (along with the actual delivered amount) to compute the proportional
    /// scaling factor for individual claims.
    /// Delegates CCIP message construction to JBCCIPLib (via DELEGATECALL) to reduce bytecode.
    /// @param transportPayment The ETH sent for CCIP fees.
    /// @param index The last leaf index in the current batch.
    /// @param token The local token to bridge.
    /// @param amount The amount of local tokens to bridge.
    /// @param remoteToken The remote token configuration (including minGas).
    /// @param suckerMessage The merkle root message to send to the remote chain.
    // forge-lint: disable-next-line(mixed-case-function)
    function _sendRootOverAMB(
        uint256 transportPayment,
        uint256 index,
        address token,
        uint256 amount,
        JBRemoteToken memory remoteToken,
        JBMessageRoot memory suckerMessage
    )
        internal
        override
    {
        Client.EVMTokenAmount[] memory tokenAmounts;
        bytes memory encodedPayload;

        {
            uint256 bridgeAmount;
            if (amount == 0) {
                tokenAmounts = new Client.EVMTokenAmount[](0);
            } else {
                address bridgeTokenAddr = address(BRIDGE_TOKEN);

                if (token == bridgeTokenAddr) {
                    bridgeAmount = amount;
                } else {
                    // Always use TWAP quoting — no caller-provided minAmountOut. Unlike the router terminal
                    // (where the caller spends their own funds), here the swap output sets the conversion
                    // rate for ALL claimers of the batch. Caller-controlled slippage would allow sandwich
                    // attacks that lock in bad rates for everyone.
                    bridgeAmount = _executeSwapOrRevert({tokenIn: token, tokenOut: bridgeTokenAddr, amount: amount});
                }

                tokenAmounts = new Client.EVMTokenAmount[](1);
                tokenAmounts[0] = Client.EVMTokenAmount({token: bridgeTokenAddr, amount: bridgeAmount});
                BRIDGE_TOKEN.forceApprove({spender: address(CCIP_ROUTER), value: bridgeAmount});
            }

            // NOTE: suckerMessage.amount stays as the original leaf-denomination total.
            // Encode batch range [batchStart, batchEnd) so the receiver can resolve leaf ownership
            // per-nonce without requiring contiguous nonce delivery.
            uint256 batchStart = _lastSentCount[token];
            uint256 batchEnd = index + 1;
            _lastSentCount[token] = batchEnd;
            encodedPayload = abi.encode(_CCIP_MSG_TYPE_ROOT, abi.encode(suckerMessage, batchStart, batchEnd));
        }

        {
            // Determine fee payment mode: native ETH or LINK token.
            address feeToken = transportPayment == 0 ? CCIPHelper.linkOfChain(block.chainid) : address(0);

            (bool refundFailed, uint256 refundAmount) = JBCCIPLib.sendCCIPMessage({
                ccipRouter: CCIP_ROUTER,
                remoteChainSelector: REMOTE_CHAIN_SELECTOR,
                peerAddress: _toAddress(peer()),
                transportPayment: transportPayment,
                feeToken: feeToken,
                feeTokenPayer: feeToken != address(0) ? _msgSender() : address(0),
                gasLimit: MESSENGER_BASE_GAS_LIMIT + remoteToken.minGas,
                encodedPayload: encodedPayload,
                tokenAmounts: tokenAmounts,
                refundRecipient: _msgSender()
            });

            if (refundFailed) {
                _retainTransportPaymentRefund({account: _msgSender(), amount: refundAmount});
                emit TransportPaymentRefundFailed({recipient: _msgSender(), amount: refundAmount, caller: _msgSender()});
            }
        }
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Execute a swap between two tokens using the best available V3 or V4 pool.
    /// @dev Delegates pool discovery, TWAP quoting, and swap execution to JBSwapPoolLib (via DELEGATECALL).
    /// Swap callbacks (`uniswapV3SwapCallback`, `unlockCallback`) remain on this contract.
    /// Always uses TWAP quoting (minAmountOut = 0) — see contract NatSpec for rationale.
    /// @param tokenIn The input token (raw address, e.g., NATIVE_TOKEN sentinel for ETH).
    /// @param tokenOut The output token (raw address).
    /// @param amount The amount of input tokens to swap.
    /// @return amountOut The amount of output tokens received.
    function _executeSwap(address tokenIn, address tokenOut, uint256 amount) internal returns (uint256 amountOut) {
        return JBSwapPoolLib.executeSwap({
            config: JBSwapPoolLib.SwapConfig({
                v3Factory: V3_FACTORY,
                poolManager: POOL_MANAGER,
                univ4Hook: UNIV4_HOOK,
                wrappedNativeToken: address(WRAPPED_NATIVE_TOKEN)
            }),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amount: amount,
            minAmountOut: 0
        });
    }

    /// @notice Execute a swap and revert if it produces no output.
    /// @param tokenIn The input token.
    /// @param tokenOut The output token.
    /// @param amount The input amount.
    /// @return amountOut The output amount.
    function _executeSwapOrRevert(
        address tokenIn,
        address tokenOut,
        uint256 amount
    )
        internal
        returns (uint256 amountOut)
    {
        amountOut = _executeSwap({tokenIn: tokenIn, tokenOut: tokenOut, amount: amount});
        if (amountOut == 0) {
            revert JBSwapCCIPSucker_SwapFailed({tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amount});
        }
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Find the received nonce whose batch contains the given leaf index.
    /// @dev Walks `_populatedNonceByIndex` instead of `[1, highestNonce]`. The populated list is the
    /// only set that can contain a claimable batch, and it stays compact even when CCIP delivers
    /// nonce 10 before nonce 2. This keeps lookup O(K) where K is received batches, avoids sparse
    /// empty-slot scans, and keeps the deployable bytecode below the EIP-170 size limit.
    /// @param token The local token address.
    /// @param leafIndex The leaf index from the claim.
    /// @return The nonce of the batch containing this leaf, or 0 if no batches have been recorded.
    function _findNonceForLeafIndex(address token, uint256 leafIndex) internal view returns (uint64) {
        // No populated batches for this token means there is no conversion rate to apply. Preserve
        // nonce 0 as the "unbatched" sentinel used by `_addToBalance`'s non-claim path.
        uint64 count = _populatedNonceCount[token];
        if (count == 0) return 0;

        // Walk only nonces that actually received a batch. The array is insertion-ordered, not
        // sorted, because CCIP can deliver batches out of nonce order; each entry still points to a
        // self-contained `[batchStart, batchEnd)` range written before the append.
        unchecked {
            for (uint64 i; i < count; i++) {
                uint64 nonce = _populatedNonceByIndex[token][i];
                uint256 end = _batchEndOf[token][nonce];

                // Ranges are non-overlapping across populated nonces. The first hit is therefore
                // the unique conversion-rate batch for this claim leaf.
                if (leafIndex >= _batchStartOf[token][nonce] && leafIndex < end) return nonce;
            }
        }

        // Batches exist for the token, but none cover this leaf index; surface the same error used
        // before the compact populated-nonce index was introduced.
        revert JBSwapCCIPSucker_BatchNotReceived({nonce: 0});
    }
}
