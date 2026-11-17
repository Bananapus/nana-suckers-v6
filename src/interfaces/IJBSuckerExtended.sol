// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBSucker, JBClaim} from "./IJBSucker.sol";

/// @notice Contains the IJBSucker interface and extends it with additional functions and events.
interface IJBSuckerExtended is IJBSucker {
    // Events

    /// @notice Emitted when the deprecation timestamp is updated.
    /// @param timestamp The new deprecation timestamp.
    /// @param caller The address that updated the timestamp.
    event DeprecationTimeUpdated(uint40 timestamp, address caller);

    /// @notice Emitted when a beneficiary exits through the emergency hatch.
    /// @param beneficiary The beneficiary receiving the tokens.
    /// @param token The terminal token address.
    /// @param terminalTokenAmount The amount of terminal tokens returned.
    /// @param projectTokenCount The number of project tokens minted.
    /// @param caller The address that performed the emergency exit.
    event EmergencyExit(
        address indexed beneficiary,
        address indexed token,
        uint256 terminalTokenAmount,
        uint256 projectTokenCount,
        address caller
    );

    /// @notice Emitted when the emergency hatch is opened for one or more tokens.
    /// @param tokens The tokens for which the emergency hatch was opened.
    /// @param caller The address that opened the emergency hatch.
    event EmergencyHatchOpened(address[] tokens, address caller);

    /// @notice Emitted when a failed `toRemoteFee` payment is retained until the fee project can take it.
    /// @param account The fee beneficiary the `toRemote` call named, credited when the retained fee is paid.
    /// @param amount The retained fee amount.
    /// @param caller The address that caused the fee to be retained.
    event RetainedToRemoteFee(address indexed account, uint256 amount, address caller);

    /// @notice Emitted when a failed transport-payment refund is retained for later refund.
    /// @param account The account that can reclaim the retained refund.
    /// @param amount The retained refund amount.
    /// @param caller The address that caused the refund to be retained.
    event RetainedTransportPaymentRefund(address indexed account, uint256 amount, address caller);

    /// @notice Emitted when a retained `toRemoteFee` is paid to the fee project.
    /// @param account The account whose retained fee was paid, credited as the fee beneficiary.
    /// @param amount The amount paid.
    /// @param caller The address that triggered the payment.
    event RetainedToRemoteFeePaid(address indexed account, uint256 amount, address caller);

    /// @notice Emitted when an account claims retained transport-payment refund ETH.
    /// @param account The account whose retained refund balance was claimed.
    /// @param beneficiary The address that received the ETH.
    /// @param amount The amount claimed.
    /// @param caller The address that triggered the claim.
    event RetainedTransportPaymentRefundClaimed(
        address indexed account, address indexed beneficiary, uint256 amount, address caller
    );

    // View functions

    /// @notice The retained failed-fee ETH owed to an account.
    /// @param account The account to look up.
    /// @return amount The retained fee amount.
    function retainedToRemoteFeeOf(address account) external view returns (uint256 amount);

    /// @notice The total retained failed-fee ETH excluded from native add-to-balance accounting.
    /// @return amount The retained fee amount.
    function retainedToRemoteFeeBalance() external view returns (uint256 amount);

    /// @notice The retained failed transport-payment refund ETH owed to an account.
    /// @param account The account to look up.
    /// @return amount The retained refund amount.
    function retainedTransportPaymentRefundOf(address account) external view returns (uint256 amount);

    /// @notice The total retained failed transport-payment refund ETH excluded from native add-to-balance accounting.
    /// @return amount The retained refund amount.
    function retainedTransportPaymentRefundBalance() external view returns (uint256 amount);

    // State-changing functions

    /// @notice Pay a retained `toRemoteFee` to the fee project, crediting `account` as the fee beneficiary. Reverts if
    /// the fee project still cannot take it.
    /// @param account The account whose retained fee to pay.
    function payRetainedToRemoteFeeOf(address account) external;

    /// @notice Claim retained failed transport-payment refund ETH.
    /// @param beneficiary The address that should receive the retained ETH.
    function claimRetainedTransportPaymentRefund(address payable beneficiary) external;

    /// @notice Open the emergency hatch for the specified tokens, allowing direct claims without bridging.
    /// @param tokens The tokens to enable the emergency hatch for.
    function enableEmergencyHatchFor(address[] calldata tokens) external;

    /// @notice Claim tokens through the emergency hatch when bridging is unavailable.
    /// @param claimData The claim data including token, leaf, and proof.
    function exitThroughEmergencyHatch(JBClaim calldata claimData) external;

    /// @notice Set or update the deprecation timestamp for this sucker.
    /// @param timestamp The timestamp after which the sucker is deprecated.
    function setDeprecation(uint40 timestamp) external;
}
