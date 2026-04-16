// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerState} from "../../src/enums/JBSuckerState.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

contract DeprecatedDestinationSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;

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
        return sender == address(this);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function _sendRootOverAMB(
        uint256,
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBMessageRoot memory,
        bytes memory
    )
        internal
        override
    {}

    function test_insertIntoTree(
        uint256 projectTokenCount,
        address token,
        uint256 terminalTokenAmount,
        bytes32 beneficiary
    )
        external
    {
        _insertIntoTree(projectTokenCount, token, terminalTokenAmount, beneficiary);
    }

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

    function test_setDeprecatedAfter(uint256 timestamp) external {
        deprecatedAfter = timestamp;
    }

    function test_getOutboxRoot(address token) external view returns (bytes32) {
        return _outboxOf[token].tree.root();
    }

    function test_getOutboxNonce(address token) external view returns (uint64) {
        return _outboxOf[token].nonce;
    }

    function test_getInboxRoot(address token) external view returns (bytes32) {
        return _inboxOf[token].root;
    }
}

contract DeprecatedSuckerDestinationTest is Test {
    using MerkleLib for MerkleLib.Tree;

    address constant DIRECTORY = address(600);
    address constant PERMISSIONS = address(800);
    address constant TOKENS = address(700);
    address constant PROJECT = address(1000);
    address constant TERMINAL = address(1200);
    address constant TOKEN = address(0x000000000000000000000000000000000000EEEe);
    uint256 constant PROJECT_ID = 1;

    DeprecatedDestinationSucker internal source;
    DeprecatedDestinationSucker internal destination;

    function setUp() public {
        vm.warp(100 days);

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(address(1), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(address(0)));
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, TOKEN)), abi.encode(TERMINAL)
        );
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(0)));

        // Mock DIRECTORY.terminalsOf() so _buildETHAggregate() in _sendRoot() doesn't revert.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(new IJBTerminal[](0)));

        source = _createSucker("codex-source");
        destination = _createSucker("codex-destination");
    }

    /// @notice Verifies that a deprecated destination now accepts roots, preventing token stranding.
    /// Previously, deprecated suckers rejected incoming roots, which could strand tokens sent just before
    /// deprecation. The fix accepts roots in DEPRECATED state since toRemote is already disabled, preventing
    /// double-spend without stranding tokens.
    function test_deprecatedDestinationAcceptsRootAfterFix() external {
        bytes32 beneficiary = bytes32(uint256(uint160(address(this))));

        source.test_setRemoteToken(
            TOKEN,
            JBRemoteToken({
                enabled: true, emergencyHatch: false, minGas: 200_000, addr: bytes32(uint256(uint160(TOKEN)))
            })
        );
        source.test_insertIntoTree({
            projectTokenCount: 10 ether, token: TOKEN, terminalTokenAmount: 1 ether, beneficiary: beneficiary
        });

        source.toRemote(TOKEN, "");

        assertEq(source.outboxOf(TOKEN).numberOfClaimsSent, 1, "leaf must be marked sent on source");

        destination.test_setDeprecatedAfter(block.timestamp - 1);
        assertEq(uint256(destination.state()), uint256(JBSuckerState.DEPRECATED), "destination must be deprecated");

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({
                nonce: source.test_getOutboxNonce(TOKEN), root: source.test_getOutboxRoot(TOKEN)
            }),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        vm.prank(address(destination));
        destination.fromRemote(root);

        // After the fix, the root IS accepted even in DEPRECATED state.
        assertEq(
            destination.test_getInboxRoot(TOKEN),
            source.test_getOutboxRoot(TOKEN),
            "deprecated destination should now accept the root"
        );
    }

    function _createSucker(bytes32 salt) internal returns (DeprecatedDestinationSucker) {
        DeprecatedDestinationSucker singleton =
            new DeprecatedDestinationSucker(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS));
        DeprecatedDestinationSucker clone =
            DeprecatedDestinationSucker(payable(address(LibClone.cloneDeterministic(address(singleton), salt))));
        clone.initialize(PROJECT_ID);
        return clone;
    }
}
