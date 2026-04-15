// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBPayRemoteMessage} from "../../src/structs/JBPayRemoteMessage.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";

contract CodexZeroCostPayRemoteHarness is JBSucker {
    bool public sendPayCalled;
    uint256 public lastTransportPayment;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(0xBEEF)), address(0))
    {}

    function peerChainId() external view override returns (uint256) {
        return block.chainid;
    }

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == _toAddress(peer());
    }

    function _sendRootOverAMB(
        uint256,
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBMessageRoot memory
    )
        internal
        override
    {}

    function _sendPayOverAMB(
        uint256 transportPayment,
        address,
        uint256 amount,
        JBRemoteToken memory,
        JBPayRemoteMessage memory
    )
        internal
        override
    {
        if (transportPayment != 0) revert JBSucker_UnexpectedMsgValue(transportPayment);
        sendPayCalled = true;
        lastTransportPayment = transportPayment;
        assert(address(this).balance == amount + 0.5 ether);
    }

    function _splitTransportBudget(uint256) internal pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function test_setRemoteToken(address token, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[token] = remoteToken;
    }
}

contract CodexNemesisPayRemoteOverpayTest is Test {
    address constant DIRECTORY = address(0x600);
    address constant PROJECTS = address(0x601);
    address constant PERMISSIONS = address(0x700);
    address constant TOKENS = address(0x800);
    uint256 constant PROJECT_ID = 1;

    CodexZeroCostPayRemoteHarness internal sucker;

    function setUp() public {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));

        CodexZeroCostPayRemoteHarness singleton =
            new CodexZeroCostPayRemoteHarness(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS));
        sucker = CodexZeroCostPayRemoteHarness(
            payable(address(LibClone.cloneDeterministic(address(singleton), bytes32("codex-nemesis-overpay"))))
        );
        sucker.initialize(PROJECT_ID);

        sucker.test_setRemoteToken(
            JBConstants.NATIVE_TOKEN,
            JBRemoteToken({
                enabled: true, emergencyHatch: false, minGas: 0, addr: bytes32(uint256(uint160(address(0xCAFE))))
            })
        );
    }

    function test_payRemote_zeroCostBridgeOverpaymentBecomesFutureClaimBacking() public {
        uint256 amount = 1 ether;
        uint256 accidentalOverpayment = 0.5 ether;

        sucker.payRemote{value: amount + accidentalOverpayment}({
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: bytes32(uint256(uint160(address(0xB0B)))),
            minTokensOut: 0,
            metadata: ""
        });

        assertTrue(sucker.sendPayCalled());
        assertEq(sucker.lastTransportPayment(), 0);
        assertEq(address(sucker).balance, amount + accidentalOverpayment);
        assertEq(sucker.amountToAddToBalanceOf(JBConstants.NATIVE_TOKEN), amount + accidentalOverpayment);
    }
}
