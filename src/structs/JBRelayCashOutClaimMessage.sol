// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A cross-chain cash out claim message sent via CCIP from the home chain to a remote chain.
/// @custom:member beneficiary The address to receive reclaimed ETH on the remote chain.
// forge-lint: disable-next-line(pascal-case-struct)
struct JBRelayCashOutClaimMessage {
    address payable beneficiary;
}
