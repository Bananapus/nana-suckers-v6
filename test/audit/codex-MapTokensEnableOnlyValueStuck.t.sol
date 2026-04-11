// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../../src/JBSucker.sol";
import "../../src/interfaces/IJBSuckerRegistry.sol";
import "../../src/structs/JBMessageRoot.sol";
import "../../src/structs/JBPayRemoteMessage.sol";
import "../../src/structs/JBRemoteToken.sol";
import "../../src/structs/JBTokenMapping.sol";

contract CodexMapTokensHarness is JBSucker {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
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
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBPayRemoteMessage memory
    ) internal override {}
}

contract CodexMapTokensEnableOnlyValueStuckTest is Test {
    address internal constant DIRECTORY = address(0x1000);
    address internal constant PERMISSIONS = address(0x2000);
    address internal constant TOKENS = address(0x3000);
    address internal constant PROJECT = address(0x4000);

    uint256 internal constant PROJECT_ID = 1;

    function test_mapTokensEnableOnlyBatchRefundsMsgValue() external {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        CodexMapTokensHarness singleton =
            new CodexMapTokensHarness(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS));
        CodexMapTokensHarness sucker = CodexMapTokensHarness(
            payable(address(LibClone.cloneDeterministic(address(singleton), bytes32("codex-enable-only-msgvalue"))))
        );
        sucker.initialize(PROJECT_ID);

        JBTokenMapping[] memory maps = new JBTokenMapping[](1);
        maps[0] = JBTokenMapping({
            localToken: address(0xBEEF),
            minGas: sucker.MESSENGER_ERC20_MIN_GAS_LIMIT(),
            remoteToken: bytes32(uint256(uint160(address(0xCAFE))))
        });

        uint256 balanceBefore = address(this).balance;
        sucker.mapTokens{value: 1 ether}(maps);

        assertEq(address(sucker).balance, 0, "enable-only msg.value should not stay in the sucker");
        assertEq(address(this).balance, balanceBefore, "enable-only msg.value should be refunded to caller");
    }

    receive() external payable {}
}
