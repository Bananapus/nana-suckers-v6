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
import {ICCIPRouter} from "./interfaces/ICCIPRouter.sol";
import {IJBCCIPSuckerDeployer} from "./interfaces/IJBCCIPSuckerDeployer.sol";
import {JBCCIPLib} from "./libraries/JBCCIPLib.sol";
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

        // Discriminate message type. New format: abi.encode(uint8 type, bytes payload).
        // For backward compatibility with in-flight messages, try new format first, fall back to old.
        (uint8 messageType, bytes memory payload) = JBCCIPLib.decodeTypedMessage(any2EvmMessage.data);

        if (messageType == _CCIP_MSG_TYPE_ROOT) {
            JBMessageRoot memory root = abi.decode(payload, (JBMessageRoot));
            // Only unwrap WETH → ETH when the root targets native token (not when claiming WETH as ERC-20).
            if (root.token == bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))) {
                JBCCIPLib.unwrapReceivedTokens(CCIP_ROUTER, any2EvmMessage.destTokenAmounts);
            }
            this.fromRemote(root);
        } else if (messageType == _CCIP_MSG_TYPE_PAY) {
            JBPayRemoteMessage memory payMsg = abi.decode(payload, (JBPayRemoteMessage));
            // Only unwrap WETH → ETH when the pay message targets native token.
            if (payMsg.token == bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))) {
                JBCCIPLib.unwrapReceivedTokens(CCIP_ROUTER, any2EvmMessage.destTokenAmounts);
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
    /// @dev Delegates CCIP message construction and sending to JBCCIPLib (via DELEGATECALL) to reduce bytecode.
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
        if (transportPayment == 0) revert JBSucker_ExpectedMsgValue();

        uint256 gasLimit = MESSENGER_BASE_GAS_LIMIT;
        Client.EVMTokenAmount[] memory tokenAmounts;
        if (amount != 0) {
            gasLimit += remoteToken.minGas;
            (tokenAmounts,) = JBCCIPLib.prepareTokenAmounts({ccipRouter: CCIP_ROUTER, token: token, amount: amount});
        } else {
            tokenAmounts = new Client.EVMTokenAmount[](0);
        }

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

        if (refundFailed) emit TransportPaymentRefundFailed(_msgSender(), refundAmount);
    }

    /// @notice Bridge funds and a pay message to the remote peer via CCIP.
    /// @dev Delegates CCIP message construction and sending to JBCCIPLib (via DELEGATECALL) to reduce bytecode.
    /// @param transportPayment The transport payment for the CCIP message.
    /// @param token The terminal token being bridged.
    /// @param amount The amount of terminal tokens to bridge.
    /// @param remoteToken The remote token configuration.
    /// @param message The pay-remote message to send.
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
            (tokenAmounts,) = JBCCIPLib.prepareTokenAmounts({ccipRouter: CCIP_ROUTER, token: token, amount: amount});
        } else {
            tokenAmounts = new Client.EVMTokenAmount[](0);
        }

        (bool refundFailed, uint256 refundAmount) = JBCCIPLib.sendCCIPMessage({
            ccipRouter: CCIP_ROUTER,
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            peerAddress: _toAddress(peer()),
            transportPayment: transportPayment,
            gasLimit: gasLimit,
            encodedPayload: abi.encode(_CCIP_MSG_TYPE_PAY, abi.encode(message)),
            tokenAmounts: tokenAmounts,
            refundRecipient: _msgSender()
        });

        if (refundFailed) emit TransportPaymentRefundFailed(_msgSender(), refundAmount);
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

    /// @notice CCIP cannot bridge native ETH for the return trip, so allocate the entire transport budget to the
    /// outbound hop. Without this override the base class splits 50/50, leaving the return half stuck in the source
    /// sucker with no recovery path.
    function _splitTransportBudget(uint256 budget) internal pure override returns (uint256, uint256) {
        return (budget, 0);
    }

}
