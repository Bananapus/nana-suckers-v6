// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// External packages (alphabetized)
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
// Local: base contracts
import {JBSucker} from "./JBSucker.sol";

// Local: deployers
import {JBCCIPSuckerDeployer} from "./deployers/JBCCIPSuckerDeployer.sol";

// Local: interfaces (alphabetized)
import {ICCIPRouter} from "./interfaces/ICCIPRouter.sol";
import {IJBCCIPSuckerDeployer} from "./interfaces/IJBCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";

// Local: libraries (alphabetized)
import {JBCCIPLib} from "./libraries/JBCCIPLib.sol";

// Local: structs (alphabetized)
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBRemoteToken} from "./structs/JBRemoteToken.sol";
import {JBTokenMapping} from "./structs/JBTokenMapping.sol";

/// @notice A `JBSucker` implementation to suck tokens between chains with Chainlink CCIP
contract JBCCIPSucker is JBSucker, IAny2EVMMessageReceiver {
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
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Message type prefix for root messages (fromRemote).
    uint8 internal constant _CCIP_MSG_TYPE_ROOT = 0;

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

    /// @param deployer A contract that deploys the clones for this contract.
    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param tokens A contract that manages token minting and burning.
    /// @param permissions A contract storing permissions.
    /// @param feeProjectId The ID of the project that receives fees.
    /// @param registry The sucker registry that tracks deployed suckers.
    /// @param trustedForwarder The trusted forwarder for ERC-2771 meta-transactions.
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
        // Read the remote chain ID from the deployer.
        REMOTE_CHAIN_ID = IJBCCIPSuckerDeployer(deployer).ccipRemoteChainId();

        // Read the CCIP chain selector from the deployer.
        REMOTE_CHAIN_SELECTOR = IJBCCIPSuckerDeployer(deployer).ccipRemoteChainSelector();

        // Read the CCIP router from the deployer.
        CCIP_ROUTER = IJBCCIPSuckerDeployer(deployer).ccipRouter();

        // Ensure the CCIP router is not the zero address.
        if (address(CCIP_ROUTER) == address(0)) revert JBCCIPSucker_InvalidRouter(address(CCIP_ROUTER));
    }

    //*********************************************************************//
    // ------------------------ external views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the chain on which the peer is located.
    /// @return chainId The chain ID of the peer.
    function peerChainId() external view virtual override returns (uint256 chainId) {
        return REMOTE_CHAIN_ID;
    }

    //*********************************************************************//
    // ------------------------- public views ---------------------------- //
    //*********************************************************************//

    /// @notice Returns the address of the current CCIP router.
    /// @return router The CCIP router address.
    function getRouter() public view returns (address router) {
        return address(CCIP_ROUTER);
    }

    /// @notice Checks whether this contract supports a given interface.
    /// @param interfaceId The interface ID to check.
    /// @return supported Whether the interface is supported.
    /// @dev Should indicate whether the contract implements IAny2EVMMessageReceiver.
    /// This allows CCIP to check if ccipReceive is available before calling it.
    /// If this returns false or reverts, only tokens are transferred to the receiver.
    /// If this returns true, tokens are transferred and ccipReceive is called atomically.
    /// Additionally, if the receiver address does not have code associated with
    /// it at the time of execution (EXTCODESIZE returns 0), only tokens will be transferred.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool supported) {
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

        // Decode the sender address from the CCIP message.
        address origin = abi.decode(any2EvmMessage.sender, (address));

        // Make sure that the message came from our peer.
        if (origin != _peerAddress() || any2EvmMessage.sourceChainSelector != REMOTE_CHAIN_SELECTOR) {
            revert JBSucker_NotPeer(_toBytes32(origin));
        }

        // Discriminate message type. New format: abi.encode(uint8 type, bytes payload).
        // For backward compatibility with in-flight messages, try new format first, fall back to old.
        (uint8 messageType, bytes memory payload) = JBCCIPLib.decodeTypedMessage(any2EvmMessage.data);

        // Handle root messages (merkle tree updates with bridged assets).
        if (messageType == _CCIP_MSG_TYPE_ROOT) {
            // Decode the root message from the payload.
            JBMessageRoot memory root = abi.decode(payload, (JBMessageRoot));

            // Only unwrap WETH -> ETH when the root targets native token (not when claiming WETH as ERC-20).
            if (root.token == bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))) {
                JBCCIPLib.unwrapReceivedTokens({
                    ccipRouter: CCIP_ROUTER, destTokenAmounts: any2EvmMessage.destTokenAmounts
                });
            }

            // Forward the root message to this contract's fromRemote handler.
            this.fromRemote(root);
        } else {
            revert JBCCIPSucker_UnknownMessageType(messageType);
        }
    }

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Uses CCIP to send the root and assets over the bridge to the peer.
    /// @dev Delegates CCIP message construction and sending to JBCCIPLib (via DELEGATECALL) to reduce bytecode.
    /// @param transportPayment The amount of `msg.value` that is going to get paid for sending this message.
    /// @param token The token to bridge the outbox tree for.
    /// @param amount The amount of tokens to bridge.
    /// @param remoteToken Information about the remote token being bridged to.
    /// @param sucker_message The message root to send to the remote peer.
    // forge-lint: disable-next-line(mixed-case-function)
    function _sendRootOverAMB(
        uint256 transportPayment,
        uint256,
        address token,
        uint256 amount,
        JBRemoteToken memory remoteToken,
        // forge-lint: disable-next-line(mixed-case-variable)
        JBMessageRoot memory sucker_message,
        bytes memory
    )
        internal
        virtual
        override
    {
        // Revert if no transport payment was provided.
        if (transportPayment == 0) revert JBSucker_ExpectedMsgValue();

        // Start with the base gas limit for cross-chain calls.
        uint256 gasLimit = MESSENGER_BASE_GAS_LIMIT;
        Client.EVMTokenAmount[] memory tokenAmounts;

        if (amount != 0) {
            // Add extra gas for the ERC-20 token transfer on the remote chain.
            gasLimit += remoteToken.minGas;

            // Wrap native ETH -> WETH if needed, build the CCIP token amounts array, and approve the router.
            // slither-disable-next-line unused-return
            (tokenAmounts,) = JBCCIPLib.prepareTokenAmounts({ccipRouter: CCIP_ROUTER, token: token, amount: amount});
        } else {
            // No tokens to bridge — use an empty array.
            tokenAmounts = new Client.EVMTokenAmount[](0);
        }

        // Build and send the CCIP message with the root payload.
        // slither-disable-next-line reentrancy-events
        (bool refundFailed, uint256 refundAmount) = JBCCIPLib.sendCCIPMessage({
            ccipRouter: CCIP_ROUTER,
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            peerAddress: _peerAddress(),
            transportPayment: transportPayment,
            gasLimit: gasLimit,
            encodedPayload: abi.encode(_CCIP_MSG_TYPE_ROOT, abi.encode(sucker_message)),
            tokenAmounts: tokenAmounts,
            refundRecipient: _msgSender()
        });

        // Emit an event if the excess transport payment refund failed.
        if (refundFailed) emit TransportPaymentRefundFailed(_msgSender(), refundAmount);
    }

    //*********************************************************************//
    // ------------------------ internal views --------------------------- //
    //*********************************************************************//

    /// @notice Checks whether the given sender is a remote peer. Unused in this context.
    /// @param sender The address to check.
    /// @return _valid Whether the sender is a remote peer.
    function _isRemotePeer(address sender) internal view override returns (bool _valid) {
        // We do not check if it is the `peer` here, as this contract is supposed to be the caller *NOT* the peer.
        return sender == address(this);
    }

    /// @notice Validates a token mapping. Allows CCIP-specific mapping rules.
    /// @dev Unlike OP/Arbitrum suckers (which share ETH as native on both chains), this CCIP sucker can connect
    /// chains with different native tokens. This means `NATIVE_TOKEN` may map to an ERC-20 on the remote chain.
    /// @param map The token mapping to validate.
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
