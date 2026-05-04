// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSwapCCIPSucker} from "../../src/JBSwapCCIPSucker.sol";
import {JBSwapCCIPSuckerDeployer} from "../../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice Harness that exposes internal conversion rate state for zero-output swap testing.
contract ZeroOutputSwapHarness is JBSwapCCIPSucker {
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
}

/// @title ZeroOutputSwapPendingTest
/// @notice Tests that zero-output CCIP swap batches are routed to pendingSwapOf, not
/// marked claimable with a zero-backed conversion rate.
contract ZeroOutputSwapPendingTest is Test {
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
    ERC20Mock internal localToken;
    ZeroOutputSwapHarness internal sucker;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        localToken = new ERC20Mock("LOCAL", "LOCAL", address(this), 0);

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

        vm.mockCall(MOCK_ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(weth)));
        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(MOCK_PROJECTS));
        vm.mockCall(MOCK_PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));

        ZeroOutputSwapHarness singleton = new ZeroOutputSwapHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );

        sucker = ZeroOutputSwapHarness(
            payable(LibClone.cloneDeterministic(address(singleton), bytes32("zero-output-test")))
        );
        sucker.initialize(PROJECT_ID);
    }

    /// @notice When a swap succeeds but returns 0 local tokens, the batch must be routed to
    /// pendingSwapOf (not marked claimable). This prevents unbacked project token minting.
    function test_zeroOutputSwapRoutesToPendingSwap() external {
        uint256 bridgeAmount = 100e6;
        uint256 leafTotal = 100e6;
        uint64 nonce = 1;

        // Mock executeSwapExternal to return 0 (simulates a swap that succeeds but produces nothing).
        vm.mockCall(
            address(sucker),
            abi.encodeWithSelector(JBSwapCCIPSucker.executeSwapExternal.selector),
            abi.encode(uint256(0))
        );

        // Build a CCIP message that delivers bridge tokens and triggers a swap.
        // localToken differs from BRIDGE_TOKEN and from tokenAmount.token, so the swap path is taken.
        JBMessageRoot memory msgRoot = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(address(localToken)))),
            amount: leafTotal,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: bytes32(uint256(0xdead))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            sourceTimestamp: 1
        });

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(usdc), amount: bridgeAmount});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)),
            data: abi.encode(uint8(0), abi.encode(msgRoot, uint256(0), uint256(1))),
            destTokenAmounts: tokenAmounts
        });

        // Mock the fromRemote call to succeed (we only care about the pendingSwapOf state).
        vm.mockCall(
            address(sucker),
            abi.encodeWithSignature(
                "fromRemote((uint8,bytes32,uint256,(uint64,bytes32),uint256,uint256,uint256,uint256,uint256,uint64))"
            ),
            abi.encode()
        );

        vm.prank(MOCK_ROUTER);
        sucker.ccipReceive(message);

        // The batch must be in pendingSwapOf, NOT in the conversion rate.
        (address bridgeToken, uint256 pendingBridgeAmount, uint256 pendingLeafTotal) =
            sucker.pendingSwapOf(address(localToken), nonce);

        assertEq(bridgeToken, address(usdc), "pending swap should store the bridge token");
        assertEq(pendingBridgeAmount, bridgeAmount, "pending swap should store the full bridge amount");
        assertEq(pendingLeafTotal, leafTotal, "pending swap should store the leaf total");

        // The conversion rate must NOT be set (both fields should be 0).
        (uint256 convLeafTotal, uint256 convLocalTotal) = sucker.exposed_conversionRateOf(address(localToken), nonce);
        assertEq(convLeafTotal, 0, "conversion rate leafTotal must be zero (not claimable)");
        assertEq(convLocalTotal, 0, "conversion rate localTotal must be zero (not claimable)");
    }

    /// @notice When a non-swap path sets localAmount > 0 (bridge token IS the local token),
    /// the conversion rate should be set normally and pendingSwapOf should NOT be populated.
    function test_nonSwapPathSetsConversionRateNormally() external {
        uint256 bridgeAmount = 100e6;
        uint64 nonce = 1;

        // When localToken == BRIDGE_TOKEN, no swap occurs — localAmount = tokenAmount.amount.
        JBMessageRoot memory msgRoot = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(address(usdc)))), // Same as BRIDGE_TOKEN
            amount: bridgeAmount,
            remoteRoot: JBInboxTreeRoot({nonce: nonce, root: bytes32(uint256(0xbeef))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            sourceTimestamp: 1
        });

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(usdc), amount: bridgeAmount});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(2)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)),
            data: abi.encode(uint8(0), abi.encode(msgRoot, uint256(0), uint256(1))),
            destTokenAmounts: tokenAmounts
        });

        vm.mockCall(
            address(sucker),
            abi.encodeWithSignature(
                "fromRemote((uint8,bytes32,uint256,(uint64,bytes32),uint256,uint256,uint256,uint256,uint256,uint64))"
            ),
            abi.encode()
        );

        vm.prank(MOCK_ROUTER);
        sucker.ccipReceive(message);

        // Conversion rate should be set.
        (uint256 convLeafTotal, uint256 convLocalTotal) = sucker.exposed_conversionRateOf(address(usdc), nonce);
        assertEq(convLeafTotal, bridgeAmount, "conversion rate leafTotal should match");
        assertEq(convLocalTotal, bridgeAmount, "conversion rate localTotal should match (no swap)");

        // pendingSwapOf should NOT be populated.
        (address bridgeToken, uint256 pendingBridgeAmount,) = sucker.pendingSwapOf(address(usdc), nonce);
        assertEq(bridgeToken, address(0), "pending swap should not be set for non-swap path");
        assertEq(pendingBridgeAmount, 0, "pending swap amount should be 0 for non-swap path");
    }
}
