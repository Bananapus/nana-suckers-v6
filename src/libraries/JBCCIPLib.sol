// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICCIPRouter, IWrappedNativeToken} from "../interfaces/ICCIPRouter.sol";

/// @notice Library with CCIP message building and sending logic extracted from JBCCIPSucker and JBSwapCCIPSucker
/// to reduce child contract sizes.
/// @dev These are `external` library functions, deployed as a separate contract and called via DELEGATECALL.
library JBCCIPLib {
    // A library for safe ERC-20 operations.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Prepare token amounts for CCIP: wrap native ETH -> WETH, build token amounts array, approve router.
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
        // If the amount is zero, return an empty array and the original token.
        if (amount == 0) {
            return (new Client.EVMTokenAmount[](0), token);
        }

        // Start with the original token as the bridge token.
        bridgeToken = token;

        // Wrap native ETH -> WETH for CCIP bridging. CCIP only transports ERC-20s.
        if (token == JBConstants.NATIVE_TOKEN) {
            // Get the wrapped native token address from the CCIP router.
            // slither-disable-next-line calls-loop
            IWrappedNativeToken wrappedNative = ccipRouter.getWrappedNative();

            // Deposit ETH to receive WETH.
            // slither-disable-next-line calls-loop,arbitrary-send-eth
            wrappedNative.deposit{value: amount}();

            // Update the bridge token to the wrapped native address.
            bridgeToken = address(wrappedNative);
        }

        // Build a single-element token amounts array for CCIP.
        tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: bridgeToken, amount: amount});

        // Approve the Router to spend tokens on the contract's behalf.
        SafeERC20.forceApprove({token: IERC20(bridgeToken), spender: address(ccipRouter), value: amount});
    }

    /// @notice Build and send a CCIP message, then handle refunds.
    /// @dev Runs via DELEGATECALL. Handles EVM2AnyMessage construction, getFee, ccipSend, and refund.
    /// @dev Supports two fee modes:
    ///   - `transportPayment > 0`: pay CCIP fees in native ETH (existing behavior).
    ///   - `transportPayment == 0`: pay CCIP fees in LINK pulled from the caller via transferFrom.
    ///     This enables chains with no meaningful native token (e.g. Tempo) to use CCIP.
    /// @param ccipRouter The CCIP router.
    /// @param remoteChainSelector The CCIP chain selector for the remote chain.
    /// @param peerAddress The peer sucker address on the remote chain.
    /// @param transportPayment The ETH transport payment available (0 for LINK fee mode).
    /// @param feeToken The fee token address: address(0) for native ETH, LINK address for LINK fee mode.
    /// @param feeTokenPayer The address to pull LINK fees from via transferFrom (0 to use sucker's own balance).
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
        address feeToken,
        address feeTokenPayer,
        uint256 gasLimit,
        bytes memory encodedPayload,
        Client.EVMTokenAmount[] memory tokenAmounts,
        address refundRecipient
    )
        external
        returns (bool refundFailed, uint256 refundAmount)
    {
        // Cache to reduce stack pressure.
        address router = address(ccipRouter);
        uint64 chainSel = remoteChainSelector;

        // Build the CCIP message.
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(peerAddress),
            data: encodedPayload,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit})),
            feeToken: feeToken
        });

        // Get the CCIP fee for sending the message.
        // slither-disable-next-line calls-loop
        uint256 fees = ICCIPRouter(router).getFee({destinationChainSelector: chainSel, message: message});

        if (feeToken != address(0)) {
            // LINK fee path: pull the fee from the caller so toRemote stays permissionless.
            // The caller must approve LINK to the sucker before calling toRemote.
            if (feeTokenPayer != address(0)) {
                // slither-disable-next-line arbitrary-send-erc20
                IERC20(feeToken).safeTransferFrom(feeTokenPayer, address(this), fees);
            }

            // Approve the router to spend LINK (fee + any bridged LINK amount).
            // When the fee token is also a bridged token (e.g. LINK on Tempo), the approval
            // must cover both the bridged amount and the fee. prepareTokenAmounts() already
            // approved the bridged amount, but forceApprove replaces (not adds), so we must
            // set the total here.
            uint256 totalApproval = fees;
            for (uint256 i; i < tokenAmounts.length; i++) {
                if (tokenAmounts[i].token == feeToken) {
                    totalApproval += tokenAmounts[i].amount;
                    break;
                }
            }
            SafeERC20.forceApprove({token: IERC20(feeToken), spender: router, value: totalApproval});

            // slither-disable-next-line calls-loop,unused-return
            ICCIPRouter(router).ccipSend({destinationChainSelector: chainSel, message: message});
        } else {
            // Native ETH fee path.
            // slither-disable-next-line calls-loop,unused-return,arbitrary-send-eth
            ICCIPRouter(router).ccipSend{value: fees}({destinationChainSelector: chainSel, message: message});

            // Calculate the excess transport payment to refund.
            refundAmount = transportPayment - fees;

            // Refund excess transport payment to the recipient.
            if (refundAmount != 0) {
                // slither-disable-next-line arbitrary-send-eth,missing-zero-check
                (bool sent,) = refundRecipient.call{value: refundAmount}("");

                // Record the refund failure if the transfer did not succeed.
                if (!sent) refundFailed = true;
            }
        }
    }

    /// @notice Unwrap WETH -> ETH from received CCIP tokens if the delivered token is the router's wrapped native.
    /// @dev Runs via DELEGATECALL so `address(this).balance` refers to the calling contract.
    /// @param ccipRouter The CCIP router (used to look up wrapped native token).
    /// @param destTokenAmounts The token amounts delivered by CCIP (length 0 or 1).
    function unwrapReceivedTokens(ICCIPRouter ccipRouter, Client.EVMTokenAmount[] calldata destTokenAmounts) external {
        // Only process if exactly one token was delivered.
        if (destTokenAmounts.length == 1) {
            // Get a reference to the delivered token amount.
            Client.EVMTokenAmount calldata tokenAmount = destTokenAmounts[0];

            // Look up the wrapped native token from the CCIP router.
            // slither-disable-next-line calls-loop
            IWrappedNativeToken wrappedNative = ccipRouter.getWrappedNative();

            // If the delivered token is WETH and the amount is non-zero, unwrap it.
            if (tokenAmount.token == address(wrappedNative) && tokenAmount.amount > 0) {
                // Record the ETH balance before unwrapping.
                uint256 balanceBefore = address(this).balance;

                // Withdraw WETH to receive ETH.
                wrappedNative.withdraw(tokenAmount.amount);

                // Assert the ETH balance increased by the expected amount.
                // slither-disable-next-line incorrect-equality
                assert(balanceBefore + tokenAmount.amount == address(this).balance);
            }
        }
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Decode a typed CCIP message: abi.encode(uint8 type, bytes payload).
    /// @param data The raw CCIP message data.
    /// @return messageType The message type (0 = root).
    /// @return payload The inner payload (encoded JBMessageRoot).
    function decodeTypedMessage(bytes memory data) external pure returns (uint8 messageType, bytes memory payload) {
        // ABI-decode the type and payload from the raw data.
        (messageType, payload) = abi.decode(data, (uint8, bytes));
    }
}
