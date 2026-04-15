// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBFixedPointNumber} from "@bananapus/core-v6/src/libraries/JBFixedPointNumber.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {JBDenominatedAmount} from "../structs/JBDenominatedAmount.sol";
import {JBInboxTreeRoot} from "../structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../structs/JBMessageRoot.sol";
import {JBPayRemoteMessage} from "../structs/JBPayRemoteMessage.sol";
import {JBRelayBeneficiary} from "./JBRelayBeneficiary.sol";
import {MerkleLib} from "../utils/MerkleLib.sol";

/// @notice Library with bytecode-heavy functions extracted from JBSucker to reduce child contract sizes.
/// @dev These are `external` library functions, so they are deployed as a separate contract and called via
/// DELEGATECALL. This avoids duplicating the bytecode in every sucker implementation.
library JBSuckerLib {
    using SafeERC20 for IERC20;

    // ------------------------- custom errors ---------------------------- //

    error JBSuckerLib_NoTerminalForToken(uint256 projectId, address token);
    error JBSuckerLib_InsufficientBalance(uint256 amount, uint256 balance);

    // ------------------------- internal constants ----------------------- //

    uint256 internal constant _ETH_CURRENCY = JBCurrencyIds.ETH;
    uint8 internal constant _ETH_DECIMALS = 18;

    // ------------------------- external views -------------------------- //

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

    // -------------------- internal helpers --------------------------- //

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
            projectId: projectId, tokens: new address[](0), decimals: _ETH_DECIMALS, currency: uint32(_ETH_CURRENCY)
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
                            if (tokenCurrency == uint32(_ETH_CURRENCY)) {
                                ethBalance += JBFixedPointNumber.adjustDecimals({
                                    value: bal, decimals: dec, targetDecimals: _ETH_DECIMALS
                                });
                            } else {
                                // Otherwise, convert the balance to ETH using the price oracle.
                                // slither-disable-next-line calls-loop
                                try prices.pricePerUnitOf({
                                    projectId: projectId,
                                    pricingCurrency: tokenCurrency,
                                    unitCurrency: uint32(_ETH_CURRENCY),
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

    // -------------------- external state-changing -------------------- //

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
    /// @param snapshotNonce The snapshot nonce (caller should pre-increment).
    /// @return message The constructed JBMessageRoot.
    function buildSnapshotMessage(
        IJBDirectory directory,
        uint256 projectId,
        bytes32 remoteToken,
        uint256 amount,
        uint64 nonce,
        bytes32 root,
        uint8 messageVersion,
        uint64 snapshotNonce
    )
        external
        view
        returns (JBMessageRoot memory message)
    {
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

        message = JBMessageRoot(
            messageVersion,
            remoteToken,
            amount,
            JBInboxTreeRoot(nonce, root),
            localTotalSupply,
            _ETH_CURRENCY,
            _ETH_DECIMALS,
            ethSurplus,
            ethBalance,
            snapshotNonce
        );
    }

    /// @notice Execute a cross-chain payment: pay project, cash out at 0% tax.
    /// @dev Runs via DELEGATECALL so external calls use the sucker's address/balance.
    /// @param directory The JB directory.
    /// @param projectId The local project ID.
    /// @param message The payment message from the remote chain.
    /// @return projectTokensReceived The project tokens received from the pay.
    /// @return terminalTokensReclaimed The terminal tokens reclaimed from the cash out.
    function executePayFromRemote(
        IJBDirectory directory,
        uint256 projectId,
        JBPayRemoteMessage calldata message
    )
        external
        returns (uint256 projectTokensReceived, uint256 terminalTokensReclaimed)
    {
        address token = address(uint160(uint256(message.token)));

        // Get the terminal for this token.
        IJBTerminal terminal = directory.primaryTerminalOf({projectId: projectId, token: token});
        if (address(terminal) == address(0)) {
            revert JBSuckerLib_NoTerminalForToken(projectId, token);
        }

        // Inject the relay beneficiary into the metadata so hooks see the real user.
        bytes memory payMetadata = JBMetadataResolver.addToMetadata(
            message.metadata, JBRelayBeneficiary.ID, abi.encode(address(uint160(uint256(message.beneficiary))))
        );

        // Pay the project with this sucker as beneficiary (so we receive project tokens).
        uint256 nativePayValue = token == JBConstants.NATIVE_TOKEN ? message.amount : 0;
        if (token != JBConstants.NATIVE_TOKEN) {
            SafeERC20.forceApprove({token: IERC20(token), spender: address(terminal), value: message.amount});
        }
        projectTokensReceived = terminal.pay{value: nativePayValue}({
            projectId: projectId,
            token: token,
            amount: message.amount,
            beneficiary: address(this),
            minReturnedTokens: message.minTokensOut,
            memo: "",
            metadata: payMetadata
        });

        // Cash out the project tokens at 0% tax (sucker privilege via data hook).
        IJBCashOutTerminal cashOutTerminal = IJBCashOutTerminal(address(terminal));
        terminalTokensReclaimed = cashOutTerminal.cashOutTokensOf({
            holder: address(this),
            projectId: projectId,
            cashOutCount: projectTokensReceived,
            tokenToReclaim: token,
            minTokensReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: bytes("")
        });
    }

    /// @notice Pay the toRemote fee into the fee project. Best-effort (does not revert on failure).
    /// @dev Runs via DELEGATECALL so msg.value is available.
    /// @param directory The JB directory.
    /// @param feeProjectId The project ID that receives the fee.
    /// @param feeAmount The fee amount in native token.
    /// @param sender The original sender (gets fee project tokens).
    function payToRemoteFee(
        IJBDirectory directory,
        uint256 feeProjectId,
        uint256 feeAmount,
        address sender
    )
        external
    {
        IJBTerminal terminal = directory.primaryTerminalOf({projectId: feeProjectId, token: JBConstants.NATIVE_TOKEN});
        if (address(terminal) != address(0)) {
            // slither-disable-next-line unused-return,reentrancy-events
            try terminal.pay{value: feeAmount}({
                projectId: feeProjectId,
                token: JBConstants.NATIVE_TOKEN,
                amount: feeAmount,
                beneficiary: sender,
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            }) returns (uint256) {}
                catch {}
        }
    }

    /// @notice Cash out project tokens for terminal tokens.
    /// @dev Runs via DELEGATECALL so the sucker's token balance and address are used.
    /// @param directory The JB directory.
    /// @param projectId The project ID.
    /// @param count The number of project tokens to cash out.
    /// @param token The terminal token to cash out for.
    /// @param minTokensReclaimed Minimum terminal tokens to reclaim.
    /// @return reclaimedAmount The terminal tokens reclaimed.
    function pullBackingAssets(
        IJBDirectory directory,
        uint256 projectId,
        uint256 count,
        address token,
        uint256 minTokensReclaimed
    )
        external
        returns (uint256 reclaimedAmount)
    {
        // Get the project's primary terminal for `token`.
        IJBCashOutTerminal terminal =
            IJBCashOutTerminal(address(directory.primaryTerminalOf({projectId: projectId, token: token})));

        if (address(terminal) == address(0)) {
            revert JBSuckerLib_NoTerminalForToken({projectId: projectId, token: token});
        }

        // Cash out the tokens.
        uint256 balanceBefore = _balanceOfToken(token, address(this));
        reclaimedAmount = terminal.cashOutTokensOf({
            holder: address(this),
            projectId: projectId,
            cashOutCount: count,
            tokenToReclaim: token,
            minTokensReclaimed: minTokensReclaimed,
            beneficiary: payable(address(this)),
            metadata: bytes("")
        });

        // Sanity check to make sure we received the expected amount.
        // slither-disable-next-line incorrect-equality
        assert(reclaimedAmount == _balanceOfToken(token, address(this)) - balanceBefore);
    }

    /// @notice Mint project tokens for a beneficiary via the controller.
    /// @dev Runs via DELEGATECALL.
    /// @param directory The JB directory.
    /// @param projectId The project ID.
    /// @param tokenCount The number of tokens to mint.
    /// @param beneficiary The address receiving the tokens.
    function mintTokensFor(
        IJBDirectory directory,
        uint256 projectId,
        uint256 tokenCount,
        address beneficiary
    )
        external
    {
        // slither-disable-next-line calls-loop,unused-return
        IJBController(address(directory.controllerOf(projectId)))
            .mintTokensOf({
                projectId: projectId,
                tokenCount: tokenCount,
                beneficiary: beneficiary,
                memo: "",
                useReservedPercent: false
            });
    }

    // -------------------- merkle tree helpers ------------------------ //

    /// @notice Compute the merkle tree root from branch and count. Loop-based replacement for the unrolled
    /// MerkleLib.root() — saves ~3KB per sucker when called via DELEGATECALL instead of inlining.
    /// @param branch The 32-element branch array (caller copies from storage to memory).
    /// @param count The number of leaves inserted into the tree.
    /// @return current The merkle root.
    function computeTreeRoot(bytes32[32] memory branch, uint256 count) external pure returns (bytes32 current) {
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

    /// @notice Compute a branch root from a leaf, branch, and index. Wraps MerkleLib.branchRoot so its
    /// ~170 lines of unrolled assembly live in the library's bytecode instead of each sucker's.
    /// @param item The leaf hash.
    /// @param branch The 32-element merkle proof branch.
    /// @param index The leaf index.
    /// @return The computed merkle root.
    function computeBranchRoot(
        bytes32 item,
        bytes32[32] memory branch,
        uint256 index
    )
        external
        pure
        returns (bytes32)
    {
        return MerkleLib.branchRoot(item, branch, index);
    }

    // -------------------- internal helpers --------------------------- //

    /// @dev Helper to get token balance (handles native token).
    function _balanceOfToken(address token, address addr) internal view returns (uint256) {
        if (token == JBConstants.NATIVE_TOKEN) return addr.balance;
        return IERC20(token).balanceOf(addr);
    }

    /// @notice Add terminal tokens to a project's balance.
    /// @dev Runs via DELEGATECALL so the sucker's token balance and ETH are used.
    /// @param directory The JB directory.
    /// @param projectId The project ID.
    /// @param token The terminal token.
    /// @param amount The amount to add.
    function addToProjectBalance(IJBDirectory directory, uint256 projectId, address token, uint256 amount) external {
        // Get the project's primary terminal for the token.
        // slither-disable-next-line calls-loop
        IJBTerminal terminal = directory.primaryTerminalOf({projectId: projectId, token: token});

        // slither-disable-next-line incorrect-equality
        if (address(terminal) == address(0)) {
            revert JBSuckerLib_NoTerminalForToken({projectId: projectId, token: token});
        }

        // Perform the `addToBalance`.
        if (token != JBConstants.NATIVE_TOKEN) {
            // slither-disable-next-line calls-loop
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));

            SafeERC20.forceApprove({token: IERC20(token), spender: address(terminal), value: amount});

            // slither-disable-next-line calls-loop
            terminal.addToBalanceOf({
                projectId: projectId,
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
                projectId: projectId,
                token: token,
                amount: amount,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: ""
            });
        }
    }
}
