// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSwapCCIPSucker} from "../../src/JBSwapCCIPSucker.sol";
import {JBSwapCCIPSuckerDeployer} from "../../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract CodexSwapZeroBatchMockTerminal {
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
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

contract CodexSwapZeroBatchHarness is JBSwapCCIPSucker {
    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBSwapCCIPSucker(deployer, directory, tokens, permissions, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function test_addToBalance(address token, uint256 amount, uint256 projectId, uint256 leafIndex) external {
        _currentClaimLeafIndex = leafIndex + 1;
        _addToBalance(token, amount, projectId);
    }

    function exposed_highestReceivedNonce(address token) external view returns (uint64) {
        return _highestReceivedNonce[token];
    }

    function exposed_batchStartOf(address token, uint64 nonce) external view returns (uint256) {
        return _batchStartOf[token][nonce];
    }

    function exposed_batchEndOf(address token, uint64 nonce) external view returns (uint256) {
        return _batchEndOf[token][nonce];
    }
}

contract CodexSwapZeroAmountBatchGapTest is Test {
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
    CodexSwapZeroBatchMockTerminal internal terminal;
    CodexSwapZeroBatchHarness internal sucker;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        terminal = new CodexSwapZeroBatchMockTerminal();

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
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("weth()"), abi.encode(address(weth)));

        vm.mockCall(MOCK_ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(weth)));
        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(MOCK_PROJECTS));
        vm.mockCall(MOCK_PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));
        vm.mockCall(
            MOCK_DIRECTORY,
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(address(terminal))
        );

        CodexSwapZeroBatchHarness singleton = new CodexSwapZeroBatchHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
        sucker = CodexSwapZeroBatchHarness(payable(LibClone.cloneDeterministic(address(singleton), bytes32("zero"))));
        sucker.initialize(PROJECT_ID);
    }

    /// @notice FIX VERIFIED: Zero-amount batch no longer creates a phantom gap.
    /// Nonce progression and cumulative count are recorded unconditionally,
    /// so later funded batches remain claimable.
    function test_zeroAmountBatch_doesNotBlockLaterClaims() external {
        // Send a zero-amount root (nonce 1, batchCount=1).
        Client.Any2EVMMessage memory zeroBatchMessage = Client.Any2EVMMessage({
            messageId: bytes32("zero"),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)),
            data: abi.encode(
                uint8(0),
                abi.encode(
                    JBMessageRoot({
                        version: 1,
                        token: bytes32(uint256(uint160(address(usdc)))),
                        amount: 0,
                        remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xAAA1))}),
                        sourceTotalSupply: 0,
                        sourceCurrency: 1,
                        sourceDecimals: 18,
                        sourceSurplus: 0,
                        sourceBalance: 0,
                        sourceTimestamp: 1
                    }),
                    uint256(0),
                    uint256(1)
                )
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(MOCK_ROUTER);
        sucker.ccipReceive(zeroBatchMessage);

        // Nonce progression IS recorded even for zero-amount batch.
        assertEq(sucker.exposed_highestReceivedNonce(address(usdc)), 1, "zero-amount batch should advance nonce");
        assertEq(sucker.exposed_batchStartOf(address(usdc), 1), 0, "zero batch start should be recorded");
        assertEq(sucker.exposed_batchEndOf(address(usdc), 1), 1, "zero batch end should be recorded");

        // Send a funded batch (nonce 2, batchCount=2).
        usdc.mint(address(sucker), 50);

        Client.EVMTokenAmount[] memory bridged = new Client.EVMTokenAmount[](1);
        bridged[0] = Client.EVMTokenAmount({token: address(usdc), amount: 50});

        Client.Any2EVMMessage memory fundedBatchMessage = Client.Any2EVMMessage({
            messageId: bytes32("funded"),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)),
            data: abi.encode(
                uint8(0),
                abi.encode(
                    JBMessageRoot({
                        version: 1,
                        token: bytes32(uint256(uint160(address(usdc)))),
                        amount: 100,
                        remoteRoot: JBInboxTreeRoot({nonce: 2, root: bytes32(uint256(0xAAA2))}),
                        sourceTotalSupply: 0,
                        sourceCurrency: 1,
                        sourceDecimals: 18,
                        sourceSurplus: 0,
                        sourceBalance: 0,
                        sourceTimestamp: 2
                    }),
                    uint256(1),
                    uint256(2)
                )
            ),
            destTokenAmounts: bridged
        });

        vm.prank(MOCK_ROUTER);
        sucker.ccipReceive(fundedBatchMessage);

        assertEq(sucker.exposed_highestReceivedNonce(address(usdc)), 2, "later funded batch is tracked");
        assertEq(sucker.exposed_batchStartOf(address(usdc), 2), 1, "later batch start should be recorded");
        assertEq(sucker.exposed_batchEndOf(address(usdc), 2), 2, "later batch end should be recorded");

        // Claim leaf 1 (from nonce 2) — should succeed, NOT revert with BatchNotReceived.
        uint256 balBefore = usdc.balanceOf(address(sucker));
        sucker.test_addToBalance(address(usdc), 100, PROJECT_ID, 1);
        uint256 claimed = balBefore - usdc.balanceOf(address(sucker));
        assertEq(claimed, 50, "claim from funded batch should use nonce 2's rate");
    }
}
