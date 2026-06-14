// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {JBSucker} from "./JBSucker.sol";
import {JBOptimismSuckerDeployer} from "./deployers/JBOptimismSuckerDeployer.sol";
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";
import {IJBOptimismSucker} from "./interfaces/IJBOptimismSucker.sol";
import {IOPMessenger} from "./interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "./interfaces/IOPStandardBridge.sol";
import {JBAccountingSnapshot} from "./structs/JBAccountingSnapshot.sol";
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBRemoteToken} from "./structs/JBRemoteToken.sol";

/// @notice A `JBSucker` implementation that bridges Juicebox project tokens and terminal-token funds between two
/// chains connected by an OP Stack bridge (Optimism, Base, etc.). Uses the `CrossDomainMessenger` for merkle-root
/// messages and the `StandardBridge` for ERC-20/native token transfers.
contract JBOptimismSucker is JBSucker, IJBOptimismSucker {
    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The bridge used to bridge tokens between the local and remote chain.
    IOPStandardBridge public immutable override OPBRIDGE;

    /// @notice The messenger used to send messages between the local and remote sucker.
    IOPMessenger public immutable override OPMESSENGER;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param deployer A contract that deploys clones of this contract.
    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param permissions A contract storing permissions.
    /// @param tokens A contract that manages token minting and burning.
    constructor(
        JBOptimismSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        uint256 feeProjectId,
        IJBSuckerRegistry registry,
        address trustedForwarder
    )
        JBSucker(directory, permissions, tokens, feeProjectId, registry, trustedForwarder)
    {
        // Fetch the messenger and bridge by doing a callback to the deployer contract.
        OPBRIDGE = JBOptimismSuckerDeployer(deployer).opBridge();
        OPMESSENGER = JBOptimismSuckerDeployer(deployer).opMessenger();
    }

    //*********************************************************************//
    // ------------------------- public views ---------------------------- //
    //*********************************************************************//

    /// @notice Returns the chain on which the peer is located.
    /// @return chainId of the peer.
    function peerChainId() public view virtual override returns (uint256) {
        uint256 chainId = block.chainid;
        if (chainId == 1) return 10;
        if (chainId == 10) return 1;
        if (chainId == 11_155_111) return 11_155_420;
        if (chainId == 11_155_420) return 11_155_111;
        return 0;
    }

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Checks if the `sender` (`_msgSender()`) is a valid representative of the remote peer.
    /// @param sender The message's sender.
    /// @return valid A flag if the sender is a valid representative of the remote peer.
    function _isRemotePeer(address sender) internal override returns (bool valid) {
        return sender == address(OPMESSENGER) && _toBytes32(OPMESSENGER.xDomainMessageSender()) == peer();
    }

    /// @notice Uses the OP messenger to send accounting data over the bridge to the peer.
    /// @param transportPayment The amount of `msg.value` that is going to get paid for sending this message.
    /// @param snapshot The accounting snapshot to send to the remote peer.
    // forge-lint: disable-next-line(mixed-case-function)
    function _sendAccountingSnapshotOverAMB(
        uint256 transportPayment,
        JBAccountingSnapshot memory snapshot
    )
        internal
        virtual
        override
    {
        // The OP messenger does not expect native transport payment for accounting-only messages.
        if (transportPayment != 0) {
            revert JBSucker_UnexpectedMsgValue({value: transportPayment});
        }

        OPMESSENGER.sendMessage({
            target: _toAddress(peer()),
            message: abi.encodeCall(JBSucker.fromRemoteAccounting, (snapshot)),
            // Scale the destination gas with the bundle so a larger mesh's accounting still stores in one relay.
            gasLimit: SafeCast.toUint32(_messagingGasLimit({accounts: snapshot.accounts}))
        });
    }

    /// @notice Use the `OPMESSENGER` to send the outbox tree for the `token` and the corresponding funds to the peer
    /// over the `OPBRIDGE`.
    /// @param transportPayment the amount of `msg.value` that is going to get paid for sending this message.
    /// @param token The token to bridge the outbox tree for.
    /// @param remoteToken Information about the remote token to bridge to.
    // forge-lint: disable-next-line(mixed-case-function)
    function _sendRootOverAMB(
        uint256 transportPayment,
        uint256,
        address token,
        uint256 amount,
        JBRemoteToken memory remoteToken,
        JBMessageRoot memory message
    )
        internal
        virtual
        override
    {
        uint256 nativeValue;

        // Revert if there's a `msg.value`. The OP bridge does not expect to be paid.
        if (transportPayment != 0) {
            revert JBSucker_UnexpectedMsgValue({value: transportPayment});
        }

        // Cache peer address to avoid redundant calls.
        address peerAddress = _toAddress(peer());

        // If the token is an ERC20, bridge it to the peer.
        // If the amount is `0` then we do not need to bridge any ERC20.
        if (token != JBConstants.NATIVE_TOKEN && amount != 0) {
            // Approve the tokens being bridged.
            SafeERC20.forceApprove({token: IERC20(token), spender: address(OPBRIDGE), value: amount});

            // Bridge the tokens to the peer sucker. Convert bytes32 types to address at the OP Bridge API boundary.
            OPBRIDGE.bridgeERC20To({
                localToken: token,
                remoteToken: _toAddress(remoteToken.addr),
                to: peerAddress,
                amount: amount,
                minGasLimit: remoteToken.minGas,
                extraData: bytes("")
            });

            SafeERC20.forceApprove({token: IERC20(token), spender: address(OPBRIDGE), value: 0});
        } else {
            // Otherwise, the token is the native token, and the amount will be sent as `msg.value`.
            nativeValue = amount;
        }

        // Send the message to the peer with the reclaimed ETH.
        OPMESSENGER.sendMessage{value: nativeValue}({
            target: peerAddress,
            message: abi.encodeCall(JBSucker.fromRemote, (message)),
            // Scale the destination gas with the bundle so a larger mesh's accounting still stores in one relay.
            gasLimit: SafeCast.toUint32(_messagingGasLimit({accounts: message.accounts}))
        });
    }
}
