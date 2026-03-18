// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

import {JBSucker} from "./JBSucker.sol";
import {JBOptimismSuckerDeployer} from "./deployers/JBOptimismSuckerDeployer.sol";
import {IJBOptimismSucker} from "./interfaces/IJBOptimismSucker.sol";
import {IOPMessenger} from "./interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "./interfaces/IOPStandardBridge.sol";
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBRemoteToken} from "./structs/JBRemoteToken.sol";
import {MerkleLib} from "./utils/MerkleLib.sol";

/// @notice A `JBSucker` implementation to suck tokens between two chains connected by an OP Bridge.
contract JBOptimismSucker is JBSucker, IJBOptimismSucker {
    using BitMaps for BitMaps.BitMap;
    using MerkleLib for MerkleLib.Tree;

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

    /// @param deployer A contract that deploys the clones for this contracts.
    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param tokens A contract that manages token minting and burning.
    /// @param permissions A contract storing permissions.
    constructor(
        JBOptimismSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        uint256 feeProjectId,
        uint256 toRemoteFee,
        address feeOwner,
        address trustedForwarder
    )
        JBSucker(directory, permissions, tokens, feeProjectId, toRemoteFee, feeOwner, trustedForwarder)
    {
        // Fetch the messenger and bridge by doing a callback to the deployer contract.
        OPBRIDGE = JBOptimismSuckerDeployer(deployer).opBridge();
        OPMESSENGER = JBOptimismSuckerDeployer(deployer).opMessenger();
    }

    //*********************************************************************//
    // ------------------------ external views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the chain on which the peer is located.
    /// @return chainId of the peer.
    function peerChainId() external view virtual override returns (uint256) {
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
    function _isRemotePeer(address sender) internal override returns (bool valid) {
        return sender == address(OPMESSENGER) && _toBytes32(OPMESSENGER.xDomainMessageSender()) == peer();
    }

    /// @notice Use the `OPMESSENGER` to send the outbox tree for the `token` and the corresponding funds to the peer
    /// over the `OPBRIDGE`.
    /// @param transportPayment the amount of `msg.value` that is going to get paid for sending this message.
    /// @param token The token to bridge the outbox tree for.
    /// @param remoteToken Information about the remote token being bridged to.
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
            revert JBSucker_UnexpectedMsgValue(transportPayment);
        }

        // If the token is an ERC20, bridge it to the peer.
        // If the amount is `0` then we do not need to bridge any ERC20.
        if (token != JBConstants.NATIVE_TOKEN && amount != 0) {
            // Approve the tokens being bridged.
            // slither-disable-next-line reentrancy-events
            SafeERC20.forceApprove({token: IERC20(token), spender: address(OPBRIDGE), value: amount});

            // Bridge the tokens to the peer sucker. Convert bytes32 types to address at the OP Bridge API boundary.
            // slither-disable-next-line reentrancy-events,calls-loop
            OPBRIDGE.bridgeERC20To({
                localToken: token,
                remoteToken: _toAddress(remoteToken.addr),
                to: _toAddress(peer()),
                amount: amount,
                minGasLimit: remoteToken.minGas,
                extraData: bytes("")
            });
        } else {
            // Otherwise, the token is the native token, and the amount will be sent as `msg.value`.
            nativeValue = amount;
        }

        // Send the message to the peer with the reclaimed ETH.
        // Convert bytes32 peer to address at the OP Messenger API boundary.
        // slither-disable-next-line arbitrary-send-eth,reentrancy-events,calls-loop
        OPMESSENGER.sendMessage{value: nativeValue}({
            target: _toAddress(peer()),
            message: abi.encodeCall(JBSucker.fromRemote, (message)),
            gasLimit: MESSENGER_BASE_GAS_LIMIT
        });
    }
}
