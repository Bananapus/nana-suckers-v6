// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICCIPRouter, IWrappedNativeToken} from "../interfaces/ICCIPRouter.sol";

/// @notice Library with CCIP message building and sending logic extracted from JBCCIPSucker and JBSwapCCIPSucker
/// to reduce child contract sizes.
/// @dev These are `external` library functions, deployed as a separate contract and called via DELEGATECALL.
library JBCCIPLib {
    using SafeERC20 for IERC20;

    // -------------------- external state-changing -------------------- //

    /// @notice Prepare token amounts for CCIP: wrap native ETH → WETH, build token amounts array, approve router.
    /// @dev Runs via DELEGATECALL so native ETH wrapping uses the caller's balance.
    /// @param ccipRouter The CCIP router.
    /// @param token The token to bridge (may be NATIVE_TOKEN).
    /// @param amount The amount to bridge.
    /// @return tokenAmounts The CCIP token amounts array (length 0 or 1).
    /// @return bridgeToken The actual ERC-20 token address being bridged (WETH if native was wrapped).
    function prepareTokenAmounts(
        ICCIPRouter ccipRouter,
        address token,
        uint256 amount
    )
        external
        returns (Client.EVMTokenAmount[] memory tokenAmounts, address bridgeToken)
    {
        if (amount == 0) {
            return (new Client.EVMTokenAmount[](0), token);
        }

        bridgeToken = token;

        // Wrap native ETH → WETH for CCIP bridging. CCIP only transports ERC-20s.
        if (token == JBConstants.NATIVE_TOKEN) {
            // slither-disable-next-line calls-loop
            IWrappedNativeToken wrappedNative = ccipRouter.getWrappedNative();
            // slither-disable-next-line calls-loop,arbitrary-send-eth
            wrappedNative.deposit{value: amount}();
            bridgeToken = address(wrappedNative);
        }

        tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: bridgeToken, amount: amount});

        // Approve the Router to spend tokens on contract's behalf.
        SafeERC20.forceApprove({token: IERC20(bridgeToken), spender: address(ccipRouter), value: amount});
    }

    /// @notice Unwrap WETH → ETH from received CCIP tokens if the delivered token is the router's wrapped native.
    /// @dev Runs via DELEGATECALL so `address(this).balance` refers to the calling contract.
    /// @param ccipRouter The CCIP router (used to look up wrapped native token).
    /// @param destTokenAmounts The token amounts delivered by CCIP (length 0 or 1).
    function unwrapReceivedTokens(ICCIPRouter ccipRouter, Client.EVMTokenAmount[] calldata destTokenAmounts) external {
        if (destTokenAmounts.length == 1) {
            Client.EVMTokenAmount calldata tokenAmount = destTokenAmounts[0];
            // slither-disable-next-line calls-loop
            IWrappedNativeToken wrappedNative = ccipRouter.getWrappedNative();
            if (tokenAmount.token == address(wrappedNative) && tokenAmount.amount > 0) {
                uint256 balanceBefore = address(this).balance;
                wrappedNative.withdraw(tokenAmount.amount);
                // slither-disable-next-line incorrect-equality
                assert(balanceBefore + tokenAmount.amount == address(this).balance);
            }
        }
    }

    /// @notice Decode a typed CCIP message: abi.encode(uint8 type, bytes payload).
    /// @param data The raw CCIP message data.
    /// @return messageType The message type (0 = root, 1 = pay).
    /// @return payload The inner payload (encoded JBMessageRoot or JBPayRemoteMessage).
    function decodeTypedMessage(bytes memory data) external pure returns (uint8 messageType, bytes memory payload) {
        (messageType, payload) = abi.decode(data, (uint8, bytes));
    }

    /// @notice Build and send a CCIP message, then handle refunds.
    /// @dev Runs via DELEGATECALL. Handles EVM2AnyMessage construction, getFee, ccipSend, and refund.
    /// @param ccipRouter The CCIP router.
    /// @param remoteChainSelector The CCIP chain selector for the remote chain.
    /// @param peerAddress The peer sucker address on the remote chain.
    /// @param transportPayment The ETH transport payment available.
    /// @param gasLimit The gas limit for the CCIP message.
    /// @param encodedPayload The ABI-encoded payload (e.g., abi.encode(type, data)).
    /// @param tokenAmounts The token amounts to bridge (from prepareTokenAmounts).
    /// @param refundRecipient The address to refund excess transport payment to.
    /// @return refundFailed Whether the refund transfer failed.
    /// @return refundAmount The amount that failed to refund (0 if successful or no refund needed).
    function sendCCIPMessage(
        ICCIPRouter ccipRouter,
        uint64 remoteChainSelector,
        address peerAddress,
        uint256 transportPayment,
        uint256 gasLimit,
        bytes memory encodedPayload,
        Client.EVMTokenAmount[] memory tokenAmounts,
        address refundRecipient
    )
        external
        returns (bool refundFailed, uint256 refundAmount)
    {
        // Build the CCIP message.
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(peerAddress),
            data: encodedPayload,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit})),
            feeToken: address(0)
        });

        // Get the CCIP fee.
        // slither-disable-next-line calls-loop
        uint256 fees = ccipRouter.getFee({destinationChainSelector: remoteChainSelector, message: message});

        // Send the CCIP message.
        // slither-disable-next-line calls-loop,unused-return
        ccipRouter.ccipSend{value: fees}({destinationChainSelector: remoteChainSelector, message: message});

        // Refund excess transport payment.
        refundAmount = transportPayment - fees;
        if (refundAmount != 0) {
            // slither-disable-next-line calls-loop,msg-value-loop,reentrancy-events
            (bool sent,) = refundRecipient.call{value: refundAmount}("");
            if (!sent) refundFailed = true;
        }
    }
}
