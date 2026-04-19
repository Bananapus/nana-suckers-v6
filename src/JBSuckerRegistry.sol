// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {JBDenominatedAmount} from "./structs/JBDenominatedAmount.sol";
import {JBSuckerState} from "./enums/JBSuckerState.sol";
import {IJBSucker} from "./interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "./interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "./structs/JBSuckerDeployerConfig.sol";
import {JBSuckersPair} from "./structs/JBSuckersPair.sol";

/// @notice A registry for deploying and tracking suckers across projects.
contract JBSuckerRegistry is ERC2771Context, Ownable, JBPermissioned, IJBSuckerRegistry {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBSuckerRegistry_DuplicatePeerChain(uint256 projectId, uint256 peerChainId);
    error JBSuckerRegistry_FeeExceedsMax(uint256 fee, uint256 max);
    error JBSuckerRegistry_InvalidDeployer(IJBSuckerDeployer deployer);
    error JBSuckerRegistry_SuckerDoesNotBelongToProject(uint256 projectId, address sucker);
    error JBSuckerRegistry_SuckerIsNotDeprecated(address sucker, JBSuckerState suckerState);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The maximum ETH fee (in wei) that the owner can set via `setToRemoteFee()`.
    uint256 public constant override MAX_TO_REMOTE_FEE = 0.001 ether;

    //*********************************************************************//
    // ------------------------- internal constants ----------------------- //
    //*********************************************************************//

    /// @notice A constant indicating that this sucker exists and belongs to a specific project.
    uint256 internal constant _SUCKER_EXISTS = 1;

    /// @notice A constant indicating that this sucker was deprecated and removed from active listings,
    /// but still retains mint permission so pending claims can be fulfilled.
    uint256 internal constant _SUCKER_DEPRECATED = 2;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The juicebox directory.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice A contract which mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Tracks whether the specified sucker deployer is approved by this registry.
    /// @custom:member deployer The address of the deployer to check.
    mapping(address deployer => bool) public override suckerDeployerIsAllowed;

    /// @notice The ETH fee (in wei) paid into the fee project via terminal.pay() on each toRemote() call.
    uint256 public override toRemoteFee;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Tracks the suckers for the specified project.
    mapping(uint256 => EnumerableMap.AddressToUintMap) internal _suckersOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The juicebox directory.
    /// @param permissions A contract storing permissions.
    /// @param initialOwner The initial owner of this contract.
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        address initialOwner,
        address trustedForwarder
    )
        ERC2771Context(trustedForwarder)
        JBPermissioned(permissions)
        Ownable(initialOwner)
    {
        DIRECTORY = directory;
        PROJECTS = directory.PROJECTS();
        toRemoteFee = MAX_TO_REMOTE_FEE;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Returns true if the specified sucker belongs to the specified project, and was deployed through this
    /// registry.
    /// @param projectId The ID of the project to check for.
    /// @param addr The address of the sucker to check.
    /// @return flag A flag indicating if the sucker belongs to the project, and was deployed through this registry.
    function isSuckerOf(uint256 projectId, address addr) external view override returns (bool) {
        (bool exists, uint256 val) = _suckersOf[projectId].tryGet(addr);
        return exists && (val == _SUCKER_EXISTS || val == _SUCKER_DEPRECATED);
    }

    /// @notice Helper function for retrieving the projects suckers and their metadata.
    /// @param projectId The ID of the project to get the suckers of.
    /// @return pairs The pairs of suckers and their metadata.
    function suckerPairsOf(uint256 projectId) external view override returns (JBSuckersPair[] memory pairs) {
        // Get all suckers (including deprecated).
        address[] memory allSuckers = _suckersOf[projectId].keys();

        // Count active suckers.
        uint256 activeCount;
        for (uint256 i; i < allSuckers.length;) {
            // slither-disable-next-line unused-return
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
            // slither-disable-next-line unused-return
            (, uint256 val) = _suckersOf[projectId].tryGet(allSuckers[i]);
            if (val == _SUCKER_EXISTS) {
                IJBSucker sucker = IJBSucker(allSuckers[i]);
                // slither-disable-next-line calls-loop
                pairs[j] =
                    JBSuckersPair({local: address(sucker), remote: sucker.peer(), remoteChainId: sucker.peerChainId()});
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
            // slither-disable-next-line unused-return
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
            // slither-disable-next-line unused-return
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

    /// @notice The cumulative balance across all remote peer chains for a project, denominated in a given currency.
    /// @dev Sums `peerChainBalanceOf` from each active sucker. Silently skips suckers that revert.
    /// @param projectId The ID of the project.
    /// @param decimals The decimal precision for the returned value.
    /// @param currency The currency to normalize to.
    /// @return balance The combined peer chain balance.
    function remoteBalanceOf(
        uint256 projectId,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        override
        returns (uint256 balance)
    {
        address[] memory allSuckers = _suckersOf[projectId].keys();
        for (uint256 i; i < allSuckers.length;) {
            // slither-disable-next-line unused-return
            (, uint256 val) = _suckersOf[projectId].tryGet(allSuckers[i]);
            if (val == _SUCKER_EXISTS) {
                // slither-disable-next-line calls-loop
                try IJBSucker(allSuckers[i]).peerChainBalanceOf(decimals, currency) returns (
                    JBDenominatedAmount memory amt
                ) {
                    balance += amt.value;
                } catch {}
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice The cumulative surplus across all remote peer chains for a project, denominated in a given currency.
    /// @dev Sums `peerChainSurplusOf` from each active sucker. Silently skips suckers that revert.
    /// @param projectId The ID of the project.
    /// @param decimals The decimal precision for the returned value.
    /// @param currency The currency to normalize to.
    /// @return surplus The combined peer chain surplus.
    function remoteSurplusOf(
        uint256 projectId,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        override
        returns (uint256 surplus)
    {
        address[] memory allSuckers = _suckersOf[projectId].keys();
        for (uint256 i; i < allSuckers.length;) {
            // slither-disable-next-line unused-return
            (, uint256 val) = _suckersOf[projectId].tryGet(allSuckers[i]);
            if (val == _SUCKER_EXISTS) {
                // slither-disable-next-line calls-loop
                try IJBSucker(allSuckers[i]).peerChainSurplusOf(decimals, currency) returns (
                    JBDenominatedAmount memory amt
                ) {
                    surplus += amt.value;
                } catch {}
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice The cumulative total supply across all remote peer chains for a project.
    /// @dev Sums `peerChainTotalSupply` from each active sucker. Silently skips suckers that revert.
    /// @param projectId The ID of the project.
    /// @return totalSupply The combined peer chain total supply.
    function remoteTotalSupplyOf(uint256 projectId) external view override returns (uint256 totalSupply) {
        address[] memory allSuckers = _suckersOf[projectId].keys();
        for (uint256 i; i < allSuckers.length;) {
            // slither-disable-next-line unused-return
            (, uint256 val) = _suckersOf[projectId].tryGet(allSuckers[i]);
            if (val == _SUCKER_EXISTS) {
                // slither-disable-next-line calls-loop
                try IJBSucker(allSuckers[i]).peerChainTotalSupply() returns (uint256 supply) {
                    totalSupply += supply;
                } catch {}
            }
            unchecked {
                ++i;
            }
        }
    }

    //*********************************************************************//
    // ------------------------ internal views --------------------------- //
    //*********************************************************************//

    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
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

    /// @notice Reverts if any active sucker for the given project already targets the same peer chain as the new
    /// sucker.
    /// @param projectId The ID of the project to check.
    /// @param newSucker The newly created sucker to validate.
    function _revertIfDuplicatePeerChain(uint256 projectId, IJBSucker newSucker) internal view {
        uint256 newPeerChainId = newSucker.peerChainId();
        address[] memory existing = _suckersOf[projectId].keys();
        for (uint256 i; i < existing.length;) {
            // slither-disable-next-line unused-return
            (, uint256 val) = _suckersOf[projectId].tryGet(existing[i]);
            if (val == _SUCKER_EXISTS) {
                // slither-disable-next-line calls-loop
                if (IJBSucker(existing[i]).peerChainId() == newPeerChainId) {
                    revert JBSuckerRegistry_DuplicatePeerChain(projectId, newPeerChainId);
                }
            }
            unchecked {
                ++i;
            }
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

    /// @notice Adds multiple suckers deployer to the allowlist.
    /// @dev Can only be called by this contract's owner (initially project ID 1, or JuiceboxDAO).
    /// @param deployers The address of the deployer to add.
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

    /// @notice Deploy one or more suckers for the specified project.
    /// @dev The caller must be the project's owner or have `JBPermissionIds.DEPLOY_SUCKERS` from the project's owner.
    /// Each newly created sucker is immediately configured by calling `mapTokens`, so successful execution also
    /// depends on this registry being authorized to perform `MAP_SUCKER_TOKEN` for the project.
    /// @param projectId The ID of the project to deploy suckers for.
    /// @param salt The salt used to deploy the contract. For the suckers to be peers, this must be the same value on
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
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.DEPLOY_SUCKERS
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
            // Get the configuration being iterated over.
            JBSuckerDeployerConfig memory configuration = configurations[i];

            // Make sure the deployer is allowed.
            if (!suckerDeployerIsAllowed[address(configuration.deployer)]) {
                revert JBSuckerRegistry_InvalidDeployer(configuration.deployer);
            }

            // Create the sucker.
            // slither-disable-next-line reentrancy-event,calls-loop
            IJBSucker sucker = configuration.deployer.createForSender({localProjectId: projectId, salt: salt});
            suckers[i] = address(sucker);

            // Make sure no active sucker already targets the same peer chain.
            // slither-disable-next-line calls-loop
            _revertIfDuplicatePeerChain({projectId: projectId, newSucker: sucker});

            // Store the sucker as being deployed for this project.
            // slither-disable-next-line unused-return
            _suckersOf[projectId].set({key: address(sucker), value: _SUCKER_EXISTS});

            // Map the tokens for the sucker.
            // slither-disable-next-line reentrancy-events,calls-loop
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
            revert JBSuckerRegistry_SuckerDoesNotBelongToProject(projectId, address(sucker));
        }

        // Check if the sucker is deprecated.
        JBSuckerState state = IJBSucker(sucker).state();
        if (state != JBSuckerState.DEPRECATED) {
            revert JBSuckerRegistry_SuckerIsNotDeprecated(address(sucker), state);
        }

        // Mark the sucker as deprecated (retains mint permission, excluded from active listings).
        // slither-disable-next-line unused-return
        _suckersOf[projectId].set(address(sucker), _SUCKER_DEPRECATED);
        emit SuckerDeprecated({projectId: projectId, sucker: address(sucker), caller: _msgSender()});
    }

    /// @notice Set the ETH fee (in wei) paid into the fee project on each toRemote() call.
    /// @dev Only callable by the contract owner. Fee cannot exceed MAX_TO_REMOTE_FEE.
    /// @param fee The new fee amount in wei.
    function setToRemoteFee(uint256 fee) public override onlyOwner {
        if (fee > MAX_TO_REMOTE_FEE) revert JBSuckerRegistry_FeeExceedsMax(fee, MAX_TO_REMOTE_FEE);
        uint256 oldFee = toRemoteFee;
        toRemoteFee = fee;
        emit ToRemoteFeeChanged(oldFee, fee, _msgSender());
    }

    /// @notice Removes a sucker deployer from the allowlist.
    /// @dev Can only be called by this contract's owner (initially project ID 1, or JuiceboxDAO).
    /// @param deployer The address of the deployer to remove.
    function removeSuckerDeployer(address deployer) public override onlyOwner {
        suckerDeployerIsAllowed[deployer] = false;
        emit SuckerDeployerRemoved({deployer: deployer, caller: _msgSender()});
    }
}
