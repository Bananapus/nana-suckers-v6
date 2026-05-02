// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../../src/JBSucker.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBDenominatedAmount} from "../../src/structs/JBDenominatedAmount.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";

contract SameTimestampSnapshotSucker is JBSucker {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function _sendRootOverAMB(
        uint256,
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBMessageRoot memory
    )
        internal
        pure
        override
    {}

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == address(this);
    }

    function peerChainId() external view override returns (uint256) {
        return block.chainid;
    }
}

contract SameTimestampSnapshotPinnedTest is Test {
    address internal constant DIRECTORY = address(0x1001);
    address internal constant PERMISSIONS = address(0x1002);
    address internal constant TOKENS = address(0x1003);
    address internal constant PROJECTS = address(0x1004);
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant ETH_CURRENCY = 1;
    uint8 internal constant ETH_DECIMALS = 18;
    address internal constant TOKEN = address(0xBEEF);

    SameTimestampSnapshotSucker internal sucker;

    function setUp() external {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(PROJECTS, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));

        SameTimestampSnapshotSucker singleton =
            new SameTimestampSnapshotSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS));
        sucker = SameTimestampSnapshotSucker(
            payable(address(LibClone.cloneDeterministic(address(singleton), bytes32("same-timestamp"))))
        );
        sucker.initialize(PROJECT_ID);
    }

    function test_laterSameBlockSnapshotRefreshesWhenSourceFreshnessIncreases() external {
        vm.prank(address(sucker));
        sucker.fromRemote(
            _messageRoot({
                nonce: 1, sourceTimestamp: 100, totalSupply: 1000 ether, surplus: 500 ether, balance: 700 ether
            })
        );

        vm.prank(address(sucker));
        sucker.fromRemote(
            _messageRoot({nonce: 2, sourceTimestamp: 101, totalSupply: 100 ether, surplus: 50 ether, balance: 70 ether})
        );

        JBDenominatedAmount memory balance = sucker.peerChainBalanceOf(ETH_DECIMALS, ETH_CURRENCY);
        JBDenominatedAmount memory surplus = sucker.peerChainSurplusOf(ETH_DECIMALS, ETH_CURRENCY);

        assertEq(sucker.snapshotTimestamp(), 101, "freshness key advances within the same block");
        assertEq(sucker.peerChainTotalSupply(), 100 ether, "later same-block supply update is applied");
        assertEq(surplus.value, 50 ether, "later same-block surplus update is applied");
        assertEq(balance.value, 70 ether, "later same-block balance update is applied");
    }

    function _messageRoot(
        uint64 nonce,
        uint64 sourceTimestamp,
        uint256 totalSupply,
        uint256 surplus,
        uint256 balance
    )
        internal
        pure
        returns (JBMessageRoot memory)
    {
        return JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: bytes32(uint256(nonce))}),
            sourceTotalSupply: totalSupply,
            sourceCurrency: ETH_CURRENCY,
            sourceDecimals: ETH_DECIMALS,
            sourceSurplus: surplus,
            sourceBalance: balance,
            sourceTimestamp: sourceTimestamp
        });
    }
}
