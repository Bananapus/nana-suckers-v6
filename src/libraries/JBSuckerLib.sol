// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
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
import {JBSourceContext} from "../structs/JBSourceContext.sol";
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
    // ---------------------- external transactions ---------------------- //
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
        // Snapshot the project's per-context surplus and balance, un-valued. No price oracle is consulted on send.
        (uint256 localTotalSupply, JBSourceContext[] memory sourceContexts) =
            _snapshotAccountsOf({directory: directory, projectId: projectId});

        // Construct the cross-chain message with the per-context snapshot data.
        message = JBMessageRoot({
            version: messageVersion,
            token: remoteToken,
            amount: amount,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: root}),
            sourceTotalSupply: localTotalSupply,
            sourceContexts: sourceContexts,
            sourceTimestamp: sourceTimestamp
        });
    }

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

    /// @notice Compute a branch root from a leaf, branch, and index. Wraps MerkleLib.branchRoot so its
    /// ~170 lines of unrolled assembly live in the library's bytecode instead of each sucker's.
    /// @param item The leaf hash.
    /// @param branch The 32-element merkle proof branch.
    /// @param index The leaf index.
    /// @return The computed merkle root.
    function computeBranchRoot(bytes32 item, bytes32[32] memory branch, uint256 index) external pure returns (bytes32) {
        // Delegate to MerkleLib's unrolled assembly implementation.
        return MerkleLib.branchRoot({item: item, branch: branch, index: index});
    }

    /// @notice Compute the merkle tree root from branch and count. Loop-based replacement for the unrolled
    /// MerkleLib.root() — saves ~3KB per sucker when called via DELEGATECALL instead of inlining.
    /// @param branch The 32-element branch array (caller copies from storage to memory).
    /// @param count The number of leaves inserted into the tree.
    /// @return current The merkle root.
    function computeTreeRoot(bytes32[32] memory branch, uint256 count) external pure returns (bytes32 current) {
        // An empty tree has a well-known root.
        if (count == 0) return MerkleLib.Z_32;

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
            try prices.pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: source.currency,
                // forge-lint: disable-next-line(unsafe-typecast)
                unitCurrency: uint32(currency),
                decimals: source.decimals
            }) returns (
                uint256 price
            ) {
                converted = mulDiv({x: source.value, y: 10 ** decimals, denominator: price});
            } catch {}
        }
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice Builds the project's per-accounting-context surplus and balance, each in the context's own currency,
    /// with no price-feed valuation.
    /// @dev Loops every terminal and accounting context, reading the raw per-token surplus (requested in the token's
    /// own currency, so the terminal performs no conversion) and the raw recorded balance. Each external call is
    /// wrapped so a single broken terminal or context never bricks the snapshot. Amounts are capped to `uint128` for
    /// cross-VM (SVM) compatibility, matching the leaf-amount cap; the cap can only under-report, the safe direction
    /// for a remote surplus. The returned buffer is over-allocated by one slot so the caller can append an optional
    /// data-hook context before trimming.
    /// @param directory The JB directory to look up terminals.
    /// @param projectId The project to snapshot.
    /// @return buf An over-allocated buffer of per-context entries (length may exceed `count`).
    /// @return count The number of populated entries in `buf`.
    function _buildSourceContexts(
        IJBDirectory directory,
        uint256 projectId
    )
        internal
        view
        returns (JBSourceContext[] memory buf, uint256 count)
    {
        IJBTerminal[] memory terminals = directory.terminalsOf(projectId);
        uint256 numTerminals = terminals.length;

        // First pass: count the accounting contexts so the buffer can be sized. The extra slot is headroom for an
        // optional data-hook context the caller may append.
        uint256 upperBound = 1;
        for (uint256 i; i < numTerminals;) {
            try terminals[i].accountingContextsOf(projectId) returns (JBAccountingContext[] memory contexts) {
                upperBound += contexts.length;
            } catch {}
            unchecked {
                ++i;
            }
        }

        buf = new JBSourceContext[](upperBound);

        // Second pass: emit one entry per (terminal, context) keyed by the source-local token, carrying the raw surplus
        // and raw balance in the context's own currency. The receiver aggregates entries that resolve to the same
        // local token.
        for (uint256 i; i < numTerminals;) {
            try terminals[i].accountingContextsOf(projectId) returns (JBAccountingContext[] memory contexts) {
                for (uint256 j; j < contexts.length;) {
                    address tkn = contexts[j].token;
                    uint8 dec = contexts[j].decimals;
                    uint32 cur = contexts[j].currency;

                    // Raw surplus for this one token, requested in its own currency so the terminal does not value it.
                    uint256 surplus;
                    address[] memory oneToken = new address[](1);
                    oneToken[0] = tkn;
                    try terminals[i].currentSurplusOf({projectId: projectId, tokens: oneToken, decimals: dec, currency: cur})
                    returns (uint256 s) {
                        surplus = s;
                    } catch {}

                    // Raw recorded balance for this token.
                    uint256 balance;
                    try IJBMultiTerminal(address(terminals[i])).STORE().balanceOf({
                        terminal: address(terminals[i]),
                        projectId: projectId,
                        token: tkn
                    }) returns (uint256 b) {
                        balance = b;
                    } catch {}

                    buf[count++] = JBSourceContext({
                        token: bytes32(uint256(uint160(tkn))),
                        currency: cur,
                        decimals: dec,
                        surplus: _toUint128(surplus),
                        balance: _toUint128(balance)
                    });

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

    /// @notice Caps a value to the `uint128` cross-VM amount ceiling. Capping can only under-report, the safe
    /// direction for a remote surplus.
    /// @param value The value to cap.
    /// @return The value, or `type(uint128).max` if it exceeds the ceiling.
    function _toUint128(uint256 value) internal pure returns (uint128) {
        return value > type(uint128).max ? type(uint128).max : uint128(value);
    }

    /// @notice Return the project's controller if it exists and advertises the controller interface.
    /// @param directory The JB directory to look up the controller.
    /// @param projectId The project ID.
    /// @return controller The project's controller, or zero if the lookup is not supported.
    function _controllerOf(IJBDirectory directory, uint256 projectId) internal view returns (IJBController controller) {
        try directory.controllerOf(projectId) returns (IERC165 controllerIERC165) {
            if (address(controllerIERC165) == address(0)) return IJBController(address(0));

            try controllerIERC165.supportsInterface(type(IJBController).interfaceId) returns (bool supported) {
                if (supported) controller = IJBController(address(controllerIERC165));
            } catch {}
        } catch {}
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
    /// @dev Project token supply stays a single currency-agnostic scalar. Surplus and balance are emitted per
    /// accounting context in each context's own currency, with no price-feed valuation — the receiving chain folds each
    /// context into its same-asset local context at par. A project data hook may contribute an additional supply plus a
    /// native-denominated surplus/balance, folded as one extra native context.
    /// @param directory The JB directory to look up controllers and terminals.
    /// @param projectId The project to snapshot.
    /// @return localTotalSupply The total project token supply, including reserved tokens.
    /// @return contexts The project's per-context surplus and balance, un-valued.
    function _snapshotAccountsOf(
        IJBDirectory directory,
        uint256 projectId
    )
        internal
        view
        returns (uint256 localTotalSupply, JBSourceContext[] memory contexts)
    {
        // Use the controller as the single source for project supply.
        IJBController controller = _controllerOf({directory: directory, projectId: projectId});

        if (address(controller) != address(0)) {
            try controller.totalTokenSupplyWithReservedTokensOf(projectId) returns (uint256 supply) {
                localTotalSupply = supply;
            } catch {}
        }

        // Per-context surplus and balance, raw and un-valued.
        (JBSourceContext[] memory buf, uint256 count) =
            _buildSourceContexts({directory: directory, projectId: projectId});

        if (address(controller) != address(0) && address(controller).code.length != 0) {
            (uint256 additionalSupply, uint256 additionalSurplus, uint256 additionalBalance) =
                _peerChainAdjustedAccountsOf({controller: controller, projectId: projectId});

            // Fold the data hook's project-wide supply adjustment in directly.
            localTotalSupply += additionalSupply;

            // The hook reports any off-terminal surplus/balance in native (ETH) terms; carry it as one native context
            // so the receiver folds it into a native reclaim at par (and conservatively ignores it for non-native
            // reclaims, consistent with the oracle-free model). The buffer reserved a slot for this entry.
            if (additionalSurplus != 0 || additionalBalance != 0) {
                buf[count++] = JBSourceContext({
                    token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
                    currency: JBCurrencyIds.ETH,
                    decimals: _ETH_DECIMALS,
                    surplus: _toUint128(additionalSurplus),
                    balance: _toUint128(additionalBalance)
                });
            }
        }

        // Trim the over-allocated buffer to the populated length.
        contexts = new JBSourceContext[](count);
        for (uint256 k; k < count;) {
            contexts[k] = buf[k];
            unchecked {
                ++k;
            }
        }
    }
}
