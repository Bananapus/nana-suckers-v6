// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBAddToBalanceMode} from "../enums/JBAddToBalanceMode.sol";
import {JBSuckerState} from "../enums/JBSuckerState.sol";
import {JBClaim} from "../structs/JBClaim.sol";
import {JBInboxTreeRoot} from "../structs/JBInboxTreeRoot.sol";
import {JBOutboxTree} from "../structs/JBOutboxTree.sol";
import {JBRemoteToken} from "../structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../structs/JBTokenMapping.sol";
import {JBMessageRoot} from "../structs/JBMessageRoot.sol";

/// @notice The minimal interface for a sucker contract.
interface IJBSucker is IERC165 {
    event Claimed(
        bytes32 beneficiary,
        address token,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        uint256 index,
        bool autoAddedToBalance,
        address caller
    );
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
    event NewInboxTreeRoot(address indexed token, uint64 nonce, bytes32 root, address caller);
    event RootToRemote(bytes32 indexed root, address indexed token, uint256 index, uint64 nonce, address caller);
    event StaleRootRejected(address indexed token, uint64 receivedNonce, uint64 currentNonce);

    /// @notice The minimum gas required for a basic cross-chain call.
    /// @return The base gas limit.
    function MESSENGER_BASE_GAS_LIMIT() external view returns (uint32);

    /// @notice The minimum gas required for bridging ERC-20 tokens.
    /// @return The ERC-20 minimum gas limit.
    function MESSENGER_ERC20_MIN_GAS_LIMIT() external view returns (uint32);

    /// @notice The mode used when adding reclaimed tokens to the project's balance.
    /// @return The add-to-balance mode.
    function ADD_TO_BALANCE_MODE() external view returns (JBAddToBalanceMode);

    /// @notice The directory of terminals and controllers.
    /// @return The directory contract.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The token registry.
    /// @return The tokens contract.
    function TOKENS() external view returns (IJBTokens);

    /// @notice The address of the deployer that created this sucker.
    /// @return The deployer address.
    function deployer() external view returns (address);

    /// @notice The address of the peer sucker on the remote chain (as bytes32 for cross-VM compatibility).
    /// @return The peer address.
    function peer() external view returns (bytes32);

    /// @notice The ID of the project on the local chain that this sucker is associated with.
    /// @return The project ID.
    function projectId() external view returns (uint256);

    /// @notice The amount of tokens waiting to be added to the project's terminal balance.
    /// @param token The terminal token address.
    /// @return amount The outstanding amount.
    function amountToAddToBalanceOf(address token) external view returns (uint256 amount);

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

    /// @notice The chain ID of the remote peer.
    /// @return chainId The remote chain ID.
    function peerChainId() external view returns (uint256 chainId);

    /// @notice Information about the remote token that a local token is mapped to.
    /// @param token The local terminal token.
    /// @return The remote token info.
    function remoteTokenFor(address token) external view returns (JBRemoteToken memory);

    /// @notice The current deprecation state of this sucker.
    /// @return The sucker state.
    function state() external view returns (JBSuckerState);

    /// @notice Add the outstanding reclaimed token balance to the project's terminal.
    /// @param token The terminal token to add to balance.
    function addOutstandingAmountToBalance(address token) external;

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
