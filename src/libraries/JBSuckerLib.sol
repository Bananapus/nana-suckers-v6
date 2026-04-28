// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {JBDenominatedAmount} from "../structs/JBDenominatedAmount.sol";
import {JBInboxTreeRoot} from "../structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../structs/JBMessageRoot.sol";
import {MerkleLib} from "../utils/MerkleLib.sol";

/// @notice Library with bytecode-heavy functions extracted from JBSucker to reduce child contract sizes.
/// @dev These are `external` library functions, so they are deployed as a separate contract and called via
/// DELEGATECALL. This avoids duplicating the bytecode in every sucker implementation.
library JBSuckerLib {
    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @dev The native-token currency used as the denomination for cross-chain snapshots.
    /// This MUST match the token-derived currency consumers use to query (uint32(uint160(NATIVE_TOKEN)) = 61166),
    /// NOT JBCurrencyIds.ETH (= 1) which is the baseCurrency used in ruleset metadata.
    uint32 internal constant _NATIVE_TOKEN_CURRENCY = uint32(uint160(JBConstants.NATIVE_TOKEN));
    uint8 internal constant _ETH_DECIMALS = 18;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Build ETH-denominated aggregate surplus and balance across all terminals for a project.
    /// @param directory The JB directory to look up terminals.
    /// @param projectId The project ID.
    /// @return ethSurplus The total surplus denominated in ETH at 18 decimals.
    /// @return ethBalance The total balance denominated in ETH at 18 decimals.
    // forge-lint: disable-next-line(mixed-case-function)
    function buildETHAggregate(
        IJBDirectory directory,
        uint256 projectId
    )
        external
        view
        returns (uint256 ethSurplus, uint256 ethBalance)
    {
        return _buildETHAggregateInternal(directory, projectId);
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @dev Shared implementation for ETH aggregate. Internal so it can be called from other
    /// external library functions (libraries cannot call their own external functions).
    // forge-lint: disable-next-line(mixed-case-function)
    function _buildETHAggregateInternal(
        IJBDirectory directory,
        uint256 projectId
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

        // Get the surplus denominated in ETH. currentSurplusOf aggregates across all terminals internally.
        // slither-disable-next-line calls-loop
        try terminals[0].currentSurplusOf({
            projectId: projectId, tokens: new address[](0), decimals: _ETH_DECIMALS, currency: _NATIVE_TOKEN_CURRENCY
        }) returns (
            uint256 surplus
        ) {
            ethSurplus = surplus;
        } catch {}

        // Get a reference to JBPrices for balance conversion.
        IJBPrices prices;
        {
            // slither-disable-next-line calls-loop
            try IJBMultiTerminal(address(terminals[0])).STORE() returns (IJBTerminalStore store) {
                // Get the price oracle from the terminal store.
                prices = store.PRICES();
            } catch {
                // If the store lookup fails, return surplus only with zero balance.
                return (ethSurplus, 0);
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

                    // Derive the currency ID from the token address.
                    uint32 tokenCurrency = uint32(uint160(tkn));

                    // slither-disable-next-line calls-loop
                    try IJBMultiTerminal(address(terminals[i])).STORE()
                        .balanceOf({terminal: address(terminals[i]), projectId: projectId, token: tkn}) returns (
                        uint256 bal
                    ) {
                        if (bal != 0) {
                            // If the token is already ETH-denominated, adjust decimals directly.
                            if (tokenCurrency == _NATIVE_TOKEN_CURRENCY) {
                                ethBalance += JBFixedPointNumber.adjustDecimals({
                                    value: bal, decimals: dec, targetDecimals: _ETH_DECIMALS
                                });
                            } else {
                                // Otherwise, convert the balance to ETH using the price oracle.
                                // slither-disable-next-line calls-loop
                                try prices.pricePerUnitOf({
                                    projectId: projectId,
                                    pricingCurrency: tokenCurrency,
                                    unitCurrency: _NATIVE_TOKEN_CURRENCY,
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
    /// @param directory The JB directory to look up terminals.
    /// @param projectId The project ID.
    /// @param source The peer chain snapshot containing value, currency, and decimals.
    /// @param decimals The target decimal precision.
    /// @param currency The target currency.
    /// @return converted The converted value.
    function convertPeerValue(
        IJBDirectory directory,
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
        if (source.currency == uint32(currency)) {
            converted = JBFixedPointNumber.adjustDecimals({
                value: source.value, decimals: source.decimals, targetDecimals: decimals
            });
        } else {
            // Look up terminals to access the price oracle.
            IJBTerminal[] memory terminals = directory.terminalsOf(projectId);

            // If there are no terminals, return zero.
            if (terminals.length == 0) return 0;

            // slither-disable-next-line calls-loop
            try IJBMultiTerminal(address(terminals[0])).STORE() returns (IJBTerminalStore store) {
                // Get the price oracle from the terminal store.
                IJBPrices prices = store.PRICES();

                // Convert using the price oracle.
                // slither-disable-next-line calls-loop
                try prices.pricePerUnitOf({
                    projectId: projectId,
                    pricingCurrency: source.currency,
                    unitCurrency: uint32(currency),
                    decimals: uint8(decimals)
                }) returns (
                    uint256 price
                ) {
                    converted = mulDiv({x: source.value, y: price, denominator: 10 ** source.decimals});
                } catch {}
            } catch {}
        }
    }

    //*********************************************************************//
    // -------------------- external state-changing ---------------------- //
    //*********************************************************************//

    /// @notice Build the cross-chain snapshot message (total supply, surplus, balance).
    /// @dev Extracted from `JBSucker._buildSnapshotAndSend` to reduce child contract bytecode.
    /// Called via DELEGATECALL. Includes ETH aggregate computation inline (cannot call own external fns).
    /// @param directory The JB directory to look up controllers and terminals.
    /// @param projectId The project ID.
    /// @param remoteToken The remote token bytes32 address.
    /// @param amount The amount of terminal tokens being bridged.
    /// @param nonce The outbox nonce for this send.
    /// @param root The merkle root of the outbox tree.
    /// @param messageVersion The message format version.
    /// @param sourceTimestamp The `block.timestamp` on the source chain when the snapshot is taken.
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
        // Will hold the total token supply (including reserved tokens) for the project.
        uint256 localTotalSupply;

        // Get the controller and verify it implements IJBController via ERC165 before querying supply.
        // slither-disable-next-line calls-loop
        try directory.controllerOf(projectId) returns (IERC165 controllerIERC165) {
            if (address(controllerIERC165) != address(0)) {
                // slither-disable-next-line calls-loop
                try controllerIERC165.supportsInterface(type(IJBController).interfaceId) returns (bool supported) {
                    if (supported) {
                        // slither-disable-next-line calls-loop
                        localTotalSupply =
                            IJBController(address(controllerIERC165)).totalTokenSupplyWithReservedTokensOf(projectId);
                    }
                } catch {}
            }
        } catch {}

        // Inline ETH aggregate computation (libraries cannot call their own external functions).
        (uint256 ethSurplus, uint256 ethBalance) =
            _buildETHAggregateInternal({directory: directory, projectId: projectId});

        // Construct the cross-chain message with the snapshot data.
        message = JBMessageRoot({
            version: messageVersion,
            token: remoteToken,
            amount: amount,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: root}),
            sourceTotalSupply: localTotalSupply,
            sourceCurrency: _NATIVE_TOKEN_CURRENCY,
            sourceDecimals: _ETH_DECIMALS,
            sourceSurplus: ethSurplus,
            sourceBalance: ethBalance,
            sourceTimestamp: sourceTimestamp
        });
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
