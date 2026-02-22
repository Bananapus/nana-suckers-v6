// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v5/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v5/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBCCIPSucker} from "../../src/JBCCIPSucker.sol";
import {JBCCIPSuckerDeployer} from "../../src/deployers/JBCCIPSuckerDeployer.sol";
import {JBAddToBalanceMode} from "../../src/enums/JBAddToBalanceMode.sol";
import {IJBCCIPSuckerDeployer} from "../../src/interfaces/IJBCCIPSuckerDeployer.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";

/// @title CCIPAmountValidationTest
/// @notice Tests for M-28 fix: validates that CCIP received token amount matches merkle root amount.
contract CCIPAmountValidationTest is Test {
    address constant DIRECTORY = address(0x1001);
    address constant PERMISSIONS = address(0x1002);
    address constant TOKENS = address(0x1003);
    address constant MOCK_ROUTER = address(0x2001);
    address constant FORWARDER = address(0x3001);

    uint256 constant PROJECT_ID = 42;
    uint256 constant REMOTE_CHAIN_ID = 137;
    uint64 constant REMOTE_CHAIN_SELECTOR = 4_051_577_828_743_386_545;

    JBCCIPSucker sucker;

    function setUp() public {
        // Mock the deployer interface methods that JBCCIPSucker reads during construction.
        address mockDeployer = address(0x4001);
        vm.mockCall(mockDeployer, abi.encodeCall(IJBCCIPSuckerDeployer.ccipRemoteChainId, ()), abi.encode(REMOTE_CHAIN_ID));
        vm.mockCall(
            mockDeployer,
            abi.encodeCall(IJBCCIPSuckerDeployer.ccipRemoteChainSelector, ()),
            abi.encode(REMOTE_CHAIN_SELECTOR)
        );
        vm.mockCall(mockDeployer, abi.encodeCall(IJBCCIPSuckerDeployer.ccipRouter, ()), abi.encode(MOCK_ROUTER));

        // Deploy singleton.
        JBCCIPSucker singleton = new JBCCIPSucker(
            JBCCIPSuckerDeployer(payable(mockDeployer)),
            IJBDirectory(DIRECTORY),
            IJBTokens(TOKENS),
            IJBPermissions(PERMISSIONS),
            JBAddToBalanceMode.MANUAL,
            FORWARDER
        );

        // Clone and initialize.
        sucker = JBCCIPSucker(payable(LibClone.cloneDeterministic(address(singleton), "ccip_amount_test")));
        sucker.initialize(PROJECT_ID);
    }

    /// @notice Helper to build a valid Any2EVMMessage from the sucker's peer.
    function _buildMessage(
        uint256 rootAmount,
        address rootToken,
        Client.EVMTokenAmount[] memory destTokenAmounts
    ) internal view returns (Client.Any2EVMMessage memory) {
        JBMessageRoot memory root = JBMessageRoot({
            token: rootToken,
            amount: rootAmount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xdead))})
        });

        return Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)), // peer() == address(this) for clones
            data: abi.encode(root),
            destTokenAmounts: destTokenAmounts
        });
    }

    // =========================================================================
    // M-28: root.amount > destTokenAmounts[0].amount → revert
    // =========================================================================

    /// @notice Root claims more tokens than were actually bridged → should revert.
    function test_ccipReceive_rootAmountExceedsReceived_reverts() public {
        address erc20 = makeAddr("bridgedToken");

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: erc20, amount: 5 ether});

        Client.Any2EVMMessage memory message = _buildMessage(10 ether, erc20, tokenAmounts);

        vm.prank(MOCK_ROUTER);
        vm.expectRevert(abi.encodeWithSelector(JBCCIPSucker.JBCCIPSucker_ReceivedAmountMismatch.selector, 10 ether, 5 ether));
        sucker.ccipReceive(message);
    }

    /// @notice Root claims tokens but no tokens were bridged (empty destTokenAmounts) → should revert.
    function test_ccipReceive_rootAmountWithNoTokens_reverts() public {
        Client.EVMTokenAmount[] memory emptyAmounts = new Client.EVMTokenAmount[](0);

        Client.Any2EVMMessage memory message = _buildMessage(1 ether, makeAddr("someToken"), emptyAmounts);

        vm.prank(MOCK_ROUTER);
        vm.expectRevert(abi.encodeWithSelector(JBCCIPSucker.JBCCIPSucker_ReceivedAmountMismatch.selector, 1 ether, 0));
        sucker.ccipReceive(message);
    }

    /// @notice Fuzz: any root.amount > receivedAmount should revert.
    function test_ccipReceive_fuzz_amountMismatch_reverts(uint256 rootAmount, uint256 receivedAmount) public {
        // Ensure rootAmount > receivedAmount and both are reasonable.
        receivedAmount = bound(receivedAmount, 0, uint256(type(uint128).max) - 1);
        rootAmount = bound(rootAmount, receivedAmount + 1, uint256(type(uint128).max));

        address erc20 = makeAddr("bridgedToken");

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: erc20, amount: receivedAmount});

        Client.Any2EVMMessage memory message = _buildMessage(rootAmount, erc20, tokenAmounts);

        vm.prank(MOCK_ROUTER);
        vm.expectRevert(
            abi.encodeWithSelector(JBCCIPSucker.JBCCIPSucker_ReceivedAmountMismatch.selector, rootAmount, receivedAmount)
        );
        sucker.ccipReceive(message);
    }

    // =========================================================================
    // Validation passes: root.amount <= destTokenAmounts[0].amount
    // =========================================================================

    /// @notice root.amount == receivedAmount → passes the amount check (may fail downstream, but not with ReceivedAmountMismatch).
    function test_ccipReceive_exactMatch_passesAmountCheck() public {
        address erc20 = makeAddr("bridgedToken");

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: erc20, amount: 5 ether});

        Client.Any2EVMMessage memory message = _buildMessage(5 ether, erc20, tokenAmounts);

        // The amount check will pass, but fromRemote will process the root.
        // Since we haven't mocked everything, it might revert for a different reason.
        // The key assertion: it does NOT revert with ReceivedAmountMismatch.
        vm.prank(MOCK_ROUTER);
        try sucker.ccipReceive(message) {} catch (bytes memory reason) {
            // If it reverts, make sure it's NOT ReceivedAmountMismatch.
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != JBCCIPSucker.JBCCIPSucker_ReceivedAmountMismatch.selector,
                "Should not revert with ReceivedAmountMismatch"
            );
        }
    }

    /// @notice root.amount == 0 with no tokens → passes the amount check (0 <= 0).
    function test_ccipReceive_zeroAmountNoTokens_passesAmountCheck() public {
        Client.EVMTokenAmount[] memory emptyAmounts = new Client.EVMTokenAmount[](0);

        Client.Any2EVMMessage memory message = _buildMessage(0, makeAddr("someToken"), emptyAmounts);

        vm.prank(MOCK_ROUTER);
        try sucker.ccipReceive(message) {} catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != JBCCIPSucker.JBCCIPSucker_ReceivedAmountMismatch.selector,
                "Should not revert with ReceivedAmountMismatch"
            );
        }
    }

    /// @notice root.amount < receivedAmount (excess tokens) → passes the amount check.
    function test_ccipReceive_excessTokens_passesAmountCheck() public {
        address erc20 = makeAddr("bridgedToken");

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: erc20, amount: 10 ether});

        // Root claims only 3 ether but 10 ether bridged — OK (excess stays in sucker).
        Client.Any2EVMMessage memory message = _buildMessage(3 ether, erc20, tokenAmounts);

        vm.prank(MOCK_ROUTER);
        try sucker.ccipReceive(message) {} catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != JBCCIPSucker.JBCCIPSucker_ReceivedAmountMismatch.selector,
                "Should not revert with ReceivedAmountMismatch"
            );
        }
    }
}
