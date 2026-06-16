// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IJBPeerChainAdjustedAccounts} from "../interfaces/IJBPeerChainAdjustedAccounts.sol";
import {IJBSuckerRegistry} from "../interfaces/IJBSuckerRegistry.sol";

import {JBPeerChainAdjustedAccountsLib} from "./JBPeerChainAdjustedAccountsLib.sol";
import {MerkleLib} from "../utils/MerkleLib.sol";

import {JBAccountingSnapshot} from "../structs/JBAccountingSnapshot.sol";
import {JBChainAccounting} from "../structs/JBChainAccounting.sol";
import {JBInboxTreeRoot} from "../structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../structs/JBMessageRoot.sol";
import {JBPeerChainContext} from "../structs/JBPeerChainContext.sol";
import {JBSourceContext} from "../structs/JBSourceContext.sol";

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

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Build the cross-chain accounting gossip bundle (the local chain's record plus known peer records).
    /// @dev Extracted from `JBSucker.syncAccountingData` to reduce child contract bytecode. Called via DELEGATECALL.
    /// Each record carries its source chain's surplus and balance per context in that context's own currency, without
    /// price-feed valuation.
    /// @param directory The JB directory to look up controllers and terminals.
    /// @param registry The sucker registry that aggregates the project's per-chain records.
    /// @param projectId The project ID.
    /// @param exceptChainId The destination chain, excluded from the gathered peer records.
    /// @param messageVersion The message format version.
    /// @param sourceTimestamp The monotonic source freshness key for the local chain's record.
    /// @return snapshot The constructed accounting snapshot.
    function buildAccountingSnapshot(
        IJBDirectory directory,
        IJBSuckerRegistry registry,
        uint256 projectId,
        uint256 exceptChainId,
        uint8 messageVersion,
        uint256 sourceTimestamp
    )
        external
        view
        returns (JBAccountingSnapshot memory snapshot)
    {
        // Construct the accounting-only message without any token-local merkle root.
        snapshot = JBAccountingSnapshot({
            version: messageVersion,
            accounts: _buildGossipBundle({
                directory: directory,
                registry: registry,
                projectId: projectId,
                exceptChainId: exceptChainId,
                sourceTimestamp: sourceTimestamp
            })
        });
    }

    /// @notice Build the cross-chain root message, carrying the accounting gossip bundle alongside the outbox root.
    /// @dev Extracted from `JBSucker._buildSnapshotAndSend` to reduce child contract bytecode. Called via DELEGATECALL.
    /// Each accounting record carries its source chain's surplus and balance per context in that context's own
    /// currency, without price-feed valuation.
    /// @param directory The JB directory to look up controllers and terminals.
    /// @param registry The sucker registry that aggregates the project's per-chain records.
    /// @param projectId The project ID.
    /// @param exceptChainId The destination chain, excluded from the gathered peer records.
    /// @param remoteToken The remote token bytes32 address.
    /// @param amount The amount of terminal tokens to bridge.
    /// @param nonce The outbox nonce for this send.
    /// @param root The merkle root of the outbox tree.
    /// @param messageVersion The message format version.
    /// @param sourceTimestamp The monotonic source freshness key for the local chain's record.
    /// @return message The constructed JBMessageRoot.
    function buildSnapshotMessage(
        IJBDirectory directory,
        IJBSuckerRegistry registry,
        uint256 projectId,
        uint256 exceptChainId,
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
        // Construct the cross-chain message with the outbox root and the accounting gossip bundle.
        message = JBMessageRoot({
            version: messageVersion,
            token: remoteToken,
            amount: amount,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: root}),
            accounts: _buildGossipBundle({
                directory: directory,
                registry: registry,
                projectId: projectId,
                exceptChainId: exceptChainId,
                sourceTimestamp: sourceTimestamp
            })
        });
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

    /// @notice Folds a peer chain's source contexts into per-currency surplus and balance.
    /// @dev Extracted from `JBSucker.peerChainContextsOf` to reduce child contract bytecode. Called via DELEGATECALL.
    /// The caller stores mapped remote-token keys in its local token namespace before this runs. This derives each
    /// token's authoritative accounting-context currency and merges entries that share BOTH currency AND decimals. The
    /// accounting-context currency is immutable, so re-resolving on each read is safe. Entries that share a currency
    /// but carry different decimals stay separate, since the raw amounts are on different scales. No price oracle is
    /// consulted.
    /// @param directory The JB directory to look up the project's terminals.
    /// @param projectId The project whose accounting contexts to read.
    /// @param rawContexts The peer chain's per-context surplus and balance.
    /// @return contexts The per-currency surplus and balance for the chain.
    function foldPeerContexts(
        IJBDirectory directory,
        uint256 projectId,
        JBSourceContext[] memory rawContexts
    )
        external
        view
        returns (JBPeerChainContext[] memory contexts)
    {
        uint256 numRaw = rawContexts.length;

        // The folded set is no larger than the raw set, so allocate to that upper bound and track the populated length.
        JBPeerChainContext[] memory buf = new JBPeerChainContext[](numRaw);
        uint256 count;

        for (uint256 i; i < numRaw;) {
            uint8 ctxDecimals = rawContexts[i].decimals;
            uint128 ctxSurplus = rawContexts[i].surplus;
            uint128 ctxBalance = rawContexts[i].balance;
            address token = address(uint160(uint256(rawContexts[i].token)));
            uint32 ctxCurrency = _currencyOf({directory: directory, projectId: projectId, token: token});

            // Fold into an existing entry that matches on BOTH currency AND decimals, or append a new one.
            bool merged;
            for (uint256 j; j < count;) {
                if (buf[j].currency == ctxCurrency && buf[j].decimals == ctxDecimals) {
                    buf[j].surplus = _saturatingAddU128(buf[j].surplus, ctxSurplus);
                    buf[j].balance = _saturatingAddU128(buf[j].balance, ctxBalance);
                    merged = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            if (!merged) {
                buf[count++] = JBPeerChainContext({
                    currency: ctxCurrency, decimals: ctxDecimals, surplus: ctxSurplus, balance: ctxBalance
                });
            }

            unchecked {
                ++i;
            }
        }

        // Trim the over-allocated buffer to the folded length.
        contexts = new JBPeerChainContext[](count);
        for (uint256 k; k < count;) {
            contexts[k] = buf[k];
            unchecked {
                ++k;
            }
        }
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice Assemble a cross-chain accounting gossip bundle: the local chain's own record plus every peer-chain
    /// record the project's suckers currently hold, excluding the destination chain.
    /// @dev The local record is taken fresh from `_snapshotAccountsOf` (including any data-hook adjusted accounts). The
    /// peer records are gathered from the registry, which is the only contract that sees a hub chain's per-peer
    /// suckers together; it dedups them to the freshest per chain. A reverting or unset registry yields a local-only
    /// bundle, so a standalone sucker still propagates its own record. Forwarded peer records keep their own origin
    /// chain and freshness key, while their context token keys are already localized by the sucker they were gathered
    /// from so the receiver only needs its mapping to the direct peer's token.
    /// @param directory The JB directory to look up controllers and terminals.
    /// @param registry The sucker registry that aggregates the project's per-chain records.
    /// @param projectId The project to snapshot.
    /// @param exceptChainId The destination chain, excluded from the gathered peer records.
    /// @param sourceTimestamp The local record's freshness key.
    /// @return accounts The assembled gossip bundle, with the local chain's record first.
    function _buildGossipBundle(
        IJBDirectory directory,
        IJBSuckerRegistry registry,
        uint256 projectId,
        uint256 exceptChainId,
        uint256 sourceTimestamp
    )
        internal
        view
        returns (JBChainAccounting[] memory accounts)
    {
        // Snapshot the local chain's own supply and per-context surplus/balance, un-valued. No price oracle is read.
        (uint256 localTotalSupply, JBSourceContext[] memory localContexts) =
            _snapshotAccountsOf({directory: directory, projectId: projectId});

        // Gather every other chain's record the project knows, deduped per chain and minus the destination. The
        // accounting gossip is best-effort, so a reverting registry must never break the essential root/token bridge:
        // catch the failure and propagate just this chain's own record.
        JBChainAccounting[] memory peers;
        try registry.peerChainAccountsOf({projectId: projectId, exceptChainId: exceptChainId}) returns (
            JBChainAccounting[] memory gathered
        ) {
            peers = gathered;
        } catch {}

        // The local record leads; forwarded peer records follow, keeping their own origin chain and freshness.
        accounts = new JBChainAccounting[](peers.length + 1);
        accounts[0] = JBChainAccounting({
            chainId: block.chainid, totalSupply: localTotalSupply, contexts: localContexts, timestamp: sourceTimestamp
        });
        for (uint256 i; i < peers.length;) {
            accounts[i + 1] = peers[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Builds the project's per-accounting-context surplus and balance, each in the context's own currency,
    /// with no price-feed valuation.
    /// @dev Loops every terminal and accounting context, reading the raw per-token surplus (requested in the token's
    /// own currency, so the terminal performs no conversion) and the raw recorded balance. Each external call is
    /// wrapped so a single broken terminal or context never bricks the snapshot. Amounts are capped to `uint128` for
    /// cross-VM (SVM) compatibility, matching the leaf-amount cap; the cap can only under-report, the safe direction
    /// for a remote surplus. The returned buffer is over-allocated by `extraSlots` so the caller can append data-hook
    /// contexts before trimming.
    /// @param directory The JB directory to look up terminals.
    /// @param projectId The project to snapshot.
    /// @param extraSlots Spare buffer slots to reserve for entries the caller appends after the terminal contexts.
    /// @return buf An over-allocated buffer of per-context entries (length may exceed `count`).
    /// @return count The number of populated entries in `buf`.
    function _buildSourceContexts(
        IJBDirectory directory,
        uint256 projectId,
        uint256 extraSlots
    )
        internal
        view
        returns (JBSourceContext[] memory buf, uint256 count)
    {
        IJBTerminal[] memory terminals = directory.terminalsOf(projectId);
        uint256 numTerminals = terminals.length;

        // First pass: count the accounting contexts so the buffer can be sized, reserving `extraSlots` of headroom for
        // entries the caller appends.
        uint256 upperBound = extraSlots;
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
                    buf[count++] =
                        _readSourceContext({terminal: terminals[i], projectId: projectId, context: contexts[j]});
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

    /// @notice The project's authoritative accounting-context currency for a local token, or a convention fallback.
    /// @dev Reads the token's accounting context from its primary terminal via length-guarded staticcalls, so a missing
    /// or non-conforming directory/terminal just yields the fallback. Falls back to `uint32(uint160(token))` when the
    /// project has no local accounting context for the token yet. The accounting-context currency is immutable.
    /// @param directory The JB directory to look up the project's primary terminal for the token.
    /// @param projectId The project whose accounting context to read.
    /// @param token The local token to resolve the currency of.
    /// @return currency The project's accounting-context currency for the token.
    function _currencyOf(
        IJBDirectory directory,
        uint256 projectId,
        address token
    )
        internal
        view
        returns (uint32 currency)
    {
        // Resolve the project's primary terminal for the token. An `address` return needs a full word.
        (bool terminalOk, bytes memory terminalData) =
            address(directory).staticcall(abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, token)));
        if (terminalOk && terminalData.length >= 32) {
            address terminal = abi.decode(terminalData, (address));
            if (terminal != address(0)) {
                // Read the token's accounting context. The struct encodes to three words.
                (bool contextOk, bytes memory contextData) =
                    terminal.staticcall(abi.encodeCall(IJBTerminal.accountingContextForTokenOf, (projectId, token)));
                if (contextOk && contextData.length >= 96) {
                    JBAccountingContext memory accountingContext = abi.decode(contextData, (JBAccountingContext));
                    if (accountingContext.currency != 0) return accountingContext.currency;
                }
            }
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(uint160(token));
    }

    /// @notice Optional project-specific adjusted accounts to add to peer-chain snapshots.
    /// @dev Reads the current ruleset's data hook and asks it for extra supply plus per-context surplus/balance, each
    /// in the context's own currency. Non-supporting or broken hooks are ignored so a project's baseline snapshot stays
    /// usable.
    /// @param controller The controller for the project to snapshot.
    /// @param projectId The project to snapshot.
    /// @return additionalSupply The project token supply to add to `sourceTotalSupply`.
    /// @return additionalContexts The per-context surplus and balance to add to the snapshot, un-valued.
    function _peerChainAdjustedAccountsOf(
        IJBController controller,
        uint256 projectId
    )
        internal
        view
        returns (uint256 additionalSupply, JBSourceContext[] memory additionalContexts)
    {
        // Use staticcall because older/downstream controllers may not expose the exact typed return expected here.
        (bool rulesetCallSucceeded, bytes memory rulesetData) =
            address(controller).staticcall(abi.encodeCall(IJBController.currentRulesetOf, (projectId)));
        if (!rulesetCallSucceeded || rulesetData.length < _CURRENT_RULESET_OF_RETURN_BYTES) {
            return (0, new JBSourceContext[](0));
        }

        // The ruleset metadata packs the active data hook; projects without a hook need no adjustment.
        (JBRuleset memory ruleset,) = abi.decode(rulesetData, (JBRuleset, JBRulesetMetadata));

        address dataHook = ruleset.dataHook();
        if (dataHook == address(0) || dataHook.code.length == 0) return (0, new JBSourceContext[](0));

        // Ask the hook for any off-terminal supply and per-context surplus/balance. Non-supporting, broken, or
        // malformed hooks are ignored so the baseline snapshot still goes out.
        (bool hookCallSucceeded, bytes memory hookData) =
            dataHook.staticcall(abi.encodeCall(IJBPeerChainAdjustedAccounts.peerChainAdjustedAccountsOf, (projectId)));
        if (!hookCallSucceeded) return (0, new JBSourceContext[](0));

        return JBPeerChainAdjustedAccountsLib.decode(hookData);
    }

    /// @notice Reads one accounting context's raw surplus and balance into a `JBSourceContext`, performing no price
    /// valuation.
    /// @dev Surplus is requested in the context's own currency so the terminal returns the raw token amount rather
    /// than converting it. Both reads are wrapped so a broken terminal yields zero instead of reverting the whole
    /// snapshot. Extracted from the snapshot loop to keep that loop's stack shallow.
    /// @param terminal The terminal holding the context.
    /// @param projectId The project to read.
    /// @param context The accounting context (token, decimals, currency) to read.
    /// @return The per-context entry keyed by the source-local token, with amounts capped to `uint128`.
    function _readSourceContext(
        IJBTerminal terminal,
        uint256 projectId,
        JBAccountingContext memory context
    )
        internal
        view
        returns (JBSourceContext memory)
    {
        address[] memory oneToken = new address[](1);
        oneToken[0] = context.token;

        // Raw surplus for this one token, requested in its own currency so the terminal does not value it.
        uint256 surplus;
        try terminal.currentSurplusOf({
            projectId: projectId, tokens: oneToken, decimals: context.decimals, currency: context.currency
        }) returns (
            uint256 contextSurplus
        ) {
            surplus = contextSurplus;
        } catch {}

        // Raw recorded balance for this token.
        uint256 balance;
        try IJBMultiTerminal(address(terminal)).STORE()
            .balanceOf({terminal: address(terminal), projectId: projectId, token: context.token}) returns (
            uint256 contextBalance
        ) {
            balance = contextBalance;
        } catch {}

        return JBSourceContext({
            token: bytes32(uint256(uint160(context.token))),
            decimals: context.decimals,
            surplus: _toUint128(surplus),
            balance: _toUint128(balance)
        });
    }

    /// @notice Adds two `uint128` amounts, saturating at `type(uint128).max` instead of overflowing.
    /// @dev Saturation keeps a pathological peer record from reverting the read path; the cap can only under-report a
    /// remote amount, the safe direction.
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

    /// @notice Builds the local accounting values used in outbound peer-chain snapshots.
    /// @dev Project token supply stays a single currency-agnostic scalar. Surplus and balance are emitted per context
    /// in that context's currency, with no price-feed valuation. The receiving chain folds each context into its
    /// same-asset local context at par. A project data hook may contribute additional supply plus its own per-context
    /// surplus/balance, appended to the terminal contexts.
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

        // Ask the project's data hook for any extra supply and per-context surplus/balance first, so the terminal
        // buffer can reserve room for the hook's contexts.
        uint256 additionalSupply;
        JBSourceContext[] memory hookContexts;
        if (address(controller) != address(0) && address(controller).code.length != 0) {
            (additionalSupply, hookContexts) =
                _peerChainAdjustedAccountsOf({controller: controller, projectId: projectId});
            // Fail soft to the baseline snapshot. A malformed hook that returns a `supply` which would overflow the
            // controller supply contributes no extra supply or contexts — the documented fail-soft model — instead
            // of
            // reverting the whole snapshot and bricking every outbound send (`toRemote` / `syncAccountingData`) while
            // the hook stays active.
            if (additionalSupply > type(uint256).max - localTotalSupply) {
                additionalSupply = 0;
                hookContexts = new JBSourceContext[](0);
            }
            localTotalSupply += additionalSupply;
        }

        // Terminal contexts, raw and un-valued, with headroom for the hook contexts.
        (JBSourceContext[] memory buf, uint256 count) =
            _buildSourceContexts({directory: directory, projectId: projectId, extraSlots: hookContexts.length});

        // Append the hook's contexts in their own currencies — folded in at par downstream, exactly like the terminal
        // contexts, so no valuation happens here either.
        for (uint256 h; h < hookContexts.length;) {
            buf[count++] = hookContexts[h];
            unchecked {
                ++h;
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

    /// @notice Caps a value to the `uint128` cross-VM amount ceiling. Capping can only under-report, the safe
    /// direction for a remote surplus.
    /// @param value The value to cap.
    /// @return The value, or `type(uint128).max` if it exceeds the ceiling.
    function _toUint128(uint256 value) internal pure returns (uint128) {
        // The cast only runs when `value <= type(uint128).max`, so it cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return value > type(uint128).max ? type(uint128).max : uint128(value);
    }
}
