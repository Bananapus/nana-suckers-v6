// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

import {JBSucker} from "./JBSucker.sol";
import {JBCCIPSuckerDeployer} from "./deployers/JBCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";
import {ICCIPRouter, IWrappedNativeToken} from "./interfaces/ICCIPRouter.sol";
import {IJBCCIPSuckerDeployer} from "./interfaces/IJBCCIPSuckerDeployer.sol";
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBPayRemoteMessage} from "./structs/JBPayRemoteMessage.sol";
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
    error JBCCIPSucker_UnknownMessageType(uint8 messageType);

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

    /// @notice Message type prefix for root messages (fromRemote).
    uint8 internal constant _CCIP_MSG_TYPE_ROOT = 0;

    /// @notice Message type prefix for pay messages (payFromRemote).
    uint8 internal constant _CCIP_MSG_TYPE_PAY = 1;

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
    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions,
        uint256 feeProjectId,
        IJBSuckerRegistry registry,
        address trustedForwarder
    )
        JBSucker(directory, permissions, tokens, feeProjectId, registry, trustedForwarder)
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

    /// @notice The entrypoint for the CCIP router to call.
    /// @param any2EvmMessage The message to process.
    /// @dev Extremely important to ensure only router calls this.
    /// @dev The CCIP NatSpec convention states that `ccipReceive` should not revert. We intentionally deviate:
    /// reverting on invalid sender/peer data is correct here because accepting and silently discarding a
    /// malformed message would lose the bridged tokens with no recovery path. A revert keeps tokens in the
    /// CCIP router where they can be retried or recovered.
    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage) external virtual override {
        // Use msg.sender (not _msgSender()) because the CCIP router never uses ERC2771 meta-transactions.
        // Using _msgSender() would allow a trusted forwarder to spoof the router address via the
        // ERC-2771 calldata suffix.
        if (msg.sender != address(CCIP_ROUTER)) revert JBSucker_NotPeer(_toBytes32(msg.sender));

        address origin = abi.decode(any2EvmMessage.sender, (address));

        // Make sure that the message came from our peer.
        if (origin != _peerAddress() || any2EvmMessage.sourceChainSelector != REMOTE_CHAIN_SELECTOR) {
            revert JBSucker_NotPeer(_toBytes32(origin));
        }

        // Discriminate message type BEFORE unwrapping. The unwrap decision depends on whether
        // the decoded local token is NATIVE_TOKEN. Unconditionally unwrapping first would destroy
        // the ERC-20 balance when the local claim token IS the wrapped-native ERC-20 (e.g., WETH),
        // making claims permanently unclaimable (NM-001 / SI-001 / FF-001).
        bytes memory data = any2EvmMessage.data;
        (uint8 messageType, bytes memory payload) = _decodeTypedMessage(data);

        if (messageType == _CCIP_MSG_TYPE_ROOT) {
            JBMessageRoot memory root = abi.decode(payload, (JBMessageRoot));
            // Only unwrap when the local claim token is NATIVE_TOKEN, not when it's the WETH ERC-20.
            if (_toAddress(root.token) == JBConstants.NATIVE_TOKEN) {
                _unwrapReceivedTokens(any2EvmMessage);
            }
            this.fromRemote(root);
        } else if (messageType == _CCIP_MSG_TYPE_PAY) {
            JBPayRemoteMessage memory payMsg = abi.decode(payload, (JBPayRemoteMessage));
            // Only unwrap when the local terminal token is NATIVE_TOKEN.
            if (_toAddress(payMsg.token) == JBConstants.NATIVE_TOKEN) {
                _unwrapReceivedTokens(any2EvmMessage);
            }
            this.payFromRemote(payMsg);
        } else {
            revert JBCCIPSucker_UnknownMessageType(messageType);
        }
    }

    //*********************************************************************//
    // ------------------------ internal views --------------------------- //
    //*********************************************************************//

    /// @notice Unused in this context.
    function _isRemotePeer(address sender) internal view override returns (bool _valid) {
        // NOTICE: We do not check if its the `peer` here, as this contract is supposed to be the caller *NOT* the peer.
        return sender == address(this);
    }

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Uses CCIP to send the root and assets over the bridge to the peer.
    /// @dev CCIP transport payment refund failures emit a `TransportPaymentRefundFailed` event by design rather
    /// than reverting. After `ccipSend` commits the bridge message and transfers tokens, reverting the transaction
    /// would leave the CCIP message in-flight with no corresponding on-chain state update — the tokens would be
    /// gone, the merkle root never processed, and the outbox inconsistent. Emitting an event preserves
    /// observability while preventing a single failed refund from blocking the entire bridge operation.
    /// @param transportPayment the amount of `msg.value` that is going to get paid for sending this message.
    /// @param token The token to bridge the outbox tree for.
    /// @param remoteToken Information about the remote token being bridged to.
    // forge-lint: disable-next-line(mixed-case-function)
    function _sendRootOverAMB(
        uint256 transportPayment,
        uint256,
        address token,
        uint256 amount,
        JBRemoteToken memory remoteToken,
        // forge-lint: disable-next-line(mixed-case-variable)
        JBMessageRoot memory sucker_message
    )
        internal
        virtual
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
                // forge-lint: disable-next-line(mixed-case-variable)
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
            SafeERC20.forceApprove({token: IERC20(token), spender: address(CCIP_ROUTER), value: amount});
        }

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // CCIP requires EVM addresses, so convert the bytes32 peer to an address for the receiver field.
        // Wrap with type prefix for message discrimination on the receiving end.
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_peerAddress()),
            data: abi.encode(_CCIP_MSG_TYPE_ROOT, abi.encode(sucker_message)),

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
        // contract. There is no sweep or recovery function — `_addToBalance` only
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

    /// @notice Bridge funds and a pay message to the remote peer via CCIP.
    // forge-lint: disable-next-line(mixed-case-function)
    function _sendPayOverAMB(
        uint256 transportPayment,
        address token,
        uint256 amount,
        JBRemoteToken memory remoteToken,
        JBPayRemoteMessage memory message
    )
        internal
        virtual
        override
    {
        if (transportPayment == 0) revert JBSucker_ExpectedMsgValue();

        uint256 gasLimit = MESSENGER_PAY_GAS_LIMIT;
        Client.EVMTokenAmount[] memory tokenAmounts;
        if (amount != 0) {
            gasLimit += remoteToken.minGas;

            // Wrap native ETH → WETH for CCIP bridging.
            if (token == JBConstants.NATIVE_TOKEN) {
                // slither-disable-next-line calls-loop
                // forge-lint: disable-next-line(mixed-case-variable)
                IWrappedNativeToken wrapped_native = CCIP_ROUTER.getWrappedNative();
                // slither-disable-next-line calls-loop,arbitrary-send-eth
                wrapped_native.deposit{value: amount}();
                token = address(wrapped_native);
            }

            tokenAmounts = new Client.EVMTokenAmount[](1);
            tokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});
            SafeERC20.forceApprove({token: IERC20(token), spender: address(CCIP_ROUTER), value: amount});
        }

        // Wrap with type prefix for message discrimination.
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_toAddress(peer())),
            data: abi.encode(_CCIP_MSG_TYPE_PAY, abi.encode(message)),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit})),
            feeToken: address(0)
        });

        // slither-disable-next-line calls-loop
        uint256 fees = CCIP_ROUTER.getFee({destinationChainSelector: REMOTE_CHAIN_SELECTOR, message: ccipMessage});

        if (fees > transportPayment) {
            revert JBSucker_InsufficientMsgValue(transportPayment, fees);
        }

        // slither-disable-next-line calls-loop,unused-return
        CCIP_ROUTER.ccipSend{value: fees}({destinationChainSelector: REMOTE_CHAIN_SELECTOR, message: ccipMessage});

        // Best-effort refund of excess transport.
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

    /// @notice Unwrap WETH → ETH from received CCIP tokens if the message targets NATIVE_TOKEN.
    /// @dev Shared by both root and pay message handling.
    function _unwrapReceivedTokens(Client.Any2EVMMessage calldata any2EvmMessage) internal {
        if (any2EvmMessage.destTokenAmounts.length == 1) {
            Client.EVMTokenAmount memory tokenAmount = any2EvmMessage.destTokenAmounts[0];

            // For both message types, check if the underlying token data indicates native.
            // We try to decode the first word of the inner payload to determine the token.
            // For root messages: token is at a known offset. For pay messages: token is in JBPayRemoteMessage.
            // We use a heuristic: if WETH was delivered, check if it should be unwrapped.
            // The unwrap decision is deferred to the message handler for pay messages since
            // the token field is inside the typed payload. For root messages, we keep the existing check.
            //
            // Actually, we need a simpler approach: always unwrap if the WETH is our wrapped native.
            // The message handler will know whether to treat funds as native or ERC-20.
            // For backward compat and simplicity, we unwrap ALL received WETH to native.
            // slither-disable-next-line calls-loop
            IWrappedNativeToken wrappedNative = CCIP_ROUTER.getWrappedNative();
            if (tokenAmount.token == address(wrappedNative) && tokenAmount.amount > 0) {
                uint256 balanceBefore = _balanceOf({token: JBConstants.NATIVE_TOKEN, addr: address(this)});
                wrappedNative.withdraw(tokenAmount.amount);
                // slither-disable-next-line incorrect-equality
                assert(
                    balanceBefore + tokenAmount.amount
                        == _balanceOf({token: JBConstants.NATIVE_TOKEN, addr: address(this)})
                );
            }
        }
    }

    /// @notice Decode a typed CCIP message. Handles backward compatibility with old format (no type prefix).
    /// @param data The raw CCIP message data.
    /// @return messageType The message type (0 = root, 1 = pay).
    /// @return payload The inner payload (encoded JBMessageRoot or JBPayRemoteMessage).
    function _decodeTypedMessage(bytes memory data)
        internal
        pure
        returns (uint8 messageType, bytes memory payload)
    {
        // New format: abi.encode(uint8, bytes)
        // Try to decode — if the first word is 0 or 1, it's likely the new format.
        // Old format: abi.encode(JBMessageRoot) where the first word is `version` (uint8, also 0 or 1).
        //
        // Discrimination: In the new format, the second slot is an offset to the dynamic bytes.
        // In the old format, the second slot is `token` (bytes32).
        // A dynamic bytes offset will be 0x40 (64) in the new format.
        // A token address in the old format will never be 0x40.
        //
        // So: if data[32:64] == 0x40, it's the new typed format. Otherwise, fall back to old root format.
        if (data.length >= 64) {
            uint256 secondWord;
            assembly ("memory-safe") {
                secondWord := mload(add(data, 0x40))
            }
            if (secondWord == 0x40) {
                // New typed format.
                (messageType, payload) = abi.decode(data, (uint8, bytes));
                return (messageType, payload);
            }
        }

        // Old format — treat as root message.
        return (_CCIP_MSG_TYPE_ROOT, data);
    }
}
