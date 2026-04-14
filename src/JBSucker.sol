// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

import {JBSuckerState} from "./enums/JBSuckerState.sol";
import {IJBSucker} from "./interfaces/IJBSucker.sol";
import {IJBSuckerExtended} from "./interfaces/IJBSuckerExtended.sol";
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "./structs/JBClaim.sol";
import {JBDenominatedAmount} from "./structs/JBDenominatedAmount.sol";
import {JBInboxTreeRoot} from "./structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBOutboxTree} from "./structs/JBOutboxTree.sol";
import {JBRemoteToken} from "./structs/JBRemoteToken.sol";
import {JBTokenMapping} from "./structs/JBTokenMapping.sol";
import {JBSuckerLib} from "./libraries/JBSuckerLib.sol";
import {MerkleLib} from "./utils/MerkleLib.sol";

/// @notice An abstract contract for bridging a Juicebox project's tokens and the corresponding funds to and from a
/// remote chain.
/// @dev Beneficiaries and balances are tracked on two merkle trees: the outbox tree is used to send from the local
/// chain to the remote chain, and the inbox tree is used to receive from the remote chain to the local chain.
/// @dev Throughout this contract, "terminal token" refers to any token accepted by a project's terminal.
/// @dev This contract does *NOT* support tokens that have a fee on regular transfers and rebasing tokens.
/// @dev Cross-chain message authentication is delegated entirely to each bridge-specific subclass via the
/// `_isRemotePeer` virtual function. Each implementation authenticates differently: Optimism uses its native
/// `CrossDomainMessenger`, Arbitrum validates against the `Bridge` and `Outbox` contracts, and CCIP verifies
/// through the Chainlink `Router`. Deployers of new bridge integrations must implement `_isRemotePeer` to
/// guarantee that only messages from the legitimate remote peer are accepted.
abstract contract JBSucker is ERC2771Context, JBPermissioned, Initializable, ERC165, IJBSuckerExtended {
    using BitMaps for BitMaps.BitMap;
    using MerkleLib for MerkleLib.Tree;
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBSucker_AmountExceedsUint128(uint256 amount);
    error JBSucker_BelowMinGas(uint256 minGas, uint256 minGasLimit);
    error JBSucker_Deprecated();
    error JBSucker_DeprecationTimestampTooSoon(uint256 givenTime, uint256 minimumTime);
    error JBSucker_ExpectedMsgValue();
    error JBSucker_InsufficientBalance(uint256 amount, uint256 balance);
    error JBSucker_InsufficientMsgValue(uint256 received, uint256 expected);
    error JBSucker_InvalidMessageVersion(uint8 received, uint8 expected);
    error JBSucker_InvalidNativeRemoteAddress(bytes32 remoteToken);
    error JBSucker_InvalidProof(bytes32 root, bytes32 inboxRoot);
    error JBSucker_LeafAlreadyExecuted(address token, uint256 index);
    error JBSucker_NoTerminalForToken(uint256 projectId, address token);
    error JBSucker_NotPeer(bytes32 caller);
    error JBSucker_NothingToSend();
    error JBSucker_RefundFailed();
    error JBSucker_TokenAlreadyMapped(address localToken, bytes32 mappedTo);
    error JBSucker_TokenHasInvalidEmergencyHatchState(address token);
    error JBSucker_TokenNotMapped(address token);
    error JBSucker_IndexOutOfRange(uint256 index);
    error JBSucker_UnexpectedMsgValue(uint256 value);
    error JBSucker_ZeroBeneficiary();
    error JBSucker_ZeroERC20Token();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice A reasonable minimum gas limit for a basic cross-chain call. The minimum amount of gas required to call
    /// the `fromRemote` (successfully/safely) on the remote chain.
    uint32 public constant override MESSENGER_BASE_GAS_LIMIT = 300_000;

    /// @notice A reasonable minimum gas limit used when bridging ERC-20s. The minimum amount of gas required to
    /// (successfully/safely) perform a transfer on the remote chain.
    uint32 public constant override MESSENGER_ERC20_MIN_GAS_LIMIT = 200_000;

    /// @notice The message format version. Used to reject incompatible messages from remote chains.
    uint8 public constant MESSAGE_VERSION = 1;

    //*********************************************************************//
    // ------------------------- internal constants ----------------------- //
    //*********************************************************************//

    /// @notice The currency used for cross-chain surplus/balance normalization: ETH (native token).
    /// @dev Bridge messages always carry surplus and balance denominated in this currency at `_ETH_DECIMALS` precision.
    uint256 internal constant _ETH_CURRENCY = JBCurrencyIds.ETH;

    /// @notice The decimal precision used for cross-chain surplus/balance normalization: 18.
    uint8 internal constant _ETH_DECIMALS = 18;

    /// @notice The depth of the merkle tree used to store the outbox and inbox.
    uint32 internal constant _TREE_DEPTH = 32;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers for projects.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The project registry (ERC-721 ownership).
    IJBProjects public immutable override PROJECTS;

    /// @notice The project ID that receives the `toRemoteFee` payment. Typically the protocol project (ID 1).
    uint256 public immutable FEE_PROJECT_ID;

    /// @notice The sucker registry that manages the global `toRemoteFee`.
    IJBSuckerRegistry public immutable REGISTRY;

    /// @notice The contract that manages token minting and burning.
    IJBTokens public immutable override TOKENS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The address of this contract's deployer.
    address public override deployer;

    /// @notice The last known total token supply on the peer chain, updated each time a bridge message is received.
    /// @dev Used by data hooks to compute `effectiveTotalSupply = localSupply + sum(peerChainTotalSupply)` across all
    /// suckers, preventing cash out tax bypass on chains where a holder dominates the local supply.
    uint256 public peerChainTotalSupply;

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

    /// @notice The outbox merkle tree for a given token.
    /// @custom:param token The local terminal token to get the outbox for.
    mapping(address token => JBOutboxTree) internal _outboxOf;

    /// @notice Information about the token on the remote chain that the given token on the local chain is mapped to.
    /// @custom:param token The local terminal token to get the remote token for.
    mapping(address token => JBRemoteToken remoteToken) internal _remoteTokenFor;

    //*********************************************************************//
    // -------------------- private stored properties -------------------- //
    //*********************************************************************//

    /// @notice The ID of the project (on the local chain) that this sucker is associated with.
    uint256 private _localProjectId;

    /// @notice The last known project-wide surplus on the peer chain. Updated each time a bridge message is received.
    /// @dev The `currency` and `decimals` fields describe the denomination; `value` is the surplus amount.
    JBDenominatedAmount private _peerChainSurplus;

    /// @notice The last known total recorded balance on the peer chain. Updated each time a bridge message is received.
    /// @dev The `currency` and `decimals` fields describe the denomination; `value` is the balance amount.
    JBDenominatedAmount private _peerChainBalance;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param permissions A contract storing permissions.
    /// @param tokens A contract that manages token minting and burning.
    /// @param feeProjectId The project ID that receives the `toRemoteFee` payment (typically 1).
    /// @param registry The sucker registry that manages the global `toRemoteFee`.
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
        PROJECTS = directory.PROJECTS();
        TOKENS = tokens;
        FEE_PROJECT_ID = feeProjectId;
        REGISTRY = registry;

        // Make it so the singleton can't be initialized.
        _disableInitializers();

        // Sanity check: make sure the merkle lib uses the same tree depth.
        assert(MerkleLib.TREE_DEPTH == _TREE_DEPTH);
    }

    //*********************************************************************//
    // ------------------------ external views --------------------------- //
    //*********************************************************************//

    /// @notice The outstanding amount of tokens to be added to the project's balance by `claim`.
    /// @param token The local terminal token to get the amount to add to balance for.
    function amountToAddToBalanceOf(address token) public view override returns (uint256) {
        // Get the amount that is in this sucker to be bridged.
        return _balanceOf({token: token, addr: address(this)}) - _outboxOf[token].balance;
    }

    /// @notice The inbox merkle tree root for a given token.
    /// @param token The local terminal token to get the inbox for.
    function inboxOf(address token) external view returns (JBInboxTreeRoot memory) {
        return _inboxOf[token];
    }

    /// @notice Checks whether the specified token is mapped to a remote token.
    /// @param token The terminal token to check.
    /// @return A boolean which is `true` if the token is mapped to a remote token and `false` if it is not.
    function isMapped(address token) external view override returns (bool) {
        return _remoteTokenFor[token].addr != bytes32(0);
    }

    /// @notice Information about the token on the remote chain that the given token on the local chain is mapped to.
    /// @param token The local terminal token to get the remote token for.
    function outboxOf(address token) external view returns (JBOutboxTree memory) {
        return _outboxOf[token];
    }

    /// @notice Returns the chain on which the peer is located.
    /// @return chain ID of the peer.
    function peerChainId() external view virtual returns (uint256);

    /// @notice Information about the token on the remote chain that the given token on the local chain is mapped to.
    /// @param token The local terminal token to get the remote token for.
    function remoteTokenFor(address token) external view returns (JBRemoteToken memory) {
        return _remoteTokenFor[token];
    }

    //*********************************************************************//
    // ------------------------- public views ---------------------------- //
    //*********************************************************************//

    /// @notice The peer sucker on the remote chain, as a bytes32 for cross-VM compatibility.
    /// @dev Defaults to `_toBytes32(address(this))`, assuming deterministic cross-chain deployment via CREATE2. The
    /// deployer (`JBSuckerDeployer`) uses `salt = keccak256(abi.encodePacked(_msgSender(), salt))` to ensure
    /// sender-specific determinism. This assumption breaks if CREATE2 conditions differ across chains (e.g.,
    /// different factory nonces, different init code, or different deployer addresses). In such cases, subclasses
    /// must override this function to return the correct peer address (e.g., a Solana program/PDA address for
    /// EVM-SVM deployments). Note that overriding `peer()` is fully supported by the sucker implementation and
    /// off-chain infrastructure, but for revnets it breaks the assumption of matching configurations on both
    /// chains -- for this reason the default same-address behavior is preferred.
    function peer() public view virtual returns (bytes32) {
        return _toBytes32(address(this));
    }

    /// @notice The peer chain balance, converted from the source denomination to the requested currency and decimal
    /// precision using the local JBPrices oracle.
    /// @param decimals The decimal precision for the returned value.
    /// @param currency The currency to normalize to (e.g. `uint256(uint160(JBConstants.NATIVE_TOKEN))` for ETH).
    /// @return A `JBDenominatedAmount` with the converted value.
    function peerChainBalanceOf(uint256 decimals, uint256 currency) external view returns (JBDenominatedAmount memory) {
        return JBDenominatedAmount({
            value: _convertPeerValue({source: _peerChainBalance, decimals: decimals, currency: currency}),
            currency: uint32(currency),
            decimals: uint8(decimals)
        });
    }

    /// @notice The peer chain surplus, converted from the source denomination to the requested currency and decimal
    /// precision using the local JBPrices oracle.
    /// @param decimals The decimal precision for the returned value.
    /// @param currency The currency to normalize to (e.g. `uint256(uint160(JBConstants.NATIVE_TOKEN))` for ETH).
    /// @return A `JBDenominatedAmount` with the converted value.
    function peerChainSurplusOf(uint256 decimals, uint256 currency) external view returns (JBDenominatedAmount memory) {
        return JBDenominatedAmount({
            value: _convertPeerValue({source: _peerChainSurplus, decimals: decimals, currency: currency}),
            currency: uint32(currency),
            decimals: uint8(decimals)
        });
    }

    /// @notice The ID of the project (on the local chain) that this sucker is associated with.
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

        // The sucker will soon be considered deprecated, this functions only as a warning to users.
        if (block.timestamp < _deprecatedAfter - _maxMessagingDelay()) {
            return JBSuckerState.DEPRECATION_PENDING;
        }

        // The sucker will no longer send new roots to the pair, but it will accept new incoming roots.
        // Additionally it will let users exit here now that we can no longer send roots/tokens.
        if (block.timestamp < _deprecatedAfter) {
            return JBSuckerState.SENDING_DISABLED;
        }

        // The sucker is now in the final state of deprecation. It will no longer allow new roots.
        return JBSuckerState.DEPRECATED;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBSuckerExtended).interfaceId || interfaceId == type(IJBSucker).interfaceId
            || interfaceId == type(IJBPermissioned).interfaceId || super.supportsInterface(interfaceId);
    }

    //*********************************************************************//
    // ------------------------ internal views --------------------------- //
    //*********************************************************************//

    /// @notice Helper to get the `addr`'s balance for a given `token`.
    /// @param token The token to get the balance for.
    /// @param addr The address to get the `token` balance of.
    /// @return balance The address' `token` balance.
    function _balanceOf(address token, address addr) internal view returns (uint256 balance) {
        if (token == JBConstants.NATIVE_TOKEN) {
            return addr.balance;
        }

        // slither-disable-next-line calls-loop
        return IERC20(token).balanceOf(addr);
    }

    /// @notice Returns the peer address as an EVM address.
    /// @return The peer address.
    function _peerAddress() internal view returns (address) {
        return _toAddress(peer());
    }

    /// @notice Returns all terminals for a project.
    /// @param _projectId The project ID.
    /// @return The terminals.
    function _terminalsOf(uint256 _projectId) internal view returns (IJBTerminal[] memory) {
        return DIRECTORY.terminalsOf(_projectId);
    }

    /// @notice Looks up the primary terminal for a project/token pair via the directory.
    /// @param _projectId The project ID.
    /// @param token The token address.
    /// @return The primary terminal.
    function _primaryTerminalOf(uint256 _projectId, address token) internal view returns (IJBTerminal) {
        return DIRECTORY.primaryTerminalOf({projectId: _projectId, token: token});
    }

    /// @notice Builds a hash as they are stored in the merkle tree.
    /// @param projectTokenCount The number of project tokens being cashed out.
    /// @param terminalTokenAmount The amount of terminal tokens being reclaimed by the cash out.
    /// @param beneficiary The beneficiary which will receive the project tokens (bytes32 for cross-VM compatibility).
    function _buildTreeHash(
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary
    )
        internal
        pure
        returns (bytes32 hash)
    {
        // All three arguments are 32 bytes — hash from free memory to avoid abi.encode allocation overhead.
        // forge-lint: disable-next-line(asm-keccak256)
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, projectTokenCount)
            mstore(add(ptr, 0x20), terminalTokenAmount)
            mstore(add(ptr, 0x40), beneficiary)
            hash := keccak256(ptr, 0x60)
        }
    }

    /// @notice Build ETH-denominated aggregate surplus and balance across all terminals for the project.
    /// @dev Delegates to `JBSuckerLib.buildETHAggregate` (deployed library, called via DELEGATECALL) to reduce
    /// child contract bytecode.
    /// @param _projectId The project ID to build the aggregate for.
    /// @return ethSurplus The total surplus denominated in ETH at 18 decimals.
    /// @return ethBalance The total balance denominated in ETH at 18 decimals.
    // forge-lint: disable-next-line(mixed-case-function)
    function _buildETHAggregate(uint256 _projectId) internal view returns (uint256 ethSurplus, uint256 ethBalance) {
        return JBSuckerLib.buildETHAggregate({directory: DIRECTORY, projectId: _projectId});
    }

    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }

    /// @notice Convert a peer chain snapshot value to the requested currency and decimal precision.
    /// @dev Delegates to `JBSuckerLib.convertPeerValue` (deployed library, called via DELEGATECALL) to reduce
    /// child contract bytecode.
    /// @param source The peer chain snapshot containing value, currency, and decimals.
    /// @param decimals The target decimal precision.
    /// @param currency The target currency (e.g. `uint256(uint160(JBConstants.NATIVE_TOKEN))` for ETH).
    /// @return converted The converted value.
    function _convertPeerValue(
        JBDenominatedAmount memory source,
        uint256 decimals,
        uint256 currency
    )
        internal
        view
        returns (uint256 converted)
    {
        return JBSuckerLib.convertPeerValue({
            directory: DIRECTORY, projectId: projectId(), source: source, decimals: decimals, currency: currency
        });
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

    /// @notice Allow sucker implementations to add/override mapping rules to suite their specific needs.
    function _validateTokenMapping(JBTokenMapping calldata map) internal pure virtual {
        bool isNative = map.localToken == JBConstants.NATIVE_TOKEN;

        // If the token being mapped is the native token, the `remoteToken` must also be the native token.
        // The native token can also be mapped to the 0 address, which is used to disable native token bridging.
        if (isNative && map.remoteToken != _toBytes32(JBConstants.NATIVE_TOKEN) && map.remoteToken != bytes32(0)) {
            revert JBSucker_InvalidNativeRemoteAddress(map.remoteToken);
        }

        // Enforce a reasonable minimum gas limit for bridging. A minimum which is too low could lead to the loss of
        // funds.
        if (map.minGas < MESSENGER_ERC20_MIN_GAS_LIMIT && !isNative) {
            revert JBSucker_BelowMinGas(map.minGas, MESSENGER_ERC20_MIN_GAS_LIMIT);
        }
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Performs multiple claims.
    /// @param claims A list of claims to perform (including the terminal token, merkle tree leaf, and proof for each
    /// claim).
    function claim(JBClaim[] calldata claims) external override {
        // Claim each.
        for (uint256 i; i < claims.length;) {
            claim(claims[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice `JBClaim` project tokens which have been bridged from the remote chain for their beneficiary.
    /// @param claimData The terminal token, merkle tree leaf, and proof for the claim.
    function claim(JBClaim calldata claimData) public override {
        // Attempt to validate the proof against the inbox tree for the terminal token.
        _validate({
            projectTokenCount: claimData.leaf.projectTokenCount,
            terminalToken: claimData.token,
            terminalTokenAmount: claimData.leaf.terminalTokenAmount,
            beneficiary: claimData.leaf.beneficiary,
            index: claimData.leaf.index,
            leaves: claimData.proof
        });

        emit Claimed({
            beneficiary: claimData.leaf.beneficiary,
            token: claimData.token,
            projectTokenCount: claimData.leaf.projectTokenCount,
            terminalTokenAmount: claimData.leaf.terminalTokenAmount,
            index: claimData.leaf.index,
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
        // slither-disable-next-line calls-loop
        uint256 _projectId = projectId();

        _requirePermissionFrom({
            account: PROJECTS.ownerOf(_projectId), projectId: _projectId, permissionId: JBPermissionIds.SUCKER_SAFETY
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

        emit EmergencyHatchOpened(tokens, _msgSender());
    }

    /// @notice Lets user exit on the chain they deposited in a scenario where the bridge is no longer functional.
    /// @param claimData The terminal token, merkle tree leaf, and proof for the claim
    function exitThroughEmergencyHatch(JBClaim calldata claimData) external override {
        // Does all the needed validation to ensure that the claim is valid *and* that claiming through the emergency
        // hatch is allowed.
        _validateForEmergencyExit({
            projectTokenCount: claimData.leaf.projectTokenCount,
            terminalToken: claimData.token,
            terminalTokenAmount: claimData.leaf.terminalTokenAmount,
            beneficiary: claimData.leaf.beneficiary,
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

    /// @notice Receive a merkle root for a terminal token from the remote project.
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
    /// @param root The merkle root, token, and amount being received.
    function fromRemote(JBMessageRoot calldata root) external payable {
        // Make sure that the message came from our peer.
        // Use msg.sender (not _msgSender()) because bridge messengers never use ERC2771 meta-transactions.
        // Using _msgSender() would allow a trusted forwarder to spoof the bridge messenger address via the
        // ERC-2771 calldata suffix.
        if (!_isRemotePeer(msg.sender)) {
            revert JBSucker_NotPeer(_toBytes32(msg.sender));
        }

        // Validate the message version to reject incompatible messages.
        if (root.version != MESSAGE_VERSION) {
            revert JBSucker_InvalidMessageVersion(root.version, MESSAGE_VERSION);
        }

        // By design, this function accepts roots for unmapped tokens. Claims against those roots will
        // fail at the token mapping lookup. Rejecting at receive time would permanently lose bridged tokens. Accepting
        // allows future token mapping to enable claims.
        //
        // Convert the remote token bytes32 to a local address for inbox lookup.
        address localToken = _toAddress(root.token);

        // Get the inbox in storage.
        JBInboxTreeRoot storage inbox = _inboxOf[localToken];

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

            // Update the peer chain's known total supply for cross-chain tax calculations.
            // Only update if the message includes supply info (non-zero) to be safe with edge cases.
            if (root.sourceTotalSupply != 0) {
                peerChainTotalSupply = root.sourceTotalSupply;
            }

            // Store the surplus and balance snapshots from the source chain.
            _peerChainSurplus = JBDenominatedAmount({
                value: root.sourceSurplus, currency: uint32(root.sourceCurrency), decimals: root.sourceDecimals
            });
            _peerChainBalance = JBDenominatedAmount({
                value: root.sourceBalance, currency: uint32(root.sourceCurrency), decimals: root.sourceDecimals
            });

            emit NewInboxTreeRoot({
                token: localToken, nonce: root.remoteRoot.nonce, root: root.remoteRoot.root, caller: _msgSender()
            });
        } else {
            // Emit an event when a root is rejected due to a stale (non-increasing) nonce.
            // This aids off-chain monitoring in detecting out-of-order or duplicate deliveries.
            emit StaleRootRejected({token: localToken, receivedNonce: root.remoteRoot.nonce, currentNonce: inbox.nonce});
        }
    }

    /// @notice Initializes the sucker with the project ID and peer address.
    /// @param _projectId The ID of the project (on the local chain) that this sucker is associated with.
    function initialize(uint256 _projectId) public initializer {
        // slither-disable-next-line missing-zero-check
        _localProjectId = _projectId;
        deployer = _msgSender();
    }

    /// @notice Map an ERC-20 token on the local chain to an ERC-20 token on the remote chain, allowing that token to be
    /// bridged.
    /// @param map The local and remote terminal token addresses to map, and minimum amount/gas limits for bridging
    /// them.
    function mapToken(JBTokenMapping calldata map) public payable override {
        _mapToken({map: map, transportPaymentValue: msg.value});
    }

    /// @notice Map multiple ERC-20 tokens on the local chain to ERC-20 tokens on the remote chain, allowing those
    /// tokens to be bridged.
    /// @param maps A list of local and remote terminal token addresses to map, and minimum amount/gas limits for
    /// bridging them.
    function mapTokens(JBTokenMapping[] calldata maps) external payable override {
        uint256 numberToDisable;

        // Loop over the number of mappings and increase numberToDisable to correctly set transportPaymentValue.
        // Note: if all mappings are enable-only (no disables), `numberToDisable` stays 0 and `transportPaymentValue`
        // is set to 0 for each call. Any ETH sent with the transaction is refunded after the second loop.
        for (uint256 h; h < maps.length;) {
            JBOutboxTree storage _outbox = _outboxOf[maps[h].localToken];
            if (maps[h].remoteToken == bytes32(0) && _outbox.numberOfClaimsSent != _outbox.tree.count) {
                numberToDisable++;
            }
            unchecked {
                ++h;
            }
        }

        // Perform each token mapping.
        for (uint256 i; i < maps.length;) {
            // slither-disable-next-line msg-value-loop
            _mapToken({map: maps[i], transportPaymentValue: numberToDisable > 0 ? msg.value / numberToDisable : 0});
            unchecked {
                ++i;
            }
        }

        // If no tokens were disabled, the full `msg.value` is unused — refund it.
        if (numberToDisable == 0) {
            if (msg.value > 0) {
                (bool _ok,) = _msgSender().call{value: msg.value}("");
                if (!_ok) revert JBSucker_RefundFailed();
            }
        } else {
            // Refund any remainder from integer division so dust wei isn't stuck in the contract.
            uint256 remainder = msg.value % numberToDisable;
            if (remainder > 0) {
                // Best-effort refund — don't revert if caller can't accept ETH.
                // slither-disable-next-line low-level-calls,unchecked-lowlevel
                (bool _ok,) = _msgSender().call{value: remainder}("");
                _ok; // Silence unused-variable warning; failure is intentionally ignored.
            }
        }
    }

    /// @notice Prepare project tokens and the cash out amount backing them to be bridged to the remote chain.
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
    /// less
    /// than this, the transaction will revert.
    /// @param token The address of the terminal token to cash out for.
    function prepare(
        uint256 projectTokenCount,
        bytes32 beneficiary,
        uint256 minTokensReclaimed,
        address token
    )
        external
        override
    {
        // Make sure the beneficiary is not the zero address, as this would revert when minting on the remote chain.
        if (beneficiary == bytes32(0)) {
            revert JBSucker_ZeroBeneficiary();
        }

        // Get the project's token.
        IERC20 projectToken = IERC20(address(TOKENS.tokenOf(projectId())));
        if (address(projectToken) == address(0)) {
            revert JBSucker_ZeroERC20Token();
        }

        // Make sure that the token is mapped to a remote token.
        if (!_remoteTokenFor[token].enabled) {
            revert JBSucker_TokenNotMapped(token);
        }

        // Make sure that the sucker still allows sending new messaged.
        JBSuckerState deprecationState = state();
        if (deprecationState == JBSuckerState.DEPRECATED || deprecationState == JBSuckerState.SENDING_DISABLED) {
            revert JBSucker_Deprecated();
        }

        // Transfer the tokens to this contract.
        // slither-disable-next-line reentrancy-events,reentrancy-benign
        projectToken.safeTransferFrom({from: _msgSender(), to: address(this), value: projectTokenCount});

        // Cash out the tokens.
        // slither-disable-next-line reentrancy-events,reentrancy-benign
        uint256 terminalTokenAmount = _pullBackingAssets({
            projectToken: projectToken, count: projectTokenCount, token: token, minTokensReclaimed: minTokensReclaimed
        });

        // Insert the item into the outbox tree for the terminal `token`.
        _insertIntoTree({
            projectTokenCount: projectTokenCount,
            token: token,
            terminalTokenAmount: terminalTokenAmount,
            beneficiary: beneficiary
        });
    }

    /// @notice Set or remove the time after which this sucker will be deprecated, once deprecated the sucker will no
    /// longer be functional and it will let all users exit.
    /// @param timestamp The time after which the sucker will be deprecated. Or `0` to remove the upcoming deprecation.
    function setDeprecation(uint40 timestamp) external override {
        // As long as the sucker has not started letting users withdrawal, its deprecation time can be
        // extended/shortened.
        JBSuckerState deprecationState = state();
        if (deprecationState == JBSuckerState.DEPRECATED || deprecationState == JBSuckerState.SENDING_DISABLED) {
            revert JBSucker_Deprecated();
        }

        // slither-disable-next-line calls-loop
        uint256 _projectId = projectId();

        // The caller must be the project owner or have the `SET_SUCKER_DEPRECATION` permission from them.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(_projectId),
            projectId: _projectId,
            permissionId: JBPermissionIds.SET_SUCKER_DEPRECATION
        });

        // This is the earliest time for when the sucker can be considered deprecated.
        // There is a mandatory delay to allow for remaining messages to be received.
        // This should be called on both sides of the suckers, preferably with a matching timestamp.
        uint256 nextEarliestDeprecationTime = block.timestamp + _maxMessagingDelay();

        // The deprecation can be entirely disabled *or* it has to be later than the earliest possible time.
        if (timestamp != 0 && timestamp < nextEarliestDeprecationTime) {
            revert JBSucker_DeprecationTimestampTooSoon(timestamp, nextEarliestDeprecationTime);
        }

        deprecatedAfter = timestamp;
        emit DeprecationTimeUpdated(timestamp, _msgSender());
    }

    /// @notice Bridge the project tokens, cashed out funds, and beneficiary information for a given `token` to the
    /// remote
    /// chain.
    /// @dev This sends the outbox root for the specified `token` to the remote chain.
    /// @dev Fee payment failure handling: The registry fee payment uses a best-effort pattern (try/catch). If the
    /// fee project's terminal doesn't exist or the `pay` call reverts, the fee ETH is retained by this contract
    /// (not added back to `transportPayment`) to avoid reverting the entire transaction. This preserves
    /// `transportPayment = msg.value - fee`, which is critical for zero-cost bridges (OP, Base, Celo, Arb L2->L1)
    /// that revert on non-zero transport payment. The fee amount is typically small (max 0.001 ETH).
    /// @dev Retained fee ETH is absorbed by future native token claims. Because `amountToAddToBalanceOf` computes
    /// `_balanceOf(token, address(this)) - _outboxOf[token].balance`, any extra ETH in the contract (including
    /// retained fees) increases the claimable amount and will be forwarded to the project's terminal via
    /// `_addToBalance` when the next native token claim is processed. This is by design — reverting on fee
    /// failure would block all bridging.
    /// @param token The terminal token being bridged.
    function toRemote(address token) external payable override {
        JBRemoteToken memory remoteToken = _remoteTokenFor[token];

        // Ensure that the token does not have an emergency hatch enabled.
        if (remoteToken.emergencyHatch) {
            revert JBSucker_TokenHasInvalidEmergencyHatchState(token);
        }

        // Revert if nothing has changed since the last toRemote() call.
        JBOutboxTree storage outbox = _outboxOf[token];
        if (outbox.balance == 0 && outbox.tree.count == outbox.numberOfClaimsSent) {
            revert JBSucker_NothingToSend();
        }

        // Read the fee from the registry.
        uint256 _toRemoteFee = REGISTRY.toRemoteFee();

        // Deduct the fee from msg.value, paying it into the fee project.
        if (msg.value < _toRemoteFee) {
            revert JBSucker_InsufficientMsgValue(msg.value, _toRemoteFee);
        }
        uint256 transportPayment = msg.value - _toRemoteFee;

        // Pay the fee into the fee project. The caller gets fee project tokens in return.
        // Best-effort: if the terminal doesn't exist or the pay call reverts, proceed without fee.
        // NOTE: On failure, the fee ETH is retained by this contract (not added back to transportPayment)
        // to avoid DoS on zero-cost bridges (OP, Base, Celo, Arbitrum L2→L1) that revert on non-zero
        // transportPayment.
        IJBTerminal terminal = _primaryTerminalOf({_projectId: FEE_PROJECT_ID, token: JBConstants.NATIVE_TOKEN});
        if (address(terminal) != address(0)) {
            // slither-disable-next-line unused-return,reentrancy-events
            try terminal.pay{value: _toRemoteFee}({
                projectId: FEE_PROJECT_ID,
                token: JBConstants.NATIVE_TOKEN,
                amount: _toRemoteFee,
                beneficiary: _msgSender(),
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            }) returns (
                uint256
            ) {}
                catch {
                // Fee payment failed — fee ETH stays in this contract, transportPayment unchanged.
                // There is no dedicated sweep path for this retained ETH. This is an accepted tradeoff
                // to avoid DoS on zero-cost bridges that revert on non-zero transport payment.
            }
        }
        // If no terminal exists, fee ETH stays in this contract. transportPayment is already correct.
        // This retained ETH is absorbed by future native token claims via `amountToAddToBalanceOf`.

        // Send the merkle root to the remote chain.
        _sendRoot({transportPayment: transportPayment, token: token, remoteToken: remoteToken});
    }

    //*********************************************************************//
    // ---------------------------- receive  ----------------------------- //
    //*********************************************************************//

    /// @notice Accepts incoming native token (ETH) transfers.
    /// @dev This receive function is intentionally unrestricted. It must accept ETH from multiple sources:
    /// - Bridge contracts (e.g., Optimism's StandardBridge, Arbitrum's gateway) delivering bridged native tokens.
    /// - WETH contracts during unwrapping (e.g., CCIP sucker unwraps WETH via `withdraw()` which sends ETH here).
    /// - Terminals returning native tokens during `cashOutTokensOf` (backing asset pulls).
    /// @dev Restricting this to known senders would risk breaking bridge integrations, as bridge contracts may change
    /// addresses or use proxy patterns. The sucker's accounting (`_outboxOf[token].balance` and
    /// `amountToAddToBalanceOf`) already tracks expected native token amounts, so excess ETH sent here does not
    /// create a double-spend risk -- it would simply increase the amount to add to balance for the project.
    receive() external payable {}

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Adds funds to the projects balance.
    /// @param token The terminal token to add to the project's balance.
    /// @param amount The amount of terminal tokens to add to the project's balance.
    /// @param cachedProjectId The cached project ID to avoid redundant storage reads.
    function _addToBalance(address token, uint256 amount, uint256 cachedProjectId) internal virtual {
        // Make sure that the current `amountToAddToBalance` is greater than or equal to the amount being added.
        uint256 addableAmount = amountToAddToBalanceOf(token);
        if (amount > addableAmount) {
            revert JBSucker_InsufficientBalance(amount, addableAmount);
        }

        // Get the project's primary terminal for the token.
        // slither-disable-next-line calls-loop
        IJBTerminal terminal = _primaryTerminalOf({_projectId: cachedProjectId, token: token});

        // slither-disable-next-line incorrect-equality
        if (address(terminal) == address(0)) revert JBSucker_NoTerminalForToken(cachedProjectId, token);

        // Perform the `addToBalance`.
        if (token != JBConstants.NATIVE_TOKEN) {
            // slither-disable-next-line calls-loop
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));

            SafeERC20.forceApprove({token: IERC20(token), spender: address(terminal), value: amount});

            // slither-disable-next-line calls-loop
            terminal.addToBalanceOf({
                projectId: cachedProjectId,
                token: token,
                amount: amount,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: ""
            });

            // Sanity check: make sure we transfer the full amount.
            // slither-disable-next-line calls-loop,incorrect-equality
            assert(IERC20(token).balanceOf(address(this)) == balanceBefore - amount);
        } else {
            // If the token is the native token, use `msg.value`.
            // slither-disable-next-line arbitrary-send-eth,calls-loop
            terminal.addToBalanceOf{value: amount}({
                projectId: cachedProjectId,
                token: token,
                amount: amount,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: ""
            });
        }
    }

    /// @notice The action(s) to perform after a user has succesfully proven their claim.
    /// @param terminalToken The terminal token being sucked.
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

        // Cast the bytes32 beneficiary to an EVM address for the local mint.
        address beneficiaryAddress = _toAddress(beneficiary);

        // Known limitation: if the destination chain's controller is misconfigured or the project
        // doesn't exist, this call will revert, permanently blocking claims. This is a deployment/configuration
        // concern, not a contract bug. Projects must ensure controller and project exist on all destination chains
        // before enabling suckers.
        //
        // Mint the project tokens for the beneficiary.
        // slither-disable-next-line calls-loop,unused-return
        IJBController(address(DIRECTORY.controllerOf(cachedProjectId)))
            .mintTokensOf({
                projectId: cachedProjectId,
                tokenCount: projectTokenAmount,
                beneficiary: beneficiaryAddress,
                memo: "",
                useReservedPercent: false
            });
    }

    /// @notice Inserts a new leaf into the outbox merkle tree for the specified `token`.
    /// @param projectTokenCount The amount of project tokens being cashed out.
    /// @param token The terminal token being cashed out for.
    /// @param terminalTokenAmount The amount of terminal tokens reclaimed by cashing out.
    /// @param beneficiary The beneficiary of the project tokens on the remote chain (bytes32 for cross-VM
    /// compatibility).
    function _insertIntoTree(
        uint256 projectTokenCount,
        address token,
        uint256 terminalTokenAmount,
        bytes32 beneficiary
    )
        internal
    {
        // Guard against amounts that would overflow uint128 on SVM (INTEROP-5).
        if (terminalTokenAmount > type(uint128).max) revert JBSucker_AmountExceedsUint128(terminalTokenAmount);
        if (projectTokenCount > type(uint128).max) revert JBSucker_AmountExceedsUint128(projectTokenCount);
        // Build a hash based on the token amounts and the beneficiary.
        bytes32 hashed = _buildTreeHash({
            projectTokenCount: projectTokenCount, terminalTokenAmount: terminalTokenAmount, beneficiary: beneficiary
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
            root: outbox.tree.root(),
            projectTokenCount: projectTokenCount,
            terminalTokenAmount: terminalTokenAmount,
            caller: _msgSender()
        });
    }

    /// @notice Checks if the `sender` (`_msgSender`) is a valid representative of the remote peer.
    /// @param sender The message's sender.
    function _isRemotePeer(address sender) internal virtual returns (bool valid);

    /// @notice Map an ERC-20 token on the local chain to an ERC-20 token on the remote chain, allowing that token to be
    /// bridged or disabled.
    /// @dev Once a token has outbox tree entries (`_outboxOf[token].tree.count != 0`), it cannot be remapped to a
    /// different remote token -- it can only be disabled by mapping to `address(0)`, which triggers a final root
    /// flush to settle outstanding claims. This permanence prevents double-spending: if a remapping were allowed
    /// after outbox activity, the same local funds could be claimed against two different remote tokens. A
    /// misconfigured mapping therefore requires deploying a new sucker. Re-enabling a previously disabled mapping
    /// (back to the same remote token) is supported.
    /// @param map The local and remote terminal token addresses to map, and minimum amount/gas limits for bridging
    /// them.
    /// @param transportPaymentValue The amount of `msg.value` to send for the token mapping.
    function _mapToken(JBTokenMapping calldata map, uint256 transportPaymentValue) internal {
        address token = map.localToken;
        JBRemoteToken memory currentMapping = _remoteTokenFor[token];

        // Once the emergency hatch for a token is enabled it can't be disabled.
        if (currentMapping.emergencyHatch) {
            revert JBSucker_TokenHasInvalidEmergencyHatchState(token);
        }

        // Validate the token mapping according to the rules of the sucker.
        _validateTokenMapping(map);

        // Reference the project id.
        uint256 _projectId = projectId();

        // slither-disable-next-line calls-loop
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(_projectId), projectId: _projectId, permissionId: JBPermissionIds.MAP_SUCKER_TOKEN
        });

        // Make sure that the token does not get remapped to another remote token.
        // As this would cause the funds for this token to be double spendable on the other side.
        // It should not be possible to cause any issues even without this check
        // a bridge *should* never accept such a request. This is mostly a sanity check.
        if (
            currentMapping.addr != bytes32(0) && currentMapping.addr != map.remoteToken && map.remoteToken != bytes32(0)
                && _outboxOf[token].tree.count != 0
        ) {
            revert JBSucker_TokenAlreadyMapped(token, currentMapping.addr);
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
            _sendRoot({transportPayment: transportPaymentValue, token: token, remoteToken: currentMapping});
        }

        // Update the token mapping.
        _remoteTokenFor[token] = JBRemoteToken({
            enabled: map.remoteToken != bytes32(0),
            emergencyHatch: false,
            minGas: map.minGas,
            // This is done so that a token can be disabled and then enabled again
            // while ensuring the remoteToken never changes (unless it hasn't been used yet)
            addr: map.remoteToken == bytes32(0) ? currentMapping.addr : map.remoteToken
        });
    }

    /// @notice What is the maximum time it takes for a message to be received on the other side.
    /// @dev Be sure to keep in mind if a message fails having to retry and the time it takes to retry.
    /// @return The maximum time it takes for a message to be received on the other side.
    function _maxMessagingDelay() internal pure virtual returns (uint40) {
        return 14 days;
    }

    /// @notice Cash out project tokens for terminal tokens.
    /// @param projectToken The project token being cashed out.
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

        uint256 _projectId = projectId();

        // Get the project's primary terminal for `token`. We will cash out from this terminal.
        IJBCashOutTerminal terminal =
            IJBCashOutTerminal(address(_primaryTerminalOf({_projectId: _projectId, token: token})));

        // If the project doesn't have a primary terminal for `token`, revert.
        if (address(terminal) == address(0)) {
            revert JBSucker_NoTerminalForToken(_projectId, token);
        }

        // Cash out the tokens.
        uint256 balanceBefore = _balanceOf({token: token, addr: address(this)});
        reclaimedAmount = terminal.cashOutTokensOf({
            holder: address(this),
            projectId: _projectId,
            cashOutCount: count,
            tokenToReclaim: token,
            minTokensReclaimed: minTokensReclaimed,
            beneficiary: payable(address(this)),
            metadata: bytes("")
        });

        // Sanity check to make sure we received the expected amount.
        // This prevents malicious terminals from reporting amounts other than what they send.
        // slither-disable-next-line incorrect-equality
        assert(reclaimedAmount == _balanceOf({token: token, addr: address(this)}) - balanceBefore);
    }

    /// @notice Send the outbox root for the specified token to the remote peer.
    /// @dev The call may have a `transportPayment` for bridging native tokens. Require it to be `0` if it is not
    /// needed. Make sure if a value being paid to the bridge is expected to revert if the given value is `0`.
    /// @param transportPayment the amount of `msg.value` that is going to get paid for sending this message. (usually
    /// derived from `msg.value`)
    /// @param token The terminal token to bridge the merkle tree of.
    /// @param remoteToken The remote token which the `token` is mapped to.
    function _sendRoot(uint256 transportPayment, address token, JBRemoteToken memory remoteToken) internal virtual {
        // Ensure the token is mapped to an address on the remote chain.
        if (remoteToken.addr == bytes32(0)) revert JBSucker_TokenNotMapped(token);

        // Make sure that the sucker still allows sending new messaged.
        JBSuckerState deprecationState = state();
        if (deprecationState == JBSuckerState.DEPRECATED || deprecationState == JBSuckerState.SENDING_DISABLED) {
            revert JBSucker_Deprecated();
        }

        // Get the outbox in storage.
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
        uint256 amount = outbox.balance;
        delete outbox.balance;

        // Increment the outbox tree's nonce.
        uint64 nonce = ++outbox.nonce;
        bytes32 root = outbox.tree.root();

        // Update the numberOfClaimsSent to the current count of the tree.
        // This is used as in the fallback to allow users to withdraw locally if the bridge is reverting.
        outbox.numberOfClaimsSent = uint192(count);
        uint256 index = count - 1;

        // Emit an event for the relayers to watch for.
        emit RootToRemote({root: root, token: token, index: index, nonce: nonce, caller: _msgSender()});

        // Get the current local total supply (including reserved tokens) and the ETH-denominated aggregate
        // surplus/balance to include in the bridge message. The peer chain uses these to track cross-chain supply,
        // surplus, and balance for cash out and data hook calculations.
        uint256 localTotalSupply;
        uint256 ethSurplus;
        uint256 ethBalance;
        {
            uint256 _projectId = projectId();
            // Get the controller and verify it implements IJBController via ERC165 before querying supply.
            // slither-disable-next-line calls-loop
            try DIRECTORY.controllerOf(_projectId) returns (IERC165 controllerIERC165) {
                if (address(controllerIERC165) != address(0)) {
                    // slither-disable-next-line calls-loop
                    try controllerIERC165.supportsInterface(type(IJBController).interfaceId) returns (bool supported) {
                        if (supported) {
                            // slither-disable-next-line calls-loop
                            localTotalSupply = IJBController(address(controllerIERC165))
                                .totalTokenSupplyWithReservedTokensOf(_projectId);
                        }
                    } catch {}
                }
            } catch {}

            (ethSurplus, ethBalance) = _buildETHAggregate(_projectId);
        }

        // Build the message to be sent. Surplus and balance are denominated in _ETH_CURRENCY at _ETH_DECIMALS.
        JBMessageRoot memory message = JBMessageRoot({
            version: MESSAGE_VERSION,
            token: remoteToken.addr,
            amount: amount,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: root}),
            sourceTotalSupply: localTotalSupply,
            sourceCurrency: _ETH_CURRENCY,
            sourceDecimals: _ETH_DECIMALS,
            sourceSurplus: ethSurplus,
            sourceBalance: ethBalance
        });

        // Execute the chain/sucker specific logic for transferring the assets and communicating the root.
        _sendRootOverAMB({
            transportPayment: transportPayment,
            index: index,
            token: token,
            amount: amount,
            remoteToken: remoteToken,
            message: message
        });
    }

    /// @notice Performs the logic to send a message to the peer over the AMB.
    /// @dev This is chain/sucker/bridge specific logic.
    /// @param transportPayment The amount of `msg.value` that is going to get paid for sending this message.
    /// @param index The index of the most recent message that is part of the root.
    /// @param token The terminal token being bridged.
    /// @param amount The amount of terminal tokens being bridged.
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
    /// @param index The index of the leaf being proved in the terminal token's inbox tree.
    /// @param leaves The leaves that prove that the leaf at the `index` is in the tree (i.e. the merkle branch that the
    /// leaf is on).
    function _validate(
        uint256 projectTokenCount,
        address terminalToken,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        uint256 index,
        bytes32[_TREE_DEPTH] calldata leaves
    )
        internal
    {
        // Ensure the index is within tree bounds (max 2^TREE_DEPTH - 1).
        if (index >= (1 << _TREE_DEPTH)) revert JBSucker_IndexOutOfRange(index);

        // Make sure the leaf has not already been executed.
        if (_executedFor[terminalToken].get(index)) {
            revert JBSucker_LeafAlreadyExecuted(terminalToken, index);
        }

        // Register the leaf as executed to prevent double-spending.
        _executedFor[terminalToken].set(index);

        // Calculate the root based on the leaf, the branch, and the index.
        // Compare to the current root, Revert if they do not match.
        _validateBranchRoot({
            expectedRoot: _inboxOf[terminalToken].root,
            projectTokenCount: projectTokenCount,
            terminalTokenAmount: terminalTokenAmount,
            beneficiary: beneficiary,
            index: index,
            leaves: leaves
        });
    }

    /// @notice Validates a branch root against the expected root.
    /// @dev This is a virtual function to allow a tests to override the behavior, it should never be overwritten
    /// otherwise.
    function _validateBranchRoot(
        bytes32 expectedRoot,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        uint256 index,
        bytes32[_TREE_DEPTH] calldata leaves
    )
        internal
        virtual
    {
        // Calculate the root based on the leaf, the branch, and the index.
        bytes32 root = MerkleLib.branchRoot({
            _item: _buildTreeHash({
                projectTokenCount: projectTokenCount, terminalTokenAmount: terminalTokenAmount, beneficiary: beneficiary
            }),
            _branch: leaves,
            _index: index
        });

        // Compare to the current root, Revert if they do not match.
        if (root != expectedRoot) {
            revert JBSucker_InvalidProof(root, expectedRoot);
        }
    }

    /// @notice Validates a leaf as being in the outbox merkle tree and not being send over the amb, and registers the
    /// leaf as executed (to prevent double-spending).
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
    /// @param index The index of the leaf being proved in the terminal token's inbox tree.
    /// @param leaves The leaves that prove that the leaf at the `index` is in the tree (i.e. the merkle branch that the
    /// leaf is on).
    function _validateForEmergencyExit(
        uint256 projectTokenCount,
        address terminalToken,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        uint256 index,
        bytes32[_TREE_DEPTH] calldata leaves
    )
        internal
    {
        // Ensure the index is within tree bounds (max 2^TREE_DEPTH - 1).
        if (index >= (1 << _TREE_DEPTH)) revert JBSucker_IndexOutOfRange(index);

        // Make sure that the emergencyHatch is enabled for the token.
        JBSuckerState deprecationState = state();
        if (
            deprecationState != JBSuckerState.DEPRECATED && deprecationState != JBSuckerState.SENDING_DISABLED
                && !_remoteTokenFor[terminalToken].emergencyHatch
        ) {
            revert JBSucker_TokenHasInvalidEmergencyHatchState(terminalToken);
        }

        // Check that this claim is within the bounds of who can claim.
        // If the root that this leaf is in was already send then we can not let the user claim here.
        // As it could have also been received by the peer sucker, which would then let the user claim on each side.
        // NOTE: We are comparing the *count* and the *index*, so `count - 1` is the last index that was sent.
        // A count of 0 means that no root has ever been send for this token, so everyone can claim.
        JBOutboxTree storage outboxOfToken = _outboxOf[terminalToken];
        if (outboxOfToken.numberOfClaimsSent != 0 && outboxOfToken.numberOfClaimsSent - 1 >= index) {
            revert JBSucker_LeafAlreadyExecuted(terminalToken, index);
        }

        {
            // We re-use the same `_executedFor` mapping but we use a different slot.
            // We can not use the regular mapping, since this claim is done for tokens being send from here to the pair.
            // where the regular mapping is for tokens that were send on the pair to here. Even though these may seem
            // similar they are actually completely unrelated.
            address emergencyExitAddress = address(bytes20(keccak256(abi.encode(terminalToken))));

            // Make sure the leaf has not already been executed.
            if (_executedFor[emergencyExitAddress].get(index)) {
                revert JBSucker_LeafAlreadyExecuted(terminalToken, index);
            }

            // Register the leaf as executed to prevent double-spending.
            _executedFor[emergencyExitAddress].set(index);
        }

        // Calculate the root based on the leaf, the branch, and the index.
        // Compare to the current root, Revert if they do not match.
        _validateBranchRoot({
            expectedRoot: _outboxOf[terminalToken].tree.root(),
            projectTokenCount: projectTokenCount,
            terminalTokenAmount: terminalTokenAmount,
            beneficiary: beneficiary,
            index: index,
            leaves: leaves
        });
    }
}
