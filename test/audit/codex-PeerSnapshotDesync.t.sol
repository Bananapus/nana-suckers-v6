// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

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

contract CodexPeerSnapshotSucker is JBSucker {
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

contract CodexPeerSnapshotDesyncTest is Test {
    address internal constant DIRECTORY = address(600);
    address internal constant PERMISSIONS = address(800);
    address internal constant TOKENS = address(700);
    address internal constant PROJECTS = address(1000);

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant ETH_CURRENCY = 1;
    uint8 internal constant ETH_DECIMALS = 18;

    address internal constant TOKEN_A = address(0xA11CE);
    address internal constant TOKEN_B = address(0xB0B);

    CodexPeerSnapshotSucker internal sucker;

    function setUp() public {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(PROJECTS, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));

        CodexPeerSnapshotSucker singleton =
            new CodexPeerSnapshotSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS));
        sucker = CodexPeerSnapshotSucker(payable(address(LibClone.cloneDeterministic(address(singleton), "peer"))));
        sucker.initialize(PROJECT_ID);
    }

    /// @notice MEDIUM fix: zero-supply messages now correctly zero out peerChainTotalSupply.
    function test_zeroSupplyUpdatesClearPhantomPeerSupply() public {
        // First message sets supply to 500.
        vm.prank(address(sucker));
        sucker.fromRemote(_messageRoot(TOKEN_A, 1, 1, 500 ether, 100 ether, 200 ether));
        assertEq(sucker.peerChainTotalSupply(), 500 ether, "supply set to 500");

        // Second message has legitimate zero supply with a newer snapshot nonce.
        vm.prank(address(sucker));
        sucker.fromRemote(_messageRoot(TOKEN_A, 2, 2, 0, 50 ether, 75 ether));

        // Fixed: zero supply is no longer skipped — phantom supply is cleared.
        assertEq(sucker.peerChainTotalSupply(), 0, "zero supply correctly clears phantom cached supply");

        JBDenominatedAmount memory balance = sucker.peerChainBalanceOf(ETH_DECIMALS, ETH_CURRENCY);
        JBDenominatedAmount memory surplus = sucker.peerChainSurplusOf(ETH_DECIMALS, ETH_CURRENCY);
        assertEq(balance.value, 75 ether, "balance updated");
        assertEq(surplus.value, 50 ether, "surplus updated");
    }

    /// @notice HIGH fix: cross-token out-of-order roots no longer rollback shared state.
    function test_crossTokenOutOfOrderRootsDoNotRollbackSharedState() public {
        // Token A arrives with per-token nonce=2 and snapshot nonce=2 (fresher project-wide state).
        vm.prank(address(sucker));
        sucker.fromRemote(_messageRoot(TOKEN_A, 2, 2, 900 ether, 300 ether, 400 ether));

        // Token B arrives with per-token nonce=1 and snapshot nonce=1 (staler project-wide state).
        vm.prank(address(sucker));
        sucker.fromRemote(_messageRoot(TOKEN_B, 1, 1, 100 ether, 10 ether, 20 ether));

        // Fixed: Token B's staler snapshot nonce (1 < 2) does NOT overwrite shared state.
        assertEq(
            sucker.peerChainTotalSupply(), 900 ether, "fresher token-A supply preserved despite later token-B delivery"
        );

        JBDenominatedAmount memory balance = sucker.peerChainBalanceOf(ETH_DECIMALS, ETH_CURRENCY);
        JBDenominatedAmount memory surplus = sucker.peerChainSurplusOf(ETH_DECIMALS, ETH_CURRENCY);
        assertEq(balance.value, 400 ether, "fresher token-A balance preserved");
        assertEq(surplus.value, 300 ether, "fresher token-A surplus preserved");
    }

    /// @notice Verify token-local inbox still updates even when shared state is stale.
    function test_staleSnapshotStillUpdatesTokenInbox() public {
        // Token A arrives with snapshot nonce=2.
        vm.prank(address(sucker));
        sucker.fromRemote(_messageRoot(TOKEN_A, 1, 2, 900 ether, 300 ether, 400 ether));

        // Token B arrives with snapshot nonce=1 (stale shared state) but valid per-token nonce=1.
        vm.prank(address(sucker));
        sucker.fromRemote(_messageRoot(TOKEN_B, 1, 1, 100 ether, 10 ether, 20 ether));

        // Shared state kept from token A (snapshot nonce 2 > 1).
        assertEq(sucker.peerChainTotalSupply(), 900 ether, "shared state from fresher snapshot");

        // But token B's inbox was still updated (per-token nonce 1 > 0).
        // We verify by trying to send the same nonce again — it should emit StaleRootRejected.
        vm.expectEmit(true, false, false, true);
        emit IJBSucker.StaleRootRejected(TOKEN_B, 1, 1);
        vm.prank(address(sucker));
        sucker.fromRemote(_messageRoot(TOKEN_B, 1, 1, 100 ether, 10 ether, 20 ether));
    }

    function _messageRoot(
        address token,
        uint64 nonce,
        uint64 sourceTs,
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
            token: bytes32(uint256(uint160(token))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: bytes32(uint256(nonce))}),
            sourceTotalSupply: totalSupply,
            sourceCurrency: ETH_CURRENCY,
            sourceDecimals: ETH_DECIMALS,
            sourceSurplus: surplus,
            sourceBalance: balance,
            sourceTimestamp: sourceTs
        });
    }
}
