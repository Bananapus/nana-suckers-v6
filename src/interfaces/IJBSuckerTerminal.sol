// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {ICCIPRouter} from "./ICCIPRouter.sol";
import {IJBSuckerRegistry} from "./IJBSuckerRegistry.sol";
import {JBProxyConfig} from "../structs/JBProxyConfig.sol";

/// @notice A factory and payment router that creates proxy projects backed by real project tokens.
/// On the home chain, routes payments locally. On remote chains, bridges funds via CCIP to the home chain.
interface IJBSuckerTerminal is IJBTerminal {
    // Events

    /// @notice Emitted when a cash out is executed on the home chain via the sucker terminal.
    /// @param proxyProjectId The ID of the proxy project.
    /// @param realProjectId The ID of the real project.
    /// @param cashOutCount The number of proxy tokens cashed out.
    /// @param reclaimAmount The amount of ETH reclaimed.
    /// @param beneficiary The address that will receive the reclaimed ETH on the remote chain.
    /// @param caller The address that initiated the cash out.
    event CashOut(
        uint256 indexed proxyProjectId,
        uint256 indexed realProjectId,
        uint256 cashOutCount,
        uint256 reclaimAmount,
        address beneficiary,
        address caller
    );

    /// @notice Emitted when a CCIP cash out claim message is received and ETH is delivered.
    /// @param beneficiary The address that received the ETH.
    /// @param amount The amount of ETH delivered.
    event CCIPCashOutClaimReceived(address indexed beneficiary, uint256 amount);

    /// @notice Emitted when a CCIP message is sent to deliver cash out proceeds to a remote chain.
    /// @param proxyProjectId The ID of the proxy project.
    /// @param reclaimAmount The amount of ETH bridged.
    /// @param beneficiary The address to receive ETH on the remote chain.
    /// @param caller The address that initiated the cash out.
    event CCIPCashOutClaimSent(
        uint256 indexed proxyProjectId, uint256 reclaimAmount, address beneficiary, address caller
    );

    /// @notice Emitted when a CCIP pay message is received on the home chain and executed.
    /// @param realProjectId The ID of the real project.
    /// @param beneficiary The address that received proxy tokens.
    /// @param amount The amount of ETH received.
    /// @param proxyTokenCount The number of proxy tokens minted.
    event CCIPPayReceived(
        uint256 indexed realProjectId, address indexed beneficiary, uint256 amount, uint256 proxyTokenCount
    );

    /// @notice Emitted when a CCIP pay message is sent from a remote chain.
    /// @param proxyProjectId The ID of the proxy project.
    /// @param realProjectId The ID of the real project on the home chain.
    /// @param amount The amount of ETH bridged.
    /// @param beneficiary The address to receive proxy tokens on the home chain.
    /// @param caller The address that initiated the payment.
    event CCIPPaySent(
        uint256 indexed proxyProjectId,
        uint256 indexed realProjectId,
        uint256 amount,
        address beneficiary,
        address caller
    );

    /// @notice Emitted when a proxy project is created for a real project.
    /// @param realProjectId The ID of the real project.
    /// @param proxyProjectId The ID of the proxy project.
    /// @param realToken The address of the real project's ERC-20 token (or NATIVE_TOKEN on remote chains).
    /// @param homeChainSelector The CCIP chain selector of the home chain (0 = home chain).
    /// @param caller The address that created the proxy.
    event CreateProxy(
        uint256 indexed realProjectId,
        uint256 indexed proxyProjectId,
        address realToken,
        uint64 homeChainSelector,
        address caller
    );

    /// @notice Emitted when a transport payment refund fails after a successful CCIP send.
    /// @param recipient The address that was supposed to receive the refund.
    /// @param amount The amount of the failed refund.
    event TransportPaymentRefundFailed(address indexed recipient, uint256 amount);

    // Views

    /// @notice The CCIP router on this chain.
    /// @return The CCIP router contract.
    function CCIP_ROUTER() external view returns (ICCIPRouter);

    /// @notice The Juicebox controller.
    /// @return The controller contract.
    function CONTROLLER() external view returns (IJBController);

    /// @notice The Juicebox directory.
    /// @return The directory contract.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The canonical JBMultiTerminal on this chain.
    /// @return The terminal contract.
    function MULTI_TERMINAL() external view returns (IJBTerminal);

    /// @notice The address of the JBSuckerTerminal on the peer chain.
    /// @return The peer address.
    function PEER() external view returns (address);

    /// @notice The Juicebox projects NFT contract.
    /// @return The projects contract.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice Returns the proxy configuration for a given proxy project ID.
    /// @param proxyProjectId The ID of the proxy project.
    /// @return The proxy configuration.
    function proxyConfigOf(uint256 proxyProjectId) external view returns (JBProxyConfig memory);

    /// @notice Returns the proxy project ID for a given real project ID and deployer.
    /// @param realProjectId The ID of the real project.
    /// @param deployer The address that created the proxy.
    /// @return The proxy project ID, or 0 if none exists.
    function proxyProjectIdOf(uint256 realProjectId, address deployer) external view returns (uint256);

    /// @notice The CCIP chain selector of the peer chain. 0 if no peer.
    /// @return The peer chain selector.
    function REMOTE_CHAIN_SELECTOR() external view returns (uint64);

    /// @notice The router terminal for swap-based fallback when delivered tokens have no direct terminal.
    /// @return The router terminal contract, or address(0) if not configured.
    function ROUTER_TERMINAL() external view returns (IJBTerminal);

    /// @notice The sucker registry.
    /// @return The registry contract.
    function SUCKER_REGISTRY() external view returns (IJBSuckerRegistry);

    /// @notice The Juicebox token store.
    /// @return The tokens contract.
    function TOKENS() external view returns (IJBTokens);

    // State-changing functions

    /// @notice Cashes out proxy tokens on the home chain, converting them back to ETH and bridging via CCIP to the
    /// remote chain.
    /// @dev Only callable on the home chain (homeChainSelector == 0). msg.value covers the CCIP transport fee.
    /// @param proxyProjectId The proxy project whose tokens are being cashed out.
    /// @param cashOutCount The number of proxy tokens to cash out.
    /// @param tokenToReclaim The token to reclaim from the real project (typically NATIVE_TOKEN).
    /// @param minReclaimAmount The minimum amount of tokens to reclaim.
    /// @param beneficiary The address to receive reclaimed ETH on the remote chain.
    /// @param metadata Extra metadata for the cash out.
    /// @return reclaimAmount The amount of ETH reclaimed from the real project.
    function cashOut(
        uint256 proxyProjectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minReclaimAmount,
        address payable beneficiary,
        bytes calldata metadata
    )
        external
        payable
        returns (uint256 reclaimAmount);

    /// @notice Creates a proxy project for a real project.
    /// @param realProjectId The ID of the real project. Must have an ERC-20 token deployed (on home chain).
    /// @param homeChainSelector The CCIP chain selector of the home chain. 0 = this is the home chain.
    /// @param name The name for the proxy project's ERC-20 token.
    /// @param symbol The symbol for the proxy project's ERC-20 token.
    /// @param salt The salt for deterministic ERC-20 deployment.
    /// @return proxyProjectId The ID of the created proxy project.
    function createProxy(
        uint256 realProjectId,
        uint64 homeChainSelector,
        string calldata name,
        string calldata symbol,
        bytes32 salt
    )
        external
        returns (uint256 proxyProjectId);
}
