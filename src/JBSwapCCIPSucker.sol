// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Core JB imports.
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
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
    error JBSwapCCIPSucker_InvalidBridgeToken();
    error JBSwapCCIPSucker_NoPendingSwap();
    error JBSwapCCIPSucker_OnlySelf();
    error JBSwapCCIPSucker_SwapFailed();
    error JBSwapCCIPSucker_SwapPending(uint64 nonce);

    //*********************************************************************//
    // ------------------------------ events ----------------------------- //
    //*********************************************************************//

    /// @notice Emitted when a previously failed inbound swap is successfully retried.
    /// @param localToken The local token that the bridge tokens were swapped into.
    /// @param nonce The nonce of the batch whose swap was retried.
    /// @param bridgeAmount The amount of bridge tokens that were swapped.
    /// @param localAmount The amount of local tokens received from the retry swap.
    event SwapRetried(address indexed localToken, uint64 indexed nonce, uint256 bridgeAmount, uint256 localAmount);

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

    /// @notice The wrapped native token (e.g., WETH on Ethereum). Used for V3 native swaps.
    IWrappedNativeToken public immutable WETH;

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

    /// @notice Cached nonce from the last successful `_findNonceForLeafIndex` lookup.
    /// @dev Batched claims from the same nonce hit this cache and skip the scan entirely.
    /// @custom:param token The local token address.
    mapping(address token => uint64) internal _cachedNonce;

    /// @notice Conversion rate for each received root batch, keyed by token and nonce.
    /// @custom:param token The local token address.
    /// @custom:param nonce The CCIP nonce identifying the batch.
    mapping(address token => mapping(uint64 nonce => ConversionRate)) internal _conversionRateOf;

    /// @notice Highest nonce received so far per token. Used as upper bound for nonce iteration.
    /// @custom:param token The local token address.
    mapping(address token => uint64) internal _highestReceivedNonce;

    /// @notice Cumulative leaf count at the last `_sendRootOverAMB` call, per token.
    /// @dev Used on the sender side to derive the batch start index for the next send.
    /// @custom:param token The local token address.
    mapping(address token => uint256) internal _lastSentCount;

    //*********************************************************************//
    // ------------------- transient stored properties ------------------- //
    //*********************************************************************//

    /// @notice Leaf index + 1 of the claim currently being processed (set by `claim` override).
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
    /// @param tokens The contract that manages token minting and burning.
    /// @param permissions The permissions contract.
    /// @param feeProjectId The project ID that receives bridge fees.
    /// @param registry The sucker registry.
    /// @param trustedForwarder The trusted forwarder for ERC-2771 meta-transactions.
    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions,
        uint256 feeProjectId,
        IJBSuckerRegistry registry,
        address trustedForwarder
    )
        JBCCIPSucker(deployer, directory, tokens, permissions, feeProjectId, registry, trustedForwarder)
    {
        IJBSwapCCIPSuckerDeployer swapDeployer = IJBSwapCCIPSuckerDeployer(address(deployer));
        BRIDGE_TOKEN = swapDeployer.bridgeToken();
        POOL_MANAGER = swapDeployer.poolManager();
        V3_FACTORY = swapDeployer.v3Factory();
        UNIV4_HOOK = swapDeployer.univ4Hook();
        WETH = IWrappedNativeToken(swapDeployer.weth());

        if (address(BRIDGE_TOKEN) == address(0)) revert JBSwapCCIPSucker_InvalidBridgeToken();
        // BRIDGE_TOKEN must not be WETH — native/WETH wrapping and CCIP ERC-20 bridging conflict.
        if (address(BRIDGE_TOKEN) == address(WETH) && address(WETH) != address(0)) {
            revert JBSwapCCIPSucker_InvalidBridgeToken();
        }
        // NOTE: V3_FACTORY and POOL_MANAGER can both be address(0) on chains where the local terminal token
        // IS the bridge token (e.g., USDC on Tempo). No swap is ever needed in that case. If a swap IS attempted
        // without swap infra, _discoverPool / _executeSwap will revert at runtime with JBSwapCCIPSucker_NoPool.
    }

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Allow this contract to receive ETH (from V4 swaps, WETH unwrap, and CCIP refunds).
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
            revert JBSucker_NotPeer(_toBytes32(origin));
        }

        // Decode the typed message: abi.encode(uint8 type, bytes payload).
        (uint8 messageType, bytes memory payload) = JBCCIPLib.decodeTypedMessage(any2EvmMessage.data);

        if (messageType == _CCIP_MSG_TYPE_ROOT) {
            // ROOT message — swap bridge tokens to local tokens before storing the merkle root.
            // Decode the root and batch range [batchStart, batchEnd).
            (JBMessageRoot memory root, uint256 batchStart, uint256 batchEnd) =
                abi.decode(payload, (JBMessageRoot, uint256, uint256));

            address localToken = _toAddress(root.token);
            uint256 localAmount;

            if (any2EvmMessage.destTokenAmounts.length == 1) {
                Client.EVMTokenAmount memory tokenAmount = any2EvmMessage.destTokenAmounts[0];

                if (localToken == address(BRIDGE_TOKEN) || localToken == tokenAmount.token) {
                    // No swap needed — bridge token IS the local token.
                    localAmount = tokenAmount.amount;
                } else {
                    // Swap bridge token -> local token via best V3/V4 pool.
                    // Wrapped in try-catch so a swap failure doesn't revert the entire CCIP message
                    // (which would leave tokens stuck in the OffRamp). On failure, bridge tokens are
                    // stored for later retry via `retrySwap`.
                    // slither-disable-next-line reentrancy-benign,reentrancy-events
                    try this.executeSwapExternal({
                        tokenIn: tokenAmount.token, tokenOut: localToken, amount: tokenAmount.amount
                    }) returns (
                        uint256 swapped
                    ) {
                        localAmount = swapped;
                    } catch {
                        // Store for later retry. Merkle root and batch range still get stored below.
                        pendingSwapOf[localToken][root.remoteRoot.nonce] = PendingSwap({
                            bridgeToken: tokenAmount.token, bridgeAmount: tokenAmount.amount, leafTotal: root.amount
                        });
                        // localAmount stays 0 — the conversion rate code below will set
                        // localTotal: 0, gating claims until retrySwap succeeds.
                    }
                }
            }

            // Record the batch range so _findNonceForLeafIndex can resolve leaf ownership
            // independently of nonce ordering. Each nonce is self-describing: [start, end).
            if (batchEnd > 0) {
                _batchStartOf[localToken][root.remoteRoot.nonce] = batchStart;
                _batchEndOf[localToken][root.remoteRoot.nonce] = batchEnd;
                if (root.remoteRoot.nonce > _highestReceivedNonce[localToken]) {
                    _highestReceivedNonce[localToken] = root.remoteRoot.nonce;
                }
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
            if (root.amount > 0) {
                if (localAmount == 0 && any2EvmMessage.destTokenAmounts.length == 1) {
                    Client.EVMTokenAmount memory zeroSwapTokenAmount = any2EvmMessage.destTokenAmounts[0];
                    // Only route to pending if there were actual bridge tokens delivered.
                    // If bridgeAmount is also 0 (zero-value batch), store the conversion rate
                    // normally — there is nothing to retry.
                    if (zeroSwapTokenAmount.amount > 0) {
                        pendingSwapOf[localToken][root.remoteRoot.nonce] = PendingSwap({
                            bridgeToken: zeroSwapTokenAmount.token,
                            bridgeAmount: zeroSwapTokenAmount.amount,
                            leafTotal: root.amount
                        });
                    } else {
                        _conversionRateOf[localToken][root.remoteRoot.nonce] =
                            ConversionRate({leafTotal: root.amount, localTotal: 0});
                    }
                } else {
                    _conversionRateOf[localToken][root.remoteRoot.nonce] =
                        ConversionRate({leafTotal: root.amount, localTotal: localAmount});
                }
            }

            // Store the inbox merkle root for later claims.
            this.fromRemote(root);
        } else {
            revert JBCCIPSucker_UnknownMessageType(messageType);
        }
    }

    /// @notice Uniswap V3 swap callback — delegates to JBSwapPoolLib (via DELEGATECALL) to reduce bytecode.
    /// @param amount0Delta The amount of token0 being used for the swap.
    /// @param amount1Delta The amount of token1 being used for the swap.
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
        if (msg.sender != address(this)) revert JBSwapCCIPSucker_OnlySelf();
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
        if (_retrySwapLocked) revert JBSwapCCIPSucker_NoPendingSwap();
        _retrySwapLocked = true;

        PendingSwap memory pending = pendingSwapOf[localToken][nonce];
        if (pending.bridgeAmount == 0) revert JBSwapCCIPSucker_NoPendingSwap();

        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events
        uint256 localAmount =
            _executeSwap({tokenIn: pending.bridgeToken, tokenOut: localToken, amount: pending.bridgeAmount});

        // Update the conversion rate so claims can proceed, then clear the pending swap.
        _conversionRateOf[localToken][nonce] = ConversionRate({leafTotal: pending.leafTotal, localTotal: localAmount});
        delete pendingSwapOf[localToken][nonce];

        _retrySwapLocked = false;
        emit SwapRetried(localToken, nonce, pending.bridgeAmount, localAmount);
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
        if (_retrySwapLocked) revert JBSwapCCIPSucker_SwapPending(0);
        // slither-disable-next-line events-maths
        _currentClaimLeafIndex = claimData.leaf.index + 1;
        super.claim(claimData);
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
                ConversionRate storage rate = _conversionRateOf[token][nonce];
                if (rate.leafTotal > 0) {
                    // Gate on pending swaps — if a swap failed and hasn't been retried yet,
                    // claims must wait. Check pendingSwapOf rather than localTotal == 0 to
                    // distinguish a pending swap from a legitimately zero-output swap.
                    if (pendingSwapOf[token][nonce].bridgeAmount > 0) {
                        revert JBSwapCCIPSucker_SwapPending(nonce);
                    }
                    amount = amount * rate.localTotal / rate.leafTotal;
                }
            }
        }

        super._addToBalance({token: token, amount: amount, cachedProjectId: cachedProjectId});
    }

    /// @notice Find the nonce whose batch contains the given leaf index.
    /// @dev Uses a per-token cache with neighbor probing for O(1) lookups when claims are batched
    /// sequentially. Falls back to a reverse scan (most-recent-first) so recent claims resolve quickly.
    /// @param token The local token address.
    /// @param leafIndex The leaf index from the claim.
    /// @return The nonce of the batch containing this leaf, or 0 if no conversion rates exist.
    function _findNonceForLeafIndex(address token, uint256 leafIndex) internal returns (uint64) {
        uint64 maxNonce = _highestReceivedNonce[token];
        if (maxNonce == 0) return 0;

        // Fast path: check cached nonce and its neighbors (covers sequential batch claims).
        uint64 hint = _cachedNonce[token];
        if (hint != 0) {
            // Check the cached nonce itself.
            if (_nonceContainsLeaf(token, hint, leafIndex)) return hint;
            // Check the next nonce (common pattern: claims move to the next batch).
            if (hint < maxNonce && _nonceContainsLeaf(token, hint + 1, leafIndex)) {
                _cachedNonce[token] = hint + 1;
                return hint + 1;
            }
            // Check the previous nonce (out-of-order claim from an earlier batch).
            if (hint > 1 && _nonceContainsLeaf(token, hint - 1, leafIndex)) {
                _cachedNonce[token] = hint - 1;
                return hint - 1;
            }
        }

        // Slow path: scan from most recent nonce backwards (recent claims found quickly).
        for (uint64 n = maxNonce; n >= 1; n--) {
            if (_nonceContainsLeaf(token, n, leafIndex)) {
                _cachedNonce[token] = n;
                return n;
            }
        }
        // Leaf index not found in any received batch.
        revert JBSwapCCIPSucker_BatchNotReceived(0);
    }

    /// @notice Check whether the given nonce's batch range contains the leaf index.
    /// @param token The local token address.
    /// @param nonce The nonce to check.
    /// @param leafIndex The leaf index to look for.
    /// @return True if the nonce's [start, end) range contains `leafIndex`.
    function _nonceContainsLeaf(address token, uint64 nonce, uint256 leafIndex) internal view returns (bool) {
        uint256 end = _batchEndOf[token][nonce];
        return end != 0 && leafIndex >= _batchStartOf[token][nonce] && leafIndex < end;
    }

    /// @notice Override to swap local tokens into bridge tokens before CCIP bridging.
    /// @dev Does NOT modify `sucker_message.amount` — keeps the original leaf-denomination total so the
    /// receiving chain can use it (along with the actual delivered amount) to compute the proportional
    /// scaling factor for individual claims.
    /// Delegates CCIP message construction to JBCCIPLib (via DELEGATECALL) to reduce bytecode.
    /// @param transportPayment The ETH sent for CCIP fees.
    /// @param index The last leaf index in the current batch.
    /// @param token The local token being bridged.
    /// @param amount The amount of local tokens to bridge.
    /// @param remoteToken The remote token configuration (including minGas).
    /// @param sucker_message The merkle root message to send to the remote chain.
    // forge-lint: disable-next-line(mixed-case-function)
    function _sendRootOverAMB(
        uint256 transportPayment,
        uint256 index,
        address token,
        uint256 amount,
        JBRemoteToken memory remoteToken,
        JBMessageRoot memory sucker_message
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
                    // slither-disable-next-line reentrancy-events,reentrancy-benign
                    bridgeAmount = _executeSwap({tokenIn: token, tokenOut: bridgeTokenAddr, amount: amount});
                    if (bridgeAmount == 0) revert JBSwapCCIPSucker_SwapFailed();
                }

                tokenAmounts = new Client.EVMTokenAmount[](1);
                tokenAmounts[0] = Client.EVMTokenAmount({token: bridgeTokenAddr, amount: bridgeAmount});
                BRIDGE_TOKEN.forceApprove({spender: address(CCIP_ROUTER), value: bridgeAmount});
            }

            // NOTE: sucker_message.amount stays as the original leaf-denomination total.
            // Encode batch range [batchStart, batchEnd) so the receiver can resolve leaf ownership
            // per-nonce without requiring contiguous nonce delivery.
            uint256 batchStart = _lastSentCount[token];
            uint256 batchEnd = index + 1;
            _lastSentCount[token] = batchEnd;
            encodedPayload = abi.encode(_CCIP_MSG_TYPE_ROOT, abi.encode(sucker_message, batchStart, batchEnd));
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

            if (refundFailed) emit TransportPaymentRefundFailed(_msgSender(), refundAmount);
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
                v3Factory: V3_FACTORY, poolManager: POOL_MANAGER, univ4Hook: UNIV4_HOOK, weth: address(WETH)
            }),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amount: amount,
            minAmountOut: 0
        });
    }
}
