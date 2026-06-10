// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract AddToBalanceHarness is JBSucker {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function test_addToBalance(address token, uint256 amount, uint256 cachedProjectId) external {
        _addToBalance({token: token, amount: amount, cachedProjectId: cachedProjectId});
    }

    function peerChainId() public view override returns (uint256) {
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
}

contract AddToBalanceUnexpectedTokenBalanceTest is Test {
    address internal constant DIRECTORY = address(0x1000);
    address internal constant PERMISSIONS = address(0x2000);
    address internal constant TOKENS = address(0x3000);
    address internal constant PROJECT = address(0x4000);
    address internal constant TERMINAL = address(0x5000);

    uint256 internal constant PROJECT_ID = 1;

    AddToBalanceHarness internal sucker;

    function setUp() external {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));

        AddToBalanceHarness singleton =
            new AddToBalanceHarness(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS));
        sucker = AddToBalanceHarness(
            payable(address(LibClone.cloneDeterministic(address(singleton), keccak256(bytes("add-to-balance")))))
        );
        sucker.initialize(PROJECT_ID);
    }

    function test_addToBalanceNonPullingTerminalRevertsWithCustomError() external {
        ERC20Mock token =
            new ERC20Mock({name: "Mock Token", symbol: "MOCK", initialAccount: address(sucker), initialBalance: 100});

        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(token))),
            abi.encode(IJBTerminal(TERMINAL))
        );
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());

        vm.expectRevert(
            abi.encodeWithSelector(
                JBSucker.JBSucker_UnexpectedTokenBalance.selector, address(token), uint256(90), uint256(100)
            )
        );
        sucker.test_addToBalance({token: address(token), amount: 10, cachedProjectId: PROJECT_ID});
    }
}
