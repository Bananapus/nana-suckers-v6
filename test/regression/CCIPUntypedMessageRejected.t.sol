// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBCCIPSucker} from "../../src/JBCCIPSucker.sol";
import {JBCCIPSuckerDeployer} from "../../src/deployers/JBCCIPSuckerDeployer.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {IJBCCIPSuckerDeployer} from "../../src/interfaces/IJBCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBAccountingSnapshot} from "../../src/structs/JBAccountingSnapshot.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBPeerChainContext} from "../../src/structs/JBPeerChainContext.sol";
import {JBSourceContext} from "../../src/structs/JBSourceContext.sol";

contract RegressionCCIPUntypedMessageHarness is JBCCIPSucker {
    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBCCIPSucker(deployer, directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}
}

/// @notice `JBCCIPSucker.ccipReceive` only accepts the typed `(uint8 messageType, bytes payload)` envelope. A raw,
/// untyped `abi.encode(root)` payload must be rejected so a malformed delivery can never reach `fromRemote`.
contract RegressionCCIPUntypedMessageRejectedTest is Test {
    address internal constant DEPLOYER = address(0x1001);
    address internal constant DIRECTORY = address(0x1002);
    address internal constant TOKENS = address(0x1003);
    address internal constant PERMISSIONS = address(0x1004);
    address internal constant PROJECTS = address(0x1005);
    address internal constant ROUTER = address(0x1006);

    uint256 internal constant REMOTE_CHAIN_ID = 42_161;
    uint64 internal constant REMOTE_CHAIN_SELECTOR = 4_949_039_107_694_359_620;

    RegressionCCIPUntypedMessageHarness internal sucker;

    function setUp() external {
        vm.etch(ROUTER, hex"01");

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(DEPLOYER, abi.encodeCall(IJBCCIPSuckerDeployer.ccipRemoteChainId, ()), abi.encode(REMOTE_CHAIN_ID));
        vm.mockCall(
            DEPLOYER,
            abi.encodeCall(IJBCCIPSuckerDeployer.ccipRemoteChainSelector, ()),
            abi.encode(REMOTE_CHAIN_SELECTOR)
        );
        vm.mockCall(DEPLOYER, abi.encodeCall(IJBCCIPSuckerDeployer.ccipRouter, ()), abi.encode(ICCIPRouter(ROUTER)));

        sucker = new RegressionCCIPUntypedMessageHarness(
            JBCCIPSuckerDeployer(DEPLOYER), IJBDirectory(DIRECTORY), IJBTokens(TOKENS), IJBPermissions(PERMISSIONS)
        );
    }

    function test_ccipReceive_revertsOnUntypedRootMessage() external {
        JBSourceContext[] memory contexts = new JBSourceContext[](1);
        contexts[0] = JBSourceContext({
            token: bytes32(uint256(uint160(address(0xBEEF)))), decimals: 18, surplus: 1 ether, balance: 1 ether
        });

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(address(0xBEEF)))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(1))}),
            sourceTotalSupply: 1 ether,
            sourceContexts: contexts,
            sourceTimestamp: 1
        });

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256(bytes("untyped")),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)),
            // A raw root encoding, not the typed (messageType, payload) envelope ccipReceive expects.
            data: abi.encode(root),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectRevert();
        vm.prank(ROUTER);
        sucker.ccipReceive(message);
    }

    function test_ccipReceive_acceptsAccountingMessageWithoutTouchingInbox() external {
        address token = address(0xBEEF);
        JBAccountingSnapshot memory snapshot = _makeAccountingSnapshot({
            token: token, sourceTotalSupply: 100 ether, surplus: 11 ether, balance: 22 ether, sourceTimestamp: 1
        });

        vm.prank(ROUTER);
        sucker.ccipReceive(_makeAccountingMessage({snapshot: snapshot, destTokenAmountCount: 0}));

        assertEq(sucker.peerChainTotalSupply(), 100 ether, "accounting supply");
        assertEq(sucker.snapshotTimestamp(), 1, "accounting timestamp");

        JBInboxTreeRoot memory inbox = sucker.inboxOf(token);
        assertEq(inbox.nonce, 0, "accounting does not update inbox nonce");
        assertEq(inbox.root, bytes32(0), "accounting does not update inbox root");

        (JBPeerChainContext[] memory contexts,,) = sucker.peerChainContextsOf();
        assertEq(contexts.length, 1, "one peer context");
        assertEq(contexts[0].currency, uint32(uint160(token)), "fallback currency");
        assertEq(contexts[0].decimals, 18, "decimals");
        assertEq(contexts[0].surplus, 11 ether, "surplus");
        assertEq(contexts[0].balance, 22 ether, "balance");
    }

    function test_ccipReceive_revertsAccountingMessageWithDeliveredTokens() external {
        JBAccountingSnapshot memory snapshot = _makeAccountingSnapshot({
            token: address(0xBEEF),
            sourceTotalSupply: 100 ether,
            surplus: 11 ether,
            balance: 22 ether,
            sourceTimestamp: 1
        });

        vm.expectRevert(abi.encodeWithSelector(JBCCIPSucker.JBCCIPSucker_UnexpectedDeliveredTokens.selector, 1));
        vm.prank(ROUTER);
        sucker.ccipReceive(_makeAccountingMessage({snapshot: snapshot, destTokenAmountCount: 1}));
    }

    function _makeAccountingMessage(
        JBAccountingSnapshot memory snapshot,
        uint256 destTokenAmountCount
    )
        internal
        view
        returns (Client.Any2EVMMessage memory message)
    {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](destTokenAmountCount);
        for (uint256 i; i < destTokenAmountCount;) {
            tokenAmounts[i] = Client.EVMTokenAmount({token: address(0xCAFE), amount: 1});
            unchecked {
                ++i;
            }
        }

        return Client.Any2EVMMessage({
            messageId: keccak256(bytes("accounting")),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)),
            data: abi.encode(uint8(1), abi.encode(snapshot)),
            destTokenAmounts: tokenAmounts
        });
    }

    function _makeAccountingSnapshot(
        address token,
        uint256 sourceTotalSupply,
        uint128 surplus,
        uint128 balance,
        uint256 sourceTimestamp
    )
        internal
        pure
        returns (JBAccountingSnapshot memory snapshot)
    {
        JBSourceContext[] memory contexts = new JBSourceContext[](1);
        contexts[0] = JBSourceContext({
            token: bytes32(uint256(uint160(token))), decimals: 18, surplus: surplus, balance: balance
        });

        return JBAccountingSnapshot({
            version: 1, sourceTotalSupply: sourceTotalSupply, sourceContexts: contexts, sourceTimestamp: sourceTimestamp
        });
    }
}
