// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingSnapshot} from "../structs/JBAccountingSnapshot.sol";
import {JBClaim} from "../structs/JBClaim.sol";
import {JBInboxTreeRoot} from "../structs/JBInboxTreeRoot.sol";
import {JBOutboxTree} from "../structs/JBOutboxTree.sol";
import {JBPeerChainContext} from "../structs/JBPeerChainContext.sol";
import {JBPeerChainValue} from "../structs/JBPeerChainValue.sol";
import {JBRemoteToken} from "../structs/JBRemoteToken.sol";
import {JBSuckerState} from "../enums/JBSuckerState.sol";
import {JBTokenMapping} from "../structs/JBTokenMapping.sol";

/// @notice The minimal interface for a sucker contract.
interface IJBSucker is IERC165 {
    // Events

    /// @notice Emitted when peer-chain accounting data is sent without a merkle-root update.
    /// @param sourceTimestamp The source freshness key assigned to the snapshot.
    /// @param caller The address that initiated the send.
    event AccountingDataSynced(uint256 sourceTimestamp, address caller);

    /// @notice Emitted when a beneficiary claims bridged tokens from the inbox tree.
    /// @param beneficiary The beneficiary receiving the tokens.
    /// @param token The terminal token address.
    /// @param projectTokenCount The number of project tokens claimed.
    /// @param terminalTokenAmount The amount of terminal tokens involved.
    /// @param index The leaf index in the inbox tree.
    /// @param metadata The opaque, caller-defined payload carried by the claimed leaf.
    /// @param caller The address that performed the claim.
    event Claimed(
        bytes32 beneficiary,
        address token,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        uint256 index,
        bytes32 metadata,
        address caller
    );

    /// @notice Emitted when a single leaf in a batch `claim(JBClaim[])` fails so the rest of the batch can proceed.
    /// @dev The failing leaf's state changes are fully reverted (the batch routes each leaf through an external
    /// `this.claim` sub-call), so the leaf remains claimable later once the underlying cause is resolved (e.g. its
    /// inbox root arrives, or a transient mint/add-to-balance dependency recovers).
    /// @param token The terminal token address of the failing leaf.
    /// @param index The leaf index in the inbox tree.
    /// @param caller The address that submitted the batch.
    event ClaimFailed(address indexed token, uint256 index, address caller);

    /// @notice Emitted when a leaf is inserted into the outbox tree.
    /// @param beneficiary The beneficiary on the remote chain.
    /// @param token The terminal token address.
    /// @param hashed The hash of the leaf data.
    /// @param index The leaf index in the outbox tree.
    /// @param root The new outbox tree root after insertion.
    /// @param projectTokenCount The number of project tokens cashed out.
    /// @param terminalTokenAmount The amount of terminal tokens reclaimed.
    /// @param metadata The opaque, caller-defined payload carried by the outbox leaf.
    /// @param caller The address that performed the insertion.
    event InsertToOutboxTree(
        bytes32 indexed beneficiary,
        address indexed token,
        bytes32 hashed,
        uint256 index,
        bytes32 root,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 metadata,
        address caller
    );

    /// @notice Emitted when a new inbox tree root is received from the remote peer.
    /// @param token The terminal token address.
    /// @param nonce The nonce of the new root.
    /// @param root The new inbox tree root.
    /// @param caller The address that relayed the root.
    event NewInboxTreeRoot(address indexed token, uint64 nonce, bytes32 root, address caller);

    /// @notice Emitted when the outbox tree root and bridged assets are sent to the remote peer.
    /// @param root The outbox tree root sent to the remote peer.
    /// @param token The terminal token to bridge.
    /// @param index The current outbox tree index.
    /// @param nonce The nonce assigned to this root message.
    /// @param caller The address that initiated the send.
    event RootToRemote(bytes32 indexed root, address indexed token, uint256 index, uint64 nonce, address caller);

    /// @notice Emitted when a received inbox root is rejected because its nonce is stale.
    /// @param token The terminal token address.
    /// @param receivedNonce The nonce of the rejected root.
    /// @param currentNonce The current nonce that was expected.
    /// @param caller The address that relayed the stale root.
    event StaleRootRejected(address indexed token, uint64 receivedNonce, uint64 currentNonce, address caller);

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

    /// @notice The project registry (ERC-721 ownership).
    /// @return The projects contract.
    function PROJECTS() external view returns (IJBProjects);

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

    /// @notice The keccak256 hash of the leaf data committed at execution time, for the leaf at the given
    /// `(terminalToken, index)`. Returns `bytes32(0)` for unexecuted indices.
    /// @dev Beneficiary contracts (e.g. `JBReferralSplitHook`) use this to authenticate post-hoc settlement when
    /// their `claim()` call was front-run by a direct external caller — they re-derive the hash from the claim
    /// data they hold and compare. The hash is computed via `_buildTreeHash(projectTokenCount,
    /// terminalTokenAmount, beneficiary, metadata)` and is pre-image-resistant, so zero unambiguously means
    /// "not executed".
    /// @param token The terminal token whose tree contains the leaf.
    /// @param index The index of the leaf in the inbox tree.
    /// @return hash The committed leaf hash (or `bytes32(0)` if unexecuted).
    function executedLeafHashOf(address token, uint256 index) external view returns (bytes32 hash);

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

    /// @notice The peer chain's raw per-context surplus and balance from the latest snapshot, bundled with the peer
    /// chain ID and snapshot freshness key.
    /// @dev Un-valued — each context is in its own currency and decimals. The registry dedups same-peer suckers by
    /// freshness, then values each context into a requested currency. The sucker consults no price oracle.
    /// @return contexts The per-currency surplus and balance from the latest snapshot.
    /// @return chainId The peer chain these contexts belong to.
    /// @return snapshot The source freshness key of the latest snapshot.
    function peerChainContextsOf()
        external
        view
        returns (JBPeerChainContext[] memory contexts, uint256 chainId, uint256 snapshot);

    /// @notice The last known total token supply on the peer chain, updated each time a bridge message is received.
    /// @dev Used by data hooks to compute `effectiveTotalSupply = localSupply + sum(peerChainTotalSupply)` across all
    /// suckers, preventing cash out tax bypass on chains where a holder dominates the local supply.
    /// @return The peer chain's total supply.
    function peerChainTotalSupply() external view returns (uint256);

    /// @notice The peer chain total supply bundled with the peer chain ID and snapshot freshness key.
    /// @dev Lets aggregators read the value, the peer chain it belongs to, and its freshness in one call. The
    /// `value` matches `peerChainTotalSupply`.
    /// @return A `JBPeerChainValue` with the total supply, peer chain ID, and snapshot freshness key.
    function peerChainTotalSupplyValue() external view returns (JBPeerChainValue memory);

    /// @notice The ID of the project on the local chain that this sucker is associated with.
    /// @return The project ID.
    function projectId() external view returns (uint256);

    /// @notice Information about the remote token that a local token is mapped to.
    /// @param token The local terminal token.
    /// @return The remote token info.
    function remoteTokenFor(address token) external view returns (JBRemoteToken memory);

    /// @notice The freshness key of the latest accepted peer-chain economic snapshot.
    /// @dev Higher values are fresher. The key is source-chain monotonic, not a value magnitude.
    /// @return The latest peer-chain snapshot freshness key.
    function snapshotTimestamp() external view returns (uint256);

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

    /// @notice Receive peer-chain accounting data from the remote sucker without a merkle-root update.
    /// @param snapshot The accounting snapshot to store.
    function fromRemoteAccounting(JBAccountingSnapshot calldata snapshot) external;

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
    /// @param metadata Opaque caller-defined attribution payload included in the leaf hash. The sucker protocol does
    /// not inspect this value — it's covered by the merkle root, so the destination contract that consumes the claim
    /// can trust it once the proof verifies. Pass `bytes32(0)` for an ordinary bridge with no attribution context.
    function prepare(
        uint256 projectTokenCount,
        bytes32 beneficiary,
        uint256 minTokensReclaimed,
        address token,
        bytes32 metadata
    )
        external;

    /// @notice Send peer-chain accounting data without sending an outbox root or paying the registry `toRemoteFee`.
    /// @dev The caller still provides bridge transport payment through `msg.value` when the bridge requires it.
    function syncAccountingData() external payable;

    /// @notice Send the outbox tree root and bridged assets to the remote peer.
    /// @param token The terminal token to bridge.
    function toRemote(address token) external payable;
}
