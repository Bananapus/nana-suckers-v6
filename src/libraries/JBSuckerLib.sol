// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IJBPeerChainAdjustedAccounts} from "../interfaces/IJBPeerChainAdjustedAccounts.sol";
import {JBDenominatedAmount} from "../structs/JBDenominatedAmount.sol";
import {JBInboxTreeRoot} from "../structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../structs/JBMessageRoot.sol";
import {MerkleLib} from "../utils/MerkleLib.sol";

/// @notice Library with bytecode-heavy functions extracted from JBSucker to reduce child contract sizes.
/// @dev These are `external` library functions, so they are deployed as a separate contract and called via
/// DELEGATECALL. This avoids duplicating the bytecode in every sucker implementation.
library JBSuckerLib {
    using JBRulesetMetadataResolver for JBRuleset;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The expected byte length returned by `IJBController.currentRulesetOf(...)`.
    /// @dev A V6 ruleset return value contains one `JBRuleset` (9 words) and one `JBRulesetMetadata` (19 words).
    uint256 internal constant _CURRENT_RULESET_OF_RETURN_BYTES = (9 + 19) * 32;

    /// @notice The ETH decimal precision used for cross-chain peer snapshots.
    uint8 internal constant _ETH_DECIMALS = 18;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Build ETH-denominated aggregate surplus and balance across all terminals for a project.
    /// @param directory The JB directory to look up terminals.
    /// @param prices The price oracle to use for non-ETH terminal-token balances.
    /// @param projectId The project ID.
    /// @return ethSurplus The total surplus denominated in ETH at 18 decimals.
    /// @return ethBalance The total balance denominated in ETH at 18 decimals.
    // forge-lint: disable-next-line(mixed-case-function)
    function buildETHAggregate(
        IJBDirectory directory,
        IJBPrices prices,
        uint256 projectId
    )
        external
        view
        returns (uint256 ethSurplus, uint256 ethBalance)
    {
        return _buildETHAggregateInternal({directory: directory, projectId: projectId, prices: prices});
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @dev Shared implementation for ETH aggregate. Internal so it can be called from other
    /// external library functions (libraries cannot call their own external functions).
    // forge-lint: disable-next-line(mixed-case-function)
    function _buildETHAggregateInternal(
        IJBDirectory directory,
        uint256 projectId,
        IJBPrices prices
    )
        internal
        view
        returns (uint256 ethSurplus, uint256 ethBalance)
    {
        // Get all terminals registered for the project.
        IJBTerminal[] memory terminals = directory.terminalsOf(projectId);

        // Get the number of terminals.
        uint256 numTerminals = terminals.length;

        // If there are no terminals, return zeros.
        if (numTerminals == 0) return (0, 0);

        for (uint256 i; i < numTerminals;) {
            // slither-disable-next-line calls-loop
            try terminals[i].currentSurplusOf({
                projectId: projectId, tokens: new address[](0), decimals: _ETH_DECIMALS, currency: JBCurrencyIds.ETH
            }) returns (
                uint256 surplus
            ) {
                ethSurplus += surplus;
            } catch {}

            unchecked {
                ++i;
            }
        }

        // Aggregate balance from each terminal, converting each token to ETH.
        for (uint256 i; i < numTerminals;) {
            // slither-disable-next-line calls-loop
            try terminals[i].accountingContextsOf(projectId) returns (JBAccountingContext[] memory contexts) {
                // Iterate over each accounting context (token) for this terminal.
                for (uint256 j; j < contexts.length;) {
                    // Get the token address for this context.
                    address tkn = contexts[j].token;

                    // Get the decimal precision for this token.
                    uint8 dec = contexts[j].decimals;

                    // Get the currency ID for this context.
                    uint32 tokenCurrency = contexts[j].currency;

                    // slither-disable-next-line calls-loop
                    try IJBMultiTerminal(address(terminals[i])).STORE()
                        .balanceOf({terminal: address(terminals[i]), projectId: projectId, token: tkn}) returns (
                        uint256 bal
                    ) {
                        if (bal != 0) {
                            // If the token is already ETH-denominated, adjust decimals directly.
                            if (tokenCurrency == JBCurrencyIds.ETH) {
                                ethBalance += JBFixedPointNumber.adjustDecimals({
                                    value: bal, decimals: dec, targetDecimals: _ETH_DECIMALS
                                });
                            } else {
                                // Otherwise, convert the balance to ETH using the price oracle.
                                // slither-disable-next-line calls-loop
                                try prices.pricePerUnitOf({
                                    projectId: projectId,
                                    pricingCurrency: tokenCurrency,
                                    unitCurrency: JBCurrencyIds.ETH,
                                    decimals: _ETH_DECIMALS
                                }) returns (
                                    uint256 price
                                ) {
                                    ethBalance += mulDiv({x: bal, y: price, denominator: 10 ** dec});
                                } catch {}
                            }
                        }
                    } catch {}

                    unchecked {
                        ++j;
                    }
                }
            } catch {}
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Convert a peer chain snapshot value to the requested currency and decimal precision.
    /// @param prices The price oracle to use when currency conversion is needed.
    /// @param projectId The project ID.
    /// @param source The peer chain snapshot containing value, currency, and decimals.
    /// @param decimals The target decimal precision.
    /// @param currency The target currency.
    /// @return converted The converted value.
    function convertPeerValue(
        IJBPrices prices,
        uint256 projectId,
        JBDenominatedAmount memory source,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256 converted)
    {
        // Nothing to convert if the source value is zero.
        if (source.value == 0) return 0;

        // If the source currency matches the target, just adjust decimals.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (source.currency == uint32(currency)) {
            converted = JBFixedPointNumber.adjustDecimals({
                value: source.value, decimals: source.decimals, targetDecimals: decimals
            });
        } else {
            // Convert using the price oracle.
            // slither-disable-next-line calls-loop
            try prices.pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: source.currency,
                // forge-lint: disable-next-line(unsafe-typecast)
                unitCurrency: uint32(currency),
                // forge-lint: disable-next-line(unsafe-typecast)
                decimals: uint8(decimals)
            }) returns (
                uint256 price
            ) {
                converted = mulDiv({x: source.value, y: price, denominator: 10 ** source.decimals});
            } catch {}
        }
    }

    /// @notice Return the project's controller if it exists and advertises the controller interface.
    /// @param directory The JB directory to look up the controller.
    /// @param projectId The project ID.
    /// @return controller The project's controller, or zero if the lookup is not supported.
    function _controllerOf(IJBDirectory directory, uint256 projectId) internal view returns (IJBController controller) {
        // slither-disable-next-line calls-loop
        try directory.controllerOf(projectId) returns (IERC165 controllerIERC165) {
            if (address(controllerIERC165) == address(0)) return IJBController(address(0));

            // slither-disable-next-line calls-loop
            try controllerIERC165.supportsInterface(type(IJBController).interfaceId) returns (bool supported) {
                if (supported) controller = IJBController(address(controllerIERC165));
            } catch {}
        } catch {}
    }

    //*********************************************************************//
    // -------------------- external state-changing ---------------------- //
    //*********************************************************************//

    /// @notice Build the cross-chain snapshot message (total supply, surplus, balance).
    /// @dev Extracted from `JBSucker._buildSnapshotAndSend` to reduce child contract bytecode.
    /// Called via DELEGATECALL. Includes ETH aggregate computation inline (cannot call own external fns).
    /// @param directory The JB directory to look up controllers and terminals.
    /// @param prices The price oracle to use for non-ETH terminal-token balances.
    /// @param projectId The project ID.
    /// @param remoteToken The remote token bytes32 address.
    /// @param amount The amount of terminal tokens to bridge.
    /// @param nonce The outbox nonce for this send.
    /// @param root The merkle root of the outbox tree.
    /// @param messageVersion The message format version.
    /// @param sourceTimestamp The monotonic source freshness key for this snapshot.
    /// @return message The constructed JBMessageRoot.
    function buildSnapshotMessage(
        IJBDirectory directory,
        IJBPrices prices,
        uint256 projectId,
        bytes32 remoteToken,
        uint256 amount,
        uint64 nonce,
        bytes32 root,
        uint8 messageVersion,
        uint256 sourceTimestamp
    )
        external
        view
        returns (JBMessageRoot memory message)
    {
        (uint256 localTotalSupply, uint256 ethSurplus, uint256 ethBalance) =
            _snapshotAccountsOf({directory: directory, prices: prices, projectId: projectId});

        // Construct the cross-chain message with the snapshot data.
        message = JBMessageRoot({
            version: messageVersion,
            token: remoteToken,
            amount: amount,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: root}),
            sourceTotalSupply: localTotalSupply,
            sourceCurrency: JBCurrencyIds.ETH,
            sourceDecimals: _ETH_DECIMALS,
            sourceSurplus: ethSurplus,
            sourceBalance: ethBalance,
            sourceTimestamp: sourceTimestamp
        });
    }

    /// @notice Optional project-specific adjusted accounts to add to peer-chain snapshots.
    /// @dev Reads the current ruleset's data hook and asks it for extra supply/surplus. Non-supporting hooks,
    /// broken hooks, and short return data are ignored so a project's baseline snapshot remains usable.
    /// @param controller The controller for the project to snapshot.
    /// @param projectId The project to snapshot.
    /// @return additionalSupply The supply to add to `sourceTotalSupply`.
    /// @return additionalSurplus The surplus to add to `sourceSurplus`, denominated in ETH at 18 decimals.
    /// @return additionalBalance The balance to add to `sourceBalance`, denominated in ETH at 18 decimals.
    function _peerChainAdjustedAccountsOf(
        IJBController controller,
        uint256 projectId
    )
        internal
        view
        returns (uint256 additionalSupply, uint256 additionalSurplus, uint256 additionalBalance)
    {
        // Use staticcall because older/downstream controllers may not expose the exact typed return expected here.
        (bool rulesetCallSucceeded, bytes memory rulesetData) =
            address(controller).staticcall(abi.encodeCall(IJBController.currentRulesetOf, (projectId)));
        if (!rulesetCallSucceeded || rulesetData.length < _CURRENT_RULESET_OF_RETURN_BYTES) return (0, 0, 0);

        // The ruleset metadata packs the active data hook; projects without a hook need no adjustment.
        (JBRuleset memory ruleset,) = abi.decode(rulesetData, (JBRuleset, JBRulesetMetadata));

        address dataHook = ruleset.dataHook();
        if (dataHook == address(0) || dataHook.code.length == 0) return (0, 0, 0);

        // Ask the hook for optional extra accounts denominated the same way this library snapshots surplus: ETH, 18
        // decimals. The hook decides what project-specific remote or hidden balances should be included.
        (bool success, bytes memory data) = dataHook.staticcall(
            abi.encodeCall(
                IJBPeerChainAdjustedAccounts.peerChainAdjustedAccountsOf, (projectId, _ETH_DECIMALS, JBCurrencyIds.ETH)
            )
        );
        if (!success || data.length < 96) return (0, 0, 0);

        return abi.decode(data, (uint256, uint256, uint256));
    }

    /// @notice Builds the local accounting values used in outbound peer-chain snapshots.
    /// @param directory The JB directory to look up controllers and terminals.
    /// @param prices The price oracle to use for non-ETH terminal-token balances.
    /// @param projectId The project to snapshot.
    /// @return localTotalSupply The total project token supply, including reserved tokens.
    /// @return ethSurplus The terminal surplus denominated in ETH at 18 decimals.
    /// @return ethBalance The terminal balance denominated in ETH at 18 decimals.
    function _snapshotAccountsOf(
        IJBDirectory directory,
        IJBPrices prices,
        uint256 projectId
    )
        internal
        view
        returns (uint256 localTotalSupply, uint256 ethSurplus, uint256 ethBalance)
    {
        // Use the controller as the single source for project supply.
        IJBController controller = _controllerOf({directory: directory, projectId: projectId});

        if (address(controller) != address(0)) {
            // slither-disable-next-line calls-loop
            try controller.totalTokenSupplyWithReservedTokensOf(projectId) returns (uint256 supply) {
                localTotalSupply = supply;
            } catch {}
        }

        // Inline ETH aggregate computation (libraries cannot call their own external functions).
        (ethSurplus, ethBalance) =
            _buildETHAggregateInternal({directory: directory, projectId: projectId, prices: prices});

        if (address(controller) != address(0) && address(controller).code.length != 0) {
            (uint256 additionalSupply, uint256 additionalSurplus, uint256 additionalBalance) =
                _peerChainAdjustedAccountsOf({controller: controller, projectId: projectId});

            // Some projects keep supply, surplus, or balance out of the normal local terminal/controller accounting.
            // Fold in only the data hook's explicit adjustment so peer-chain snapshots match that project model.
            localTotalSupply += additionalSupply;
            ethSurplus += additionalSurplus;
            ethBalance += additionalBalance;
        }
    }

    //*********************************************************************//
    // -------------------- merkle tree helpers -------------------------- //
    //*********************************************************************//

    /// @notice Compute the merkle tree root from branch and count. Loop-based replacement for the unrolled
    /// MerkleLib.root() — saves ~3KB per sucker when called via DELEGATECALL instead of inlining.
    /// @param branch The 32-element branch array (caller copies from storage to memory).
    /// @param count The number of leaves inserted into the tree.
    /// @return current The merkle root.
    function computeTreeRoot(bytes32[32] memory branch, uint256 count) external pure returns (bytes32 current) {
        // An empty tree has a well-known root.
        if (count == 0) return MerkleLib.Z_32;

        // slither-disable-start incorrect-shift
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            // Build zero hashes on-the-fly: Z[0] = 0, Z[i+1] = keccak256(Z[i], Z[i]).
            let zPtr := mload(0x40)
            mstore(0x40, add(zPtr, 0x420)) // 33 slots × 32 bytes
            mstore(zPtr, 0) // Z[0] = bytes32(0)
            for { let j := 0 } lt(j, 32) { j := add(j, 1) } {
                let prev := mload(add(zPtr, mul(j, 0x20)))
                mstore(0x00, prev)
                mstore(0x20, prev)
                mstore(add(zPtr, mul(add(j, 1), 0x20)), keccak256(0x00, 0x40))
            }

            // Walk bits of `count` from LSB to MSB.
            // First set bit → initialize current = keccak256(branch[i], Z[i]).
            // Each subsequent level → merge branch[i] or Z[i] with current.
            let started := 0
            for { let i := 0 } lt(i, 32) { i := add(i, 1) } {
                switch started
                case 0 {
                    if and(count, shl(i, 1)) {
                        mstore(0x00, mload(add(branch, mul(i, 0x20))))
                        mstore(0x20, mload(add(zPtr, mul(i, 0x20))))
                        current := keccak256(0x00, 0x40)
                        started := 1
                    }
                }
                default {
                    switch and(count, shl(i, 1))
                    case 0 {
                        mstore(0x00, current)
                        mstore(0x20, mload(add(zPtr, mul(i, 0x20))))
                    }
                    default {
                        mstore(0x00, mload(add(branch, mul(i, 0x20))))
                        mstore(0x20, current)
                    }
                    current := keccak256(0x00, 0x40)
                }
            }
        }
        // slither-disable-end incorrect-shift
    }

    /// @notice Compute a branch root from a leaf, branch, and index. Wraps MerkleLib.branchRoot so its
    /// ~170 lines of unrolled assembly live in the library's bytecode instead of each sucker's.
    /// @param item The leaf hash.
    /// @param branch The 32-element merkle proof branch.
    /// @param index The leaf index.
    /// @return The computed merkle root.
    function computeBranchRoot(bytes32 item, bytes32[32] memory branch, uint256 index) external pure returns (bytes32) {
        // Delegate to MerkleLib's unrolled assembly implementation.
        return MerkleLib.branchRoot({_item: item, _branch: branch, _index: index});
    }
}
