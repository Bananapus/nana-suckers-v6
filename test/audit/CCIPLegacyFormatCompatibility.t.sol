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
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";

contract CodexCCIPLegacyFormatHarness is JBCCIPSucker {
    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBCCIPSucker(deployer, directory, tokens, permissions, 1, IJBSuckerRegistry(address(1)), address(0))
    {}
}

contract CodexCCIPLegacyFormatCompatibilityTest is Test {
    address internal constant DEPLOYER = address(0x1001);
    address internal constant DIRECTORY = address(0x1002);
    address internal constant TOKENS = address(0x1003);
    address internal constant PERMISSIONS = address(0x1004);
    address internal constant PROJECTS = address(0x1005);
    address internal constant ROUTER = address(0x1006);

    uint256 internal constant REMOTE_CHAIN_ID = 42_161;
    uint64 internal constant REMOTE_CHAIN_SELECTOR = 4_949_039_107_694_359_620;

    CodexCCIPLegacyFormatHarness internal sucker;

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

        sucker = new CodexCCIPLegacyFormatHarness(
            JBCCIPSuckerDeployer(DEPLOYER), IJBDirectory(DIRECTORY), IJBTokens(TOKENS), IJBPermissions(PERMISSIONS)
        );
    }

    function test_ccipReceive_revertsOnLegacyUntypedRootMessage() external {
        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(address(0xBEEF)))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(1))}),
            sourceTotalSupply: 1 ether,
            sourceCurrency: 1,
            sourceDecimals: 18,
            sourceSurplus: 1 ether,
            sourceBalance: 1 ether,
            sourceTimestamp: 1
        });

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32("legacy"),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)),
            data: abi.encode(root),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectRevert();
        vm.prank(ROUTER);
        sucker.ccipReceive(message);
    }
}
