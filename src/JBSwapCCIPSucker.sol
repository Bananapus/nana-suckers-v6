// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Core JB imports.
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

// CCIP imports.
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

// OpenZeppelin imports.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap V3 imports.
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

// Uniswap V4 imports.
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Local: contracts.
import {JBCCIPSucker} from "./JBCCIPSucker.sol";

// Local: deployers.
import {JBSwapCCIPSuckerDeployer} from "./deployers/JBSwapCCIPSuckerDeployer.sol";

// Local: interfaces (alphabetized).
import {ICCIPRouter} from "./interfaces/ICCIPRouter.sol";
import {IGeomeanOracle} from "./interfaces/IGeomeanOracle.sol";
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";
import {IJBSwapCCIPSuckerDeployer} from "./interfaces/IJBSwapCCIPSuckerDeployer.sol";
import {IWrappedNativeToken} from "./interfaces/IWrappedNativeToken.sol";

// Local: libraries.
import {JBSwapLib} from "./libraries/JBSwapLib.sol";

// Local: structs (alphabetized).
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBPayRemoteMessage} from "./structs/JBPayRemoteMessage.sol";
import {JBRemoteToken} from "./structs/JBRemoteToken.sol";

/// @notice A `JBCCIPSucker` extension that swaps between local and bridge tokens using the best
/// Uniswap V3 or V4 pool before/after CCIP bridging.
/// @dev Enables cross-currency bridging: e.g., ETH on Ethereum <-> USDC on Tempo.
/// Discovers the most liquid pool across V3 fee tiers and V4 pool configurations,
/// then applies TWAP-based quoting with sigmoid slippage protection.
///
/// **Cross-denomination claim scaling:** Because the merkle tree leaf amounts are denominated in the
/// source chain's terminal token, the receiving chain must scale each claim proportionally. This contract
/// maintains a FIFO queue of per-batch conversion entries (one per received root), preserving each batch's
/// exact swap rate. `_addToBalance` consumes entries from the oldest batch first, applying the rate
/// `scaledAmount = leafAmount * batchLocal / batchLeaf` for each batch independently.
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
/// **Liveness risk**: If a swap reverts during `ccipReceive` (due to insufficient liquidity, stale
/// TWAP observations, or extreme price impact exceeding the sigmoid slippage tolerance), the bridged
/// tokens remain in the CCIP OffRamp contract. They are NOT permanently lost — CCIP supports manual
/// re-execution with adjusted gas limits once swap conditions improve. However, the tokens are
/// inaccessible until the message is successfully re-executed. This is a liveness concern, not a
/// fund-loss risk. Operators should monitor for failed CCIP messages and trigger re-execution when
/// liquidity or price conditions normalize.
contract JBSwapCCIPSucker is JBCCIPSucker, IUnlockCallback, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBSwapCCIPSucker_SwapFailed();
    error JBSwapCCIPSucker_InvalidBridgeToken();
    error JBSwapCCIPSucker_CallerNotPoolManager(address caller);
    error JBSwapCCIPSucker_CallerNotPool(address caller);
    error JBSwapCCIPSucker_SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error JBSwapCCIPSucker_NoPool();
    error JBSwapCCIPSucker_NoLiquidity();
    error JBSwapCCIPSucker_InsufficientTwapHistory();
    error JBSwapCCIPSucker_AmountOverflow(uint256 amount);

    //*********************************************************************//
    // --------------------- private constants -------------------------- //
    //*********************************************************************//

    /// @notice Default V3 TWAP window (10 minutes).
    uint256 private constant _DEFAULT_TWAP_WINDOW = 600;

    /// @notice Minimum V3 TWAP window (2 minutes).
    uint256 private constant _MIN_TWAP_WINDOW = 120;

    /// @notice V4 hook TWAP window (2 minutes). Matches the minimum V3 TWAP window for
    /// consistent manipulation resistance across both pool versions.
    uint32 private constant _V4_TWAP_WINDOW = 120;

    /// @notice Denominator for slippage tolerance basis points.
    uint256 private constant _SLIPPAGE_DENOMINATOR = 10_000;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The ERC-20 token used for CCIP bridging (e.g., USDC). Must exist on both chains.
    IERC20 public immutable BRIDGE_TOKEN;

    /// @notice The Uniswap V4 PoolManager. Can be address(0) if V4 is unavailable on this chain.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice The Uniswap V3 factory for pool discovery and callback verification. Can be address(0).
    IUniswapV3Factory public immutable V3_FACTORY;

    /// @notice The Uniswap V4 hook address for pool discovery (optional).
    address public immutable UNIV4_HOOK;

    /// @notice The wrapped native token (e.g., WETH on Ethereum). Used for V3 native swaps.
    IWrappedNativeToken public immutable WETH;

    //*********************************************************************//
    // ------------------- internal stored properties -------------------- //
    //*********************************************************************//

    /// @notice A conversion entry preserving the exact exchange rate of one received root batch.
    /// @dev Stored in a FIFO queue per token so each batch's rate is applied independently.
    struct ConversionEntry {
        uint256 leafAmount; // Remaining leaf-denomination (source chain) amount
        uint256 localAmount; // Remaining local-denomination (after swap) amount
    }

    /// @notice FIFO queue of conversion entries per token, one per received root batch.
    /// @dev Claims consume entries from the head of the queue (oldest batch first), ensuring
    /// each batch is scaled at its own swap rate rather than a blended token-wide average.
    mapping(address token => ConversionEntry[]) internal _conversionQueue;

    /// @notice Head pointer into `_conversionQueue[token]` — the index of the next entry to consume.
    mapping(address token => uint256) internal _conversionQueueHead;

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
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Uniswap V4 unlock callback — executes the swap atomically within `PoolManager.unlock()`.
    /// @param data Encoded swap parameters: (PoolKey, bool zeroForOne, int256 amountSpecified,
    ///             uint160 sqrtPriceLimit, uint256 minAmountOut).
    /// @return Encoded output amount.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert JBSwapCCIPSucker_CallerNotPoolManager(msg.sender);

        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, uint256 minAmountOut) =
            abi.decode(data, (PoolKey, bool, int256, uint160, uint256));

        // Execute the swap.
        BalanceDelta delta = POOL_MANAGER.swap({
            key: key,
            params: SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            hookData: ""
        });

        // V4 sign convention: negative = we owe (input), positive = we're owed (output).
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        uint256 amountIn;
        uint256 amountOut;

        if (zeroForOne) {
            amountIn = uint256(uint128(-delta0));
            amountOut = uint256(uint128(delta1));
        } else {
            amountIn = uint256(uint128(-delta1));
            amountOut = uint256(uint128(delta0));
        }

        if (amountOut < minAmountOut) revert JBSwapCCIPSucker_SlippageExceeded(amountOut, minAmountOut);

        // Settle input (pay what we owe to the PoolManager).
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        _settleV4(inputCurrency, amountIn);

        // Take output (receive what the PoolManager owes us).
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        _takeV4(outputCurrency, amountOut);

        return abi.encode(amountOut);
    }

    /// @notice Uniswap V3 swap callback — settles the input side of the swap.
    /// @dev Verifies the caller is a legitimate pool via the factory, then transfers input tokens.
    /// @param amount0Delta The amount of token0 being used for the swap.
    /// @param amount1Delta The amount of token1 being used for the swap.
    /// @param data Encoded (originalTokenIn, normalizedTokenIn, normalizedTokenOut).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        (address originalTokenIn, address normalizedIn, address normalizedOut) =
            abi.decode(data, (address, address, address));

        // Verify caller is a legitimate V3 pool via the factory.
        // slither-disable-next-line calls-loop
        uint24 fee = IUniswapV3Pool(msg.sender).fee();
        address expectedPool = V3_FACTORY.getPool({tokenA: normalizedIn, tokenB: normalizedOut, fee: fee});
        if (msg.sender != expectedPool) revert JBSwapCCIPSucker_CallerNotPool(msg.sender);

        // The positive delta is what we owe to the pool.
        uint256 amountToSend = amount0Delta < 0 ? uint256(amount1Delta) : uint256(amount0Delta);

        // If input is native ETH, wrap to WETH for V3.
        if (originalTokenIn == JBConstants.NATIVE_TOKEN) {
            WETH.deposit{value: amountToSend}();
        }

        IERC20(normalizedIn).safeTransfer({to: msg.sender, value: amountToSend});
    }

    /// @notice Override CCIP receive to swap bridge tokens into local tokens and track denomination conversion.
    /// @dev Preserves the parent's typed message discrimination (ROOT vs PAY) and adds swap logic for ROOT messages.
    /// For ROOT messages: swaps received bridge tokens to local tokens and tracks the leaf-to-local conversion ratio.
    /// For PAY messages: delegates to the parent's flow (unwrap WETH if needed, then payFromRemote).
    /// @param any2EvmMessage The CCIP message received from the remote chain.
    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage) external override {
        // Use msg.sender (not _msgSender()) to prevent ERC2771 spoofing.
        if (msg.sender != address(CCIP_ROUTER)) revert JBSucker_NotPeer(_toBytes32(msg.sender));

        address origin = abi.decode(any2EvmMessage.sender, (address));

        if (origin != _toAddress(peer()) || any2EvmMessage.sourceChainSelector != REMOTE_CHAIN_SELECTOR) {
            revert JBSucker_NotPeer(_toBytes32(origin));
        }

        // Decode the typed message (handles backward compatibility with old format).
        (uint8 messageType, bytes memory payload) = _decodeTypedMessage(any2EvmMessage.data);

        if (messageType == _CCIP_MSG_TYPE_ROOT) {
            // ROOT message — swap bridge tokens to local tokens before storing the merkle root.
            JBMessageRoot memory root = abi.decode(payload, (JBMessageRoot));
            address localToken = _toAddress(root.token);
            uint256 localAmount;

            if (any2EvmMessage.destTokenAmounts.length == 1) {
                Client.EVMTokenAmount memory tokenAmount = any2EvmMessage.destTokenAmounts[0];

                if (localToken == address(BRIDGE_TOKEN) || localToken == tokenAmount.token) {
                    // No swap needed — bridge token IS the local token.
                    localAmount = tokenAmount.amount;
                } else {
                    // Swap bridge token -> local token via best V3/V4 pool.
                    localAmount = _executeSwap(tokenAmount.token, localToken, tokenAmount.amount);
                }
            }

            // Push a conversion entry for this root batch, preserving its exact swap rate.
            // root.amount is the sum of leaf terminalTokenAmount values (in source-chain denomination).
            // localAmount is the actual amount of local tokens received (after swap, if any).
            if (root.amount > 0 && localAmount > 0) {
                _conversionQueue[localToken].push(ConversionEntry({leafAmount: root.amount, localAmount: localAmount}));
            }

            // Store the inbox merkle root for later claims.
            this.fromRemote(root);
        } else if (messageType == _CCIP_MSG_TYPE_PAY) {
            // PAY message — swap bridge token to local token if needed, then pay.
            JBPayRemoteMessage memory payMsg = abi.decode(payload, (JBPayRemoteMessage));
            address localToken = _toAddress(payMsg.token);

            if (any2EvmMessage.destTokenAmounts.length == 1) {
                Client.EVMTokenAmount memory tokenAmount = any2EvmMessage.destTokenAmounts[0];

                if (localToken != address(BRIDGE_TOKEN) && localToken != tokenAmount.token) {
                    // Cross-currency: swap bridge token -> local token and update the pay amount.
                    payMsg.amount = _executeSwap(tokenAmount.token, localToken, tokenAmount.amount);
                }
            }

            this.payFromRemote(payMsg);
        } else {
            revert JBCCIPSucker_UnknownMessageType(messageType);
        }
    }

    //*********************************************************************//
    // -------------------- internal overrides --------------------------- //
    //*********************************************************************//

    /// @notice Override to swap local tokens into bridge tokens before CCIP bridging.
    /// @dev Does NOT modify `sucker_message.amount` — keeps the original leaf-denomination total so the
    /// receiving chain can use it (along with the actual delivered amount) to compute the proportional
    /// scaling factor for individual claims.
    // forge-lint: disable-next-line(mixed-case-function)
    function _sendRootOverAMB(
        uint256 transportPayment,
        uint256 index,
        address token,
        uint256 amount,
        JBRemoteToken memory remoteToken,
        // forge-lint: disable-next-line(mixed-case-variable)
        JBMessageRoot memory sucker_message
    )
        internal
        override
    {
        if (transportPayment == 0) revert JBSucker_ExpectedMsgValue();

        // If no tokens to bridge, delegate to parent for message-only send.
        if (amount == 0) {
            super._sendRootOverAMB(transportPayment, index, token, amount, remoteToken, sucker_message);
            return;
        }

        uint256 bridgeAmount;
        address bridgeTokenAddr = address(BRIDGE_TOKEN);

        if (token == bridgeTokenAddr) {
            // No swap needed — local token IS the bridge token.
            bridgeAmount = amount;
        } else {
            // Swap local token -> bridge token via best V3/V4 pool.
            bridgeAmount = _executeSwap(token, bridgeTokenAddr, amount);
            if (bridgeAmount == 0) revert JBSwapCCIPSucker_SwapFailed();
        }

        // NOTE: We intentionally do NOT update sucker_message.amount here.
        // It stays as the original leaf-denomination total (e.g., ETH wei), which the
        // receiving chain uses to compute the proportional scaling factor for claims.

        // Build the CCIP message with bridge tokens.
        uint256 gasLimit = MESSENGER_BASE_GAS_LIMIT + remoteToken.minGas;

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: bridgeTokenAddr, amount: bridgeAmount});

        // Approve the CCIP router to spend bridge tokens.
        BRIDGE_TOKEN.forceApprove({spender: address(CCIP_ROUTER), value: bridgeAmount});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_toAddress(peer())),
            data: abi.encode(_CCIP_MSG_TYPE_ROOT, abi.encode(sucker_message)),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit})),
            feeToken: address(0)
        });

        uint256 fees = CCIP_ROUTER.getFee({destinationChainSelector: REMOTE_CHAIN_SELECTOR, message: message});
        if (fees > transportPayment) revert JBSucker_InsufficientMsgValue(transportPayment, fees);

        // slither-disable-next-line unused-return
        CCIP_ROUTER.ccipSend{value: fees}({destinationChainSelector: REMOTE_CHAIN_SELECTOR, message: message});

        // Refund excess transport payment.
        uint256 refundAmount = transportPayment - fees;
        if (refundAmount != 0) {
            (bool sent,) = _msgSender().call{value: refundAmount}("");
            if (!sent) emit TransportPaymentRefundFailed(_msgSender(), refundAmount);
        }
    }

    /// @notice Override to swap local tokens into bridge tokens before CCIP bridging of PAY messages.
    /// @dev Mirrors `_sendRootOverAMB`: swaps local -> bridge, updates `message.amount` to bridge denomination,
    /// then sends via CCIP. The remote swap sucker's `ccipReceive` PAY handler reverses the swap.
    // forge-lint: disable-next-line(mixed-case-function)
    function _sendPayOverAMB(
        uint256 transportPayment,
        address token,
        uint256 amount,
        JBRemoteToken memory remoteToken,
        JBPayRemoteMessage memory message
    )
        internal
        override
    {
        if (transportPayment == 0) revert JBSucker_ExpectedMsgValue();

        // If no tokens to bridge, delegate to parent for message-only send.
        if (amount == 0) {
            super._sendPayOverAMB(transportPayment, token, amount, remoteToken, message);
            return;
        }

        uint256 bridgeAmount;
        address bridgeTokenAddr = address(BRIDGE_TOKEN);

        if (token == bridgeTokenAddr) {
            // No swap needed — local token IS the bridge token.
            bridgeAmount = amount;
        } else {
            // Swap local token -> bridge token via best V3/V4 pool.
            bridgeAmount = _executeSwap(token, bridgeTokenAddr, amount);
            if (bridgeAmount == 0) revert JBSwapCCIPSucker_SwapFailed();
        }

        // Update the message amount to bridge denomination so the remote side knows what it received.
        message.amount = bridgeAmount;

        // Build the CCIP message with bridge tokens.
        uint256 gasLimit = MESSENGER_PAY_GAS_LIMIT + remoteToken.minGas;

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: bridgeTokenAddr, amount: bridgeAmount});

        // Approve the CCIP router to spend bridge tokens.
        BRIDGE_TOKEN.forceApprove({spender: address(CCIP_ROUTER), value: bridgeAmount});

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_toAddress(peer())),
            data: abi.encode(_CCIP_MSG_TYPE_PAY, abi.encode(message)),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit})),
            feeToken: address(0)
        });

        uint256 fees = CCIP_ROUTER.getFee({destinationChainSelector: REMOTE_CHAIN_SELECTOR, message: ccipMessage});
        if (fees > transportPayment) revert JBSucker_InsufficientMsgValue(transportPayment, fees);

        // slither-disable-next-line unused-return
        CCIP_ROUTER.ccipSend{value: fees}({destinationChainSelector: REMOTE_CHAIN_SELECTOR, message: ccipMessage});

        // Refund excess transport payment.
        uint256 refundAmount = transportPayment - fees;
        if (refundAmount != 0) {
            (bool sent,) = _msgSender().call{value: refundAmount}("");
            if (!sent) emit TransportPaymentRefundFailed(_msgSender(), refundAmount);
        }
    }

    /// @notice Override to scale claim amounts from source-chain denomination to local-chain denomination.
    /// @dev When cross-currency bridging, merkle tree leaf amounts are in the source chain's terminal token
    /// denomination. This override converts them proportionally using the FIFO conversion queue populated
    /// during `ccipReceive`.
    ///
    /// **Per-batch isolation**: Each received root creates its own conversion entry in the queue. Claims consume
    /// entries from the oldest batch first, so each batch's swap rate is applied independently. This prevents
    /// a blended-rate bug where overlapping roots at different exchange rates would distort individual claims.
    function _addToBalance(address token, uint256 amount, uint256 cachedProjectId) internal override {
        ConversionEntry[] storage queue = _conversionQueue[token];
        uint256 head = _conversionQueueHead[token];

        if (head < queue.length) {
            // Scale using the FIFO queue — each batch keeps its own swap rate.
            uint256 remaining = amount;
            uint256 scaledTotal;

            while (remaining > 0 && head < queue.length) {
                ConversionEntry storage entry = queue[head];
                uint256 consume = remaining > entry.leafAmount ? entry.leafAmount : remaining;
                uint256 scaled = consume * entry.localAmount / entry.leafAmount;

                entry.leafAmount -= consume;
                entry.localAmount -= scaled;
                remaining -= consume;
                scaledTotal += scaled;

                if (entry.leafAmount == 0) {
                    delete queue[head];
                    ++head;
                }
            }

            _conversionQueueHead[token] = head;
            amount = scaledTotal + remaining;
        }

        super._addToBalance(token, amount, cachedProjectId);
    }

    /// @notice Allow this contract to receive ETH (from V4 swaps, WETH unwrap, and CCIP refunds).
    receive() external payable override {}

    //*********************************************************************//
    // ---------------------- internal swap logic ------------------------ //
    //*********************************************************************//

    /// @notice Execute a swap between two tokens using the best available V3 or V4 pool.
    /// @param tokenIn The input token (raw address, e.g., NATIVE_TOKEN sentinel for ETH).
    /// @param tokenOut The output token (raw address).
    /// @param amount The amount of input tokens to swap.
    /// @return amountOut The amount of output tokens received.
    function _executeSwap(address tokenIn, address tokenOut, uint256 amount) internal returns (uint256 amountOut) {
        address normalizedIn = _normalize(tokenIn);
        address normalizedOut = _normalize(tokenOut);

        // Guard: no swap needed if tokens are the same after normalization (e.g., NATIVE_TOKEN and WETH).
        if (normalizedIn == normalizedOut) return amount;

        // Discover the most liquid pool across V3 and V4.
        (bool isV4, IUniswapV3Pool v3Pool, PoolKey memory v4Key) = _discoverPool(normalizedIn, normalizedOut);

        if (!isV4 && address(v3Pool) == address(0)) revert JBSwapCCIPSucker_NoPool();

        if (isV4) {
            // V4 path: quote via hook TWAP or spot, then swap via PoolManager.unlock().
            uint256 minOut = _getV4Quote(v4Key, normalizedIn, normalizedOut, amount);
            amountOut = _executeV4Swap(v4Key, normalizedIn, amount, minOut);
        } else {
            // V3 path: quote via TWAP oracle, then swap via pool.swap().
            uint256 minOut = _getV3TwapQuote(v3Pool, normalizedIn, normalizedOut, amount);
            amountOut = _executeV3Swap(v3Pool, normalizedIn, normalizedOut, amount, minOut, tokenIn);
            // V3 outputs WETH for native pairs — unwrap to raw ETH.
            if (tokenOut == JBConstants.NATIVE_TOKEN) {
                WETH.withdraw(amountOut);
            }
        }
    }

    /// @notice Find the highest liquidity pool across all V3 fee tiers and V4 pool configurations.
    /// @param normalizedTokenIn The input token (wrapped if native, i.e., WETH not NATIVE_TOKEN).
    /// @param normalizedTokenOut The output token (wrapped if native).
    /// @return isV4 Whether the best pool is on V4.
    /// @return v3Pool The V3 pool reference (valid when isV4 is false).
    /// @return v4Key The V4 pool key (valid when isV4 is true).
    function _discoverPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        internal
        view
        returns (bool isV4, IUniswapV3Pool v3Pool, PoolKey memory v4Key)
    {
        // Search V3 pools (4 fee tiers).
        uint128 bestLiquidity;
        (v3Pool, bestLiquidity) = _discoverV3Pool(normalizedTokenIn, normalizedTokenOut);

        // Search V4 pools (4 fee tiers x 2 hook configs).
        if (address(POOL_MANAGER) != address(0)) {
            (PoolKey memory v4Candidate, uint128 v4Liquidity) = _discoverV4Pool(normalizedTokenIn, normalizedTokenOut);
            if (v4Liquidity > bestLiquidity) {
                // Prefer V4 over V3 only when V4 has a hook (potential TWAP) or V3 has no liquidity.
                // V3 pools always have TWAP oracles, whereas hookless V4 pools only offer spot ticks,
                // making them vulnerable to sandwich attacks.
                if (address(v4Candidate.hooks) != address(0) || bestLiquidity == 0) {
                    isV4 = true;
                    v3Pool = IUniswapV3Pool(address(0));
                    v4Key = v4Candidate;
                }
            }
        }
    }

    /// @notice Search V3 pools across 4 fee tiers for the highest liquidity.
    function _discoverV3Pool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        internal
        view
        returns (IUniswapV3Pool bestPool, uint128 bestLiquidity)
    {
        if (address(V3_FACTORY) == address(0)) return (bestPool, bestLiquidity);

        for (uint256 i; i < 4;) {
            // slither-disable-next-line calls-loop
            address poolAddr =
                V3_FACTORY.getPool({tokenA: normalizedTokenIn, tokenB: normalizedTokenOut, fee: _feeTier(i)});

            if (poolAddr != address(0)) {
                // slither-disable-next-line calls-loop
                uint128 poolLiquidity = IUniswapV3Pool(poolAddr).liquidity();
                if (poolLiquidity > bestLiquidity) {
                    bestLiquidity = poolLiquidity;
                    bestPool = IUniswapV3Pool(poolAddr);
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Search V4 pools across 4 fee tiers and 2 hook configs for the highest liquidity.
    function _discoverV4Pool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        internal
        view
        returns (PoolKey memory bestKey, uint128 bestLiquidity)
    {
        // Convert to V4 convention: WETH -> address(0) for native ETH.
        address sorted0;
        address sorted1;
        {
            address v4In = normalizedTokenIn == address(WETH) ? address(0) : normalizedTokenIn;
            address v4Out = normalizedTokenOut == address(WETH) ? address(0) : normalizedTokenOut;
            (sorted0, sorted1) = v4In < v4Out ? (v4In, v4Out) : (v4Out, v4In);
        }

        for (uint256 i; i < 4;) {
            for (uint256 j; j < 2;) {
                // Probe vanilla pools first (j=0), then the configured hook (j=1).
                IHooks hooks = j == 0 ? IHooks(address(0)) : IHooks(UNIV4_HOOK);
                if (j != 0 && address(hooks) == address(0)) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }

                PoolKey memory key;
                {
                    (uint24 fee, int24 tickSpacing) = _v4FeeAndTickSpacing(i);
                    key = PoolKey({
                        currency0: Currency.wrap(sorted0),
                        currency1: Currency.wrap(sorted1),
                        fee: fee,
                        tickSpacing: tickSpacing,
                        hooks: hooks
                    });
                }

                {
                    PoolId id = key.toId();

                    // Check if pool is initialized (sqrtPriceX96 != 0).
                    // slither-disable-next-line unused-return,calls-loop
                    (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(id);
                    // slither-disable-next-line incorrect-equality
                    if (sqrtPriceX96 == 0) {
                        unchecked {
                            ++j;
                        }
                        continue;
                    }

                    // slither-disable-next-line calls-loop
                    uint128 poolLiquidity = POOL_MANAGER.getLiquidity(id);
                    if (poolLiquidity > bestLiquidity) {
                        bestLiquidity = poolLiquidity;
                        bestKey = key;
                    }
                }

                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    //*********************************************************************//
    // -------------------- internal V3 execution ----------------------- //
    //*********************************************************************//

    /// @notice Execute a swap through a V3 pool.
    /// @param pool The V3 pool to swap through.
    /// @param normalizedTokenIn The normalized token being sold (WETH not NATIVE_TOKEN).
    /// @param normalizedTokenOut The normalized token being bought.
    /// @param amount The exact input amount to swap.
    /// @param minAmountOut The minimum acceptable output after slippage protection.
    /// @param originalTokenIn The pre-normalization token address (for WETH wrapping in callback).
    /// @return amountOut The amount of output tokens received.
    function _executeV3Swap(
        IUniswapV3Pool pool,
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint256 amount,
        uint256 minAmountOut,
        address originalTokenIn
    )
        internal
        returns (uint256 amountOut)
    {
        // Determine swap direction using Uniswap's canonical token ordering.
        bool zeroForOne = normalizedTokenIn < normalizedTokenOut;

        // Execute the V3 swap. The callback settles the input token.
        (int256 amount0, int256 amount1) = pool.swap({
            recipient: address(this),
            zeroForOne: zeroForOne,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: JBSwapLib.sqrtPriceLimitFromAmounts({
                amountIn: amount, minimumAmountOut: minAmountOut, zeroForOne: zeroForOne
            }),
            data: abi.encode(originalTokenIn, normalizedTokenIn, normalizedTokenOut)
        });

        // The output side is negative (pool sent tokens out), so negate to get positive amount.
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        if (amountOut < minAmountOut) revert JBSwapCCIPSucker_SlippageExceeded(amountOut, minAmountOut);
    }

    //*********************************************************************//
    // -------------------- internal V4 execution ----------------------- //
    //*********************************************************************//

    /// @notice Execute a swap through a V4 pool via `PoolManager.unlock()`.
    /// @param key The V4 pool key describing the pool to swap through.
    /// @param normalizedTokenIn The normalized token being swapped in (WETH not NATIVE_TOKEN).
    /// @param amount The amount of input tokens to swap.
    /// @param minAmountOut The minimum acceptable amount out for the swap.
    /// @return amountOut The amount produced by the V4 swap.
    function _executeV4Swap(
        PoolKey memory key,
        address normalizedTokenIn,
        uint256 amount,
        uint256 minAmountOut
    )
        internal
        returns (uint256 amountOut)
    {
        // Convert WETH to V4's native ETH (address(0)) for direction comparison.
        address v4In = normalizedTokenIn == address(WETH) ? address(0) : normalizedTokenIn;
        bool zeroForOne = Currency.unwrap(key.currency0) == v4In;

        uint160 sqrtPriceLimitX96 = JBSwapLib.sqrtPriceLimitFromAmounts({
            amountIn: amount, minimumAmountOut: minAmountOut, zeroForOne: zeroForOne
        });

        // V4: negative amountSpecified = exact input.
        int256 exactInputAmount = -int256(amount);

        bytes memory result =
            POOL_MANAGER.unlock(abi.encode(key, zeroForOne, exactInputAmount, sqrtPriceLimitX96, minAmountOut));

        amountOut = abi.decode(result, (uint256));
    }

    //*********************************************************************//
    // --------------------- internal quoting --------------------------- //
    //*********************************************************************//

    /// @notice Get a TWAP-based quote with dynamic slippage for a V3 pool.
    /// @param pool The V3 pool being quoted.
    /// @param normalizedTokenIn The normalized input token.
    /// @param normalizedTokenOut The normalized output token.
    /// @param amount The amount of input tokens being quoted.
    /// @return minAmountOut The minimum amount out implied by the TWAP and sigmoid slippage model.
    function _getV3TwapQuote(
        IUniswapV3Pool pool,
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint256 amount
    )
        internal
        view
        returns (uint256 minAmountOut)
    {
        // Convert V3 fee tier into basis points for the slippage helper.
        uint256 feeBps = uint256(pool.fee()) / 100;

        // Read how much oracle history the pool has.
        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(address(pool));
        if (oldestObservation == 0) revert JBSwapCCIPSucker_InsufficientTwapHistory();

        // Clamp the TWAP window to available history.
        uint256 twapWindow = _DEFAULT_TWAP_WINDOW;
        if (oldestObservation < twapWindow) twapWindow = oldestObservation;
        if (twapWindow < _MIN_TWAP_WINDOW) revert JBSwapCCIPSucker_InsufficientTwapHistory();

        // Query the V3 oracle for arithmetic-mean tick and in-range liquidity.
        (int24 arithmeticMeanTick, uint128 liquidity) =
            OracleLibrary.consult({pool: address(pool), secondsAgo: uint32(twapWindow)});

        if (liquidity == 0) revert JBSwapCCIPSucker_NoLiquidity();

        minAmountOut = _quoteWithSlippage({
            amount: amount,
            liquidity: liquidity,
            tokenIn: normalizedTokenIn,
            tokenOut: normalizedTokenOut,
            tick: arithmeticMeanTick,
            poolFeeBps: feeBps
        });
    }

    /// @notice Get a V4 quote with dynamic slippage. Prefers hook TWAP, falls back to spot tick.
    /// @param key The V4 pool key.
    /// @param normalizedTokenIn The normalized input token.
    /// @param normalizedTokenOut The normalized output token.
    /// @param amount The amount of input tokens being quoted.
    /// @return minAmountOut The minimum amount out after the sigmoid slippage model.
    function _getV4Quote(
        PoolKey memory key,
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint256 amount
    )
        internal
        view
        returns (uint256 minAmountOut)
    {
        // Extract fee early to free the key pointer from the stack before the final call.
        uint256 feeBps = uint256(key.fee) / 100;
        int24 tick;
        uint128 liquidity;

        // Scope: pool state reads and TWAP attempt.
        {
            PoolId id = key.toId();
            bool usedTwap;

            // Try hook-provided TWAP if the pool has a hook.
            if (address(key.hooks) != address(0)) {
                uint32[] memory secondsAgos = new uint32[](2);
                secondsAgos[0] = _V4_TWAP_WINDOW;
                secondsAgos[1] = 0;

                // slither-disable-next-line unused-return
                try IGeomeanOracle(address(key.hooks)).observe(key, secondsAgos) returns (
                    int56[] memory tickCumulatives, uint160[] memory
                ) {
                    tick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(_V4_TWAP_WINDOW)));
                    usedTwap = true;
                } catch {}
            }

            // Fall back to the instantaneous spot tick.
            if (!usedTwap) {
                // slither-disable-next-line unused-return
                (, tick,,) = POOL_MANAGER.getSlot0(id);
            }

            liquidity = POOL_MANAGER.getLiquidity(id);
        }

        if (liquidity == 0) revert JBSwapCCIPSucker_NoLiquidity();

        // V4 uses address(0) for native ETH — adjust for OracleLibrary token sorting.
        address quotingIn = normalizedTokenIn == address(WETH) ? address(0) : normalizedTokenIn;
        address quotingOut = normalizedTokenOut == address(WETH) ? address(0) : normalizedTokenOut;

        minAmountOut = _quoteWithSlippage({
            amount: amount,
            liquidity: liquidity,
            tokenIn: quotingIn,
            tokenOut: quotingOut,
            tick: tick,
            poolFeeBps: feeBps
        });
    }

    /// @notice Compute the minimum acceptable output using sigmoid slippage at the given tick.
    /// @param amount The amount of input tokens being swapped.
    /// @param liquidity The pool's in-range liquidity.
    /// @param tokenIn The input token address (used for token sorting and quoting).
    /// @param tokenOut The output token address.
    /// @param tick The tick to quote at (TWAP mean tick or spot tick).
    /// @param poolFeeBps The pool fee in basis points.
    /// @return minAmountOut The quoted output amount after slippage.
    function _quoteWithSlippage(
        uint256 amount,
        uint128 liquidity,
        address tokenIn,
        address tokenOut,
        int24 tick,
        uint256 poolFeeBps
    )
        internal
        pure
        returns (uint256 minAmountOut)
    {
        // Compute sigmoid slippage tolerance.
        uint256 slippageTolerance = _getSlippageTolerance({
            amountIn: amount,
            liquidity: liquidity,
            tokenOut: tokenOut,
            tokenIn: tokenIn,
            arithmeticMeanTick: tick,
            poolFeeBps: poolFeeBps
        });

        // Full slippage means no safe output.
        if (slippageTolerance >= _SLIPPAGE_DENOMINATOR) return 0;

        // OracleLibrary accepts only uint128 base amounts.
        if (amount > type(uint128).max) revert JBSwapCCIPSucker_AmountOverflow(amount);

        // Quote the gross output at the supplied tick.
        minAmountOut = OracleLibrary.getQuoteAtTick({
            tick: tick, baseAmount: uint128(amount), baseToken: tokenIn, quoteToken: tokenOut
        });

        // Discount by the computed slippage tolerance.
        minAmountOut -= (minAmountOut * slippageTolerance) / _SLIPPAGE_DENOMINATOR;
    }

    /// @notice Compute the sigmoid slippage tolerance for a given swap.
    /// @param amountIn The amount of tokens being swapped in.
    /// @param liquidity The pool's in-range liquidity.
    /// @param tokenOut The output token address.
    /// @param tokenIn The input token address.
    /// @param arithmeticMeanTick The TWAP or spot tick.
    /// @param poolFeeBps The pool fee in basis points.
    /// @return The slippage tolerance in basis points.
    function _getSlippageTolerance(
        uint256 amountIn,
        uint128 liquidity,
        address tokenOut,
        address tokenIn,
        int24 arithmeticMeanTick,
        uint256 poolFeeBps
    )
        internal
        pure
        returns (uint256)
    {
        // Determine token ordering for directional impact calculation.
        (address token0,) = tokenOut < tokenIn ? (tokenOut, tokenIn) : (tokenIn, tokenOut);
        bool zeroForOne = tokenIn == token0;

        // Convert tick to sqrt price for impact calculation.
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(arithmeticMeanTick);
        if (sqrtP == 0) return _SLIPPAGE_DENOMINATOR;

        // Estimate price impact using JBSwapLib sigmoid model.
        uint256 impact =
            JBSwapLib.calculateImpact({amountIn: amountIn, liquidity: liquidity, sqrtP: sqrtP, zeroForOne: zeroForOne});

        return JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps});
    }

    //*********************************************************************//
    // --------------------- internal V4 helpers ------------------------ //
    //*********************************************************************//

    /// @notice Settle the input side of a V4 swap by transferring the owed asset to the PoolManager.
    /// @param currency The V4 currency the contract owes to the PoolManager.
    /// @param amount The amount to settle.
    function _settleV4(Currency currency, uint256 amount) internal {
        if (Currency.unwrap(currency) == address(0)) {
            // Native ETH settlement.
            // slither-disable-next-line unused-return
            POOL_MANAGER.settle{value: amount}();
        } else {
            // ERC20 settlement: sync -> transfer -> settle.
            POOL_MANAGER.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer({to: address(POOL_MANAGER), value: amount});
            // slither-disable-next-line unused-return
            POOL_MANAGER.settle();
        }
    }

    /// @notice Take the output side of a V4 swap by pulling the owed asset from the PoolManager.
    /// @param currency The V4 currency the PoolManager owes to the contract.
    /// @param amount The amount to take.
    function _takeV4(Currency currency, uint256 amount) internal {
        POOL_MANAGER.take({currency: currency, to: address(this), amount: amount});
    }

    //*********************************************************************//
    // ----------------------- internal helpers ------------------------- //
    //*********************************************************************//

    /// @notice Normalize NATIVE_TOKEN to WETH address for Uniswap pool lookups.
    /// @param token The raw token address (may be NATIVE_TOKEN sentinel).
    /// @return The normalized address (WETH if native, otherwise unchanged).
    function _normalize(address token) internal view returns (address) {
        return token == JBConstants.NATIVE_TOKEN ? address(WETH) : token;
    }

    /// @notice Return the V3 fee tier at the given index (ordered by commonality).
    /// @param index The tier index (0-3): 0.30%, 0.05%, 1.00%, 0.01%.
    /// @return fee The fee value.
    function _feeTier(uint256 index) internal pure returns (uint24 fee) {
        if (index == 0) return 3000; // 0.30%
        if (index == 1) return 500; // 0.05%
        if (index == 2) return 10_000; // 1.00%
        return 100; // 0.01%
    }

    /// @notice Return the V4 fee and tick spacing at the given index.
    /// @param index The tier index (0-3).
    /// @return fee The V4 fee value.
    /// @return tickSpacing The V4 tick spacing value.
    function _v4FeeAndTickSpacing(uint256 index) internal pure returns (uint24 fee, int24 tickSpacing) {
        if (index == 0) return (3000, 60); // 0.30%
        if (index == 1) return (500, 10); // 0.05%
        if (index == 2) return (10_000, 200); // 1.00%
        return (100, 1); // 0.01%
    }
}
