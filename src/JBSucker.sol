// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// External packages (alphabetized)
import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Local: enums
import {JBSuckerState} from "./enums/JBSuckerState.sol";

// Local: interfaces (alphabetized)
import {IJBSucker} from "./interfaces/IJBSucker.sol";
import {IJBSuckerExtended} from "./interfaces/IJBSuckerExtended.sol";
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";

// Local: libraries (alphabetized)
import {JBSuckerLib} from "./libraries/JBSuckerLib.sol";
import {MerkleLib} from "./utils/MerkleLib.sol";

// Local: structs (alphabetized)
import {JBClaim} from "./structs/JBClaim.sol";
import {JBInboxTreeRoot} from "./structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBPeerChainContext} from "./structs/JBPeerChainContext.sol";
import {JBSourceContext} from "./structs/JBSourceContext.sol";
import {JBOutboxTree} from "./structs/JBOutboxTree.sol";
import {JBPeerChainValue} from "./structs/JBPeerChainValue.sol";
import {JBRemoteToken} from "./structs/JBRemoteToken.sol";
import {JBTokenMapping} from "./structs/JBTokenMapping.sol";

/// @notice Bridges a Juicebox project's tokens and their backing terminal-token funds between two chains. Token
/// holders call `prepare` to cash out their project tokens and queue the resulting funds+tokens into an outbox merkle
/// tree. Anyone can then call `toRemote` to send that tree's root (and the locked funds) across the bridge to the
/// peer sucker on the remote chain. Once the root arrives, beneficiaries call `claim` with a merkle proof to mint
/// project tokens and deposit the corresponding terminal tokens into the remote project's balance.
///
/// @dev Dual merkle trees: the **outbox** accumulates leaves for tokens leaving the local chain; the **inbox** stores
/// the root received from the remote chain so claims can be verified locally.
/// @dev Throughout this contract, "terminal token" refers to any token accepted by a project's terminal.
/// @dev This contract does *NOT* support fee-on-transfer or rebasing tokens.
/// @dev Cross-chain message authentication is delegated to each bridge-specific subclass via `_isRemotePeer`.
/// Optimism uses `CrossDomainMessenger`, Arbitrum validates against `Bridge`/`Outbox`, and CCIP verifies through
/// Chainlink's `Router`.
abstract contract JBSucker is ERC2771Context, JBPermissioned, Initializable, ERC165, IJBSuckerExtended {
    using BitMaps for BitMaps.BitMap;
    using MerkleLib for MerkleLib.Tree;
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a terminal-token or project-token amount being bridged exceeds the `uint128` cap enforced
    /// for cross-VM compatibility.
    error JBSucker_AmountExceedsUint128(uint256 amount);

    /// @notice Thrown when a token mapping specifies a bridging gas limit below the minimum required to safely deliver
    /// an ERC-20 on the remote chain.
    error JBSucker_BelowMinGas(uint256 minGas, uint256 minGasLimit);

    /// @notice Thrown when an outbound action is attempted while the sucker is deprecated (or no longer accepting
    /// sends).
    error JBSucker_Deprecated(JBSuckerState state);

    /// @notice Thrown when a deprecation is scheduled for a time sooner than the minimum allowed delay.
    error JBSucker_DeprecationTimestampTooSoon(uint256 givenTime, uint256 minimumTime);

    /// @notice Thrown when a native token transport payment is required but no `msg.value` was sent.
    error JBSucker_ExpectedMsgValue(uint256 msgValue);

    /// @notice Thrown when a merkle leaf index is greater than or equal to the maximum number of leaves the tree can
    /// hold.
    error JBSucker_IndexOutOfRange(uint256 index);

    /// @notice Thrown when the amount to add to the project's balance exceeds the funds available to the sucker.
    error JBSucker_InsufficientBalance(uint256 amount, uint256 balance);

    /// @notice Thrown when the `msg.value` sent is less than the required `toRemoteFee`.
    error JBSucker_InsufficientMsgValue(uint256 received, uint256 expected);

    /// @notice Thrown when an incoming bridge message has a format version that does not match the expected version.
    error JBSucker_InvalidMessageVersion(uint8 received, uint8 expected);

    /// @notice Thrown when the native token is mapped to a remote token that is neither the native token nor the zero
    /// address.
    error JBSucker_InvalidNativeRemoteAddress(bytes32 remoteToken);

    /// @notice Thrown when a claim's merkle proof does not validate against the stored inbox root.
    error JBSucker_InvalidProof(bytes32 root, bytes32 inboxRoot);

    /// @notice Thrown when a leaf at the given index has already been executed for the given token.
    error JBSucker_LeafAlreadyExecuted(address token, uint256 index);

    /// @notice Thrown when no terminal can be found for the given project and token.
    error JBSucker_NoTerminalForToken(uint256 projectId, address token);

    /// @notice Thrown when the caller is not a valid representative of the remote peer sucker.
    error JBSucker_NotPeer(bytes32 caller);

    /// @notice Thrown when a send is attempted but there is nothing new in the outbox to bridge.
    error JBSucker_NothingToSend(address token, uint256 outboxBalance, uint256 treeCount, uint256 numberOfClaimsSent);

    /// @notice Thrown when an account attempts to claim a retained failed-fee refund but is owed nothing.
    error JBSucker_NoRetainedToRemoteFee(address account);

    /// @notice Thrown when an account attempts to claim a retained failed transport-payment refund but is owed nothing.
    error JBSucker_NoRetainedTransportPaymentRefund(address account);

    /// @notice Thrown when a native token refund transfer to the beneficiary fails.
    error JBSucker_RefundFailed(address beneficiary, uint256 amount);

    /// @notice Thrown when a token mapping targets a remote token that another local token has already reserved.
    error JBSucker_RemoteTokenAlreadyMapped(bytes32 remoteToken, address localToken);

    /// @notice Thrown when remapping a local token whose outbox tree already has entries, which is no longer permitted.
    error JBSucker_TokenAlreadyMapped(address localToken, bytes32 mappedTo);

    /// @notice Thrown when an emergency-hatch action is attempted for a token whose emergency hatch state does not
    /// allow it.
    error JBSucker_TokenHasInvalidEmergencyHatchState(address token);

    /// @notice Thrown when an action references a token that has not been mapped to a remote token.
    error JBSucker_TokenNotMapped(address token);

    /// @notice Thrown when `msg.value` is sent for an action that expects none.
    error JBSucker_UnexpectedMsgValue(uint256 value);

    /// @notice Thrown when an ERC-20 terminal balance does not decrease by the amount added to the project balance.
    error JBSucker_UnexpectedTokenBalance(address token, uint256 expectedBalance, uint256 actualBalance);

    /// @notice Thrown when a required beneficiary address is the zero address.
    error JBSucker_ZeroBeneficiary(bytes32 beneficiary);

    /// @notice Thrown when bridging is attempted for a project that has no ERC-20 token deployed.
    error JBSucker_ZeroERC20Token(uint256 projectId);

    /// @notice Thrown when a bridge is queued with zero project tokens.
    error JBSucker_ZeroProjectTokenCount();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice A reasonable minimum gas limit for a basic cross-chain call to `fromRemote` on the remote chain.
    uint32 public constant override MESSENGER_BASE_GAS_LIMIT = 300_000;

    /// @notice A reasonable minimum gas limit for performing an ERC-20 transfer on the remote chain.
    uint32 public constant override MESSENGER_ERC20_MIN_GAS_LIMIT = 200_000;

    /// @notice The message format version. Used to reject incompatible messages from remote chains.
    uint8 public constant MESSAGE_VERSION = 1;

    //*********************************************************************//
    // ------------------------- internal constants ----------------------- //
    //*********************************************************************//

    /// @notice The number of recently-accepted inbox roots retained per token so that a proof generated against a
    /// slightly older root still validates after a later `toRemote`/`fromRemote` advances the inbox.
    /// @dev The inbox is append-only and a leaf's `(hash, index)` is stable across roots, so honoring a small window
    /// of recent roots is safe: the `_executedFor` double-spend guard is keyed by `(token, leafIndex)` — independent
    /// of which retained root validated the proof — so an executed leaf stays blocked no matter which retained root a
    /// later proof matches. The window only widens which still-valid proofs are accepted; it never relaxes the
    /// double-spend guard.
    uint256 internal constant _INBOX_ROOT_RING_SIZE = 4;

    /// @notice The depth of the merkle tree used to store the outbox and inbox.
    uint32 internal constant _TREE_DEPTH = 32;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers for projects.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The project ID that receives the `toRemoteFee` payment. Typically the protocol project (ID 1).
    uint256 public immutable FEE_PROJECT_ID;

    /// @notice The project registry (ERC-721 ownership).
    IJBProjects public immutable override PROJECTS;

    /// @notice The sucker registry that manages the global `toRemoteFee`.
    IJBSuckerRegistry public immutable REGISTRY;

    /// @notice The contract that manages token minting and burning.
    IJBTokens public immutable override TOKENS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The address of this contract's deployer.
    address public override deployer;

    /// @notice The keccak256 hash of the leaf data committed at execution time, keyed by `(terminalToken,
    /// leafIndex)`. Beneficiary contracts (e.g. `JBReferralSplitHook`) use this to authenticate post-hoc
    /// settlement when their `claim()` call was front-run by a direct external caller — they re-derive the
    /// hash from the claim data they hold and compare. Returns `bytes32(0)` for unexecuted indices —
    /// `_buildTreeHash` is pre-image-resistant so zero unambiguously means "not executed".
    /// @custom:param token The token whose inbox tree contains the leaf.
    /// @custom:param index The leaf's index in the inbox tree.
    mapping(address token => mapping(uint256 index => bytes32)) public override executedLeafHashOf;

    /// @notice The last known total token supply on the peer chain, updated each time a bridge message is received.
    /// @dev Used by data hooks to compute `effectiveTotalSupply = localSupply + sum(peerChainTotalSupply)` across all
    /// suckers, preventing cash out tax bypass on chains where a holder dominates the local supply.
    uint256 public peerChainTotalSupply;

    /// @notice The total retained failed-fee ETH excluded from native add-to-balance accounting.
    uint256 public retainedToRemoteFeeBalance;

    /// @notice The total retained failed transport-payment refund ETH excluded from native add-to-balance accounting.
    uint256 public retainedTransportPaymentRefundBalance;

    /// @notice The retained failed-fee ETH owed to each original `toRemote` caller.
    /// @custom:param account The address owed the retained ETH.
    mapping(address account => uint256 amount) public retainedToRemoteFeeOf;

    /// @notice The retained failed transport-payment refund ETH owed to each original bridge caller.
    /// @custom:param account The address owed the retained ETH.
    mapping(address account => uint256 amount) public retainedTransportPaymentRefundOf;

    /// @notice The source chain freshness key for the most recent accepted peer snapshot.
    /// @dev Only snapshots with a strictly newer source freshness key are accepted, preventing stale rollbacks.
    /// Named to align with the `JBMessageRoot.sourceTimestamp` field it tracks.
    /// Returns 0 if no snapshot has been received yet.
    uint256 public snapshotTimestamp;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The timestamp after which the sucker is entirely deprecated.
    uint256 internal deprecatedAfter;

    /// @notice Tracks whether individual leaves in a given token's merkle tree have been executed (to prevent
    /// double-spending).
    /// @dev A leaf is "executed" when the tokens it represents are minted for its beneficiary.
    /// @custom:param token The token to get the executed bitmap of.
    mapping(address token => BitMaps.BitMap) internal _executedFor;

    /// @notice The inbox merkle tree root for a given token.
    /// @custom:param token The local terminal token to get the inbox for.
    mapping(address token => JBInboxTreeRoot root) internal _inboxOf;

    /// @notice The index of the most recently-written slot in `_inboxRootRingOf[token]`.
    /// @dev Advances modulo `_INBOX_ROOT_RING_SIZE` each time `fromRemote` accepts a newer-nonce root, overwriting the
    /// oldest retained root. Defaults to `0`; the first accepted root is written to slot `1` after the pre-increment.
    /// @custom:param token The local terminal token to get the ring cursor for.
    mapping(address token => uint256 cursor) internal _inboxRootRingCursorOf;

    /// @notice A small ring buffer of the most recently-accepted inbox roots for a given token.
    /// @dev Holds the last `_INBOX_ROOT_RING_SIZE` distinct roots accepted by `fromRemote` (the newest is also mirrored
    /// in `_inboxOf[token].root`). `_validate` accepts a proof matching ANY retained, not-yet-executed leaf's root, so
    /// proofs generated against a recent-but-superseded root keep validating without regenerated branches. The window
    /// is intentionally small: it bounds storage/gas and keeps the set of accepted roots tightly recent. Unused slots
    /// are `bytes32(0)`, which `_validate` skips (a real root is never `bytes32(0)` — the empty-tree root is
    /// `MerkleLib.Z_32`, and roots only enter the ring once a non-empty tree has been bridged).
    /// @custom:param token The local terminal token to get the retained inbox roots for.
    mapping(address token => bytes32[_INBOX_ROOT_RING_SIZE] roots) internal _inboxRootRingOf;

    /// @notice The local token that has reserved each remote token address in this sucker.
    /// @dev Inbound roots are keyed by `root.token` on the destination chain. Within a single sucker, allowing two
    /// local tokens to send roots to the same remote token would give them independent source nonces but one shared
    /// destination inbox, causing stale rejections or root overwrites. Each sucker keeps its own reservation map, so
    /// separate bridge lanes for the same asset pair can coexist.
    /// @custom:param remoteToken The remote terminal token address encoded as bytes32.
    mapping(bytes32 remoteToken => address localToken) internal _localTokenForRemoteToken;

    /// @notice The outbox merkle tree for a given token.
    /// @custom:param token The local terminal token to get the outbox for.
    mapping(address token => JBOutboxTree) internal _outboxOf;

    /// @notice Information about the token on the remote chain that the given token on the local chain is mapped to.
    /// @custom:param token The local terminal token to get the remote token for.
    mapping(address token => JBRemoteToken remoteToken) internal _remoteTokenFor;

    //*********************************************************************//
    // -------------------- private stored properties -------------------- //
    //*********************************************************************//

    /// @notice Caches a local token's authoritative accounting-context currency, derived once and reused on later
    /// snapshots. A project's accounting-context currency is immutable once set, so the cached value never goes stale;
    /// only an authoritative read is cached (a not-yet-configured token uses the convention without caching, so a later
    /// snapshot re-reads it once its context exists).
    /// @custom:param token The local token.
    mapping(address token => uint32 currency) private _cachedCurrencyOf;

    /// @notice The ID of the project (on the local chain) that this sucker is associated with.
    uint256 private _localProjectId;

    /// @notice Tie-breaker mixed into outbound snapshot freshness keys when multiple roots are sent at one timestamp.
    uint256 private _outboundSnapshotSequence;

    /// @notice Optional explicit peer sucker address on the remote chain.
    /// @dev A zero value preserves the default same-address deterministic peer.
    bytes32 private _peer;

    /// @notice The peer chain's per-currency surplus and balance from the latest snapshot.
    /// @dev Rebuilt from each fresher snapshot; dropped contexts are absent without per-entry versioning or clearing.
    /// A read sums these and values them into the requested currency.
    JBPeerChainContext[] private _peerContexts;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param permissions A contract storing permissions.
    /// @param tokens A contract that manages token minting and burning.
    /// @param feeProjectId The project ID that receives the `toRemoteFee` payment (typically 1).
    /// @param registry The sucker registry that manages the global `toRemoteFee`.
    /// @param trustedForwarder The trusted forwarder for ERC-2771 meta-transactions.
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        uint256 feeProjectId,
        IJBSuckerRegistry registry,
        address trustedForwarder
    )
        ERC2771Context(trustedForwarder)
        JBPermissioned(permissions)
    {
        DIRECTORY = directory;
        FEE_PROJECT_ID = feeProjectId;
        PROJECTS = directory.PROJECTS();
        REGISTRY = registry;
        TOKENS = tokens;

        // Make it so the singleton can't be initialized.
        _disableInitializers();

        // Sanity check: make sure the merkle lib uses the same tree depth.
        assert(MerkleLib.TREE_DEPTH == _TREE_DEPTH);
    }

    //*********************************************************************//
    // ---------------------------- receive  ----------------------------- //
    //*********************************************************************//

    /// @notice Accepts incoming native token (ETH) transfers.
    /// @dev This receive function is intentionally unrestricted. It must accept ETH from multiple sources:
    /// - Bridge contracts (e.g., Optimism's StandardBridge, Arbitrum's gateway) delivering bridged native tokens.
    /// - Wrapped native token contracts during unwrapping (e.g., CCIP sucker unwraps via `withdraw()` which sends
    /// native tokens here). - Terminals returning native tokens during `cashOutTokensOf` (backing asset pulls).
    /// @dev Restricting this to known senders would risk breaking bridge integrations, as bridge contracts may change
    /// addresses or use proxy patterns. The sucker's accounting (`_outboxOf[token].balance` and
    /// `amountToAddToBalanceOf`) already tracks expected native token amounts, so excess ETH sent here does not
    /// create a double-spend risk -- it would simply increase the amount to add to balance for the project.
    receive() external payable virtual {}

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Claim multiple bridged entries in a single transaction. Each claim mints project tokens for the
    /// beneficiary and deposits the corresponding terminal tokens into the project's local balance.
    /// @dev Per-leaf resilience: each leaf is claimed through an external `this.claim(JBClaim)` sub-call wrapped in
    /// try/catch, so a single failing or stale leaf (e.g. its inbox root has not arrived yet, it was already executed,
    /// or a transient mint/add-to-balance dependency reverts) only skips that one leaf — the rest of the batch still
    /// settles. Because the sub-call is a separate message frame, a caught revert rolls back every state change that
    /// leaf attempted (its `_executedFor` bit, its `executedLeafHashOf` entry, and any `_addToBalance`/`mintTokensOf`
    /// effects), so the skipped leaf stays fully claimable later. Routing through `this.claim` is safe because the
    /// single-leaf `claim` mints to `claimData.leaf.beneficiary` and adds funds to the project balance — it never
    /// depends on `msg.sender` being the original batch caller, so the self-call does not change who is credited.
    /// @param claims A list of claims to perform (including the terminal token, merkle tree leaf, and proof for each
    /// claim).
    function claim(JBClaim[] calldata claims) external override {
        // Claim each. Isolate each leaf in its own external sub-call so one bad/stale leaf cannot revert the batch.
        for (uint256 i; i < claims.length;) {
            try this.claim(claims[i]) {
            // Leaf settled successfully.
            }
            catch {
                // The leaf failed: its sub-call reverted atomically, leaving no persisted state for it. Surface the
                // skip for off-chain monitoring; the leaf remains claimable in a future call.
                emit ClaimFailed({token: claims[i].token, index: claims[i].leaf.index, caller: _msgSender()});
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Claim a single bridged entry: verifies the merkle proof against the inbox root, mints the specified
    /// project tokens for the beneficiary, and deposits the terminal tokens into the project's local balance.
    /// @param claimData The terminal token, merkle tree leaf, and proof for the claim.
    function claim(JBClaim calldata claimData) public virtual override {
        // Attempt to validate the proof against the inbox tree for the terminal token. The leaf hash includes
        // `claimData.leaf.metadata` so the proof is only valid for the exact (amount, beneficiary, metadata) tuple the
        // origin committed to.
        _validate({
            projectTokenCount: claimData.leaf.projectTokenCount,
            terminalToken: claimData.token,
            terminalTokenAmount: claimData.leaf.terminalTokenAmount,
            beneficiary: claimData.leaf.beneficiary,
            metadata: claimData.leaf.metadata,
            index: claimData.leaf.index,
            leaves: claimData.proof
        });

        emit Claimed({
            beneficiary: claimData.leaf.beneficiary,
            token: claimData.token,
            projectTokenCount: claimData.leaf.projectTokenCount,
            terminalTokenAmount: claimData.leaf.terminalTokenAmount,
            index: claimData.leaf.index,
            metadata: claimData.leaf.metadata,
            caller: _msgSender()
        });

        // Give the user their project tokens, send the project its funds.
        _handleClaim({
            terminalToken: claimData.token,
            terminalTokenAmount: claimData.leaf.terminalTokenAmount,
            projectTokenAmount: claimData.leaf.projectTokenCount,
            beneficiary: claimData.leaf.beneficiary
        });
    }

    /// @notice Enables the emergency hatch for a list of tokens, allowing users to exit on the chain they deposited on.
    /// @dev For use when a token or a few tokens are no longer compatible with a bridge.
    /// @param tokens The terminal tokens to enable the emergency hatch for.
    function enableEmergencyHatchFor(address[] calldata tokens) external override {
        // The caller must be the project owner or have the `QUEUE_RULESETS` permission from them.
        uint256 _projectId = projectId();

        _requirePermissionFrom({
            account: _ownerOf(_projectId), projectId: _projectId, permissionId: JBPermissionIds.SUCKER_SAFETY
        });

        // Enable the emergency hatch for each token.
        for (uint256 i; i < tokens.length;) {
            // We have an invariant where if emergencyHatch is true, enabled should be false.
            _remoteTokenFor[tokens[i]].enabled = false;
            _remoteTokenFor[tokens[i]].emergencyHatch = true;
            unchecked {
                ++i;
            }
        }

        emit EmergencyHatchOpened({tokens: tokens, caller: _msgSender()});
    }

    /// @notice Emergency escape hatch: lets a user reclaim their project tokens and terminal tokens on the chain they
    /// deposited from, when the bridge has become permanently non-functional. Must be enabled by the project
    /// owner via `enableEmergencyHatchFor`.
    /// @param claimData The terminal token, merkle tree leaf, and proof for the claim.
    function exitThroughEmergencyHatch(JBClaim calldata claimData) external override {
        // Does all the needed validation to ensure that the claim is valid *and* that claiming through the emergency
        // hatch is allowed. The leaf hash covers `metadata` so a remote-attribution leaf is only exitable if the
        // emergency exiter knows the exact `metadata` value the origin committed to.
        _validateForEmergencyExit({
            projectTokenCount: claimData.leaf.projectTokenCount,
            terminalToken: claimData.token,
            terminalTokenAmount: claimData.leaf.terminalTokenAmount,
            beneficiary: claimData.leaf.beneficiary,
            metadata: claimData.leaf.metadata,
            index: claimData.leaf.index,
            leaves: claimData.proof
        });

        // Decrease the outstanding balance for this token.
        _outboxOf[claimData.token].balance -= claimData.leaf.terminalTokenAmount;

        emit EmergencyExit({
            beneficiary: _toAddress(claimData.leaf.beneficiary),
            token: claimData.token,
            terminalTokenAmount: claimData.leaf.terminalTokenAmount,
            projectTokenCount: claimData.leaf.projectTokenCount,
            caller: _msgSender()
        });

        // Give the user their project tokens, send the project its funds.
        _handleClaim({
            terminalToken: claimData.token,
            terminalTokenAmount: claimData.leaf.terminalTokenAmount,
            projectTokenAmount: claimData.leaf.projectTokenCount,
            beneficiary: claimData.leaf.beneficiary
        });
    }

    /// @notice Receive a merkle root and peer-chain accounting snapshot from the remote sucker. Updates the inbox tree
    /// so that users can claim bridged tokens. Also accepts any native-token funds delivered with the message.
    /// @dev This can only be called by the messenger contract on the local chain, with a message from the remote peer.
    /// @dev Nonce ordering: This function accepts any nonce strictly greater than the current inbox nonce, rather than
    /// requiring sequential (nonce == inbox.nonce + 1) processing. This is intentional because some bridges (e.g.,
    /// Chainlink CCIP) do not guarantee in-order message delivery. If nonces arrive out of order, the inbox root is
    /// set to the latest nonce's root. Claims from earlier nonces remain provable against the latest root (the merkle
    /// tree is append-only), but users will need regenerated proofs computed against the current root. This trade-off
    /// is accepted because enforcing sequential nonces could permanently block a token's inbox if a single message is
    /// delayed or lost by the bridge.
    /// @dev Post-deprecation root acceptance: Roots are accepted in DEPRECATED state to prevent stranding tokens that
    /// were sent before deprecation. Even though the mandatory `_maxMessagingDelay()` (14-day) buffer gives in-flight
    /// messages time to arrive, accepting roots after deprecation provides a stronger guarantee that users can always
    /// claim their bridged tokens. Double-spend is not a concern because `toRemote` is already disabled in
    /// `SENDING_DISABLED` and `DEPRECATED` states, so no new outbound transfers can occur.
    /// @param root The merkle root, token, and amount to receive.
    function fromRemote(JBMessageRoot calldata root) external payable {
        // Make sure that the message came from our peer.
        // Use msg.sender (not _msgSender()) because bridge messengers never use ERC2771 meta-transactions.
        // Using _msgSender() would allow a trusted forwarder to spoof the bridge messenger address via the
        // ERC-2771 calldata suffix.
        if (!_isRemotePeer(msg.sender)) {
            revert JBSucker_NotPeer({caller: _toBytes32(msg.sender)});
        }

        // Validate the message version to reject incompatible messages.
        if (root.version != MESSAGE_VERSION) {
            revert JBSucker_InvalidMessageVersion({received: root.version, expected: MESSAGE_VERSION});
        }

        // By design, this function accepts roots for unmapped tokens. Claims against those roots will
        // fail at the token mapping lookup. Rejecting at receive time would permanently lose bridged tokens. Accepting
        // allows future token mapping to enable claims.
        //
        // Convert the remote token bytes32 to a local address for inbox lookup.
        address localToken = _toAddress(root.token);

        // Get the inbox in storage.
        JBInboxTreeRoot storage inbox = _inboxOf[localToken];

        // --- Token-local inbox update (gated by per-token nonce) ---
        // Nonce gaps in received messages are expected when messages are processed out of order or retried. The
        // sucker processes each root independently — skipped nonces don't cause data loss, they just mean some
        // messages arrived before others.
        //
        // If the received tree's nonce is greater than the current inbox tree's nonce, update the inbox tree.
        // We can't revert because this could be a native token transfer. If we reverted, we would lose the native
        // tokens.
        if (root.remoteRoot.nonce > inbox.nonce) {
            inbox.nonce = root.remoteRoot.nonce;
            inbox.root = root.remoteRoot.root;

            // Retain the newly-accepted root in the per-token ring so proofs generated against a recent-but-superseded
            // root still validate. Advance the cursor and overwrite the oldest slot. Skipping the empty-tree root keeps
            // the ring populated only with roots that can actually back a claim.
            if (root.remoteRoot.root != MerkleLib.Z_32) {
                uint256 nextCursor = (_inboxRootRingCursorOf[localToken] + 1) % _INBOX_ROOT_RING_SIZE;
                _inboxRootRingCursorOf[localToken] = nextCursor;
                _inboxRootRingOf[localToken][nextCursor] = root.remoteRoot.root;
            }

            emit NewInboxTreeRoot({
                token: localToken, nonce: root.remoteRoot.nonce, root: root.remoteRoot.root, caller: _msgSender()
            });
        } else {
            // Emit an event when a root is rejected due to a stale (non-increasing) nonce.
            // This aids off-chain monitoring in detecting out-of-order or duplicate deliveries.
            emit StaleRootRejected({
                token: localToken, receivedNonce: root.remoteRoot.nonce, currentNonce: inbox.nonce, caller: _msgSender()
            });
        }

        // --- Project-wide shared state update (gated by source freshness key) ---
        // Only accept snapshots whose source freshness key is strictly newer than the last accepted one.
        // This prevents a staler per-token message from rolling back shared state (surplus, balance, supply)
        // that was already updated by a fresher message for a different token.
        if (root.sourceTimestamp > snapshotTimestamp) {
            // Advance the snapshot freshness key (used by the registry to dedup same-peer suckers).
            snapshotTimestamp = root.sourceTimestamp;

            // Update unconditionally — a legitimate zero supply must clear phantom cached supply.
            peerChainTotalSupply = root.sourceTotalSupply;

            // Rebuild the per-currency context set from scratch. A context that dropped out of this fresher snapshot is
            // simply absent from the new set, so no per-entry clearing is needed.
            delete _peerContexts;

            // Fold each source context into the local currency it resolves to. Resolution prefers the token mapping (so
            // a same-asset token at a different remote address binds to the right local context) and falls back to
            // identity for same-address tokens; the local currency is then derived from that resolved local token's
            // authoritative accounting context, NOT trusted from the wire, so a same-asset token at a different address
            // still folds under the receiver's own currency. Multiple source contexts that resolve to the same local
            // currency (e.g. the same token across multiple terminals) are summed.
            uint256 numContexts = root.sourceContexts.length;
            for (uint256 i; i < numContexts;) {
                JBSourceContext calldata ctx = root.sourceContexts[i];

                address contextToken = _localTokenForRemoteToken[ctx.token];
                if (contextToken == address(0)) contextToken = _toAddress(ctx.token);
                (uint32 contextCurrency, bool authoritative) = _localCurrencyOf(contextToken);
                // Cache an authoritative currency so later snapshots reuse it instead of re-reading the terminal. The
                // accounting-context currency is immutable, so the cache never goes stale; a not-yet-configured token
                // is left uncached and re-read next time.
                if (authoritative && _cachedCurrencyOf[contextToken] == 0) {
                    _cachedCurrencyOf[contextToken] = contextCurrency;
                }

                // Accumulate into an existing entry that matches on BOTH currency AND decimals, or append a new one.
                // The decimals must match: `surplus`/`balance` are raw, un-valued token amounts, so two contexts that
                // share a currency but carry different decimals (e.g. a 6-decimal and an 18-decimal representation of
                // the same currency) are on different scales and CANNOT be summed directly — doing so would corrupt
                // the
                // aggregate. Keeping them as separate entries lets the read side (`remoteSurplusOf` -> `_valued`)
                // decimal-adjust each one independently before summing. The context set is small (one entry per
                // distinct local currency+decimals), so a linear scan is cheaper than a mapping.
                uint256 numStored = _peerContexts.length;
                bool merged;
                for (uint256 j; j < numStored;) {
                    if (_peerContexts[j].currency == contextCurrency && _peerContexts[j].decimals == ctx.decimals) {
                        _peerContexts[j].surplus = _saturatingAddU128(_peerContexts[j].surplus, ctx.surplus);
                        _peerContexts[j].balance = _saturatingAddU128(_peerContexts[j].balance, ctx.balance);
                        merged = true;
                        break;
                    }
                    unchecked {
                        ++j;
                    }
                }
                if (!merged) {
                    _peerContexts.push(
                        JBPeerChainContext({
                            currency: contextCurrency,
                            decimals: ctx.decimals,
                            surplus: ctx.surplus,
                            balance: ctx.balance
                        })
                    );
                }

                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @notice Configure which remote-chain tokens each local terminal token maps to, enabling (or disabling) those
    /// tokens for cross-chain bridging. Setting a remote token to `bytes32(0)` disables bridging and flushes any
    /// pending outbox entries. Requires `MAP_SUCKER_TOKEN` permission from the project owner or deployment registry.
    /// @param maps A list of local and remote terminal token addresses to map, and minimum amount/gas limits for
    /// bridging them.
    function mapTokens(JBTokenMapping[] calldata maps) external payable override {
        uint256 disableCandidates;

        // Count mappings that currently need a final outbox flush. This is an upper bound because duplicated disables
        // in the same batch can become no-ops after the first one updates `numberOfClaimsSent`.
        for (uint256 h; h < maps.length;) {
            JBOutboxTree storage _outbox = _outboxOf[maps[h].localToken];
            if (maps[h].remoteToken == bytes32(0) && _outbox.numberOfClaimsSent != _outbox.tree.count) {
                ++disableCandidates;
            }
            unchecked {
                ++h;
            }
        }

        // Split the attached value across disable candidates, then refund any value not actually used by a final
        // outbox flush. Enable-only and duplicate/no-op disable entries do not consume transport payment.
        uint256 transportPaymentValue = disableCandidates == 0 ? 0 : msg.value / disableCandidates;
        uint256 transportPaymentSpent;
        for (uint256 i; i < maps.length;) {
            transportPaymentSpent += _mapToken({map: maps[i], transportPaymentValue: transportPaymentValue});
            unchecked {
                ++i;
            }
        }

        // Return enable-only value, duplicate/no-op disable value, and integer-division dust to the caller.
        if (msg.value > transportPaymentSpent) {
            _sendNativeTo({beneficiary: payable(_msgSender()), amount: msg.value - transportPaymentSpent});
        }
    }

    /// @notice Queue project tokens for bridging to the remote chain. Transfers the caller's project tokens into this
    /// contract, cashes them out for the specified terminal token, and inserts a leaf into the outbox merkle tree. The
    /// queued entry will be bridged the next time anyone calls `toRemote` for the same `token`.
    /// @dev This adds the tokens and funds to the outbox tree for the `token`. They will be bridged by the next call to
    /// `toRemote` for the same `token`.
    /// @dev Reentrancy protection: This function has implicit reentrancy protection through `_pullBackingAssets`.
    /// The `assert` in `_pullBackingAssets` verifies that the contract's token balance increased by exactly the
    /// amount reported by the terminal's `cashOutTokensOf`. A reentrant `prepare()` call would trigger a nested
    /// `cashOutTokensOf`, changing the contract's balance before the outer call's `assert` executes. The outer
    /// `assert` would then fail because the balance delta no longer matches the reported `reclaimedAmount`.
    /// Note: because `assert` is used (not `revert`), a failed reentrancy attempt will consume all remaining gas.
    /// @param projectTokenCount The number of project tokens to prepare for bridging.
    /// @param beneficiary The recipient on the remote chain (bytes32 for cross-VM compatibility).
    ///   For EVM peers: the EVM address left-padded to 32 bytes via `_toBytes32`.
    ///   For SVM peers: the full 32-byte Solana public key.
    /// @param minTokensReclaimed The minimum amount of terminal tokens to cash out for. If the amount cashed out is
    /// less than this, the transaction will revert.
    /// @param token The address of the terminal token to cash out for.
    function prepare(
        uint256 projectTokenCount,
        bytes32 beneficiary,
        uint256 minTokensReclaimed,
        address token,
        bytes32 metadata
    )
        external
        override
    {
        // Reject zero-token prepares. A zero-token prepare burns nothing and reclaims nothing, but it still inserts a
        // leaf into the outbox tree and lets `toRemote` ship a zero-value bridge message — a permissionless way to
        // inflate the per-token populated-nonce list on swap-CCIP suckers, taxing every legitimate claim with extra
        // lookup work and eventually exceeding the block gas limit.
        if (projectTokenCount == 0) {
            revert JBSucker_ZeroProjectTokenCount();
        }

        // Make sure the beneficiary is not the zero address, as this would revert when minting on the remote chain.
        if (beneficiary == bytes32(0)) {
            revert JBSucker_ZeroBeneficiary({beneficiary: beneficiary});
        }

        // Get the project's token.
        IERC20 projectToken = IERC20(address(TOKENS.tokenOf(projectId())));
        if (address(projectToken) == address(0)) {
            revert JBSucker_ZeroERC20Token({projectId: projectId()});
        }

        // Make sure that the token is mapped to a remote token.
        if (!_remoteTokenFor[token].enabled) {
            revert JBSucker_TokenNotMapped({token: token});
        }

        // Make sure that the sucker still allows sending new messages.
        _requireSendingEnabled();

        // Transfer the tokens to this contract.
        projectToken.safeTransferFrom({from: _msgSender(), to: address(this), value: projectTokenCount});

        // Cash out the tokens.
        uint256 terminalTokenAmount = _pullBackingAssets({
            projectToken: projectToken, count: projectTokenCount, token: token, minTokensReclaimed: minTokensReclaimed
        });

        // Insert the item into the outbox tree for the terminal `token`. The `metadata` field travels inside the leaf
        // hash so receivers can read attribution context from a proven claim — the sucker protocol itself never
        // inspects it.
        _insertIntoTree({
            projectTokenCount: projectTokenCount,
            token: token,
            terminalTokenAmount: terminalTokenAmount,
            beneficiary: beneficiary,
            metadata: metadata
        });
    }

    /// @notice Schedule (or cancel) the deprecation of this sucker. Once deprecated, no new outbound transfers are
    /// accepted and users can exit via the emergency hatch. Requires `SET_SUCKER_DEPRECATION` permission. A mandatory
    /// 14-day buffer ensures in-flight messages have time to arrive before the sucker fully shuts down.
    /// @param timestamp The time after which the sucker will be deprecated. Or `0` to remove the upcoming deprecation.
    function setDeprecation(uint40 timestamp) external override {
        // As long as the sucker has not started letting users withdraw, its deprecation time can be
        // extended/shortened.
        _requireSendingEnabled();

        uint256 _projectId = projectId();

        // The caller must be the project owner or have the `SET_SUCKER_DEPRECATION` permission from them.
        _requirePermissionFrom({
            account: _ownerOf(_projectId), projectId: _projectId, permissionId: JBPermissionIds.SET_SUCKER_DEPRECATION
        });

        // This is the earliest time the sucker can be considered deprecated.
        // There is a mandatory delay to allow for remaining messages to be received.
        // This should be called on both sides of the suckers, preferably with a matching timestamp.
        uint256 nextEarliestDeprecationTime = block.timestamp + _maxMessagingDelay();

        // The deprecation can be entirely disabled *or* it has to be later than the earliest possible time.
        if (timestamp != 0 && timestamp <= nextEarliestDeprecationTime) {
            revert JBSucker_DeprecationTimestampTooSoon({
                givenTime: timestamp, minimumTime: nextEarliestDeprecationTime
            });
        }

        deprecatedAfter = timestamp;
        emit DeprecationTimeUpdated({timestamp: timestamp, caller: _msgSender()});
    }

    /// @notice Send the accumulated outbox merkle root and locked terminal-token funds for a given `token` across the
    /// bridge to the remote peer sucker. Anyone can call this once entries exist in the outbox. Requires `msg.value`
    /// to cover the registry's `toRemoteFee` plus any bridge transport payment.
    /// @dev This sends the outbox root for the specified `token` to the remote chain.
    /// @dev Fee payment failure handling: The registry fee payment uses a best-effort pattern (try/catch). If the
    /// fee project's terminal doesn't exist or the `pay` call reverts, the fee ETH is retained as a refundable balance
    /// for the original caller instead of being added back to `transportPayment`. This preserves
    /// `transportPayment = msg.value - fee`, which is critical for zero-cost bridges (OP, Base, Celo, Arb L2->L1)
    /// that revert on non-zero transport payment. The retained fee is excluded from `amountToAddToBalanceOf`.
    /// @param token The terminal token to bridge.
    function toRemote(address token) external payable override {
        JBRemoteToken memory remoteToken = _remoteTokenFor[token];

        // Ensure that the token does not have an emergency hatch enabled.
        if (remoteToken.emergencyHatch) {
            revert JBSucker_TokenHasInvalidEmergencyHatchState({token: token});
        }

        // Revert if nothing has changed since the last toRemote() call.
        JBOutboxTree storage outbox = _outboxOf[token];
        if (outbox.balance == 0 && outbox.tree.count == outbox.numberOfClaimsSent) {
            revert JBSucker_NothingToSend({
                token: token,
                outboxBalance: outbox.balance,
                treeCount: outbox.tree.count,
                numberOfClaimsSent: outbox.numberOfClaimsSent
            });
        }

        // Read the fee from the registry.
        uint256 _toRemoteFee = REGISTRY.toRemoteFee();

        // Deduct the fee from msg.value, paying it into the fee project.
        if (msg.value < _toRemoteFee) {
            revert JBSucker_InsufficientMsgValue({received: msg.value, expected: _toRemoteFee});
        }
        uint256 transportPayment = msg.value - _toRemoteFee;

        // Best-effort: if the terminal doesn't exist or the pay call reverts, proceed without fee.
        // On failure, the fee ETH is retained as refundable caller credit instead of being added back to
        // transportPayment, avoiding DoS on zero-cost bridges that revert on non-zero transportPayment.
        IJBTerminal feeTerminal = _primaryTerminalOf({forProjectId: FEE_PROJECT_ID, token: JBConstants.NATIVE_TOKEN});
        bool feePaid;
        if (address(feeTerminal) != address(0) && _toRemoteFee != 0) {
            try feeTerminal.pay{value: _toRemoteFee}({
                projectId: FEE_PROJECT_ID,
                token: JBConstants.NATIVE_TOKEN,
                amount: _toRemoteFee,
                beneficiary: _msgSender(),
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            }) returns (
                uint256
            ) {
                feePaid = true;
            } catch {
                // Fee payment failed. Keep transportPayment unchanged and retain the fee for caller refund below.
            }
        }
        if (!feePaid && _toRemoteFee != 0) _retainToRemoteFee({account: _msgSender(), amount: _toRemoteFee});

        // Send the merkle root to the remote chain.
        _sendRoot({transportPayment: transportPayment, token: token, remoteToken: remoteToken});
    }

    //*********************************************************************//
    // ------------------------ external views --------------------------- //
    //*********************************************************************//

    /// @notice The inbox merkle tree root for a given token.
    /// @param token The local terminal token to get the inbox for.
    /// @return The inbox tree root for the token.
    function inboxOf(address token) external view returns (JBInboxTreeRoot memory) {
        return _inboxOf[token];
    }

    /// @notice Checks whether the specified token is mapped to a remote token.
    /// @param token The terminal token to check.
    /// @return A boolean which is `true` if the token is mapped to a remote token and `false` if it is not.
    function isMapped(address token) external view override returns (bool) {
        return _remoteTokenFor[token].addr != bytes32(0);
    }

    /// @notice The outbox merkle tree for a given token.
    /// @param token The local terminal token to get the outbox for.
    /// @return The outbox tree for the token.
    function outboxOf(address token) external view returns (JBOutboxTree memory) {
        return _outboxOf[token];
    }

    /// @notice The peer chain's raw per-context surplus and balance from the latest snapshot, bundled with the peer
    /// chain ID and snapshot freshness key.
    /// @dev The contexts are un-valued, in each context's own currency and decimals — the registry dedups same-peer
    /// suckers by freshness, then values each context into a requested currency. The sucker consults no price oracle.
    /// @return contexts The per-currency surplus and balance from the latest snapshot.
    /// @return chainId The peer chain these contexts belong to.
    /// @return snapshot The source freshness key of the latest snapshot.
    function peerChainContextsOf()
        external
        view
        returns (JBPeerChainContext[] memory contexts, uint256 chainId, uint256 snapshot)
    {
        return (_peerContexts, peerChainId(), snapshotTimestamp);
    }

    /// @notice The peer chain total supply bundled with the peer chain ID and snapshot freshness key.
    /// @dev Lets aggregators (e.g. `JBSuckerRegistry`) read the value, peer chain, and freshness in one call instead
    /// of three separate staticcalls. The `value` is identical to `peerChainTotalSupply`.
    /// @return A `JBPeerChainValue` with the total supply, peer chain ID, and snapshot freshness key.
    function peerChainTotalSupplyValue() external view returns (JBPeerChainValue memory) {
        return JBPeerChainValue({
            value: peerChainTotalSupply, peerChainId: peerChainId(), snapshotTimestamp: snapshotTimestamp
        });
    }

    /// @notice Information about the token on the remote chain that the given token on the local chain is mapped to.
    /// @param token The local terminal token to get the remote token for.
    /// @return The remote token mapping for the given local token.
    function remoteTokenFor(address token) external view returns (JBRemoteToken memory) {
        return _remoteTokenFor[token];
    }

    //*********************************************************************//
    // ------------------------- public views ---------------------------- //
    //*********************************************************************//

    /// @notice The outstanding amount of tokens to be added to the project's balance by `claim`.
    /// @param token The local terminal token to get the amount to add to balance for.
    /// @return The amount of terminal tokens available to add to the project's balance.
    function amountToAddToBalanceOf(address token) public view override returns (uint256) {
        // Start with the local balance that is not already committed to the outbox. Outbox funds are waiting to be
        // bridged and cannot also be claimed into the project's local balance.
        uint256 amount = _balanceOf({token: token, addr: address(this)}) - _outboxOf[token].balance;
        if (token == JBConstants.NATIVE_TOKEN) {
            // Native ETH can include caller refunds retained after failed fee payouts. Keep those credits reserved for
            // their claimants before reporting any claimable project balance.
            uint256 retainedFeeBalance = retainedToRemoteFeeBalance;
            if (amount <= retainedFeeBalance) return 0;
            amount -= retainedFeeBalance;

            // Native ETH can also include failed transport-payment refunds. These share the contract's ETH balance, so
            // exclude them from the amount that `claim` can add to the project balance.
            uint256 retainedRefundBalance = retainedTransportPaymentRefundBalance;
            if (amount <= retainedRefundBalance) return 0;
            amount -= retainedRefundBalance;
        }
        return amount;
    }

    /// @notice Returns the chain on which the peer is located.
    /// @dev `public` (not `external`) so the combined peer-chain views in this contract can read it internally
    /// without a self-call; subclasses implement the bridge-specific chain ID.
    /// @return chain ID of the peer.
    function peerChainId() public view virtual returns (uint256);

    /// @notice The peer sucker on the remote chain, as a bytes32 for cross-VM compatibility.
    /// @dev Defaults to `_toBytes32(address(this))`, assuming deterministic cross-chain deployment via CREATE2. The
    /// deployer (`JBSuckerDeployer`) uses `salt = keccak256(abi.encodePacked(_msgSender(), salt))` to ensure
    /// sender-specific determinism. An explicit peer can be set during clone initialization for deployments where
    /// the legitimate remote sucker address is known but does not match the local clone address.
    /// @return The bytes32 representation of the peer sucker address.
    function peer() public view virtual returns (bytes32) {
        bytes32 configuredPeer = _peer;
        if (configuredPeer != bytes32(0)) return configuredPeer;
        return _toBytes32(address(this));
    }

    /// @notice The ID of the project (on the local chain) that this sucker is associated with.
    /// @return The local project ID.
    function projectId() public view returns (uint256) {
        return _localProjectId;
    }

    /// @notice Reports the deprecation state of the sucker.
    /// @return state The current deprecation state
    function state() public view override returns (JBSuckerState) {
        uint256 _deprecatedAfter = deprecatedAfter;

        // The sucker is fully functional, no deprecation has been set yet.
        if (_deprecatedAfter == 0) {
            return JBSuckerState.ENABLED;
        }

        // The sucker is close to deprecation; this state only warns users.
        // Deprecation state is intentionally time-based.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < _deprecatedAfter - _maxMessagingDelay()) {
            return JBSuckerState.DEPRECATION_PENDING;
        }

        // The sucker no longer sends new roots to the pair, but it accepts new incoming roots.
        // Additionally it lets users exit here, since the sucker can no longer send roots/tokens.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < _deprecatedAfter) {
            return JBSuckerState.SENDING_DISABLED;
        }

        // The sucker is in the final state of deprecation. It does not allow new roots.
        return JBSuckerState.DEPRECATED;
    }

    /// @notice Indicates whether this contract supports the given interface.
    /// @param interfaceId The interface ID to check.
    /// @return A boolean indicating whether the interface is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBSuckerExtended).interfaceId || interfaceId == type(IJBSucker).interfaceId
            || interfaceId == type(IJBPermissioned).interfaceId || super.supportsInterface(interfaceId);
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Claim retained failed-fee ETH.
    /// @param beneficiary The address that should receive the retained ETH.
    function claimRetainedToRemoteFee(address payable beneficiary) external override {
        if (beneficiary == address(0)) revert JBSucker_ZeroBeneficiary({beneficiary: bytes32(0)});

        address account = _msgSender();
        uint256 amount = retainedToRemoteFeeOf[account];
        if (amount == 0) revert JBSucker_NoRetainedToRemoteFee(account);

        retainedToRemoteFeeOf[account] = 0;
        retainedToRemoteFeeBalance -= amount;

        _sendNativeTo({beneficiary: beneficiary, amount: amount});

        // State was cleared before sending ETH; the event is emitted after the transfer so failed sends do not log.
        emit RetainedToRemoteFeeClaimed({
            account: account, beneficiary: beneficiary, amount: amount, caller: _msgSender()
        });
    }

    /// @notice Claim retained failed transport-payment refund ETH.
    /// @param beneficiary The address that should receive the retained ETH.
    function claimRetainedTransportPaymentRefund(address payable beneficiary) external override {
        if (beneficiary == address(0)) revert JBSucker_ZeroBeneficiary({beneficiary: bytes32(0)});

        address account = _msgSender();
        uint256 amount = retainedTransportPaymentRefundOf[account];
        if (amount == 0) revert JBSucker_NoRetainedTransportPaymentRefund(account);

        retainedTransportPaymentRefundOf[account] = 0;
        retainedTransportPaymentRefundBalance -= amount;

        _sendNativeTo({beneficiary: beneficiary, amount: amount});

        // State was cleared before sending ETH; the event is emitted after the transfer so failed sends do not log.
        emit RetainedTransportPaymentRefundClaimed({
            account: account, beneficiary: beneficiary, amount: amount, caller: _msgSender()
        });
    }

    /// @notice Initializes the sucker with the project ID.
    /// @param initialProjectId The ID of the project (on the local chain) that this sucker is associated with.
    function initialize(uint256 initialProjectId) public initializer {
        _initialize({initialProjectId: initialProjectId, remotePeer: bytes32(0)});
    }

    /// @notice Initializes the sucker with the project ID and an explicit peer address.
    /// @param localProjectId The ID of the project (on the local chain) that this sucker is associated with.
    /// @param remotePeer The remote peer address. Leave zero to use the default deterministic same-address peer.
    function initialize(uint256 localProjectId, bytes32 remotePeer) public initializer {
        _initialize({initialProjectId: localProjectId, remotePeer: remotePeer});
    }

    /// @notice Initializes the sucker's project and optional peer address.
    /// @param initialProjectId The ID of the project (on the local chain) that this sucker is associated with.
    /// @param remotePeer The remote peer address. Leave zero to use the default deterministic same-address peer.
    function _initialize(uint256 initialProjectId, bytes32 remotePeer) internal {
        _localProjectId = initialProjectId;
        _peer = remotePeer;
        deployer = _msgSender();
    }

    /// @notice Map an ERC-20 token on the local chain to a remote-chain ERC-20 token for bridging.
    /// @param map The local and remote terminal token addresses to map, and minimum amount/gas limits for bridging
    /// them.
    function mapToken(JBTokenMapping calldata map) public payable override {
        _mapToken({map: map, transportPaymentValue: msg.value});
    }

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Adds funds to the project's balance.
    /// @param token The terminal token to add to the project's balance.
    /// @param amount The amount of terminal tokens to add to the project's balance.
    /// @param cachedProjectId The cached project ID to avoid redundant storage reads.
    function _addToBalance(address token, uint256 amount, uint256 cachedProjectId) internal virtual {
        // Make sure that the current `amountToAddToBalance` is greater than or equal to the amount being added.
        uint256 addableAmount = amountToAddToBalanceOf(token);
        if (amount > addableAmount) {
            revert JBSucker_InsufficientBalance({amount: amount, balance: addableAmount});
        }

        // Get the project's primary terminal for the token.
        IJBTerminal terminal = _primaryTerminalOf({forProjectId: cachedProjectId, token: token});

        // Revert if no terminal is configured for this token.
        if (address(terminal) == address(0)) {
            revert JBSucker_NoTerminalForToken({projectId: cachedProjectId, token: token});
        }

        // Native and ERC-20 differ only in (a) value attachment to the call, and (b) ERC-20 requires an
        // allowance grant + post-transfer balance assertion to catch fee-on-transfer / non-conforming tokens.
        // The terminal call itself is identical for both, so it lives outside the branch.
        uint256 nativeValue;
        uint256 balanceBefore;
        bool isErc20 = token != JBConstants.NATIVE_TOKEN;
        if (isErc20) {
            balanceBefore = IERC20(token).balanceOf(address(this));
            SafeERC20.forceApprove({token: IERC20(token), spender: address(terminal), value: amount});
        } else {
            nativeValue = amount;
        }

        terminal.addToBalanceOf{value: nativeValue}({
            projectId: cachedProjectId,
            token: token,
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
        });

        if (isErc20) {
            // The terminal must pull exactly `amount`; fee-on-transfer or non-conforming tokens are unsupported.
            uint256 expectedBalance = balanceBefore - amount;
            uint256 actualBalance = IERC20(token).balanceOf(address(this));
            if (actualBalance != expectedBalance) {
                revert JBSucker_UnexpectedTokenBalance({
                    token: token, expectedBalance: expectedBalance, actualBalance: actualBalance
                });
            }
        }
    }

    /// @notice Actions to perform after a user has successfully proven their claim.
    /// @param terminalToken The terminal token to suck.
    /// @param terminalTokenAmount The amount of terminal tokens.
    /// @param projectTokenAmount The amount of project tokens.
    /// @param beneficiary The beneficiary of the project tokens (bytes32 for cross-VM compatibility).
    function _handleClaim(
        address terminalToken,
        uint256 terminalTokenAmount,
        uint256 projectTokenAmount,
        bytes32 beneficiary
    )
        internal
    {
        uint256 cachedProjectId = projectId();

        // Add the cashed out funds to the project's balance.
        if (terminalTokenAmount != 0) {
            _addToBalance({token: terminalToken, amount: terminalTokenAmount, cachedProjectId: cachedProjectId});
        }

        // Known limitation: if the destination chain's controller is misconfigured or the project
        // doesn't exist, this call will revert, permanently blocking claims. This is a deployment/configuration
        // concern, not a contract bug. Projects must ensure controller and project exist on all destination chains
        // before enabling suckers.
        //
        // Mint the project tokens for the beneficiary via the project's controller.
        IJBController(address(DIRECTORY.controllerOf(cachedProjectId)))
            .mintTokensOf({
            projectId: cachedProjectId,
            tokenCount: projectTokenAmount,
            beneficiary: _toAddress(beneficiary),
            memo: "",
            useReservedPercent: false
        });
    }

    /// @notice Inserts a new leaf into the outbox merkle tree for the specified `token`.
    /// @param projectTokenCount The amount of project tokens to cash out.
    /// @param token The terminal token to cash out for.
    /// @param terminalTokenAmount The amount of terminal tokens reclaimed by cashing out.
    /// @param beneficiary The beneficiary of the project tokens on the remote chain (bytes32 for cross-VM
    /// compatibility).
    function _insertIntoTree(
        uint256 projectTokenCount,
        address token,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        bytes32 metadata
    )
        internal
    {
        // Guard against amounts that would overflow uint128 on SVM, which caps bridged amounts at uint128.
        if (terminalTokenAmount > type(uint128).max) revert JBSucker_AmountExceedsUint128(terminalTokenAmount);
        if (projectTokenCount > type(uint128).max) revert JBSucker_AmountExceedsUint128(projectTokenCount);
        // Build a hash based on the token amounts, the beneficiary, and the attribution metadata.
        bytes32 hashed = _buildTreeHash({
            projectTokenCount: projectTokenCount,
            terminalTokenAmount: terminalTokenAmount,
            beneficiary: beneficiary,
            metadata: metadata
        });

        // Get the outbox in storage.
        JBOutboxTree storage outbox = _outboxOf[token];

        // Insert the hash directly into the storage-backed tree — writes only the changed branch slot and count.
        outbox.tree.insert(hashed);
        outbox.balance += terminalTokenAmount;

        emit InsertToOutboxTree({
            beneficiary: beneficiary,
            token: token,
            hashed: hashed,
            index: outbox.tree.count - 1, // Subtract 1 since we want the 0-based index.
            root: _computeOutboxRoot(outbox.tree),
            projectTokenCount: projectTokenCount,
            terminalTokenAmount: terminalTokenAmount,
            metadata: metadata,
            caller: _msgSender()
        });
    }

    /// @notice Checks if the `sender` (`_msgSender`) is a valid representative of the remote peer.
    /// @param sender The message's sender.
    /// @return valid Whether the sender is the remote peer.
    function _isRemotePeer(address sender) internal virtual returns (bool valid);

    /// @notice Map an ERC-20 token on the local chain to a remote-chain ERC-20 token, or disable bridging.
    /// @dev Once a token has outbox tree entries (`_outboxOf[token].tree.count != 0`), it cannot be remapped to a
    /// different remote token -- it can only be disabled by mapping to `address(0)`, which triggers a final root
    /// flush to settle outstanding claims. This permanence prevents double-spending: if a remapping were allowed
    /// after outbox activity, the same local funds could be claimed against two different remote tokens. A
    /// misconfigured mapping therefore requires deploying a new sucker. Re-enabling a disabled mapping
    /// (back to the same remote token) is supported.
    /// @dev Remote tokens are also unique per local token within this sucker. The source side keeps separate
    /// outboxes/nonces per local token, but the destination side stores roots under the remote token address. Sharing
    /// one remote token across multiple local tokens in the same sucker would merge those inboxes on the destination
    /// chain. Separate suckers can still map the same local/remote token pair, letting users choose a bridge lane.
    /// @param map The local and remote terminal token addresses to map, and minimum amount/gas limits for bridging
    /// them.
    /// @param transportPaymentValue The amount of `msg.value` to send for the token mapping.
    /// @return transportPaymentSpent The amount of transport payment used by a final outbox flush.
    function _mapToken(
        JBTokenMapping calldata map,
        uint256 transportPaymentValue
    )
        internal
        returns (uint256 transportPaymentSpent)
    {
        address token = map.localToken;
        JBRemoteToken memory currentMapping = _remoteTokenFor[token];

        // Once the emergency hatch for a token is enabled it can't be disabled.
        if (currentMapping.emergencyHatch) {
            revert JBSucker_TokenHasInvalidEmergencyHatchState({token: token});
        }

        // Validate the token mapping according to the rules of the sucker.
        _validateTokenMapping(map);

        // Reference the project id.
        uint256 _projectId = projectId();

        // The registry can map during authorized deployment. Otherwise, require the project's mapping permission.
        _requirePermissionAllowingOverrideFrom({
            account: _ownerOf(_projectId),
            projectId: _projectId,
            permissionId: JBPermissionIds.MAP_SUCKER_TOKEN,
            alsoGrantAccessIf: _msgSender() == address(REGISTRY)
        });

        // Make sure that the token does not get remapped to another remote token.
        // As this would cause the funds for this token to be double spendable on the other side.
        // It should not be possible to cause any issues even without this check
        // a bridge *should* never accept such a request. This is mostly a sanity check.
        if (
            currentMapping.addr != bytes32(0) && currentMapping.addr != map.remoteToken && map.remoteToken != bytes32(0)
                && _outboxOf[token].tree.count != 0
        ) {
            revert JBSucker_TokenAlreadyMapped({localToken: token, mappedTo: currentMapping.addr});
        }

        // A remote token can back only one local token's outbox in this sucker. Otherwise two independent source
        // nonces would race into the same destination inbox key (`root.token`), making one token's root stale or
        // overwriting the other. Other suckers have separate inbox/outbox storage and are unaffected.
        if (map.remoteToken != bytes32(0)) {
            address mappedLocalToken = _localTokenForRemoteToken[map.remoteToken];
            if (mappedLocalToken != address(0) && mappedLocalToken != token) {
                revert JBSucker_RemoteTokenAlreadyMapped({remoteToken: map.remoteToken, localToken: mappedLocalToken});
            }
        }

        // No inbox guard needed here. Token remapping only affects the outbound (sending) path —
        // it changes where tokens get bridged TO. Existing inbox claims are resolved against the inbox merkle
        // tree keyed by the local token address. Changing the remote token doesn't invalidate those claims
        // since the tokens have already arrived and the merkle proofs remain valid.

        // If the remote token is being set to the 0 address (which disables bridging), send any remaining outbox funds
        // to the remote chain. Once disabled, the token enters SENDING_DISABLED state — no new outbox entries can be
        // created and the mapping cannot be changed to a different remote token. If tokens are stuck in this state
        // (e.g., the bridge is non-functional), the project owner can call `enableEmergencyHatchFor` to allow
        // local withdrawals via `exitThroughEmergencyHatch`.
        if (map.remoteToken == bytes32(0) && _outboxOf[token].numberOfClaimsSent != _outboxOf[token].tree.count) {
            // Disable before external call to prevent reentrancy via prepare().
            // _sendRoot uses the `currentMapping` parameter, not storage, so this is safe.
            _remoteTokenFor[token].enabled = false;
            _sendRoot({transportPayment: transportPaymentValue, token: token, remoteToken: currentMapping});
            transportPaymentSpent = transportPaymentValue;
        }

        // Update the reverse reservation if an unused local token is being remapped to a new remote token.
        if (
            map.remoteToken != bytes32(0) && currentMapping.addr != bytes32(0) && currentMapping.addr != map.remoteToken
                && _localTokenForRemoteToken[currentMapping.addr] == token
        ) {
            delete _localTokenForRemoteToken[currentMapping.addr];
        }

        bytes32 remoteToken = map.remoteToken == bytes32(0) ? currentMapping.addr : map.remoteToken;
        if (remoteToken != bytes32(0)) _localTokenForRemoteToken[remoteToken] = token;

        // Update the token mapping.
        _remoteTokenFor[token] = JBRemoteToken({
            enabled: map.remoteToken != bytes32(0),
            emergencyHatch: false,
            minGas: map.minGas,
            // This is done so that a token can be disabled and then enabled again
            // while ensuring the remoteToken never changes (unless it hasn't been used yet)
            addr: remoteToken
        });
    }

    /// @notice What is the maximum time it takes for a message to be received on the other side.
    /// @dev Be sure to keep in mind if a message fails having to retry and the time it takes to retry.
    /// @return The maximum time it takes for a message to be received on the other side.
    function _maxMessagingDelay() internal pure virtual returns (uint40) {
        return 14 days;
    }

    /// @notice Cash out project tokens for terminal tokens.
    /// @param projectToken The project token to cash out (unused, kept for interface compatibility).
    /// @param count The number of project tokens to cash out.
    /// @param token The terminal token to cash out for.
    /// @param minTokensReclaimed The minimum amount of terminal tokens to reclaim. If the amount reclaimed is less than
    /// this, the transaction will revert.
    /// @return reclaimedAmount The amount of terminal tokens reclaimed by the cash out.
    function _pullBackingAssets(
        IERC20 projectToken,
        uint256 count,
        address token,
        uint256 minTokensReclaimed
    )
        internal
        virtual
        returns (uint256 reclaimedAmount)
    {
        projectToken;

        uint256 cachedProjectId = projectId();

        // Get the project's primary terminal for `token`.
        IJBCashOutTerminal terminal =
            IJBCashOutTerminal(address(_primaryTerminalOf({forProjectId: cachedProjectId, token: token})));

        // Revert if no terminal is configured for this token.
        if (address(terminal) == address(0)) {
            revert JBSucker_NoTerminalForToken({projectId: cachedProjectId, token: token});
        }

        // Record the balance before the cash out for the sanity check.
        uint256 balanceBefore = _balanceOf({token: token, addr: address(this)});

        // Cash out the project tokens for terminal tokens. Suckers are a transparent value-mover; the bridge
        // accounting is the entirety of their function.
        reclaimedAmount = terminal.cashOutTokensOf({
            holder: address(this),
            projectId: cachedProjectId,
            cashOutCount: count,
            tokenToReclaim: token,
            minTokensReclaimed: minTokensReclaimed,
            beneficiary: payable(address(this)),
            metadata: bytes("")
        });

        // Sanity check to make sure we received the expected amount.
        assert(reclaimedAmount == _balanceOf({token: token, addr: address(this)}) - balanceBefore);
    }

    /// @notice Send the outbox root for the specified token to the remote peer.
    /// @dev Some bridges require a nonzero `transportPayment`; zero-cost bridges must reject nonzero values.
    /// @param transportPayment The amount of `msg.value` paid to the transport for this message.
    /// @param token The terminal token to bridge the merkle tree of.
    /// @param remoteToken The remote token which the `token` is mapped to.
    function _sendRoot(uint256 transportPayment, address token, JBRemoteToken memory remoteToken) internal virtual {
        // Ensure the token is mapped to an address on the remote chain.
        if (remoteToken.addr == bytes32(0)) revert JBSucker_TokenNotMapped(token);

        // Make sure that the sucker still allows sending new messages.
        _requireSendingEnabled();

        // Drain the outbox: read balance/nonce/root, clear balance, advance nonce and numberOfClaimsSent.
        uint256 amount;
        uint64 nonce;
        bytes32 root;
        uint256 index;
        {
            JBOutboxTree storage outbox = _outboxOf[token];

            // If the outbox tree is empty (no `prepare()` calls have been made), there is nothing to send.
            // This prevents an arithmetic underflow when computing `count - 1` below.
            uint256 count = outbox.tree.count;
            if (count == 0) return;

            // Get the amount to send and then clear it from the outbox tree.
            // By design, `amountToAddToBalanceOf` is transiently inflated after this deletion because the
            // contract's token balance has not yet been transferred to the bridge. This inflation is scoped
            // within this transaction — `_sendRootOverAMB` (called below) transfers the tokens to the bridge
            // before the tx completes, settling the balance. This is inherent to the two-phase bridge model.
            amount = outbox.balance;
            delete outbox.balance;

            // Increment the outbox tree's nonce.
            nonce = ++outbox.nonce;
            root = _computeOutboxRoot(outbox.tree);

            // Update the numberOfClaimsSent to the current count of the tree.
            // This is used as in the fallback to allow users to withdraw locally if the bridge is reverting.
            // forge-lint: disable-next-line(unsafe-typecast)
            outbox.numberOfClaimsSent = uint192(count);
            index = count - 1;
        }

        // Emit an event for the relayers to watch for.
        emit RootToRemote({root: root, token: token, index: index, nonce: nonce, caller: _msgSender()});

        // Build the snapshot message and send it over the bridge.
        _buildSnapshotAndSend({
            transportPayment: transportPayment,
            token: token,
            remoteToken: remoteToken,
            amount: amount,
            nonce: nonce,
            root: root,
            index: index
        });
    }

    /// @notice Send native tokens, reverting if the recipient rejects them.
    /// @param beneficiary The recipient.
    /// @param amount The amount to send.
    function _sendNativeTo(address payable beneficiary, uint256 amount) internal {
        (bool success,) = beneficiary.call{value: amount}("");
        if (!success) revert JBSucker_RefundFailed({beneficiary: beneficiary, amount: amount});
    }

    /// @notice Performs the logic to send a message to the peer over the AMB.
    /// @dev This is chain/sucker/bridge specific logic.
    /// @param transportPayment The amount of `msg.value` that is going to get paid for sending this message.
    /// @param index The index of the most recent message that is part of the root.
    /// @param token The terminal token to bridge.
    /// @param amount The amount of terminal tokens to bridge.
    /// @param remoteToken The remote token which the terminal token is mapped to.
    /// @param message The message/root to send to the remote chain.
    // forge-lint: disable-next-line(mixed-case-function)
    function _sendRootOverAMB(
        uint256 transportPayment,
        uint256 index,
        address token,
        uint256 amount,
        JBRemoteToken memory remoteToken,
        JBMessageRoot memory message
    )
        internal
        virtual;

    /// @notice Validates a leaf as being in the inbox merkle tree and registers the leaf as executed (to prevent
    /// double-spending).
    /// @dev Reverts if the leaf is invalid.
    /// @param projectTokenCount The number of project tokens which were cashed out.
    /// @param terminalToken The terminal token that the project tokens were cashed out for.
    /// @param terminalTokenAmount The amount of terminal tokens reclaimed by the cash out.
    /// @param beneficiary The beneficiary of the project tokens (bytes32 for cross-VM compatibility).
    /// @param index The index of the leaf to prove in the terminal token's inbox tree.
    /// @param leaves The leaves that prove that the leaf at the `index` is in the tree (i.e. the merkle branch that the
    /// leaf is on).
    function _validate(
        uint256 projectTokenCount,
        address terminalToken,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        bytes32 metadata,
        uint256 index,
        bytes32[_TREE_DEPTH] calldata leaves
    )
        internal
    {
        // Ensure the index is within tree bounds (max 2^TREE_DEPTH - 1).
        if (index >= (uint256(1) << _TREE_DEPTH)) revert JBSucker_IndexOutOfRange(index);

        // Make sure the leaf has not already been executed.
        if (_executedFor[terminalToken].get(index)) {
            revert JBSucker_LeafAlreadyExecuted({token: terminalToken, index: index});
        }

        // Register the leaf as executed to prevent double-spending.
        _executedFor[terminalToken].set(index);

        // Compute the leaf hash once. It's used twice: stored in `executedLeafHashOf` (so beneficiary contracts
        // can authenticate post-hoc settlement when their `claim()` was front-run) and passed to
        // `_validateBranchRoot` for merkle verification. The bare executed bitmap proves "some leaf at index I
        // was executed" but not "which leaf"; storing the hash binds the index to the actual leaf content.
        bytes32 leafHash = _buildTreeHash({
            projectTokenCount: projectTokenCount,
            terminalTokenAmount: terminalTokenAmount,
            beneficiary: beneficiary,
            metadata: metadata
        });
        executedLeafHashOf[terminalToken][index] = leafHash;

        // Select which retained inbox root this proof should be validated against. A proof generated against any of
        // the last `_INBOX_ROOT_RING_SIZE` accepted roots is honored, not only the latest, so a proof does not become
        // unusable the instant a newer root arrives. If the proof matches no retained root, the latest root is used as
        // the fallback so the failure path reverts with the canonical `JBSucker_InvalidProof` against the live root.
        //
        // This widening is double-spend-safe: the `_executedFor[terminalToken]` guard above is keyed by leaf `index`,
        // not by root. The merkle branch binds `(leafHash, index)` to whichever retained root it matches, so the same
        // leaf carries the same `index` regardless of which retained root proves it — once executed, every later
        // proof
        // for that leaf (against any retained root) is rejected by the bitmap before reaching this point.
        bytes32 expectedRoot =
            _selectRetainedInboxRoot({terminalToken: terminalToken, leafHash: leafHash, index: index, leaves: leaves});

        // Calculate the root and compare it to the selected retained inbox root.
        _validateBranchRoot({expectedRoot: expectedRoot, leafHash: leafHash, index: index, leaves: leaves});
    }

    /// @notice Validates a branch root against the expected root.
    /// @dev This is a virtual function to allow tests to override the behavior; it should never be overridden
    /// otherwise.
    /// @param expectedRoot The expected merkle root to validate against.
    /// @param leafHash The precomputed leaf hash (`_buildTreeHash` output) for the leaf being validated.
    /// @param index The index of the leaf in the merkle tree.
    /// @param leaves The merkle branch proving the leaf's inclusion.
    function _validateBranchRoot(
        bytes32 expectedRoot,
        bytes32 leafHash,
        uint256 index,
        bytes32[_TREE_DEPTH] calldata leaves
    )
        internal
        virtual
    {
        // Calculate the root based on the leaf, the branch, and the index.
        // Delegates to JBSuckerLib (via DELEGATECALL) to keep MerkleLib.branchRoot bytecode out of each sucker.
        bytes32 root = JBSuckerLib.computeBranchRoot({item: leafHash, branch: leaves, index: index});

        // Revert if the computed root does not match the expected inbox root.
        if (root != expectedRoot) {
            revert JBSucker_InvalidProof({root: root, inboxRoot: expectedRoot});
        }
    }

    /// @notice Validates a leaf as being in the outbox merkle tree and not having been sent over the amb, and registers
    /// the leaf as executed (to prevent double-spending).
    /// @dev Reverts if the leaf is invalid.
    /// @dev IMPORTANT: Emergency exit safety depends on `numberOfClaimsSent` being accurately tracked.
    /// `numberOfClaimsSent` is updated in `_sendRoot` to equal `outbox.tree.count` at the time the root is sent
    /// over the bridge. This value determines which leaves have already been communicated to the remote peer and
    /// are therefore NOT safe to reclaim locally (as they could be claimed on the remote chain too, enabling
    /// double-spending).
    /// @dev Assumptions:
    /// 1. `numberOfClaimsSent` is only updated in `_sendRoot`, which is called from `toRemote` and `_mapToken`
    ///    (when disabling a token). If `_sendRoot` fails or is never called, `numberOfClaimsSent` remains 0,
    ///    allowing all leaves to be emergency-exited (which is correct -- nothing was sent).
    /// 2. If the bridge delivers the root but `numberOfClaimsSent` was set before additional leaves were added
    ///    to the outbox tree, those additional leaves (with index >= numberOfClaimsSent) are safe to emergency-exit
    ///    because they were never part of the sent root.
    /// 3. A compromised or buggy `_sendRootOverAMB` implementation that fails silently (does not revert but also
    ///    does not deliver the message) could lead to `numberOfClaimsSent` being incremented without the remote
    ///    peer receiving the root. In this scenario, leaves with index < numberOfClaimsSent would be blocked from
    ///    emergency exit even though they were never claimable remotely. This is a conservative failure mode --
    ///    funds are locked rather than double-spent. The emergency hatch or deprecation flow would need to be used.
    /// @param projectTokenCount The number of project tokens which were cashed out.
    /// @param terminalToken The terminal token that the project tokens were cashed out for.
    /// @param terminalTokenAmount The amount of terminal tokens reclaimed by the cash out.
    /// @param beneficiary The beneficiary of the project tokens (bytes32 for cross-VM compatibility).
    /// @param index The index of the leaf to prove in the terminal token's outbox tree.
    /// @param leaves The leaves that prove that the leaf at the `index` is in the tree (i.e. the merkle branch that the
    /// leaf is on).
    function _validateForEmergencyExit(
        uint256 projectTokenCount,
        address terminalToken,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        bytes32 metadata,
        uint256 index,
        bytes32[_TREE_DEPTH] calldata leaves
    )
        internal
    {
        // Ensure the index is within tree bounds (max 2^TREE_DEPTH - 1).
        if (index >= (uint256(1) << _TREE_DEPTH)) revert JBSucker_IndexOutOfRange(index);

        // Make sure that the emergencyHatch is enabled for the token.
        JBSuckerState deprecationState = state();
        if (
            deprecationState != JBSuckerState.DEPRECATED && deprecationState != JBSuckerState.SENDING_DISABLED
                && !_remoteTokenFor[terminalToken].emergencyHatch
        ) {
            revert JBSucker_TokenHasInvalidEmergencyHatchState({token: terminalToken});
        }

        // Check that this claim is within the bounds of who can claim.
        // If the root that this leaf is in was already sent then we can not let the user claim here.
        // As it could have also been received by the peer sucker, which would then let the user claim on each side.
        // NOTE: We are comparing the *count* and the *index*, so `count - 1` is the last index that was sent.
        // A count of 0 means that no root has ever been sent for this token, so everyone can claim.
        JBOutboxTree storage outboxOfToken = _outboxOf[terminalToken];
        if (outboxOfToken.numberOfClaimsSent != 0 && outboxOfToken.numberOfClaimsSent - 1 >= index) {
            revert JBSucker_LeafAlreadyExecuted({token: terminalToken, index: index});
        }

        {
            // We re-use the same `_executedFor` mapping but we use a different slot.
            // We can not use the regular mapping, since this claim is done for tokens being sent from here to the pair.
            // where the regular mapping is for tokens that were sent on the pair to here. Even though these may seem
            // similar they are actually completely unrelated.
            address emergencyExitAddress = address(bytes20(keccak256(abi.encode(terminalToken))));

            // Make sure the leaf has not already been executed.
            if (_executedFor[emergencyExitAddress].get(index)) {
                revert JBSucker_LeafAlreadyExecuted({token: terminalToken, index: index});
            }

            // Register the leaf as executed to prevent double-spending.
            _executedFor[emergencyExitAddress].set(index);
        }

        // Calculate the root and compare it to the current outbox root.
        _validateBranchRoot({
            expectedRoot: _computeOutboxRoot(_outboxOf[terminalToken].tree),
            leafHash: _buildTreeHash({
                projectTokenCount: projectTokenCount,
                terminalTokenAmount: terminalTokenAmount,
                beneficiary: beneficiary,
                metadata: metadata
            }),
            index: index,
            leaves: leaves
        });
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice Helper to get the `addr`'s balance for a given `token`.
    /// @param token The token to get the balance for.
    /// @param addr The address to get the `token` balance of.
    /// @return balance The address' `token` balance.
    function _balanceOf(address token, address addr) internal view returns (uint256 balance) {
        if (token == JBConstants.NATIVE_TOKEN) {
            return addr.balance;
        }

        return IERC20(token).balanceOf(addr);
    }

    /// @notice Compute the merkle root of an outbox tree by reading its branch into memory and delegating
    /// to JBSuckerLib.computeTreeRoot (via DELEGATECALL). Replaces inlined MerkleLib.root() to save ~3KB.
    /// @param tree The storage-backed merkle tree.
    /// @return The merkle root.
    function _computeOutboxRoot(MerkleLib.Tree storage tree) internal view returns (bytes32) {
        uint256 count = tree.count;
        // An empty tree has a known zero root.
        if (count == 0) return MerkleLib.Z_32;

        // Copy only the non-zero branch slots from storage into memory for the root computation.
        bytes32[_TREE_DEPTH] memory branch;
        for (uint256 i; i < _TREE_DEPTH;) {
            if (count & (uint256(1) << i) != 0) {
                branch[i] = tree.branch[i];
            }
            unchecked {
                ++i;
            }
        }
        return JBSuckerLib.computeTreeRoot({branch: branch, count: count});
    }

    /// @notice Builds a hash as they are stored in the merkle tree.
    /// @param projectTokenCount The number of project tokens to cash out.
    /// @param terminalTokenAmount The amount of terminal tokens to reclaim from the cash out.
    /// @param beneficiary The beneficiary which will receive the project tokens (bytes32 for cross-VM compatibility).
    /// @param metadata Opaque caller-defined attribution payload travelling inside the leaf hash.
    /// @return hash The keccak256 hash of the leaf data.
    function _buildTreeHash(
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        bytes32 metadata
    )
        internal
        pure
        returns (bytes32 hash)
    {
        // All four arguments are 32 bytes — hash from free memory to avoid abi.encode allocation overhead.
        // forge-lint: disable-next-line(asm-keccak256)
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, projectTokenCount)
            mstore(add(ptr, 0x20), terminalTokenAmount)
            mstore(add(ptr, 0x40), beneficiary)
            mstore(add(ptr, 0x60), metadata)
            hash := keccak256(ptr, 0x80)
        }
    }

    /// @notice The length of the context suffix for ERC-2771 meta-transactions.
    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    /// @return The suffix length in bytes.
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }

    /// @notice The authoritative accounting-context currency the project uses for a local token. Peer context is keyed
    /// by this currency so a consumer reads it under the same currency it already works in (which the project may set
    /// to a well-known id like USD rather than the token-keyed convention).
    /// @dev Both lookups use a low-level staticcall guarded by a returndata-length check, so a missing or
    /// non-conforming directory/terminal (including one that returns short/empty data) can't block a bridge message —
    /// it just yields the fallback. Returns the cached value when one exists (the accounting-context currency is
    /// immutable, so the cache never goes stale). Falls back to the conventional `uint32(uint160(token))` only when the
    /// project has no local accounting context for the token yet; that fallback is NOT cached, so a later snapshot
    /// re-reads it once the context exists.
    /// @param token The resolved local token.
    /// @return currency The project's accounting-context currency for the token.
    /// @return authoritative Whether `currency` came from a cached or configured accounting context (true) or the
    /// convention fallback (false). `fromRemote` caches only authoritative results, since those are immutable.
    function _localCurrencyOf(address token) internal view returns (uint32 currency, bool authoritative) {
        // Reuse the value derived on an earlier snapshot — no need to read the terminal again.
        uint32 cached = _cachedCurrencyOf[token];
        if (cached != 0) return (cached, true);

        uint256 forProjectId = projectId();

        // Resolve the project's primary terminal for the token. An `address` return needs a full word.
        (bool terminalOk, bytes memory terminalData) =
            address(DIRECTORY).staticcall(abi.encodeCall(IJBDirectory.primaryTerminalOf, (forProjectId, token)));
        if (terminalOk && terminalData.length >= 32) {
            address terminal = abi.decode(terminalData, (address));
            if (terminal != address(0)) {
                // Read the token's accounting context. The struct encodes to three words.
                (bool contextOk, bytes memory contextData) =
                    terminal.staticcall(abi.encodeCall(IJBTerminal.accountingContextForTokenOf, (forProjectId, token)));
                if (contextOk && contextData.length >= 96) {
                    JBAccountingContext memory accountingContext = abi.decode(contextData, (JBAccountingContext));
                    if (accountingContext.currency != 0) return (accountingContext.currency, true);
                }
            }
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint32(uint160(token)), false);
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @notice Resolve the current owner of the project this sucker belongs to.
    /// @dev `PROJECTS.ownerOf(...)` is the source of truth for "project owner" permission checks; we hit it from
    /// every permission-gated entrypoint (`enableEmergencyHatchFor`, `setDeprecation`, `_mapToken`). Routing all
    /// three through this internal helper emits the abi-encode + STATICCALL + return-decode sequence once in the
    /// child contract's bytecode instead of inlining it at each call site, which is what keeps `JBSwapCCIPSucker`
    /// under the EIP-170 limit after the leaf-`metadata` thread-through landed.
    /// @param forProjectId The project ID to look up — always the sucker's own `projectId()`, but accepted as a
    /// parameter so callers can pass the cached local they already computed (avoiding a redundant `projectId()`
    /// call against the read-only registry).
    /// @return owner The address currently registered as the project's ERC-721 holder.
    function _ownerOf(uint256 forProjectId) internal view returns (address owner) {
        return PROJECTS.ownerOf(forProjectId);
    }

    /// @notice Retain a failed `toRemoteFee` payment for later caller refund.
    /// @param account The account that can reclaim the retained fee.
    /// @param amount The retained fee amount.
    function _retainToRemoteFee(address account, uint256 amount) internal {
        retainedToRemoteFeeOf[account] += amount;
        retainedToRemoteFeeBalance += amount;
        emit RetainedToRemoteFee({account: account, amount: amount, caller: _msgSender()});
    }

    /// @notice Retains a failed transport-payment refund as account-scoped native credit.
    /// @param account The account that can reclaim the retained refund.
    /// @param amount The retained refund amount.
    function _retainTransportPaymentRefund(address account, uint256 amount) internal {
        retainedTransportPaymentRefundOf[account] += amount;
        retainedTransportPaymentRefundBalance += amount;
        emit RetainedTransportPaymentRefund({account: account, amount: amount, caller: _msgSender()});
    }

    /// @notice Returns the peer address as an EVM address.
    /// @return The peer address.
    function _peerAddress() internal view returns (address) {
        return _toAddress(peer());
    }

    /// @notice Looks up the primary terminal for a project/token pair via the directory.
    /// @param forProjectId The project ID.
    /// @param token The token address.
    /// @return The primary terminal.
    function _primaryTerminalOf(uint256 forProjectId, address token) internal view returns (IJBTerminal) {
        // Claim processing may call this through a bounded claim list; each lookup must use the live directory state.
        return DIRECTORY.primaryTerminalOf({projectId: forProjectId, token: token});
    }

    /// @notice Revert if new outbound sends are disabled or deprecated.
    function _requireSendingEnabled() internal view {
        JBSuckerState deprecationState = state();
        if (deprecationState == JBSuckerState.DEPRECATED || deprecationState == JBSuckerState.SENDING_DISABLED) {
            revert JBSucker_Deprecated({state: deprecationState});
        }
    }

    /// @notice Adds two `uint128` amounts, saturating at `type(uint128).max` instead of overflowing.
    /// @dev Saturation keeps a pathological peer snapshot from reverting the receive path; the cap can only
    /// under-report a remote amount, the safe direction.
    /// @param a The first amount.
    /// @param b The second amount.
    /// @return The saturated sum.
    function _saturatingAddU128(uint128 a, uint128 b) internal pure returns (uint128) {
        unchecked {
            uint256 sum = uint256(a) + uint256(b);
            // The cast only runs when `sum <= type(uint128).max`, so it cannot truncate.
            // forge-lint: disable-next-line(unsafe-typecast)
            return sum > type(uint128).max ? type(uint128).max : uint128(sum);
        }
    }

    /// @notice Selects which retained inbox root a proof should be validated against, honoring a small window of
    /// recently-accepted roots rather than only the latest.
    /// @dev Computes the branch root implied by the proof once, then returns the first retained ring root it matches.
    /// Falls back to the latest inbox root (`_inboxOf[terminalToken].root`) when the proof matches no retained root, so
    /// the caller's subsequent `_validateBranchRoot` reverts against the live root exactly as it did before the ring
    /// existed. This is `view` and side-effect free; the double-spend guard lives entirely in `_validate`'s bitmap.
    /// @param terminalToken The terminal token whose retained inbox roots are searched.
    /// @param leafHash The precomputed leaf hash for the leaf being validated.
    /// @param index The index of the leaf in the inbox tree.
    /// @param leaves The merkle branch proving the leaf's inclusion.
    /// @return expectedRoot The retained root the proof matches, or the latest inbox root if none match.
    function _selectRetainedInboxRoot(
        address terminalToken,
        bytes32 leafHash,
        uint256 index,
        bytes32[_TREE_DEPTH] calldata leaves
    )
        internal
        view
        virtual
        returns (bytes32 expectedRoot)
    {
        // The latest accepted root. Used as the fallback so the failure path is unchanged.
        bytes32 latestRoot = _inboxOf[terminalToken].root;

        // Compute the root implied by this proof once.
        bytes32 computedRoot = JBSuckerLib.computeBranchRoot({item: leafHash, branch: leaves, index: index});

        // Honor the latest root first (the common case), then any other retained root in the ring.
        if (computedRoot == latestRoot) return latestRoot;

        bytes32[_INBOX_ROOT_RING_SIZE] storage ring = _inboxRootRingOf[terminalToken];
        for (uint256 i; i < _INBOX_ROOT_RING_SIZE;) {
            bytes32 retained = ring[i];
            // Skip empty slots; a real inbox root is never `bytes32(0)`.
            if (retained != bytes32(0) && computedRoot == retained) return retained;
            unchecked {
                ++i;
            }
        }

        // No retained root matched. Fall back to the latest root so `_validateBranchRoot` reverts against it.
        return latestRoot;
    }

    /// @notice Convert a bytes32 remote address to a local EVM address.
    /// @param remote The bytes32 representation of the address.
    /// @return The EVM address (lower 20 bytes).
    function _toAddress(bytes32 remote) internal pure returns (address) {
        return address(uint160(uint256(remote)));
    }

    /// @notice Convert an EVM address to a bytes32 remote address.
    /// @param addr The EVM address.
    /// @return The bytes32 representation (left-padded with zeros).
    function _toBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /// @notice Allow sucker implementations to add/override mapping rules to suit their specific needs.
    /// @param map The token mapping to validate.
    function _validateTokenMapping(JBTokenMapping calldata map) internal pure virtual {
        bool isNative = map.localToken == JBConstants.NATIVE_TOKEN;

        // If the token being mapped is the native token, the `remoteToken` must also be the native token.
        // The native token can also be mapped to the 0 address, which is used to disable native token bridging.
        if (isNative && map.remoteToken != _toBytes32(JBConstants.NATIVE_TOKEN) && map.remoteToken != bytes32(0)) {
            revert JBSucker_InvalidNativeRemoteAddress({remoteToken: map.remoteToken});
        }

        // Enforce a reasonable minimum gas limit for bridging. A minimum which is too low could lead to the loss of
        // funds.
        if (map.minGas < MESSENGER_ERC20_MIN_GAS_LIMIT && !isNative) {
            revert JBSucker_BelowMinGas({minGas: map.minGas, minGasLimit: MESSENGER_ERC20_MIN_GAS_LIMIT});
        }
    }

    //*********************************************************************//
    // ------------------------- private helpers ------------------------- //
    //*********************************************************************//

    /// @notice Builds the cross-chain snapshot message and sends it over the bridge.
    /// @dev Delegates snapshot construction to JBSuckerLib (deployed library, called via DELEGATECALL) to reduce
    /// child contract bytecode.
    /// @param transportPayment The amount of `msg.value` that is going to get paid for sending this message.
    /// @param token The terminal token to bridge.
    /// @param remoteToken The remote token which the terminal token is mapped to.
    /// @param amount The amount of terminal tokens to bridge.
    /// @param nonce The outbox nonce for this send.
    /// @param root The merkle root of the outbox tree.
    /// @param index The index of the most recent message that is part of the root.
    function _buildSnapshotAndSend(
        uint256 transportPayment,
        address token,
        JBRemoteToken memory remoteToken,
        uint256 amount,
        uint64 nonce,
        bytes32 root,
        uint256 index
    )
        private
    {
        uint256 sourceTimestamp;
        unchecked {
            // High bits preserve the source-chain timestamp for operators/indexers. Low bits make same-timestamp
            // roots distinct so the receiver can still reject stale project-wide snapshots with a strict `>`.
            sourceTimestamp = (block.timestamp << 128) | ++_outboundSnapshotSequence;
        }

        JBMessageRoot memory message = JBSuckerLib.buildSnapshotMessage({
            directory: DIRECTORY,
            projectId: projectId(),
            remoteToken: remoteToken.addr,
            amount: amount,
            nonce: nonce,
            root: root,
            messageVersion: MESSAGE_VERSION,
            sourceTimestamp: sourceTimestamp
        });

        // Send the root over the AMB. This overloaded interface call is intentionally positional.
        _sendRootOverAMB({
            transportPayment: transportPayment,
            index: index,
            token: token,
            amount: amount,
            remoteToken: remoteToken,
            message: message
        });
    }
}
