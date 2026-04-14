// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBridge} from "@arbitrum/nitro-contracts/src/bridge/IBridge.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IOutbox} from "@arbitrum/nitro-contracts/src/bridge/IOutbox.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {ArbSys} from "@arbitrum/nitro-contracts/src/precompiles/ArbSys.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

import {JBSucker} from "./JBSucker.sol";
import {JBArbitrumSuckerDeployer} from "./deployers/JBArbitrumSuckerDeployer.sol";
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";
import {JBLayer} from "./enums/JBLayer.sol";
import {IArbGatewayRouter} from "./interfaces/IArbGatewayRouter.sol";
import {IArbL1GatewayRouter} from "./interfaces/IArbL1GatewayRouter.sol";
import {IArbL2GatewayRouter} from "./interfaces/IArbL2GatewayRouter.sol";
import {IJBArbitrumSucker} from "./interfaces/IJBArbitrumSucker.sol";
import {ARBChains} from "./libraries/ARBChains.sol";
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBRemoteToken} from "./structs/JBRemoteToken.sol";
import {MerkleLib} from "./utils/MerkleLib.sol";

/// @notice A `JBSucker` implementation to suck tokens between two chains connected by an Arbitrum bridge.
contract JBArbitrumSucker is JBSucker, IJBArbitrumSucker {
    using BitMaps for BitMaps.BitMap;
    using MerkleLib for MerkleLib.Tree;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBArbitrumSucker_NotEnoughGas(uint256 payment, uint256 cost);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The inbox used to send messages between the local and remote sucker.
    IInbox public immutable override ARBINBOX;

    /// @notice The gateway router for the specific chain
    IArbGatewayRouter public immutable override GATEWAYROUTER;

    /// @notice The layer that this contract is on.
    JBLayer public immutable override LAYER;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param permissions A contract storing permissions.
    /// @param tokens A contract that manages token minting and burning.
    constructor(
        JBArbitrumSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        uint256 feeProjectId,
        IJBSuckerRegistry registry,
        address trustedForwarder
    )
        JBSucker(directory, permissions, tokens, feeProjectId, registry, trustedForwarder)
    {
        GATEWAYROUTER = JBArbitrumSuckerDeployer(deployer).arbGatewayRouter();
        ARBINBOX = JBArbitrumSuckerDeployer(deployer).arbInbox();
        LAYER = JBArbitrumSuckerDeployer(deployer).arbLayer();
    }

    //*********************************************************************//
    // ------------------------ external views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the chain on which the peer is located.
    /// @return chainId of the peer.
    function peerChainId() external view virtual override returns (uint256) {
        uint256 chainId = block.chainid;
        if (chainId == ARBChains.ETH_CHAINID) return ARBChains.ARB_CHAINID;
        if (chainId == ARBChains.ARB_CHAINID) return ARBChains.ETH_CHAINID;
        if (chainId == ARBChains.ETH_SEP_CHAINID) return ARBChains.ARB_SEP_CHAINID;
        if (chainId == ARBChains.ARB_SEP_CHAINID) return ARBChains.ETH_SEP_CHAINID;
        return 0;
    }

    //*********************************************************************//
    // ------------------------ internal views --------------------------- //
    //*********************************************************************//

    /// @notice Checks if the `sender` (`_msgSender()`) is a valid representative of the remote peer.
    /// @param sender The message's sender.
    /// @return valid A flag if the sender is a valid representative of the remote peer.
    function _isRemotePeer(address sender) internal view override returns (bool) {
        // Convert the bytes32 peer to an address for comparison with EVM bridge contracts.
        address peerAddress = _peerAddress();

        // If we are the L1 peer,
        if (LAYER == JBLayer.L1) {
            IBridge bridge = ARBINBOX.bridge();
            // Check that the sender is the bridge and that the outbox has our peer as the sender.
            return sender == address(bridge) && peerAddress == IOutbox(bridge.activeOutbox()).l2ToL1Sender();
        }

        // If we are the L2 peer, check using the `AddressAliasHelper`.
        return sender == AddressAliasHelper.applyL1ToL2Alias(peerAddress);
    }

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Helper to create the retryable ticket, avoiding stack-too-deep.
    function _createRetryableTicket(
        uint256 callTransportCost,
        uint256 nativeValue,
        uint256 maxSubmissionCost,
        uint256 maxFeePerGas,
        bytes memory data
    )
        internal
    {
        address peerAddress = _peerAddress();
        // slither-disable-next-line unused-return,calls-loop
        ARBINBOX.unsafeCreateRetryableTicket{value: callTransportCost + nativeValue}({
            to: peerAddress,
            l2CallValue: nativeValue,
            maxSubmissionCost: maxSubmissionCost,
            excessFeeRefundAddress: _msgSender(),
            callValueRefundAddress: peerAddress,
            gasLimit: MESSENGER_BASE_GAS_LIMIT,
            maxFeePerGas: maxFeePerGas,
            data: data
        });
    }

    /// @notice Approves the Arbitrum gateway to spend `amount` of `token`.
    function _approveGateway(address token, uint256 amount) internal {
        // slither-disable-next-line calls-loop
        SafeERC20.forceApprove({token: IERC20(token), spender: GATEWAYROUTER.getGateway(token), value: amount});
    }

    /// @notice Uses the L1/L2 gateway to send the root and assets over the bridge to the peer.
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
        JBMessageRoot memory message
    )
        internal
        override
    {
        // Build the calldata that will be send to the peer. This will call `JBSucker.fromRemote` on the remote peer.
        bytes memory data = abi.encodeCall(JBSucker.fromRemote, (message));

        // Depending on which layer we are on, send the call to the other layer.
        // slither-disable-start out-of-order-retryable
        if (LAYER == JBLayer.L1) {
            // L1→L2 requires transport payment for retryable tickets.
            if (transportPayment == 0) revert JBSucker_ExpectedMsgValue();
            _toL2({
                token: token, transportPayment: transportPayment, amount: amount, data: data, remoteToken: remoteToken
            });
        } else {
            // L2→L1 via ArbSys is free — reject any transport payment.
            if (transportPayment != 0) revert JBSucker_UnexpectedMsgValue(transportPayment);
            _toL1({token: token, amount: amount, data: data, remoteToken: remoteToken});
        }
        // slither-disable-end out-of-order-retryable
    }

    /// @notice Bridge the `token` and data to the remote L1 chain.
    /// @dev IMPORTANT — Arbitrum non-atomic bridging limitation:
    /// For ERC-20 transfers, this function performs two independent operations: one for the token bridge
    /// (via the L2 gateway router) and one for the `fromRemote` merkle root message (via `ArbSys.sendTxToL1`).
    /// These are processed independently on L1, with no guaranteed ordering.
    ///
    /// `_handleClaim` calls `_addToBalance` which checks `amountToAddToBalanceOf` (derived from the contract's
    /// actual token balance minus outbox balance). If the tokens have not arrived yet, this check will revert
    /// with `JBSucker_InsufficientBalance`, preventing unbacked token minting.
    /// @param token The token to bridge.
    /// @param amount The amount of tokens to bridge.
    /// @param data The calldata to send to the remote chain. This calls `JBSucker.fromRemote` on the remote peer.
    /// @param remoteToken Information about the remote token to bridged to.
    function _toL1(address token, uint256 amount, bytes memory data, JBRemoteToken memory remoteToken) internal {
        uint256 nativeValue;

        // Cache peer address to avoid redundant calls.
        address peerAddress = _peerAddress();

        // If the token is an ERC-20, bridge it to the peer.
        // If the amount is `0` then we do not need to bridge any ERC20.
        if (token != JBConstants.NATIVE_TOKEN && amount != 0) {
            _approveGateway(token, amount);

            // Convert bytes32 types to address at the Arbitrum bridge API boundary.
            // slither-disable-next-line calls-loop,unused-return
            IArbL2GatewayRouter(address(GATEWAYROUTER))
                .outboundTransfer({
                    l1Token: _toAddress(remoteToken.addr), to: peerAddress, amount: amount, data: bytes("")
                });
        } else {
            // Otherwise, the token is the native token, and the amount will be sent as `msg.value`.
            nativeValue = amount;
        }

        // Send the message to the peer with the reclaimed ETH.
        // Address `100` is the ArbSys precompile address.
        // slither-disable-next-line calls-loop,unused-return
        ArbSys(address(100)).sendTxToL1{value: nativeValue}({destination: peerAddress, data: data});
    }

    /// @notice Bridge the `token` and data to the remote L2 chain.
    /// @dev IMPORTANT — Arbitrum non-atomic bridging limitation:
    /// For ERC-20 transfers, this function creates two independent retryable tickets: one for the token bridge
    /// (via the gateway router) and one for the `fromRemote` merkle root message (via the inbox).
    /// These tickets are redeemed independently on L2, with no guaranteed ordering.
    ///
    /// `_handleClaim` calls `_addToBalance` which checks `amountToAddToBalanceOf` (derived from the contract's
    /// actual token balance minus outbox balance). If the tokens have not arrived yet, this check will revert
    /// with `JBSucker_InsufficientBalance`, preventing unbacked token minting.
    /// @param token The token to bridge.
    /// @param amount The amount of tokens to bridge.
    /// @param data The calldata to send to the remote chain. This calls `JBSucker.fromRemote` on the remote peer.
    function _toL2(
        address token,
        uint256 transportPayment,
        uint256 amount,
        bytes memory data,
        JBRemoteToken memory remoteToken
    )
        internal
    {
        uint256 nativeValue;
        uint256 maxFeePerGas = block.basefee;
        uint256 callTransportCost;
        uint256 maxSubmissionCost;

        {
            // slither-disable-next-line calls-loop
            maxSubmissionCost =
                ARBINBOX.calculateRetryableSubmissionFee({dataLength: data.length, baseFee: maxFeePerGas});

            // Tracks the cost for the call to the remote peer.
            callTransportCost = maxSubmissionCost + (MESSENGER_BASE_GAS_LIMIT * maxFeePerGas);
        }

        // If the token is an ERC-20, bridge it to the peer.
        // If the amount is `0` then we do not need to bridge any ERC20.
        if (token != JBConstants.NATIVE_TOKEN && amount != 0) {
            // Calculate the cost of the ERC-20 transfer. (96 is the length of the abi encoded `data`)
            // slither-disable-next-line calls-loop
            uint256 maxSubmissionCostERC20 =
                ARBINBOX.calculateRetryableSubmissionFee({dataLength: 96, baseFee: maxFeePerGas});

            uint256 tokenTransportCost = maxSubmissionCostERC20 + (remoteToken.minGas * maxFeePerGas);

            // Ensure we bridge enough for gas costs on L2 side
            if (transportPayment < callTransportCost + tokenTransportCost) {
                revert JBArbitrumSucker_NotEnoughGas(transportPayment, callTransportCost + tokenTransportCost);
            }

            {
                // The amount of left over transportPayment will be split over the two calls.
                uint256 transportPaymentRemainder = (transportPayment - callTransportCost - tokenTransportCost) / 2;
                tokenTransportCost += transportPaymentRemainder;
                callTransportCost += transportPaymentRemainder;
            }

            // Approve the tokens to be bridged.
            _approveGateway(token, amount);

            // Perform the ERC-20 bridge transfer. Convert bytes32 peer to address at the Arbitrum bridge API boundary.
            // slither-disable-start out-of-order-retryable
            // slither-disable-next-line calls-loop,unused-return
            IArbL1GatewayRouter(address(GATEWAYROUTER)).outboundTransferCustomRefund{value: tokenTransportCost}({
                token: token,
                refundTo: _msgSender(),
                to: _peerAddress(),
                amount: amount,
                maxGas: remoteToken.minGas,
                gasPriceBid: maxFeePerGas,
                data: bytes(abi.encode(maxSubmissionCostERC20, bytes("")))
            });
        } else {
            // Ensure we bridge enough for gas costs on L2 side
            if (transportPayment < callTransportCost) {
                revert JBArbitrumSucker_NotEnoughGas(transportPayment, callTransportCost);
            }

            // If the token is the native token then we only need to do a single call.
            // So it should use all of the transportPayment.
            callTransportCost = transportPayment;

            // Otherwise, the token is the native token, and the amount will be sent as `msg.value`.
            nativeValue = amount;
        }

        // Create the retryable ticket containing the merkleRoot.
        // We call unsafe as we do not want the refund address to be aliased to L2.
        // The above check is the same check that makes it `safeCreateRetryableTicket`.

        // Convert bytes32 peer to address at the Arbitrum inbox API boundary.
        // slither-disable-next-line calls-loop,unused-return
        _createRetryableTicket({
            callTransportCost: callTransportCost,
            nativeValue: nativeValue,
            maxSubmissionCost: maxSubmissionCost,
            maxFeePerGas: maxFeePerGas,
            data: data
        });
        // slither-disable-end out-of-order-retryable
    }
}
