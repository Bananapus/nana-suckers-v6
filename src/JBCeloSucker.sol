// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {JBSucker} from "./JBSucker.sol";
import {JBOptimismSucker} from "./JBOptimismSucker.sol";
import {JBCeloSuckerDeployer} from "./deployers/JBCeloSuckerDeployer.sol";
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";
import {IWrappedNativeToken} from "./interfaces/IWrappedNativeToken.sol";
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBRemoteToken} from "./structs/JBRemoteToken.sol";
import {JBTokenMapping} from "./structs/JBTokenMapping.sol";

/// @notice A `JBSucker` implementation for Celo — an OP Stack chain with a custom gas token (CELO, not ETH).
/// @dev ETH exists on Celo only as an ERC-20 (WETH). This sucker wraps native ETH → WETH before bridging
/// as ERC-20 via the OP standard bridge, and removes the `NATIVE_TOKEN → NATIVE_TOKEN` restriction so that
/// native ETH can map to a remote ERC-20.
contract JBCeloSucker is JBOptimismSucker {
    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The wrapped native token (WETH) on the local chain.
    IWrappedNativeToken public immutable WRAPPED_NATIVE;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param deployer A contract that deploys the clones for this contracts.
    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param permissions A contract storing permissions.
    /// @param tokens A contract that manages token minting and burning.
    constructor(
        JBCeloSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        uint256 feeProjectId,
        IJBSuckerRegistry registry,
        address trustedForwarder
    )
        JBOptimismSucker(deployer, directory, permissions, tokens, feeProjectId, registry, trustedForwarder)
    {
        // Fetch the wrapped native token by doing a callback to the deployer contract.
        WRAPPED_NATIVE = JBCeloSuckerDeployer(deployer).wrappedNative();
    }

    //*********************************************************************//
    // ------------------------ external views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the chain on which the peer is located.
    /// @return chainId of the peer.
    function peerChainId() external view virtual override returns (uint256) {
        uint256 chainId = block.chainid;
        if (chainId == 1) return 42_220;
        if (chainId == 42_220) return 1;
        return 0;
    }

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Unwraps WETH → native ETH before adding to the project's balance.
    /// @dev When tokens are bridged from Celo → L1 via the OP bridge, L1 WETH (ERC-20) is released to the sucker.
    /// But the L1 project's terminal accepts native ETH (NATIVE_TOKEN), not WETH. This override unwraps the WETH
    /// and adds native ETH to the project's balance.
    /// @param token The terminal token to add to the project's balance.
    /// @param amount The amount of terminal tokens to add to the project's balance.
    /// @param cachedProjectId The cached project ID to avoid redundant storage reads.
    function _addToBalance(address token, uint256 amount, uint256 cachedProjectId) internal override {
        if (token == address(WRAPPED_NATIVE)) {
            // Check addable amount against WETH balance before unwrapping.
            uint256 addableAmount = amountToAddToBalanceOf(token);
            if (amount > addableAmount) {
                revert JBSucker_InsufficientBalance(amount, addableAmount);
            }

            // Unwrap WETH → native ETH.
            // slither-disable-next-line calls-loop
            WRAPPED_NATIVE.withdraw(amount);

            // Get the project's primary terminal for native token.
            // slither-disable-next-line calls-loop
            IJBTerminal terminal =
                DIRECTORY.primaryTerminalOf({projectId: cachedProjectId, token: JBConstants.NATIVE_TOKEN});

            if (address(terminal) == address(0)) {
                revert JBSucker_NoTerminalForToken(cachedProjectId, JBConstants.NATIVE_TOKEN);
            }

            // Add native ETH to the project's balance.
            // slither-disable-next-line arbitrary-send-eth,calls-loop
            terminal.addToBalanceOf{value: amount}({
                projectId: cachedProjectId,
                token: JBConstants.NATIVE_TOKEN,
                amount: amount,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: ""
            });
        } else {
            super._addToBalance({token: token, amount: amount, cachedProjectId: cachedProjectId});
        }
    }

    /// @notice Use the `OPMESSENGER` to send the outbox tree for the `token` and the corresponding funds to the peer
    /// over the `OPBRIDGE`.
    /// @dev For Celo, native ETH is wrapped to WETH and bridged as ERC-20. The messenger message is sent with
    /// `nativeValue = 0` because Celo's native token is CELO (not ETH), so we never attach ETH as msg.value.
    /// @param transportPayment the amount of `msg.value` that is going to get paid for sending this message.
    /// @param token The token to bridge the outbox tree for.
    /// @param remoteToken Information about the remote token being bridged to.
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
        override
    {
        index; // Silence unused parameter warning (not needed for Celo bridge).

        // Revert if there's a `msg.value`. The OP bridge does not expect to be paid.
        if (transportPayment != 0) {
            revert JBSucker_UnexpectedMsgValue(transportPayment);
        }

        // Cache peer address to avoid redundant calls.
        address peerAddress = _toAddress(peer());

        if (amount != 0) {
            // Determine the local token to bridge — native ETH is wrapped to WETH first.
            address bridgeToken = token;
            if (token == JBConstants.NATIVE_TOKEN) {
                // Wrap native ETH → WETH so it can be bridged as ERC-20.
                // slither-disable-next-line arbitrary-send-eth,calls-loop
                WRAPPED_NATIVE.deposit{value: amount}();
                bridgeToken = address(WRAPPED_NATIVE);
            }

            // Approve the bridge to spend the token.
            // slither-disable-next-line reentrancy-events
            SafeERC20.forceApprove({token: IERC20(bridgeToken), spender: address(OPBRIDGE), value: amount});

            // Bridge the ERC-20 token to the peer.
            // slither-disable-next-line reentrancy-events,calls-loop
            OPBRIDGE.bridgeERC20To({
                localToken: bridgeToken,
                remoteToken: _toAddress(remoteToken.addr),
                to: peerAddress,
                amount: amount,
                minGasLimit: remoteToken.minGas,
                extraData: bytes("")
            });
        }

        // Send the messenger message with nativeValue = 0.
        // Celo's native token is CELO, not ETH — we never attach ETH as msg.value on the messenger.
        // On L1, the ETH was already wrapped and bridged as ERC-20 above.
        // slither-disable-next-line reentrancy-events,calls-loop
        OPMESSENGER.sendMessage({
            target: peerAddress,
            message: abi.encodeCall(JBSucker.fromRemote, (message)),
            gasLimit: MESSENGER_BASE_GAS_LIMIT
        });
    }

    /// @notice Allow `NATIVE_TOKEN` to map to any remote token (not just `NATIVE_TOKEN`).
    /// @dev Celo uses CELO as native gas token. ETH is an ERC-20 on Celo (WETH). So `NATIVE_TOKEN` on L1
    /// maps to an ERC-20 address on Celo, not to `NATIVE_TOKEN`. The base class restriction is removed.
    function _validateTokenMapping(JBTokenMapping calldata map) internal pure virtual override {
        // Enforce a reasonable minimum gas limit for bridging. Since we always bridge as ERC-20
        // (wrapping native ETH to WETH), all tokens need sufficient gas for an ERC-20 transfer.
        if (map.minGas < MESSENGER_ERC20_MIN_GAS_LIMIT) {
            revert JBSucker_BelowMinGas(map.minGas, MESSENGER_ERC20_MIN_GAS_LIMIT);
        }
    }
}
