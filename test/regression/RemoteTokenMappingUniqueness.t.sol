// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";

contract RemoteTokenMappingUniquenessHarness is JBSucker {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        JBSucker(directory, permissions, IJBPrices(address(1)), tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function peerChainId() external view override returns (uint256) {
        return block.chainid;
    }

    function test_localTokenForRemoteToken(bytes32 remoteToken) external view returns (address) {
        return _localTokenForRemoteToken[remoteToken];
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

contract RemoteTokenMappingUniquenessTest is Test {
    address internal constant DIRECTORY = address(0x1000);
    address internal constant PERMISSIONS = address(0x2000);
    address internal constant TOKENS = address(0x3000);
    address internal constant PROJECT = address(0x4000);

    uint256 internal constant PROJECT_ID = 1;

    RemoteTokenMappingUniquenessHarness internal sucker;

    function setUp() external {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        sucker = _deployHarness("remote-token-uniqueness");
    }

    function test_mapTokenRejectsSecondLocalTokenForSameRemote() external {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        bytes32 remoteToken = _remote("sharedRemote");

        sucker.mapToken(_map(tokenA, remoteToken));
        JBTokenMapping memory tokenBMapping = _map(tokenB, remoteToken);

        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_RemoteTokenAlreadyMapped.selector, remoteToken, tokenA)
        );
        sucker.mapToken(tokenBMapping);
    }

    function test_mapTokensRejectsDuplicateRemoteInSameBatch() external {
        address tokenA = makeAddr("batchTokenA");
        address tokenB = makeAddr("batchTokenB");
        bytes32 remoteToken = _remote("batchSharedRemote");

        JBTokenMapping[] memory maps = new JBTokenMapping[](2);
        maps[0] = _map(tokenA, remoteToken);
        maps[1] = _map(tokenB, remoteToken);

        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_RemoteTokenAlreadyMapped.selector, remoteToken, tokenA)
        );
        sucker.mapTokens(maps);
    }

    function test_sameLocalTokenCanRemapUnusedRemoteReservation() external {
        address tokenA = makeAddr("remapTokenA");
        address tokenB = makeAddr("remapTokenB");
        bytes32 remoteA = _remote("remoteA");
        bytes32 remoteB = _remote("remoteB");

        sucker.mapToken(_map(tokenA, remoteA));
        assertEq(sucker.test_localTokenForRemoteToken(remoteA), tokenA, "remoteA should be reserved");

        sucker.mapToken(_map(tokenA, remoteB));

        assertEq(sucker.test_localTokenForRemoteToken(remoteA), address(0), "remoteA should be released");
        assertEq(sucker.test_localTokenForRemoteToken(remoteB), tokenA, "remoteB should be reserved");
        assertEq(sucker.remoteTokenFor(tokenA).addr, remoteB, "tokenA should point to remoteB");

        sucker.mapToken(_map(tokenB, remoteA));
        assertEq(sucker.test_localTokenForRemoteToken(remoteA), tokenB, "remoteA should be reusable after release");
    }

    function test_disabledMappingKeepsRemoteReservedUntilRemappedAway() external {
        address tokenA = makeAddr("disabledTokenA");
        address tokenB = makeAddr("disabledTokenB");
        bytes32 remoteToken = _remote("disabledRemote");

        sucker.mapToken(_map(tokenA, remoteToken));
        sucker.mapToken(_map(tokenA, bytes32(0)));

        JBRemoteToken memory disabled = sucker.remoteTokenFor(tokenA);
        assertFalse(disabled.enabled, "mapping should be disabled");
        assertEq(disabled.addr, remoteToken, "disabled mapping keeps its remote token");
        assertEq(sucker.test_localTokenForRemoteToken(remoteToken), tokenA, "remote stays reserved");

        JBTokenMapping memory tokenBMapping = _map(tokenB, remoteToken);
        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_RemoteTokenAlreadyMapped.selector, remoteToken, tokenA)
        );
        sucker.mapToken(tokenBMapping);

        sucker.mapToken(_map(tokenA, remoteToken));
        assertTrue(sucker.remoteTokenFor(tokenA).enabled, "same local token can re-enable");
    }

    function test_parallelSuckersCanMapSameEthAndUsdcRoutes() external {
        RemoteTokenMappingUniquenessHarness nativeBridgeSucker = _deployHarness("native-bridge-sucker");
        RemoteTokenMappingUniquenessHarness ccipSucker = _deployHarness("ccip-sucker");

        bytes32 remoteEth = bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)));
        address usdc = makeAddr("usdc");
        bytes32 remoteUsdc = _remote("remoteUsdc");

        nativeBridgeSucker.mapToken(_mapFor(nativeBridgeSucker, JBConstants.NATIVE_TOKEN, remoteEth));
        ccipSucker.mapToken(_mapFor(ccipSucker, JBConstants.NATIVE_TOKEN, remoteEth));
        nativeBridgeSucker.mapToken(_mapFor(nativeBridgeSucker, usdc, remoteUsdc));
        ccipSucker.mapToken(_mapFor(ccipSucker, usdc, remoteUsdc));

        assertEq(nativeBridgeSucker.remoteTokenFor(JBConstants.NATIVE_TOKEN).addr, remoteEth, "native bridge maps ETH");
        assertEq(ccipSucker.remoteTokenFor(JBConstants.NATIVE_TOKEN).addr, remoteEth, "CCIP maps ETH");
        assertEq(nativeBridgeSucker.remoteTokenFor(usdc).addr, remoteUsdc, "native bridge maps USDC");
        assertEq(ccipSucker.remoteTokenFor(usdc).addr, remoteUsdc, "CCIP maps USDC");
        assertEq(
            nativeBridgeSucker.test_localTokenForRemoteToken(remoteEth),
            JBConstants.NATIVE_TOKEN,
            "native ETH reservation is local"
        );
        assertEq(
            ccipSucker.test_localTokenForRemoteToken(remoteEth),
            JBConstants.NATIVE_TOKEN,
            "CCIP ETH reservation is local"
        );
        assertEq(nativeBridgeSucker.test_localTokenForRemoteToken(remoteUsdc), usdc, "native reservation is local");
        assertEq(ccipSucker.test_localTokenForRemoteToken(remoteUsdc), usdc, "CCIP reservation is local");
    }

    function _map(address localToken, bytes32 remoteToken) internal view returns (JBTokenMapping memory) {
        return _mapFor(sucker, localToken, remoteToken);
    }

    function _mapFor(
        RemoteTokenMappingUniquenessHarness target,
        address localToken,
        bytes32 remoteToken
    )
        internal
        view
        returns (JBTokenMapping memory)
    {
        return JBTokenMapping({
            localToken: localToken, minGas: target.MESSENGER_ERC20_MIN_GAS_LIMIT(), remoteToken: remoteToken
        });
    }

    function _deployHarness(string memory salt) internal returns (RemoteTokenMappingUniquenessHarness deployed) {
        RemoteTokenMappingUniquenessHarness singleton = new RemoteTokenMappingUniquenessHarness(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS)
        );
        deployed = RemoteTokenMappingUniquenessHarness(
            payable(address(LibClone.cloneDeterministic(address(singleton), keccak256(bytes(salt)))))
        );
        deployed.initialize(PROJECT_ID);
    }

    function _remote(string memory name) internal pure returns (bytes32) {
        return keccak256(bytes(name));
    }
}
