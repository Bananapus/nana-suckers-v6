// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBRulesets} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

import {JBSucker} from "./JBSucker.sol";
import {JBCCIPSuckerDeployer} from "./deployers/JBCCIPSuckerDeployer.sol";
import {JBAddToBalanceMode} from "./enums/JBAddToBalanceMode.sol";
import {ICCIPRouter, IWrappedNativeToken} from "./interfaces/ICCIPRouter.sol";
import {IJBCCIPSuckerDeployer} from "./interfaces/IJBCCIPSuckerDeployer.sol";
import {CCIPHelper} from "./libraries/CCIPHelper.sol";
import {JBInboxTreeRoot} from "./structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBRemoteToken} from "./structs/JBRemoteToken.sol";
import {JBTokenMapping} from "./structs/JBTokenMapping.sol";
import {MerkleLib} from "./utils/MerkleLib.sol";

/// @notice A `JBSucker` implementation to suck tokens between chains with Chainlink CCIP
contract JBCCIPSucker is JBSucker, IAny2EVMMessageReceiver {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBCCIPSucker_InvalidRouter(address router);

    //*********************************************************************//
    // ------------------------------ events ----------------------------- //
    //*********************************************************************//

    /// @notice Emitted when a transport payment refund fails after a successful CCIP send.
    /// @dev The refunded ETH is permanently stuck in this contract — there is no recovery function.
    /// This is an accepted tradeoff to avoid reverting after CCIP has committed the bridge message.
    /// @param recipient The address that was supposed to receive the refund.
    /// @param amount The amount of the failed refund (permanently stuck in this contract).
    event TransportPaymentRefundFailed(address indexed recipient, uint256 amount);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The CCIP router used to bridge tokens between the local and remote chain.
    ICCIPRouter public immutable CCIP_ROUTER;

    /// @notice The chain id of the remote chain.
    uint256 public immutable REMOTE_CHAIN_ID;

    /// @notice The CCIP chain selector of the remote chain.
    uint64 public immutable REMOTE_CHAIN_SELECTOR;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param deployer A contract that deploys the clones for this contracts.
    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param tokens A contract that manages token minting and burning.
    /// @param permissions A contract storing permissions.
    /// @param addToBalanceMode The mode of adding tokens to balance.
    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions,
        JBAddToBalanceMode addToBalanceMode,
        address trustedForwarder
    )
        JBSucker(directory, permissions, tokens, addToBalanceMode, trustedForwarder)
    {
        REMOTE_CHAIN_ID = IJBCCIPSuckerDeployer(deployer).ccipRemoteChainId();
        REMOTE_CHAIN_SELECTOR = IJBCCIPSuckerDeployer(deployer).ccipRemoteChainSelector();
        CCIP_ROUTER = IJBCCIPSuckerDeployer(deployer).ccipRouter();

        if (address(CCIP_ROUTER) == address(0)) revert JBCCIPSucker_InvalidRouter(address(CCIP_ROUTER));
    }

    //*********************************************************************//
    // ------------------------ external views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the chain on which the peer is located.
    /// @return chainId of the peer.
    function peerChainId() external view virtual override returns (uint256 chainId) {
        // Return the remote chain id
        return REMOTE_CHAIN_ID;
    }

    //*********************************************************************//
    // ------------------------- public views ---------------------------- //
    //*********************************************************************//

    /// @notice Return the current router
    /// @return CCIP router address
    function getRouter() public view returns (address) {
        return address(CCIP_ROUTER);
    }

    /// @notice IERC165 supports an interfaceId
    /// @param interfaceId The interfaceId to check
    /// @return true if the interfaceId is supported
    /// @dev Should indicate whether the contract implements IAny2EVMMessageReceiver
    /// e.g. return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId
    /// This allows CCIP to check if ccipReceive is available before calling it.
    /// If this returns false or reverts, only tokens are transferred to the receiver.
    /// If this returns true, tokens are transferred and ccipReceive is called atomically.
    /// Additionally, if the receiver address does not have code associated with
    /// it at the time of execution (EXTCODESIZE returns 0), only tokens will be transferred.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice The entrypoint for the CCIP router to call. This function should
    /// never revert, all errors should be handled internally in this contract.
    /// @param any2EvmMessage The message to process.
    /// @dev Extremely important to ensure only router calls this.
    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage) external override {
        // only calls from the set router are accepted.
        if (_msgSender() != address(CCIP_ROUTER)) revert JBSucker_NotPeer(_toBytes32(_msgSender()));

        // Decode the message root from the peer
        JBMessageRoot memory root = abi.decode(any2EvmMessage.data, (JBMessageRoot));
        address origin = abi.decode(any2EvmMessage.sender, (address));

        // Make sure that the message came from our peer.
        if (origin != _toAddress(peer()) || any2EvmMessage.sourceChainSelector != REMOTE_CHAIN_SELECTOR) {
            revert JBSucker_NotPeer(_toBytes32(origin));
        }

        // We intentionally do NOT validate root.amount against destTokenAmounts[0].amount here.
        // CCIP fees are paid separately (via feeToken), so delivered amounts should always match what was sent.
        // If we reverted on a mismatch, the tokens already transferred by CCIP would be locked in the router
        // with no recovery path — a concrete fund-loss risk that outweighs the theoretical defense-in-depth
        // benefit against a CCIP-level failure or peer compromise.

        // We either send no tokens or a single token.
        if (any2EvmMessage.destTokenAmounts.length == 1) {
            // The sucker only handles ERC-20s or native. CCIP delivers wrapped native (WETH).
            Client.EVMTokenAmount memory tokenAmount = any2EvmMessage.destTokenAmounts[0];
            // Unwrap WETH -> ETH only when the root says the token is NATIVE_TOKEN.
            // When root.token is an ERC-20 address (e.g., bridging to a chain where ETH is an ERC-20), no unwrap.
            if (root.token == _toBytes32(JBConstants.NATIVE_TOKEN)) {
                // We can (safely) assume that the token that is set in the `destTokenAmounts` is a valid wrapped
                // native.
                // If this ends up not being the case then our sanity check to see if we unwrapped the native asset will
                // fail.
                IWrappedNativeToken wrapped_native = IWrappedNativeToken(tokenAmount.token);
                uint256 balanceBefore = _balanceOf({token: JBConstants.NATIVE_TOKEN, addr: address(this)});

                // Withdraw the wrapped native asset.
                wrapped_native.withdraw(tokenAmount.amount);

                // Sanity check the unwrapping of the native asset.
                // slither-disable-next-line incorrect-equality
                assert(
                    balanceBefore + tokenAmount.amount
                        == _balanceOf({token: JBConstants.NATIVE_TOKEN, addr: address(this)})
                );
            }
        }

        // Call ourselves to process the root.
        this.fromRemote(root);
    }

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Unused in this context.
    function _isRemotePeer(address sender) internal view override returns (bool _valid) {
        // NOTICE: We do not check if its the `peer` here, as this contract is supposed to be the caller *NOT* the peer.
        return sender == address(this);
    }

    /// @notice Uses CCIP to send the root and assets over the bridge to the peer.
    /// @param transportPayment the amount of `msg.value` that is going to get paid for sending this message.
    /// @param token The token to bridge the outbox tree for.
    /// @param remoteToken Information about the remote token being bridged to.
    function _sendRootOverAMB(
        uint256 transportPayment,
        uint256,
        address token,
        uint256 amount,
        JBRemoteToken memory remoteToken,
        JBMessageRoot memory sucker_message
    )
        internal
        override
    {
        // Make sure we are attempting to pay the bridge
        if (transportPayment == 0) revert JBSucker_ExpectedMsgValue();

        uint256 gasLimit = MESSENGER_BASE_GAS_LIMIT;
        Client.EVMTokenAmount[] memory tokenAmounts;
        if (amount != 0) {
            // If we also do an asset transfer then we increase the min required gas amount.
            gasLimit += remoteToken.minGas;

            // Wrap native ETH -> WETH for CCIP bridging. CCIP only transports ERC-20s.
            // This is why `_validateTokenMapping` enforces minGas for native tokens too.
            if (token == JBConstants.NATIVE_TOKEN) {
                // Get the wrapped native token.
                // slither-disable-next-line calls-loop
                IWrappedNativeToken wrapped_native = CCIP_ROUTER.getWrappedNative();
                // Deposit the wrapped native asset.
                // slither-disable-next-line calls-loop,arbitrary-send-eth
                wrapped_native.deposit{value: amount}();
                // Update the token to be the wrapped native asset.
                token = address(wrapped_native);
            }

            // Set the token amounts
            tokenAmounts = new Client.EVMTokenAmount[](1);
            tokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});

            // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
            SafeERC20.forceApprove(IERC20(token), address(CCIP_ROUTER), amount);
        }

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // CCIP requires EVM addresses, so convert the bytes32 peer to an address for the receiver field.
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_toAddress(peer())),
            data: abi.encode(sucker_message),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                // Additional arguments, setting gas limit
                Client.EVMExtraArgsV1({gasLimit: gasLimit})
            ),
            // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees,
            // We pay in the native asset.
            feeToken: address(0)
        });

        // Get the fee required to send the CCIP message
        // slither-disable-next-line calls-loop
        uint256 fees = CCIP_ROUTER.getFee({destinationChainSelector: REMOTE_CHAIN_SELECTOR, message: message});

        if (fees > transportPayment) {
            revert JBSucker_InsufficientMsgValue(transportPayment, fees);
        }

        // slither-disable-next-line calls-loop,unused-return
        CCIP_ROUTER.ccipSend{value: fees}({destinationChainSelector: REMOTE_CHAIN_SELECTOR, message: message});

        // Refund remaining balance. We use a low-level call that does not revert on failure because
        // `ccipSend` above has already committed the bridge message and transferred the tokens. If we
        // reverted here (e.g. because the caller is a non-payable contract), the entire transaction
        // would roll back — but the CCIP message is already in-flight. The tokens would be gone, the
        // merkle root never gets processed, and the outbox state is inconsistent.
        //
        // If the refund fails, the ETH (transportPayment - fees) will be permanently stuck in this
        // contract. There is no sweep or recovery function — `addOutstandingAmountToBalance` only
        // moves funds tracked via `fromRemote`, not arbitrary ETH. This is an accepted tradeoff:
        // stuck dust from a fee overpayment is far less harmful than bricking the entire bridge
        // operation. The event provides observability so it doesn't go unnoticed.
        //
        uint256 refundAmount = transportPayment - fees;
        if (refundAmount != 0) {
            // slither-disable-next-line calls-loop,msg-value-loop,reentrancy-events
            (bool sent,) = _msgSender().call{value: refundAmount}("");
            if (!sent) emit TransportPaymentRefundFailed(_msgSender(), refundAmount);
        }
    }

    /// @notice Allow sucker implementations to add/override mapping rules to suite their specific needs.
    /// @dev Unlike OP/Arbitrum suckers (which share ETH as native on both chains), this CCIP sucker can connect
    /// chains with different native tokens. This means `NATIVE_TOKEN` may map to an ERC-20 on the remote chain.
    ///
    /// Example: ETH mainnet (native = ETH) <-> Celo (native = CELO, ETH is an ERC-20).
    ///   - On mainnet: `mapToken({localToken: NATIVE_TOKEN, remoteToken: celoETH_address})`
    ///   - Sending: `_sendRootOverAMB` wraps native ETH -> WETH, bridges WETH via CCIP.
    ///   - Receiving: `ccipReceive` checks `root.token == NATIVE_TOKEN` to decide whether to unwrap WETH -> ETH.
    ///     If `root.token` is an ERC-20 address (like celoETH), no unwrap occurs — tokens stay as ERC-20.
    ///
    /// The base class restriction (`NATIVE_TOKEN` can only map to `NATIVE_TOKEN` or `address(0)`) is intentionally
    /// removed here. The base class retains that restriction for OP/Arbitrum where both chains share ETH as native.
    function _validateTokenMapping(JBTokenMapping calldata map) internal pure virtual override {
        // Enforce a reasonable minimum gas limit for bridging. A minimum which is too low could lead to the loss of
        // funds. CCIP wraps native tokens to WETH before bridging (see `_sendRootOverAMB`), so ALL tokens —
        // including native — need sufficient gas for an ERC-20 transfer on the remote chain.
        if (map.minGas < MESSENGER_ERC20_MIN_GAS_LIMIT) {
            revert JBSucker_BelowMinGas(map.minGas, MESSENGER_ERC20_MIN_GAS_LIMIT);
        }
    }
}
