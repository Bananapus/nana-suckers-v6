// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Configuration linking a proxy project to its real project.
/// @custom:member realProjectId The ID of the real project that the proxy project represents.
/// @custom:member homeChainSelector The CCIP chain selector of the home chain where the real project lives. 0 = this
/// is the home chain (route locally).
// forge-lint: disable-next-line(pascal-case-struct)
struct JBProxyConfig {
    uint256 realProjectId;
    uint64 homeChainSelector;
}
