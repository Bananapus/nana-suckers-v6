// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSwapCCIPSucker} from "../../src/JBSwapCCIPSucker.sol";
import {JBSwapCCIPSuckerDeployer} from "../../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice Harness exposing JBSwapCCIPSucker internals for testing stale nonce fix.
contract StaleNonceTestHarness is JBSwapCCIPSucker {
    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBSwapCCIPSucker(
            deployer, directory, permissions, address(1), tokens, 1, IJBSuckerRegistry(address(1)), address(0)
        )
    {}

    /// @notice Read a conversion rate for a given nonce.
    function exposed_conversionRateOf(
        address token,
        uint64 nonce
    )
        external
        view
        returns (uint256 leafTotal, uint256 localTotal)
    {
        ConversionRate storage rate = _conversionRateOf[token][nonce];
        return (rate.leafTotal, rate.localTotal);
    }

    /// @notice Read the batch start for a given nonce.
    function exposed_batchStartOf(address token, uint64 nonce) external view returns (uint256) {
        return _batchStartOf[token][nonce];
    }

    /// @notice Read the batch end for a given nonce.
    function exposed_batchEndOf(address token, uint64 nonce) external view returns (uint256) {
        return _batchEndOf[token][nonce];
    }

    /// @notice Read the highest received nonce for a token.
    function exposed_highestReceivedNonce(address token) external view returns (uint64) {
        return _highestReceivedNonce[token];
    }
}

/// @title StaleNonceMetadataOverwriteTest
/// @notice Verifies that replaying a CCIP message with a stale nonce
/// does NOT overwrite the conversion rate or batch metadata written by the original delivery.
/// Before the fix, batch metadata and conversion rate writes happened BEFORE fromRemote
/// validated the nonce, so a replayed stale message could corrupt the original accepted data.
contract StaleNonceMetadataOverwriteTest is Test {
    address internal constant MOCK_DEPLOYER = address(0xDE);
    address internal constant MOCK_DIRECTORY = address(0xD1);
    address internal constant MOCK_TOKENS = address(0xD2);
    address internal constant MOCK_PERMISSIONS = address(0xD3);
    address internal constant MOCK_ROUTER = address(0xD4);
    address internal constant MOCK_PROJECTS = address(0xD5);

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant REMOTE_CHAIN_ID = 4217;
    uint64 internal constant REMOTE_CHAIN_SELECTOR = 7_281_642_695_469_137_430;

    ERC20Mock internal usdc;
    ERC20Mock internal weth;
    StaleNonceTestHarness internal sucker;

    function setUp() external {
        usdc = new ERC20Mock("USDC", "USDC", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);

        vm.etch(MOCK_ROUTER, hex"01");

        // Mock deployer responses.
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(REMOTE_CHAIN_ID));
        vm.mockCall(
            MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(REMOTE_CHAIN_SELECTOR)
        );
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(MOCK_ROUTER));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("bridgeToken()"), abi.encode(address(usdc)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("poolManager()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("v3Factory()"), abi.encode(address(0x1234)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("univ4Hook()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("weth()"), abi.encode(address(weth)));

        // Mock CCIP router.
        vm.mockCall(MOCK_ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(weth)));

        // Mock directory.
        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(MOCK_PROJECTS));
        vm.mockCall(MOCK_PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));

        // Deploy singleton and clone.
        StaleNonceTestHarness singleton = new StaleNonceTestHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
        sucker = StaleNonceTestHarness(
            payable(LibClone.cloneDeterministic(address(singleton), bytes32("stale-nonce-test")))
        );
        sucker.initialize(PROJECT_ID);
    }

    /// @notice Build a CCIP Any2EVMMessage for a ROOT message with the given parameters.
    /// @param nonce The root nonce.
    /// @param amount The root amount (leaf denomination total).
    /// @param bridgeAmount The amount of bridge tokens delivered by CCIP.
    /// @param batchStart The batch start index.
    /// @param batchEnd The batch end index.
    /// @param sourceTimestamp The source timestamp for the snapshot.
    /// @return message The constructed CCIP message.
    function _buildCCIPMessage(
        uint64 nonce,
        uint256 amount,
        uint256 bridgeAmount,
        uint256 batchStart,
        uint256 batchEnd,
        uint256 sourceTimestamp
    )
        internal
        view
        returns (Client.Any2EVMMessage memory message)
    {
        // The localToken is USDC (the bridge token), so no swap is needed.
        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(address(usdc)))),
            amount: amount,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: bytes32(uint256(0xdead0000 + nonce))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            sourceTimestamp: sourceTimestamp
        });

        // Build token amounts (bridge token = local token, so no swap needed).
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(usdc), amount: bridgeAmount});

        // Encode the typed message payload: (JBMessageRoot, batchStart, batchEnd).
        bytes memory payload = abi.encode(root, batchStart, batchEnd);
        bytes memory data = abi.encode(uint8(0), payload); // type 0 = ROOT

        message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(nonce)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)), // peer == self for CCIP sucker
            data: data,
            destTokenAmounts: tokenAmounts
        });
    }

    /// @notice Deliver a CCIP message with the given nonce and parameters.
    function _deliverMessage(
        uint64 nonce,
        uint256 amount,
        uint256 bridgeAmount,
        uint256 batchStart,
        uint256 batchEnd,
        uint256 sourceTimestamp
    )
        internal
    {
        // Mint bridge tokens to the sucker (simulating CCIP token delivery).
        usdc.mint(address(sucker), bridgeAmount);

        Client.Any2EVMMessage memory message =
            _buildCCIPMessage(nonce, amount, bridgeAmount, batchStart, batchEnd, sourceTimestamp);

        vm.prank(MOCK_ROUTER);
        sucker.ccipReceive(message);
    }

    // =========================================================================
    // Test: stale nonce replay does NOT overwrite conversion rate
    // =========================================================================

    /// @notice Replaying a CCIP message with a stale nonce must not
    /// overwrite the conversion rate or batch metadata from the original accepted delivery.
    function test_staleNonceReplay_doesNotOverwriteConversionRate() external {
        address token = address(usdc);

        // Deliver nonce 1: 1000e6 leaf amount, 1000e6 bridge tokens, range [0, 5).
        _deliverMessage({
            nonce: 1, amount: 1000e6, bridgeAmount: 1000e6, batchStart: 0, batchEnd: 5, sourceTimestamp: 100
        });

        // Verify nonce 1's conversion rate was stored correctly.
        (uint256 leafTotal1, uint256 localTotal1) = sucker.exposed_conversionRateOf(token, 1);
        assertEq(leafTotal1, 1000e6, "nonce 1 leafTotal should be 1000e6");
        assertEq(localTotal1, 1000e6, "nonce 1 localTotal should be 1000e6");
        assertEq(sucker.exposed_batchStartOf(token, 1), 0, "nonce 1 batchStart should be 0");
        assertEq(sucker.exposed_batchEndOf(token, 1), 5, "nonce 1 batchEnd should be 5");

        // Deliver nonce 2 so the inbox nonce advances past 1.
        _deliverMessage({
            nonce: 2, amount: 500e6, bridgeAmount: 500e6, batchStart: 5, batchEnd: 8, sourceTimestamp: 200
        });

        // Verify nonce 2 was stored.
        (uint256 leafTotal2, uint256 localTotal2) = sucker.exposed_conversionRateOf(token, 2);
        assertEq(leafTotal2, 500e6, "nonce 2 leafTotal should be 500e6");
        assertEq(localTotal2, 500e6, "nonce 2 localTotal should be 500e6");

        // Now replay nonce 1 with DIFFERENT values.
        // This simulates a stale CCIP message being re-delivered or replayed.
        _deliverMessage({
            nonce: 1,
            amount: 9999e6, // Different leaf amount — would corrupt rate if written
            bridgeAmount: 9999e6, // Different bridge amount
            batchStart: 100, // Different batch start
            batchEnd: 200, // Different batch end
            sourceTimestamp: 50 // Older timestamp
        });

        // Verify nonce 1's conversion rate was NOT overwritten by the replay.
        (uint256 leafAfterReplay, uint256 localAfterReplay) = sucker.exposed_conversionRateOf(token, 1);
        assertEq(leafAfterReplay, 1000e6, "CRITICAL: stale replay must not overwrite nonce 1 leafTotal");
        assertEq(localAfterReplay, 1000e6, "CRITICAL: stale replay must not overwrite nonce 1 localTotal");

        // Verify batch metadata was NOT overwritten.
        assertEq(
            sucker.exposed_batchStartOf(token, 1), 0, "CRITICAL: stale replay must not overwrite nonce 1 batchStart"
        );
        assertEq(sucker.exposed_batchEndOf(token, 1), 5, "CRITICAL: stale replay must not overwrite nonce 1 batchEnd");

        // Verify highest nonce was NOT rolled back.
        assertEq(sucker.exposed_highestReceivedNonce(token), 2, "highestReceivedNonce must not be rolled back");
    }

    // =========================================================================
    // Test: same-nonce replay (nonce == current inbox nonce) also rejected
    // =========================================================================

    /// @notice Replaying the current inbox nonce (not strictly greater) should also be rejected.
    function test_sameNonceReplay_doesNotOverwriteConversionRate() external {
        address token = address(usdc);

        // Deliver nonce 1.
        _deliverMessage({
            nonce: 1, amount: 1000e6, bridgeAmount: 1000e6, batchStart: 0, batchEnd: 5, sourceTimestamp: 100
        });

        // Verify initial state.
        (uint256 leafTotal, uint256 localTotal) = sucker.exposed_conversionRateOf(token, 1);
        assertEq(leafTotal, 1000e6);
        assertEq(localTotal, 1000e6);

        // Replay nonce 1 again (same nonce, inbox is at nonce 1).
        // fromRemote requires nonce > inbox.nonce, so nonce 1 == inbox.nonce is rejected.
        _deliverMessage({
            nonce: 1,
            amount: 7777e6, // Different values
            bridgeAmount: 7777e6,
            batchStart: 50,
            batchEnd: 100,
            sourceTimestamp: 50
        });

        // Verify conversion rate was NOT overwritten.
        (uint256 leafAfter, uint256 localAfter) = sucker.exposed_conversionRateOf(token, 1);
        assertEq(leafAfter, 1000e6, "same-nonce replay must not overwrite leafTotal");
        assertEq(localAfter, 1000e6, "same-nonce replay must not overwrite localTotal");

        // Verify batch metadata was NOT overwritten.
        assertEq(sucker.exposed_batchStartOf(token, 1), 0, "same-nonce replay must not overwrite batchStart");
        assertEq(sucker.exposed_batchEndOf(token, 1), 5, "same-nonce replay must not overwrite batchEnd");
    }

    // =========================================================================
    // Test: fresh nonce still works correctly
    // =========================================================================

    /// @notice Sanity check: a fresh (higher) nonce still writes metadata correctly.
    function test_freshNonce_writesMetadataCorrectly() external {
        address token = address(usdc);

        // Deliver nonce 1.
        _deliverMessage({
            nonce: 1, amount: 1000e6, bridgeAmount: 1000e6, batchStart: 0, batchEnd: 5, sourceTimestamp: 100
        });

        // Deliver nonce 2 (fresh, should be accepted).
        _deliverMessage({
            nonce: 2, amount: 2000e6, bridgeAmount: 2000e6, batchStart: 5, batchEnd: 10, sourceTimestamp: 200
        });

        // Verify nonce 2's metadata was written correctly.
        (uint256 leafTotal, uint256 localTotal) = sucker.exposed_conversionRateOf(token, 2);
        assertEq(leafTotal, 2000e6, "fresh nonce should write leafTotal");
        assertEq(localTotal, 2000e6, "fresh nonce should write localTotal");
        assertEq(sucker.exposed_batchStartOf(token, 2), 5, "fresh nonce should write batchStart");
        assertEq(sucker.exposed_batchEndOf(token, 2), 10, "fresh nonce should write batchEnd");
        assertEq(sucker.exposed_highestReceivedNonce(token), 2, "highestReceivedNonce should advance");

        // Verify nonce 1 is still intact.
        (uint256 leaf1, uint256 local1) = sucker.exposed_conversionRateOf(token, 1);
        assertEq(leaf1, 1000e6, "nonce 1 should be unaffected");
        assertEq(local1, 1000e6, "nonce 1 should be unaffected");
    }
}
