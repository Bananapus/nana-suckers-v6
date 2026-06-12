// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// External packages (alphabetized)
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
// Local: base contracts
import {JBSucker} from "./JBSucker.sol";

// Local: deployers
import {JBCCIPSuckerDeployer} from "./deployers/JBCCIPSuckerDeployer.sol";

// Local: interfaces (alphabetized)
import {ICCIPRouter} from "./interfaces/ICCIPRouter.sol";
import {IJBCCIPSuckerDeployer} from "./interfaces/IJBCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";

// Local: libraries (alphabetized)
import {CCIPHelper} from "./libraries/CCIPHelper.sol";
import {JBCCIPLib} from "./libraries/JBCCIPLib.sol";

// Local: structs (alphabetized)
import {JBAccountingSnapshot} from "./structs/JBAccountingSnapshot.sol";
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBRemoteToken} from "./structs/JBRemoteToken.sol";
import {JBTokenMapping} from "./structs/JBTokenMapping.sol";

/// @notice A `JBSucker` implementation that bridges Juicebox project tokens and terminal-token funds across any pair of
/// chains supported by Chainlink CCIP. Messages and token transfers are bundled into a single CCIP lane message, with
/// the CCIP Router handling cross-chain delivery and fee estimation.
contract JBCCIPSucker is JBSucker, IAny2EVMMessageReceiver {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the configured CCIP router address is the zero address.
    error JBCCIPSucker_InvalidRouter(address router);

    /// @notice Thrown when an incoming root message claims a positive amount but no tokens were delivered with it.
    error JBCCIPSucker_PositiveRootWithoutDelivery(uint256 rootAmount);

    /// @notice Thrown when the amount of tokens delivered is less than the amount declared in the root message.
    error JBCCIPSucker_UnderDeliveredAmount(uint256 delivered, uint256 rootAmount);

    /// @notice Thrown when an incoming message delivers an unexpected number of token transfers.
    error JBCCIPSucker_UnexpectedDeliveredTokens(uint256 count);

    /// @notice Thrown when an incoming message has an unrecognized message type prefix.
    error JBCCIPSucker_UnknownMessageType(uint8 messageType);

    /// @notice Thrown when the token delivered with an incoming message does not match the expected token.
    error JBCCIPSucker_WrongDeliveredToken(address delivered, address expected);

    //*********************************************************************//
    // ------------------------------ events ----------------------------- //
    //*********************************************************************//

    /// @notice Emitted when a transport payment refund fails after a successful CCIP send.
    /// @dev The refunded ETH is retained as account-scoped credit so the CCIP send does not revert after
    /// committing the bridge message.
    /// @param recipient The address that was supposed to receive the refund.
    /// @param amount The amount of the failed refund.
    /// @param caller The address that triggered the CCIP send.
    event TransportPaymentRefundFailed(address indexed recipient, uint256 amount, address caller);

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Message type prefix for accounting-only messages (fromRemoteAccounting).
    uint8 internal constant _CCIP_MSG_TYPE_ACCOUNTING = 1;

    /// @notice Message type prefix for root messages (fromRemote).
    uint8 internal constant _CCIP_MSG_TYPE_ROOT = 0;

    /// @notice Extra destination gas budgeted for each source accounting context carried in a CCIP message.
    uint256 internal constant _CCIP_SOURCE_CONTEXT_GAS_LIMIT = 75_000;

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
    /// @param permissions A contract storing permissions.
    /// @param tokens A contract that manages token minting and burning.
    /// @param feeProjectId The ID of the project that receives fees.
    /// @param registry The sucker registry that tracks deployed suckers.
    /// @param trustedForwarder The trusted forwarder for ERC-2771 meta-transactions.
    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
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
            revert JBSucker_NotPeer({caller: _toBytes32(origin)});
        }

        // Discriminate message type: abi.encode(uint8 type, bytes payload).
        (uint8 messageType, bytes memory payload) = abi.decode(any2EvmMessage.data, (uint8, bytes));

        // Handle root messages (merkle tree updates with bridged assets).
        if (messageType == _CCIP_MSG_TYPE_ROOT) {
            // Decode the root message from the payload.
            JBMessageRoot memory root = abi.decode(payload, (JBMessageRoot));

            // Cross-check the delivered tokens against the advertised root before recording anything.
            //
            // The send-side guarantees at most one entry in `destTokenAmounts`: length 0 for zero-value batches,
            // length 1 for value-bearing batches. A compromised peer (or a malformed CCIP delivery) that violates
            // these invariants would otherwise let `fromRemote` record a root advertising more value than was
            // bridged, letting later claims mint project tokens against unrelated balance until the inbox runs dry.
            // `JBSwapCCIPSucker.ccipReceive` already enforces equivalent reverts for the swap variant; mirror
            // them here so both variants share a single defensive baseline.
            uint256 deliveryCount = any2EvmMessage.destTokenAmounts.length;
            if (deliveryCount > 1) {
                revert JBCCIPSucker_UnexpectedDeliveredTokens(deliveryCount);
            }
            if (deliveryCount == 0) {
                if (root.amount > 0) revert JBCCIPSucker_PositiveRootWithoutDelivery(root.amount);
            } else {
                Client.EVMTokenAmount calldata delivered = any2EvmMessage.destTokenAmounts[0];
                bool rootIsNativeToken = root.token == bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)));

                // For NATIVE_TOKEN bridges the delivered ERC-20 is the wrapped native token (CCIP cannot transport
                // raw native), so require the router-reported wrapped native address before unwrapping. For
                // everything else, the delivered token must equal the local mapped token the root advertises.
                address expectedToken =
                    rootIsNativeToken ? address(CCIP_ROUTER.getWrappedNative()) : _toAddress(root.token);
                if (delivered.token != expectedToken) {
                    revert JBCCIPSucker_WrongDeliveredToken({delivered: delivered.token, expected: expectedToken});
                }

                // The bridged amount must back at least the value the root advertises. A short delivery against a
                // positive root is the structural twin of "no delivery + positive root" — both leave the inbox
                // recording more claimable value than it actually holds.
                if (delivered.amount < root.amount) {
                    revert JBCCIPSucker_UnderDeliveredAmount({delivered: delivered.amount, rootAmount: root.amount});
                }
            }

            // Only unwrap wrapped native token when the root targets native token (not when claiming it as ERC-20).
            if (root.token == bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))) {
                JBCCIPLib.unwrapReceivedTokens({
                    ccipRouter: CCIP_ROUTER, destTokenAmounts: any2EvmMessage.destTokenAmounts
                });
            }

            // Forward the root message to this contract's fromRemote handler.
            this.fromRemote(root);
        } else if (messageType == _CCIP_MSG_TYPE_ACCOUNTING) {
            // Accounting-only messages must not carry tokens; transported value belongs exclusively to root messages.
            uint256 deliveryCount = any2EvmMessage.destTokenAmounts.length;
            if (deliveryCount != 0) {
                revert JBCCIPSucker_UnexpectedDeliveredTokens(deliveryCount);
            }

            JBAccountingSnapshot memory snapshot = abi.decode(payload, (JBAccountingSnapshot));

            // Forward the accounting message to this contract's authenticated accounting handler.
            this.fromRemoteAccounting(snapshot);
        } else {
            revert JBCCIPSucker_UnknownMessageType({messageType: messageType});
        }
    }

    //*********************************************************************//
    // ------------------------- public views ---------------------------- //
    //*********************************************************************//

    /// @notice Returns the address of the current CCIP router.
    /// @return router The CCIP router address.
    function getRouter() public view returns (address router) {
        return address(CCIP_ROUTER);
    }

    /// @notice Returns the chain on which the peer is located.
    /// @return chainId The chain ID of the peer.
    function peerChainId() public view virtual override returns (uint256 chainId) {
        return REMOTE_CHAIN_ID;
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
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Uses CCIP to send accounting data over the bridge to the peer.
    /// @dev Supports the same native/LINK fee modes as root messages, but never transports token amounts.
    /// @param transportPayment The amount of `msg.value` that is going to get paid for sending this message.
    /// @param snapshot The accounting snapshot to send to the remote peer.
    // forge-lint: disable-next-line(mixed-case-function)
    function _sendAccountingSnapshotOverAMB(
        uint256 transportPayment,
        JBAccountingSnapshot memory snapshot
    )
        internal
        virtual
        override
    {
        _sendCcipMessage({
            transportPayment: transportPayment,
            gasLimit: _ccipGasLimitFor({sourceContextCount: snapshot.sourceContexts.length}),
            encodedPayload: abi.encode(_CCIP_MSG_TYPE_ACCOUNTING, abi.encode(snapshot)),
            tokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    /// @notice Sends a CCIP message and records failed native-fee refunds as caller credit.
    /// @param transportPayment The amount of `msg.value` available to pay native CCIP fees.
    /// @param gasLimit The destination gas limit to ask CCIP to provide.
    /// @param encodedPayload The typed CCIP payload to send to the peer sucker.
    /// @param tokenAmounts The token amounts to bridge with the message.
    function _sendCcipMessage(
        uint256 transportPayment,
        uint256 gasLimit,
        bytes memory encodedPayload,
        Client.EVMTokenAmount[] memory tokenAmounts
    )
        internal
    {
        // Cache the caller so refund accounting and LINK fee pulls are charged to the same account.
        address sender = _msgSender();

        // Determine fee payment mode: native ETH or LINK token.
        // When transportPayment == 0, we pay in LINK pulled from the caller via transferFrom.
        // This enables chains with no meaningful native token (e.g. Tempo) while keeping
        // toRemote permissionless — the caller provides LINK inline with their bridge intent.
        address feeToken = transportPayment == 0 ? CCIPHelper.linkOfChain(block.chainid) : address(0);

        // Build and send the CCIP message with the provided typed payload.
        (bool refundFailed, uint256 refundAmount) = JBCCIPLib.sendCCIPMessage({
            ccipRouter: CCIP_ROUTER,
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            peerAddress: _peerAddress(),
            transportPayment: transportPayment,
            feeToken: feeToken,
            feeTokenPayer: feeToken != address(0) ? sender : address(0),
            gasLimit: gasLimit,
            encodedPayload: encodedPayload,
            tokenAmounts: tokenAmounts,
            refundRecipient: sender
        });

        // Retain failed refunds as caller credit instead of leaving them project-addable or stranded.
        if (refundFailed) {
            _retainTransportPaymentRefund({account: sender, amount: refundAmount});
            emit TransportPaymentRefundFailed({recipient: sender, amount: refundAmount, caller: sender});
        }
    }

    /// @notice Uses CCIP to send the root and assets over the bridge to the peer.
    /// @dev Delegates CCIP message construction and sending to JBCCIPLib (via DELEGATECALL) to reduce bytecode.
    /// @dev Supports two fee modes:
    ///   - `transportPayment > 0`: pay CCIP fees in native ETH (existing behavior).
    ///   - `transportPayment == 0`: pay CCIP fees in LINK from the sucker's pre-funded balance.
    ///     This enables chains with no meaningful native token (e.g. Tempo) to use CCIP.
    /// @param transportPayment The amount of `msg.value` that is going to get paid for sending this message.
    /// @param token The token to bridge the outbox tree for.
    /// @param amount The amount of tokens to bridge.
    /// @param remoteToken Information about the remote token to bridge to.
    /// @param suckerMessage The message root to send to the remote peer.
    // forge-lint: disable-next-line(mixed-case-function)
    function _sendRootOverAMB(
        uint256 transportPayment,
        uint256,
        address token,
        uint256 amount,
        JBRemoteToken memory remoteToken,
        JBMessageRoot memory suckerMessage
    )
        internal
        virtual
        override
    {
        // Budget for the root receiver plus the accounting contexts carried in the root message.
        uint256 gasLimit = _ccipGasLimitFor({sourceContextCount: suckerMessage.sourceContexts.length});
        Client.EVMTokenAmount[] memory tokenAmounts;

        if (amount != 0) {
            // Add extra gas for the ERC-20 token transfer on the remote chain.
            gasLimit += remoteToken.minGas;

            // Wrap native tokens if needed, build the CCIP token amounts array, and approve the router.
            (tokenAmounts,) = JBCCIPLib.prepareTokenAmounts({ccipRouter: CCIP_ROUTER, token: token, amount: amount});
        } else {
            // No tokens to bridge — use an empty array.
            tokenAmounts = new Client.EVMTokenAmount[](0);
        }

        _sendCcipMessage({
            transportPayment: transportPayment,
            gasLimit: gasLimit,
            encodedPayload: abi.encode(_CCIP_MSG_TYPE_ROOT, abi.encode(suckerMessage)),
            tokenAmounts: tokenAmounts
        });
    }

    //*********************************************************************//
    // ------------------------ internal views --------------------------- //
    //*********************************************************************//

    /// @notice The CCIP destination gas limit for a message carrying `sourceContextCount` accounting contexts.
    /// @param sourceContextCount The number of source accounting contexts in the message.
    /// @return gasLimit The destination gas limit to ask CCIP to provide.
    function _ccipGasLimitFor(uint256 sourceContextCount) internal pure returns (uint256 gasLimit) {
        return MESSENGER_BASE_GAS_LIMIT + (sourceContextCount * _CCIP_SOURCE_CONTEXT_GAS_LIMIT);
    }

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
    ///   - Sending: `_sendRootOverAMB` wraps native tokens, bridges them via CCIP.
    ///   - Receiving: `ccipReceive` checks `root.token == NATIVE_TOKEN` to decide whether to unwrap.
    ///     If `root.token` is an ERC-20 address (like celoETH), no unwrap occurs — tokens stay as ERC-20.
    ///
    /// The base class restriction (`NATIVE_TOKEN` can only map to `NATIVE_TOKEN` or `address(0)`) is intentionally
    /// removed here. The base class retains that restriction for OP/Arbitrum where both chains share ETH as native.
    function _validateTokenMapping(JBTokenMapping calldata map) internal pure virtual override {
        // Enforce a reasonable minimum gas limit for bridging. A minimum which is too low could lead to the loss of
        // funds. CCIP wraps native tokens before bridging (see `_sendRootOverAMB`), so ALL tokens —
        // including native — need sufficient gas for an ERC-20 transfer on the remote chain.
        if (map.minGas < MESSENGER_ERC20_MIN_GAS_LIMIT) {
            revert JBSucker_BelowMinGas({minGas: map.minGas, minGasLimit: MESSENGER_ERC20_MIN_GAS_LIMIT});
        }
    }
}
