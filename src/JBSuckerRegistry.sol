// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {JBSuckerState} from "./enums/JBSuckerState.sol";
import {IJBSucker} from "./interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "./interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";
import {JBChainAccounting} from "./structs/JBChainAccounting.sol";
import {JBPeerChainContext} from "./structs/JBPeerChainContext.sol";
import {JBPeerChainValue} from "./structs/JBPeerChainValue.sol";
import {JBSuckerDeployerConfig} from "./structs/JBSuckerDeployerConfig.sol";
import {JBSuckersPair} from "./structs/JBSuckersPair.sol";
import {PeerAccountScratch} from "./structs/PeerAccountScratch.sol";
import {PeerValueScratch} from "./structs/PeerValueScratch.sol";
import {RemoteValueParams} from "./structs/RemoteValueParams.sol";

/// @notice The canonical registry that deploys, tracks, and governs cross-chain suckers for Juicebox projects. It
/// maintains an allowlist of approved deployer contracts, allows multiple active suckers per peer chain for bridge
/// resilience, manages the global `toRemoteFee` (paid into the protocol fee project on each bridge send), and provides
/// aggregate views of remote-chain balances, surplus, and token supply across all of a project's suckers.
contract JBSuckerRegistry is ERC2771Context, Ownable, JBPermissioned, IJBSuckerRegistry {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the owner attempts to set a `toRemoteFee` greater than the maximum allowed fee.
    error JBSuckerRegistry_FeeExceedsMax(uint256 fee, uint256 max);

    /// @notice Thrown when a sucker deployment references a deployer that is not approved by this registry.
    error JBSuckerRegistry_InvalidDeployer(IJBSuckerDeployer deployer);

    /// @notice Thrown when an action references a sucker that is not registered to the given project.
    error JBSuckerRegistry_SuckerDoesNotBelongToProject(uint256 projectId, address sucker);

    /// @notice Thrown when a sucker is being removed from active listings but is not deprecated.
    error JBSuckerRegistry_SuckerIsNotDeprecated(address sucker, JBSuckerState suckerState);

    /// @notice Thrown when token mapping arrays have different lengths.
    error JBSuckerRegistry_TokenMappingLengthMismatch(
        uint256 localTokenCount, uint256 remoteChainIdCount, uint256 remoteTokenCount
    );

    /// @notice Thrown when a project chooses an owner-gated token mapping that has not been approved.
    error JBSuckerRegistry_TokenMappingNotAllowed(address localToken, uint256 remoteChainId, bytes32 remoteToken);

    /// @notice Thrown when a sucker reports a zero peer chain ID and cannot identify a real peer chain.
    error JBSuckerRegistry_ZeroPeerChainId(address sucker);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The maximum ETH fee (in wei) that the owner can set via `setToRemoteFee()`.
    uint256 public constant override MAX_TO_REMOTE_FEE = 0.001 ether;

    //*********************************************************************//
    // ------------------------- internal constants ----------------------- //
    //*********************************************************************//

    /// @notice The fixed-point fidelity used when valuing remote contexts across currencies, matching the terminal
    /// store's `_MAX_FIXED_POINT_FIDELITY`.
    uint256 internal constant _PRICE_FIDELITY = 18;

    /// @notice A constant indicating that this sucker exists and belongs to a specific project.
    uint256 internal constant _SUCKER_EXISTS = 1;

    /// @notice A constant indicating that this sucker was deprecated and removed from active listings,
    /// but still retains mint permission so pending claims can be fulfilled.
    uint256 internal constant _SUCKER_DEPRECATED = 2;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The Juicebox directory for project terminals and controllers.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The prices contract for valuing remote per-context surplus and balance into a requested currency,
    /// exactly as the terminal store values local surplus.
    IJBPrices public immutable PRICES;

    /// @notice A contract which mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Tracks whether the specified sucker deployer is approved by this registry.
    /// @custom:param deployer The address of the deployer to check.
    mapping(address deployer => bool) public override suckerDeployerIsAllowed;

    /// @notice Tracks whether projects may choose an owner-gated token mapping.
    /// @dev Disable mappings and non-native same-address mappings pass through the mapping checks directly.
    /// @custom:param localToken The local token address.
    /// @custom:param remoteChainId The ID of the remote chain.
    /// @custom:param remoteToken The remote token address encoded as bytes32.
    mapping(address localToken => mapping(uint256 remoteChainId => mapping(bytes32 remoteToken => bool)))
        public
        override tokenMappingIsAllowed;

    /// @notice The ETH fee (in wei) paid into the fee project via terminal.pay() on each toRemote() call.
    uint256 public override toRemoteFee;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Tracks the suckers for the specified project.
    /// @custom:param projectId The ID of the project whose suckers are tracked.
    mapping(uint256 projectId => EnumerableMap.AddressToUintMap) internal _suckersOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The juicebox directory.
    /// @param permissions A contract storing permissions.
    /// @param prices The prices contract for valuing remote per-context surplus/balance into a requested currency.
    /// @param initialOwner The initial owner of this contract.
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBPrices prices,
        address initialOwner,
        address trustedForwarder
    )
        ERC2771Context(trustedForwarder)
        JBPermissioned(permissions)
        Ownable(initialOwner)
    {
        DIRECTORY = directory;
        PRICES = prices;
        PROJECTS = directory.PROJECTS();
        toRemoteFee = MAX_TO_REMOTE_FEE;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice All suckers for a project, INCLUDING deprecated entries that are no longer listed in `suckersOf`.
    /// @dev Used by consumers that need to detect "has any sucker ever peered to chain X?" — e.g. to prevent
    /// premature burn of bridgeable credit by `JBReferralSplitHook.burnUnbridgeableCreditFor`. Returns every key
    /// from `_suckersOf[projectId]` regardless of active/deprecated state. Order matches the underlying
    /// `EnumerableMap` iteration order (insertion order, with swap-and-pop semantics on removal — which this
    /// registry doesn't trigger, since deprecation transitions to `_SUCKER_DEPRECATED` rather than deleting).
    /// @param projectId The ID of the project to get the suckers of.
    /// @return suckers The addresses of every sucker ever registered for `projectId`.
    function allSuckersOf(uint256 projectId) external view override returns (address[] memory suckers) {
        return _suckersOf[projectId].keys();
    }

    /// @notice Whether the given address is a sucker (active or deprecated) that was deployed through this registry for
    /// the specified project. Used by controllers to authorize mint calls from suckers.
    /// @param projectId The ID of the project to check for.
    /// @param addr The address of the sucker to check.
    /// @return flag A flag indicating if the sucker belongs to the project, and was deployed through this registry.
    function isSuckerOf(uint256 projectId, address addr) external view override returns (bool) {
        (bool exists, uint256 val) = _suckersOf[projectId].tryGet(addr);
        return exists && (val == _SUCKER_EXISTS || val == _SUCKER_DEPRECATED);
    }

    /// @notice The freshest accounting record per source chain that a project's suckers hold, for re-gossiping to a
    /// peer.
    /// @dev A sucker building an outbound gossip bundle calls this to gather the project's full cross-chain knowledge
    /// (the registry is the only place a hub chain's per-peer suckers are visible together), then prepends its own
    /// local record. Records are deduped per chain (freshest wins; an active sucker's record supersedes a deprecated
    /// one's), and the destination chain and the local chain are excluded. Suckers and records that revert are
    /// silently skipped.
    /// @param projectId The ID of the project.
    /// @param exceptChainId The destination chain to exclude (it has authoritative data about itself).
    /// @return accounts The deduped raw accounting records, one per known source chain.
    function peerChainAccountsOf(
        uint256 projectId,
        uint256 exceptChainId
    )
        external
        view
        override
        returns (JBChainAccounting[] memory accounts)
    {
        address[] memory allSuckers = _suckersOf[projectId].keys();

        // Bound the distinct-chain scratch by the total records across the project's suckers.
        (, uint256 totalChains) = _peerChainIdsBySucker(allSuckers);
        PeerAccountScratch memory scratch = PeerAccountScratch({
            chainIds: new uint256[](totalChains),
            records: new JBChainAccounting[](totalChains),
            hasActiveRecord: new bool[](totalChains),
            chainCount: 0
        });

        uint256 len = allSuckers.length;
        for (uint256 i; i < len;) {
            (, uint256 val) = _suckersOf[projectId].tryGet(allSuckers[i]);
            // Include both active and deprecated suckers; deprecated only fill a gap no active sucker answers.
            if (val == _SUCKER_EXISTS || val == _SUCKER_DEPRECATED) {
                _gatherSuckerAccounts({
                    scratch: scratch,
                    sucker: allSuckers[i],
                    isActive: val == _SUCKER_EXISTS,
                    exceptChainId: exceptChainId
                });
            }
            unchecked {
                ++i;
            }
        }

        // Trim to the populated chains.
        accounts = new JBChainAccounting[](scratch.chainCount);
        for (uint256 k; k < scratch.chainCount;) {
            accounts[k] = scratch.records[k];
            unchecked {
                ++k;
            }
        }
    }

    /// @notice The cumulative total supply across all remote peer chains for a project.
    /// @dev Each sucker holds an accounting record per source chain it has heard about (its direct peer plus chains
    /// gossiped through it), so this aggregates over every (sucker, chain) pair and dedups per chain. Includes
    /// deprecated suckers only when no active sucker answers for the same peer chain, to prevent undercounting during
    /// migration windows without letting stale deprecated records dominate live routes. Silently skips suckers and
    /// records that revert.
    /// @param projectId The ID of the project.
    /// @return totalSupply The combined peer chain total supply.
    function remoteTotalSupplyOf(uint256 projectId) external view override returns (uint256 totalSupply) {
        address[] memory allSuckers = _suckersOf[projectId].keys();

        // Gather each sucker's known peer chains once, and size the per-chain dedup scratch by the total across them.
        (uint256[][] memory chainIdsBySucker, uint256 totalChains) = _peerChainIdsBySucker(allSuckers);
        PeerValueScratch memory scratch = _peerValueScratch(totalChains);

        uint256 len = allSuckers.length;
        for (uint256 i; i < len;) {
            (, uint256 val) = _suckersOf[projectId].tryGet(allSuckers[i]);
            // Include both active and deprecated suckers in aggregate economic views.
            if (val == _SUCKER_EXISTS || val == _SUCKER_DEPRECATED) {
                bool isActive = val == _SUCKER_EXISTS;
                uint256[] memory chainIds = chainIdsBySucker[i];
                uint256 numChains = chainIds.length;
                for (uint256 c; c < numChains;) {
                    // One call returns this chain's value, peer chain ID, and freshness key together.
                    try IJBSucker(allSuckers[i]).peerChainTotalSupplyValue(chainIds[c]) returns (
                        JBPeerChainValue memory read
                    ) {
                        scratch.chainCount = _recordPeerChainValue({
                            scratch: scratch, read: read, sucker: allSuckers[i], isActive: isActive
                        });
                    } catch {}
                    unchecked {
                        ++c;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }

        // Sum the per-chain selected values.
        for (uint256 k; k < scratch.chainCount;) {
            totalSupply += scratch.values[k];
            unchecked {
                ++k;
            }
        }
    }

    /// @notice Reverts unless a local-to-remote token mapping can be chosen by a project.
    /// @dev Disable mappings never require owner approval. Non-native same-address mappings pass through directly.
    /// Native-to-native and differing-address mappings must be explicitly allowed.
    /// @param localToken The local token address.
    /// @param remoteChainId The ID of the remote chain.
    /// @param remoteToken The remote token address encoded as bytes32.
    function requireTokenMappingAllowed(
        address localToken,
        uint256 remoteChainId,
        bytes32 remoteToken
    )
        external
        view
        override
    {
        _requireTokenMappingAllowed({localToken: localToken, remoteChainId: remoteChainId, remoteToken: remoteToken});
    }

    /// @notice All active (non-deprecated) suckers for a project, with their remote peer address and chain ID.
    /// @param projectId The ID of the project to get the suckers of.
    /// @return pairs The pairs of suckers and their metadata.
    function suckerPairsOf(uint256 projectId) external view override returns (JBSuckersPair[] memory pairs) {
        // Get all suckers (including deprecated).
        address[] memory allSuckers = _suckersOf[projectId].keys();

        // Count active suckers.
        uint256 activeCount;
        for (uint256 i; i < allSuckers.length;) {
            (, uint256 val) = _suckersOf[projectId].tryGet(allSuckers[i]);
            if (val == _SUCKER_EXISTS) activeCount++;
            unchecked {
                ++i;
            }
        }

        // Populate only active pairs.
        pairs = new JBSuckersPair[](activeCount);
        uint256 j;
        for (uint256 i; i < allSuckers.length;) {
            (, uint256 val) = _suckersOf[projectId].tryGet(allSuckers[i]);
            if (val == _SUCKER_EXISTS) {
                IJBSucker sucker = IJBSucker(allSuckers[i]);
                pairs[j] = JBSuckersPair({
                    local: address(sucker), remote: sucker.peer(), remoteChainId: _peerChainIdOf(sucker)
                });
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Gets all of the specified project's active suckers which were deployed through this registry.
    /// @dev Excludes suckers that have been deprecated and removed via `removeDeprecatedSucker`.
    /// @param projectId The ID of the project to get the suckers of.
    /// @return suckers The addresses of the suckers.
    function suckersOf(uint256 projectId) external view override returns (address[] memory suckers) {
        address[] memory allSuckers = _suckersOf[projectId].keys();

        // Count active suckers.
        uint256 activeCount;
        for (uint256 i; i < allSuckers.length;) {
            (, uint256 val) = _suckersOf[projectId].tryGet(allSuckers[i]);
            if (val == _SUCKER_EXISTS) activeCount++;
            unchecked {
                ++i;
            }
        }

        // Populate only active suckers.
        suckers = new address[](activeCount);
        uint256 j;
        for (uint256 i; i < allSuckers.length;) {
            (, uint256 val) = _suckersOf[projectId].tryGet(allSuckers[i]);
            if (val == _SUCKER_EXISTS) {
                suckers[j] = allSuckers[i];
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice The cumulative peer-chain balance across all remote peer chains for a project, valued into a currency.
    /// @dev Aggregates over every (sucker, chain) pair and dedups per chain by freshest record, then sums each chain's
    /// balance valued into `currency`. Includes deprecated suckers only when no active sucker answers for the same peer
    /// chain, to prevent undercounting during migration windows without letting stale deprecated records dominate live
    /// routes. A context whose currency already matches is taken at par (no feed); a missing cross-currency feed
    /// reverts and that (sucker, chain) is silently skipped (conservative, bias-low).
    /// @param projectId The ID of the project.
    /// @param currency The currency to value the combined balance into.
    /// @param decimals The decimal precision for the returned value.
    /// @return balance The combined peer chain balance.
    function totalRemoteBalanceOf(
        uint256 projectId,
        uint256 currency,
        uint256 decimals
    )
        external
        view
        override
        returns (uint256 balance)
    {
        return _aggregateRemoteValueOf({projectId: projectId, currency: currency, decimals: decimals, surplus: false});
    }

    /// @notice The cumulative peer-chain surplus across all remote peer chains for a project, valued into a currency.
    /// @dev Aggregates over every (sucker, chain) pair and dedups per chain by freshest record, then sums each chain's
    /// surplus valued into `currency`. Includes deprecated suckers only when no active sucker answers for the same peer
    /// chain, to prevent undercounting during migration windows without letting stale deprecated records dominate live
    /// routes. A context whose currency already matches is taken at par (no feed); a missing cross-currency feed
    /// reverts and that (sucker, chain) is silently skipped (conservative, bias-low).
    /// @param projectId The ID of the project.
    /// @param currency The currency to value the combined surplus into.
    /// @param decimals The decimal precision for the returned value.
    /// @return surplus The combined peer chain surplus.
    function totalRemoteSurplusOf(
        uint256 projectId,
        uint256 currency,
        uint256 decimals
    )
        external
        view
        override
        returns (uint256 surplus)
    {
        return _aggregateRemoteValueOf({projectId: projectId, currency: currency, decimals: decimals, surplus: true});
    }

    //*********************************************************************//
    // ------------------------ internal views --------------------------- //
    //*********************************************************************//

    /// @notice Values every known peer chain held by one sucker and folds each into the per-chain dedup scratch.
    /// @dev Each (sucker, chain) is valued independently so a reverted sucker read or missing cross-currency price
    /// feed drops only that one chain. Reads the sucker's chains itself, and is extracted from the aggregate view to
    /// keep both stacks shallow.
    /// @param scratch The per-chain dedup scratch to fold values into.
    /// @param sucker The sucker whose chains to value.
    /// @param isActive Whether the sucker is active (vs deprecated).
    /// @param params The invariant valuation parameters for this aggregation pass.
    function _accrueChainValues(
        PeerValueScratch memory scratch,
        address sucker,
        bool isActive,
        RemoteValueParams memory params
    )
        internal
        view
    {
        uint256[] memory chainIds;
        // Aggregate over direct peer chains and gossiped virtual chains so the result reflects every chain the project
        // knows, not only its direct bridges.
        try IJBSucker(sucker).peerChainIds(true) returns (uint256[] memory ids) {
            chainIds = ids;
        } catch {
            return;
        }

        uint256 numChains = chainIds.length;
        for (uint256 c; c < numChains;) {
            (bool ok, JBPeerChainValue memory value) = _remoteValueOf({
                sucker: sucker,
                chainId: chainIds[c],
                projectId: params.projectId,
                currency: params.currency,
                decimals: params.decimals,
                surplus: params.surplus
            });

            if (ok) {
                scratch.chainCount =
                    _recordPeerChainValue({scratch: scratch, read: value, sucker: sucker, isActive: isActive});
            }

            unchecked {
                ++c;
            }
        }
    }

    /// @notice The cumulative peer-chain balance or surplus across all of a project's peer chains, valued into a
    /// currency.
    /// @dev Aggregates over every (sucker, chain) pair and dedups per chain by freshest record (active supersedes
    /// deprecated), then sums the selected per-chain values. Shared by `totalRemoteBalanceOf` and
    /// `totalRemoteSurplusOf`.
    /// @param projectId The ID of the project.
    /// @param currency The currency to value into.
    /// @param decimals The decimal precision for the returned value.
    /// @param surplus Whether to aggregate surplus (true) or balance (false).
    /// @return total The combined valued amount across every peer chain.
    function _aggregateRemoteValueOf(
        uint256 projectId,
        uint256 currency,
        uint256 decimals,
        bool surplus
    )
        internal
        view
        returns (uint256 total)
    {
        address[] memory allSuckers = _suckersOf[projectId].keys();

        // Size the per-chain dedup scratch by the total records across the project's suckers.
        (, uint256 totalChains) = _peerChainIdsBySucker(allSuckers);
        PeerValueScratch memory scratch = _peerValueScratch(totalChains);
        RemoteValueParams memory params =
            RemoteValueParams({projectId: projectId, currency: currency, decimals: decimals, surplus: surplus});

        uint256 len = allSuckers.length;
        for (uint256 i; i < len;) {
            (, uint256 val) = _suckersOf[projectId].tryGet(allSuckers[i]);
            // Include both active and deprecated suckers in aggregate economic views.
            if (val == _SUCKER_EXISTS || val == _SUCKER_DEPRECATED) {
                _accrueChainValues({
                    scratch: scratch, sucker: allSuckers[i], isActive: val == _SUCKER_EXISTS, params: params
                });
            }
            unchecked {
                ++i;
            }
        }

        // Sum the per-chain selected values.
        for (uint256 k; k < scratch.chainCount;) {
            total += scratch.values[k];
            unchecked {
                ++k;
            }
        }
    }

    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }

    /// @notice Reads one sucker's locally-keyed records and folds each into the per-chain gather scratch.
    /// @dev Extracted from `peerChainAccountsOf` to keep its stack shallow. A sucker that reverts contributes nothing.
    /// The destination chain, the local chain, and chain 0 are excluded.
    /// @param scratch The per-chain gather scratch to fold records into.
    /// @param sucker The sucker to read records from.
    /// @param isActive Whether the sucker is active (vs deprecated).
    /// @param exceptChainId The destination chain to exclude.
    function _gatherSuckerAccounts(
        PeerAccountScratch memory scratch,
        address sucker,
        bool isActive,
        uint256 exceptChainId
    )
        internal
        view
    {
        try IJBSucker(sucker).peerChainAccountsOf() returns (JBChainAccounting[] memory records) {
            uint256 numRecords = records.length;
            for (uint256 r; r < numRecords;) {
                // Exclude the destination chain (authoritative about itself), the local chain, and chain 0.
                if (
                    records[r].chainId != exceptChainId && records[r].chainId != block.chainid
                        && records[r].chainId != 0
                ) {
                    _recordPeerChainAccounting({scratch: scratch, record: records[r], isActive: isActive});
                }
                unchecked {
                    ++r;
                }
            }
        } catch {}
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

    /// @notice Reads a sucker's peer chain ID, reverting if the sucker cannot identify a real peer chain.
    /// @param sucker The sucker to query.
    /// @return chainId The non-zero peer chain ID.
    function _peerChainIdOf(IJBSucker sucker) internal view returns (uint256 chainId) {
        chainId = sucker.peerChainId();
        if (chainId == 0) revert JBSuckerRegistry_ZeroPeerChainId({sucker: address(sucker)});
    }

    /// @notice Gathers each sucker's known peer chains and the total across them, to size per-chain aggregation
    /// scratch.
    /// @dev Each sucker holds a record per source chain it has heard about, so the distinct-chain count can exceed the
    /// sucker count. A sucker that reverts contributes no chains. The gathered arrays are reused by the caller's
    /// per-chain loop so `peerChainIds()` is read once per sucker.
    /// @param allSuckers The project's suckers (active and deprecated).
    /// @return chainIdsBySucker Each sucker's peer chain IDs, parallel to `allSuckers`; empty for a sucker that
    /// reverts.
    /// @return totalChains The total number of (sucker, chain) entries, the upper bound on distinct peer chains.
    function _peerChainIdsBySucker(address[] memory allSuckers)
        internal
        view
        returns (uint256[][] memory chainIdsBySucker, uint256 totalChains)
    {
        uint256 len = allSuckers.length;
        chainIdsBySucker = new uint256[][](len);
        for (uint256 i; i < len;) {
            // The full set — directly-connected plus gossiped (virtual) chains — drives cross-chain aggregation.
            try IJBSucker(allSuckers[i]).peerChainIds(true) returns (uint256[] memory chainIds) {
                chainIdsBySucker[i] = chainIds;
                totalChains += chainIds.length;
            } catch {
                chainIdsBySucker[i] = new uint256[](0);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Allocates scratch arrays for collapsing many suckers into one aggregate value per peer chain.
    /// @dev `len` is the number of suckers being scanned, which is the maximum possible number of distinct peer
    /// chains. `chainCount` starts at zero and is incremented as new peer chains are discovered.
    /// @param len The maximum number of peer-chain entries the aggregation can need.
    /// @return scratch Empty scratch space sized for the current aggregation pass.
    function _peerValueScratch(uint256 len) internal pure returns (PeerValueScratch memory scratch) {
        // Allocate each parallel array up front so `_recordPeerValue` can update by index without resizing memory.
        scratch.chainIds = new uint256[](len);
        scratch.values = new uint256[](len);
        scratch.snapshotTimestamps = new uint256[](len);
        scratch.hasActiveValue = new bool[](len);
    }

    /// @notice Records one source chain's accounting record into a per-chain gather scratch, keeping the freshest.
    /// @dev Mirrors `_recordPeerValue`'s selection rule for gathered records: an active sucker's record supersedes a
    /// deprecated one's for the same chain; among same-state records the strictly-fresher timestamp wins; equal
    /// freshness keeps the first writer, since records from one origin chain at one freshness key are identical. Used
    /// to gather records for re-gossiping.
    /// @param scratch The per-chain gather scratch recorded so far.
    /// @param record The record to fold in.
    /// @param isActive Whether the record came from an active sucker.
    function _recordPeerChainAccounting(
        PeerAccountScratch memory scratch,
        JBChainAccounting memory record,
        bool isActive
    )
        internal
        pure
    {
        for (uint256 k; k < scratch.chainCount;) {
            if (scratch.chainIds[k] == record.chainId) {
                if (isActive) {
                    // An active record replaces a deprecated one, or a staler active one.
                    if (!scratch.hasActiveRecord[k] || record.timestamp > scratch.records[k].timestamp) {
                        scratch.records[k] = record;
                    }
                    scratch.hasActiveRecord[k] = true;
                } else if (!scratch.hasActiveRecord[k] && record.timestamp > scratch.records[k].timestamp) {
                    // A deprecated record only fills the gap until an active record for this chain is seen.
                    scratch.records[k] = record;
                }
                return;
            }
            unchecked {
                ++k;
            }
        }

        scratch.chainIds[scratch.chainCount] = record.chainId;
        scratch.records[scratch.chainCount] = record;
        scratch.hasActiveRecord[scratch.chainCount] = isActive;
        unchecked {
            scratch.chainCount = scratch.chainCount + 1;
        }
    }

    /// @notice Records a combined peer-chain read (value, peer chain ID, snapshot freshness key) from one sucker.
    /// @dev A wrapper over `_recordPeerValue` that unpacks the single-call `JBPeerChainValue` read and enforces the
    /// same non-zero peer-chain requirement the registry applies everywhere else. A zero peer chain ID fails the whole
    /// aggregate view because it makes the source chain unidentifiable.
    /// @param scratch The per-chain aggregate values and freshness keys recorded so far.
    /// @param read The combined value, peer chain ID, and snapshot freshness key returned by the sucker.
    /// @param sucker The sucker the read came from, used only for the zero-peer-chain error.
    /// @param isActive Whether the value came from an active sucker.
    /// @return The updated number of populated chain entries.
    function _recordPeerChainValue(
        PeerValueScratch memory scratch,
        JBPeerChainValue memory read,
        address sucker,
        bool isActive
    )
        internal
        pure
        returns (uint256)
    {
        if (read.peerChainId == 0) revert JBSuckerRegistry_ZeroPeerChainId({sucker: sucker});
        return _recordPeerValue({
            scratch: scratch,
            chainId: read.peerChainId,
            value: read.value,
            snapshotTimestamp: read.snapshotTimestamp,
            isActive: isActive
        });
    }

    /// @notice Records a project-scoped peer-chain aggregate value.
    /// @dev Callers pass scratch arrays sized from `_suckersOf[projectId].keys()`, so entries are already scoped to
    /// the project being aggregated. For each peer chain, active suckers replace deprecated suckers; deprecated
    /// values are only used as a migration fallback when no active sucker has reported for that chain.
    /// @param scratch The per-chain aggregate values and freshness keys recorded so far.
    /// @param chainId The peer-chain id to record.
    /// @param value The value to record.
    /// @param snapshotTimestamp The snapshot freshness key to record.
    /// @param isActive Whether the value came from an active sucker.
    /// @return The updated number of populated chain entries.
    function _recordPeerValue(
        PeerValueScratch memory scratch,
        uint256 chainId,
        uint256 value,
        uint256 snapshotTimestamp,
        bool isActive
    )
        internal
        pure
        returns (uint256)
    {
        // A freshly-deployed active sucker advertises its direct peer chain through `peerChainIds(true)` before it has
        // received any snapshot, producing an empty sentinel (value 0, timestamp 0). Skip that empty active record so
        // it cannot supersede a deprecated sucker's real record for the chain during a migration window. The timestamp
        // is the discriminator — a real snapshot always stamps a nonzero freshness key, so a zero key means "never
        // synced" and this never drops a legitimately zero-valued synced chain; the value clause keeps the skip to
        // genuinely empty records.
        if (isActive && snapshotTimestamp == 0 && value == 0) return scratch.chainCount;

        for (uint256 j; j < scratch.chainCount;) {
            if (scratch.chainIds[j] == chainId) {
                // Each sucker caches the entire remote chain's state (not a per-sucker share), so multiple
                // suckers targeting the same chain report redundant snapshots. Prefer the freshest source-chain
                // snapshot; use MAX only as a same-freshness tie-breaker or deprecated fallback.
                if (isActive) {
                    if (
                        !scratch.hasActiveValue[j] || snapshotTimestamp > scratch.snapshotTimestamps[j]
                            || (snapshotTimestamp == scratch.snapshotTimestamps[j] && value > scratch.values[j])
                    ) {
                        scratch.values[j] = value;
                        scratch.snapshotTimestamps[j] = snapshotTimestamp;
                    }
                    scratch.hasActiveValue[j] = true;
                } else if (
                    !scratch.hasActiveValue[j]
                        && (snapshotTimestamp > scratch.snapshotTimestamps[j]
                            || (snapshotTimestamp == scratch.snapshotTimestamps[j] && value > scratch.values[j]))
                ) {
                    // Deprecated suckers only fill the gap until an active value for this chain has been observed.
                    scratch.values[j] = value;
                    scratch.snapshotTimestamps[j] = snapshotTimestamp;
                }
                return scratch.chainCount;
            }
            unchecked {
                ++j;
            }
        }

        scratch.chainIds[scratch.chainCount] = chainId;
        scratch.values[scratch.chainCount] = value;
        scratch.snapshotTimestamps[scratch.chainCount] = snapshotTimestamp;
        scratch.hasActiveValue[scratch.chainCount] = isActive;
        unchecked {
            return scratch.chainCount + 1;
        }
    }

    /// @notice Values one peer chain's raw balance or surplus held by one sucker into a currency.
    /// @dev Returns `false` if the sucker read reverts or any cross-currency price read fails, allowing aggregate
    /// views to skip only the affected (sucker, chain) record.
    /// @param sucker The sucker to read.
    /// @param chainId The peer chain to read.
    /// @param projectId The project whose price feeds to use.
    /// @param currency The currency to value into.
    /// @param decimals The decimal precision for the returned value.
    /// @param surplus Whether to value surplus (true) or balance (false).
    /// @return ok Whether the peer-chain value was read and valued successfully.
    /// @return read The peer-chain value, peer chain ID, and snapshot freshness key.
    function _remoteValueOf(
        address sucker,
        uint256 chainId,
        uint256 projectId,
        uint256 currency,
        uint256 decimals,
        bool surplus
    )
        internal
        view
        returns (bool ok, JBPeerChainValue memory read)
    {
        JBPeerChainContext[] memory contexts;
        uint256 snapshot;

        // The sucker read is isolated so one reverting sucker/chain does not make the aggregate view unusable.
        try IJBSucker(sucker).peerChainContextsOf(chainId) returns (
            JBPeerChainContext[] memory readContexts, uint256 readSnapshot
        ) {
            contexts = readContexts;
            snapshot = readSnapshot;
        } catch {
            return (false, read);
        }

        uint256 value;
        uint256 numContexts = contexts.length;
        for (uint256 i; i < numContexts;) {
            // The same context set backs both aggregate views; select the requested side before pricing.
            uint256 amount = surplus ? contexts[i].surplus : contexts[i].balance;

            // If one context cannot be valued, the caller skips the whole (sucker, chain) record instead of returning a
            // partially priced total.
            (bool priced, uint256 valued) = _tryValued({
                amount: amount,
                fromCurrency: contexts[i].currency,
                fromDecimals: contexts[i].decimals,
                toCurrency: currency,
                toDecimals: decimals,
                projectId: projectId
            });

            if (!priced) return (false, read);

            // Contexts have already been folded by currency/decimals on the sucker, so valued outputs share the
            // requested units and can be added directly.
            value += valued;

            unchecked {
                ++i;
            }
        }

        read = JBPeerChainValue({value: value, peerChainId: chainId, snapshotTimestamp: snapshot});
        ok = true;
    }

    /// @notice Reverts unless a local-to-remote token mapping is allowed.
    /// @param localToken The local token address.
    /// @param remoteChainId The ID of the remote chain.
    /// @param remoteToken The remote token address encoded as bytes32.
    function _requireTokenMappingAllowed(address localToken, uint256 remoteChainId, bytes32 remoteToken) internal view {
        if (_tokenMappingPassesWithoutApproval({localToken: localToken, remoteToken: remoteToken})) return;

        // All economically asserted mappings must be allowlisted by the registry owner before project owners choose
        // them.
        if (!tokenMappingIsAllowed[localToken][remoteChainId][remoteToken]) {
            revert JBSuckerRegistry_TokenMappingNotAllowed({
                localToken: localToken, remoteChainId: remoteChainId, remoteToken: remoteToken
            });
        }
    }

    /// @notice Whether a local-to-remote token mapping can be chosen without owner approval.
    /// @param localToken The local token address.
    /// @param remoteToken The remote token address encoded as bytes32.
    /// @return Whether the mapping passes without owner approval.
    function _tokenMappingPassesWithoutApproval(address localToken, bytes32 remoteToken) internal pure returns (bool) {
        // Disabling a mapping is a project-local safety action, not a claim about remote token equivalence.
        if (remoteToken == bytes32(0)) return true;

        // Non-native same-address mappings are unambiguous across EVM chains. Native tokens use the same sentinel
        // even when the underlying assets differ, so native-to-native still needs registry owner approval.
        return localToken != JBConstants.NATIVE_TOKEN && remoteToken == bytes32(uint256(uint160(localToken)));
    }

    /// @notice Tries to value an amount held in one currency/decimals into another.
    /// @dev Returns `false` when the needed cross-currency price read reverts or returns zero. Same-currency and
    /// zero-amount values never consult the price feed.
    /// @param amount The raw amount in `fromCurrency`/`fromDecimals`.
    /// @param fromCurrency The currency the amount is held in.
    /// @param fromDecimals The decimals the amount is held in.
    /// @param toCurrency The currency to value into.
    /// @param toDecimals The decimals to value into.
    /// @param projectId The project whose price feeds to use.
    /// @return ok Whether the amount was valued successfully.
    /// @return converted The amount valued into `toCurrency`/`toDecimals`.
    function _tryValued(
        uint256 amount,
        uint256 fromCurrency,
        uint256 fromDecimals,
        uint256 toCurrency,
        uint256 toDecimals,
        uint256 projectId
    )
        internal
        view
        returns (bool ok, uint256 converted)
    {
        // Convert the raw context amount to the caller's requested decimals before any currency comparison, matching
        // terminal-store valuation semantics.
        converted = fromDecimals == toDecimals
            ? amount
            : JBFixedPointNumber.adjustDecimals({value: amount, decimals: fromDecimals, targetDecimals: toDecimals});

        // Zero and same-currency values need no price feed. This is what lets same-asset remote accounting work even
        // when a project has not configured a price feed.
        if (converted == 0 || fromCurrency == toCurrency) return (true, converted);

        // Cross-currency valuation is best-effort. A reverting or zero price makes the caller drop this (sucker, chain)
        // record rather than mix priced and unpriced contexts.
        try PRICES.pricePerUnitOf({
            projectId: projectId, pricingCurrency: fromCurrency, unitCurrency: toCurrency, decimals: _PRICE_FIDELITY
        }) returns (
            uint256 price
        ) {
            if (price == 0) return (false, 0);

            // `pricePerUnitOf` returns the `fromCurrency` price of one `toCurrency`, so division expresses the source
            // amount in `toCurrency`.
            converted = mulDiv({x: converted, y: 10 ** _PRICE_FIDELITY, denominator: price});
            ok = true;
        } catch {
            return (false, 0);
        }
    }

    //*********************************************************************//
    // ---------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Adds a suckers deployer to the allowlist.
    /// @dev Can only be called by this contract's owner (initially project ID 1, or JuiceboxDAO).
    /// @param deployer The address of the deployer to add.
    function allowSuckerDeployer(address deployer) public override onlyOwner {
        suckerDeployerIsAllowed[deployer] = true;
        emit SuckerDeployerAllowed({deployer: deployer, caller: _msgSender()});
    }

    /// @notice Adds multiple sucker deployers to the allowlist.
    /// @dev Can only be called by this contract's owner (initially project ID 1, or JuiceboxDAO).
    /// @param deployers The addresses of the deployers to add.
    function allowSuckerDeployers(address[] calldata deployers) public override onlyOwner {
        // Cache _msgSender() to avoid redundant calls in the loop.
        address sender = _msgSender();

        // Iterate through the deployers and allow them.
        for (uint256 i; i < deployers.length;) {
            // Get the deployer being iterated over.
            address deployer = deployers[i];

            // Allow the deployer.
            suckerDeployerIsAllowed[deployer] = true;
            emit SuckerDeployerAllowed({deployer: deployer, caller: sender});
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Adds a local-to-remote token mapping to the allowlist.
    /// @dev Can only be called by this contract's owner (initially project ID 1, or JuiceboxDAO).
    /// @param localToken The local token address.
    /// @param remoteChainId The ID of the remote chain.
    /// @param remoteToken The remote token address encoded as bytes32.
    function allowTokenMapping(
        address localToken,
        uint256 remoteChainId,
        bytes32 remoteToken
    )
        public
        override
        onlyOwner
    {
        tokenMappingIsAllowed[localToken][remoteChainId][remoteToken] = true;
        emit TokenMappingAllowed({
            localToken: localToken, remoteChainId: remoteChainId, remoteToken: remoteToken, caller: _msgSender()
        });
    }

    /// @notice Adds multiple local-to-remote token mappings to the allowlist.
    /// @dev Can only be called by this contract's owner (initially project ID 1, or JuiceboxDAO).
    /// @param localTokens The local token addresses.
    /// @param remoteChainIds The remote chain IDs.
    /// @param remoteTokens The remote token addresses encoded as bytes32.
    function allowTokenMappings(
        address[] calldata localTokens,
        uint256[] calldata remoteChainIds,
        bytes32[] calldata remoteTokens
    )
        public
        override
        onlyOwner
    {
        uint256 localTokenCount = localTokens.length;
        if (localTokenCount != remoteChainIds.length || localTokenCount != remoteTokens.length) {
            revert JBSuckerRegistry_TokenMappingLengthMismatch({
                localTokenCount: localTokenCount,
                remoteChainIdCount: remoteChainIds.length,
                remoteTokenCount: remoteTokens.length
            });
        }

        // Cache _msgSender() to avoid redundant calls in the loop.
        address sender = _msgSender();

        // Iterate over each parallel pair exactly once so a single admin transaction configures a full route set.
        for (uint256 i; i < localTokenCount;) {
            address localToken = localTokens[i];
            uint256 remoteChainId = remoteChainIds[i];
            bytes32 remoteToken = remoteTokens[i];

            tokenMappingIsAllowed[localToken][remoteChainId][remoteToken] = true;
            emit TokenMappingAllowed({
                localToken: localToken, remoteChainId: remoteChainId, remoteToken: remoteToken, caller: sender
            });
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Deploy one or more cross-chain suckers for a project in a single transaction. Each sucker is created via
    /// its deployer, registered in this registry, and immediately configured with its token mappings. Multiple suckers
    /// targeting the same peer chain are allowed for bridge resilience. The caller must have `DEPLOY_SUCKERS`
    /// permission, which also authorizes the initial token mappings in each deployment configuration.
    /// @param projectId The ID of the project to deploy suckers for.
    /// @param salt The deployment salt. For the suckers to be peers, this must be the same value on
    /// each chain where suckers are deployed.
    /// @param configurations The sucker deployer configs to use to deploy the suckers.
    /// @return suckers The addresses of the deployed suckers.
    function deploySuckersFor(
        uint256 projectId,
        bytes32 salt,
        JBSuckerDeployerConfig[] calldata configurations
    )
        public
        override
        returns (address[] memory suckers)
    {
        // Cache the project owner so deployment and explicit-peer authorization are both checked against the same
        // project authority, not a delegated operator.
        address projectOwner = PROJECTS.ownerOf(projectId);

        // `DEPLOY_SUCKERS` authorizes creating suckers and applying their launch-time token mappings.
        _requirePermissionFrom({
            account: projectOwner, projectId: projectId, permissionId: JBPermissionIds.DEPLOY_SUCKERS
        });

        // Create an array to store the suckers as they are deployed.
        suckers = new address[](configurations.length);

        // Cache _msgSender() to avoid redundant calls in the loop.
        address sender = _msgSender();

        // Calculate the salt using the sender's address and the provided `salt`.
        // This is an intentional part of the same-address peer invariant: if projects deploy suckers from
        // different sender addresses on different chains, the resulting sucker addresses will differ and the
        // default peer symmetry assumption will not hold.
        salt = keccak256(abi.encode(sender, salt));

        // Iterate through the configurations and deploy the suckers.
        for (uint256 i; i < configurations.length;) {
            // Copy the configuration once because its deployer, peer, mappings, and event payload are all reused below.
            JBSuckerDeployerConfig memory configuration = configurations[i];

            // Make sure the deployer is allowed.
            if (!suckerDeployerIsAllowed[address(configuration.deployer)]) {
                revert JBSuckerRegistry_InvalidDeployer({deployer: configuration.deployer});
            }

            // `peer == 0` tells the sucker to use its own clone address as the deterministic same-address peer, so the
            // deploy permission is enough for that default path.
            // Every nonzero value is an explicit remote authority, including this registry's address.
            if (configuration.peer != bytes32(0)) {
                // Only a caller with `SET_SUCKER_PEER` may choose that explicit remote authority.
                _requirePermissionFrom({
                    account: projectOwner, projectId: projectId, permissionId: JBPermissionIds.SET_SUCKER_PEER
                });
            }

            // Create the sucker.
            IJBSucker sucker = configuration.deployer
            .createForSender({localProjectId: projectId, salt: salt, peer: configuration.peer});
            _peerChainIdOf(sucker);
            suckers[i] = address(sucker);

            // Store the sucker as being deployed for this project.
            _suckersOf[projectId].set({key: address(sucker), value: _SUCKER_EXISTS});

            // Map the tokens for the sucker.
            sucker.mapTokens(configuration.mappings);
            emit SuckerDeployedFor({
                projectId: projectId, sucker: address(sucker), configuration: configuration, caller: sender
            });
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Lets anyone mark a deprecated sucker as removed from active listings.
    /// @dev The sucker retains mint permission (`isSuckerOf` still returns true) so pending claims
    /// can still be fulfilled. It is excluded from `suckersOf` and `suckerPairsOf`.
    /// @param projectId The ID of the project to remove the sucker from.
    /// @param sucker The address of the deprecated sucker to remove.
    function removeDeprecatedSucker(uint256 projectId, address sucker) public override {
        // Sanity check, make sure that the sucker does actually belong to the project.
        (bool belongsToProject, uint256 val) = _suckersOf[projectId].tryGet(sucker);
        if (!belongsToProject || val != _SUCKER_EXISTS) {
            revert JBSuckerRegistry_SuckerDoesNotBelongToProject({projectId: projectId, sucker: address(sucker)});
        }

        // Check if the sucker is deprecated.
        JBSuckerState state = IJBSucker(sucker).state();
        if (state != JBSuckerState.DEPRECATED) {
            revert JBSuckerRegistry_SuckerIsNotDeprecated({sucker: address(sucker), suckerState: state});
        }

        // Mark the sucker as deprecated (retains mint permission, excluded from active listings).
        _suckersOf[projectId].set({key: address(sucker), value: _SUCKER_DEPRECATED});
        emit SuckerDeprecated({projectId: projectId, sucker: address(sucker), caller: _msgSender()});
    }

    /// @notice Removes a sucker deployer from the allowlist.
    /// @dev Can only be called by this contract's owner (initially project ID 1, or JuiceboxDAO).
    /// @param deployer The address of the deployer to remove.
    function removeSuckerDeployer(address deployer) public override onlyOwner {
        suckerDeployerIsAllowed[deployer] = false;
        emit SuckerDeployerRemoved({deployer: deployer, caller: _msgSender()});
    }

    /// @notice Removes a local-to-remote token mapping from the allowlist.
    /// @dev Can only be called by this contract's owner (initially project ID 1, or JuiceboxDAO).
    /// @param localToken The local token address.
    /// @param remoteChainId The ID of the remote chain.
    /// @param remoteToken The remote token address encoded as bytes32.
    function removeTokenMapping(
        address localToken,
        uint256 remoteChainId,
        bytes32 remoteToken
    )
        public
        override
        onlyOwner
    {
        tokenMappingIsAllowed[localToken][remoteChainId][remoteToken] = false;
        emit TokenMappingRemoved({
            localToken: localToken, remoteChainId: remoteChainId, remoteToken: remoteToken, caller: _msgSender()
        });
    }

    /// @notice Removes multiple local-to-remote token mappings from the allowlist.
    /// @dev Can only be called by this contract's owner (initially project ID 1, or JuiceboxDAO).
    /// @param localTokens The local token addresses.
    /// @param remoteChainIds The remote chain IDs.
    /// @param remoteTokens The remote token addresses encoded as bytes32.
    function removeTokenMappings(
        address[] calldata localTokens,
        uint256[] calldata remoteChainIds,
        bytes32[] calldata remoteTokens
    )
        public
        override
        onlyOwner
    {
        uint256 localTokenCount = localTokens.length;
        if (localTokenCount != remoteChainIds.length || localTokenCount != remoteTokens.length) {
            revert JBSuckerRegistry_TokenMappingLengthMismatch({
                localTokenCount: localTokenCount,
                remoteChainIdCount: remoteChainIds.length,
                remoteTokenCount: remoteTokens.length
            });
        }

        // Cache _msgSender() to avoid redundant calls in the loop.
        address sender = _msgSender();

        // Iterate over each parallel pair exactly once so a single admin transaction can remove a route set.
        for (uint256 i; i < localTokenCount;) {
            address localToken = localTokens[i];
            uint256 remoteChainId = remoteChainIds[i];
            bytes32 remoteToken = remoteTokens[i];

            tokenMappingIsAllowed[localToken][remoteChainId][remoteToken] = false;
            emit TokenMappingRemoved({
                localToken: localToken, remoteChainId: remoteChainId, remoteToken: remoteToken, caller: sender
            });
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Set the ETH fee (in wei) paid into the fee project on each toRemote() call.
    /// @dev Only callable by the contract owner. Fee cannot exceed MAX_TO_REMOTE_FEE.
    /// @param fee The new fee amount in wei.
    function setToRemoteFee(uint256 fee) public override onlyOwner {
        if (fee > MAX_TO_REMOTE_FEE) revert JBSuckerRegistry_FeeExceedsMax(fee, MAX_TO_REMOTE_FEE);
        uint256 oldFee = toRemoteFee;
        toRemoteFee = fee;
        emit ToRemoteFeeChanged({oldFee: oldFee, newFee: fee, caller: _msgSender()});
    }
}
