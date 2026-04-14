// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A message describing a cross-chain payment to be executed on the remote chain.
/// @dev Used by `payRemote` to bridge funds from the source chain to the destination chain, where the sucker
/// pays the project, cashes out at 0% tax (sucker privilege), inserts the resulting project tokens into the
/// outbox tree, and auto-triggers the return bridge so the beneficiary can claim on the source chain.
struct JBPayRemoteMessage {
    /// @notice The terminal token on the remote chain to pay with (bytes32 for cross-VM compatibility).
    bytes32 token;
    /// @notice The amount of terminal tokens to pay.
    uint256 amount;
    /// @notice Budget for the return bridge hop (0 for free bridges like OP/Base/Celo).
    uint256 returnTransport;
    /// @notice Who receives the project tokens on the source chain (bytes32 for cross-VM compatibility).
    bytes32 beneficiary;
    /// @notice Minimum project tokens to receive from the pay step (slippage protection).
    uint256 minTokensOut;
    /// @notice Metadata forwarded to `terminal.pay()` for hooks (721 mints, buyback, etc.).
    bytes metadata;
}
