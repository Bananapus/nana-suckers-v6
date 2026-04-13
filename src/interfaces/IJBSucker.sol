// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {JBClaim} from "../structs/JBClaim.sol";
import {JBInboxTreeRoot} from "../structs/JBInboxTreeRoot.sol";
import {JBOutboxTree} from "../structs/JBOutboxTree.sol";
import {JBRemoteToken} from "../structs/JBRemoteToken.sol";
import {JBSuckerState} from "../enums/JBSuckerState.sol";
import {JBTokenMapping} from "../structs/JBTokenMapping.sol";

/// @notice The minimal interface for a sucker contract.
interface IJBSucker is IERC165 {
    // Events

    /// @notice Emitted when a beneficiary claims bridged tokens from the inbox tree.
    /// @param beneficiary The beneficiary receiving the tokens.
    /// @param token The terminal token address.
    /// @param projectTokenCount The number of project tokens claimed.
    /// @param terminalTokenAmount The amount of terminal tokens involved.
    /// @param index The leaf index in the inbox tree.
    /// @param caller The address that performed the claim.
    event Claimed(
        bytes32 beneficiary,
        address token,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        uint256 index,
        address caller
    );

    /// @notice Emitted when a leaf is inserted into the outbox tree.
    /// @param beneficiary The beneficiary on the remote chain.
    /// @param token The terminal token address.
    /// @param hashed The hash of the leaf data.
    /// @param index The leaf index in the outbox tree.
    /// @param root The new outbox tree root after insertion.
    /// @param projectTokenCount The number of project tokens cashed out.
    /// @param terminalTokenAmount The amount of terminal tokens reclaimed.
    /// @param caller The address that performed the insertion.
    event InsertToOutboxTree(
        bytes32 indexed beneficiary,
        address indexed token,
        bytes32 hashed,
        uint256 index,
        bytes32 root,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        address caller
    );

    /// @notice Emitted when a new inbox tree root is received from the remote peer.
    /// @param token The terminal token address.
    /// @param nonce The nonce of the new root.
    /// @param root The new inbox tree root.
    /// @param caller The address that relayed the root.
    event NewInboxTreeRoot(address indexed token, uint64 nonce, bytes32 root, address caller);

    /// @notice Emitted when the outbox tree root and bridged assets are sent to the remote peer.
    /// @param root The outbox tree root being sent.
    /// @param token The terminal token being bridged.
    /// @param index The current outbox tree index.
    /// @param nonce The nonce assigned to this root message.
    /// @param caller The address that initiated the send.
    event RootToRemote(bytes32 indexed root, address indexed token, uint256 index, uint64 nonce, address caller);

    /// @notice Emitted when a received inbox root is rejected because its nonce is stale.
    /// @param token The terminal token address.
    /// @param receivedNonce The nonce of the rejected root.
    /// @param currentNonce The current nonce that was expected.
    event StaleRootRejected(address indexed token, uint64 receivedNonce, uint64 currentNonce);

    // View functions

    /// @notice The directory of terminals and controllers.
    /// @return The directory contract.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The minimum gas required for a basic cross-chain call.
    /// @return The base gas limit.
    function MESSENGER_BASE_GAS_LIMIT() external view returns (uint32);

    /// @notice The minimum gas required for bridging ERC-20 tokens.
    /// @return The ERC-20 minimum gas limit.
    function MESSENGER_ERC20_MIN_GAS_LIMIT() external view returns (uint32);

    /// @notice The token registry.
    /// @return The tokens contract.
    function TOKENS() external view returns (IJBTokens);

    /// @notice The amount of tokens waiting to be added to the project's terminal balance.
    /// @param token The terminal token address.
    /// @return amount The outstanding amount.
    function amountToAddToBalanceOf(address token) external view returns (uint256 amount);

    /// @notice The address of the deployer that created this sucker.
    /// @return The deployer address.
    function deployer() external view returns (address);

    /// @notice The inbox merkle tree root for a given token.
    /// @param token The local terminal token.
    /// @return The inbox tree root.
    function inboxOf(address token) external view returns (JBInboxTreeRoot memory);

    /// @notice Whether a token has been mapped for bridging.
    /// @param token The local token address.
    /// @return Whether the token is mapped.
    function isMapped(address token) external view returns (bool);

    /// @notice The outbox merkle tree for a given token.
    /// @param token The local terminal token.
    /// @return The outbox tree.
    function outboxOf(address token) external view returns (JBOutboxTree memory);

    /// @notice The address of the peer sucker on the remote chain (as bytes32 for cross-VM compatibility).
    /// @return The peer address.
    function peer() external view returns (bytes32);

    /// @notice The chain ID of the remote peer.
    /// @return chainId The remote chain ID.
    function peerChainId() external view returns (uint256 chainId);

    /// @notice The last known total token supply on the peer chain, updated each time a bridge message is received.
    /// @dev Used by data hooks to compute `effectiveTotalSupply = localSupply + sum(peerChainTotalSupply)` across all
    /// suckers, preventing cash out tax bypass on chains where a holder dominates the local supply.
    /// @return The peer chain's total supply.
    function peerChainTotalSupply() external view returns (uint256);

    /// @notice The last known total surplus (balance) on the peer chain, updated each time a bridge message is
    /// received.
    /// @dev Used by data hooks to compute `effectiveSurplus = localSurplus + sum(peerChainBalance)` across all
    /// suckers, preventing disproportionate reclaim when tokens bridge away but surplus stays.
    /// @return The peer chain's total surplus.
    function peerChainBalance() external view returns (uint256);

    /// @notice The ID of the project on the local chain that this sucker is associated with.
    /// @return The project ID.
    function projectId() external view returns (uint256);

    /// @notice Information about the remote token that a local token is mapped to.
    /// @param token The local terminal token.
    /// @return The remote token info.
    function remoteTokenFor(address token) external view returns (JBRemoteToken memory);

    /// @notice The current deprecation state of this sucker.
    /// @return The sucker state.
    function state() external view returns (JBSuckerState);

    // State-changing functions

    /// @notice Perform multiple claims of bridged project tokens.
    /// @param claims The claims to perform.
    function claim(JBClaim[] calldata claims) external;

    /// @notice Claim bridged project tokens for a beneficiary.
    /// @param claimData The claim data including token, leaf, and proof.
    function claim(JBClaim calldata claimData) external;

    /// @notice Map a local token to a remote token for bridging.
    /// @param map The token mapping to add.
    function mapToken(JBTokenMapping calldata map) external payable;

    /// @notice Map multiple local tokens to remote tokens for bridging.
    /// @param maps The token mappings to add.
    function mapTokens(JBTokenMapping[] calldata maps) external payable;

    /// @notice Cash out project tokens and add a leaf to the outbox tree for bridging.
    /// @param projectTokenCount The number of project tokens to cash out.
    /// @param beneficiary The beneficiary on the remote chain (bytes32 for cross-VM compatibility).
    /// @param minTokensReclaimed The minimum terminal tokens to receive from the cash out.
    /// @param token The terminal token to cash out into.
    function prepare(
        uint256 projectTokenCount,
        bytes32 beneficiary,
        uint256 minTokensReclaimed,
        address token
    )
        external;

    /// @notice Send the outbox tree root and bridged assets to the remote peer.
    /// @param token The terminal token to bridge.
    function toRemote(address token) external payable;
}
