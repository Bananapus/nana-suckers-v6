// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSwapCCIPSucker} from "../../src/JBSwapCCIPSucker.sol";
import {JBSwapCCIPSuckerDeployer} from "../../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract CodexNemesisSwapZeroLocalTerminal {
    uint256 public lastAmount;
    address public lastToken;

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
        lastToken = token;
        lastAmount = amount;
    }
}

contract CodexNemesisSwapZeroLocalController {
    uint256 public lastMintAmount;
    address public lastBeneficiary;

    function mintTokensOf(
        uint256,
        uint256 tokenCount,
        address beneficiary,
        string calldata,
        bool
    )
        external
        returns (uint256 beneficiaryTokenCount)
    {
        lastMintAmount = tokenCount;
        lastBeneficiary = beneficiary;
        return tokenCount;
    }
}

contract CodexNemesisSwapZeroLocalHarness is JBSwapCCIPSucker {
    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBSwapCCIPSucker(deployer, directory, tokens, permissions, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function test_setConversionRate(
        address token,
        uint64 nonce,
        uint256 leafTotal,
        uint256 localTotal,
        uint256 batchStart,
        uint256 batchEnd
    )
        external
    {
        _conversionRateOf[token][nonce] = ConversionRate({leafTotal: leafTotal, localTotal: localTotal});
        _batchStartOf[token][nonce] = batchStart;
        _batchEndOf[token][nonce] = batchEnd;
        _highestReceivedNonce[token] = nonce;
    }

    function test_handleClaim(
        address terminalToken,
        uint256 terminalTokenAmount,
        uint256 projectTokenAmount,
        uint256 leafIndex,
        bytes32 beneficiary
    )
        external
    {
        _currentClaimLeafIndex = leafIndex + 1;
        _handleClaim(terminalToken, terminalTokenAmount, projectTokenAmount, beneficiary);
    }
}

contract CodexNemesisSwapZeroLocalTotalUnbackedClaimTest is Test {
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
    CodexNemesisSwapZeroLocalTerminal internal terminal;
    CodexNemesisSwapZeroLocalController internal controller;
    CodexNemesisSwapZeroLocalHarness internal sucker;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        terminal = new CodexNemesisSwapZeroLocalTerminal();
        controller = new CodexNemesisSwapZeroLocalController();

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
        vm.mockCall(
            MOCK_DIRECTORY,
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, PROJECT_ID),
            abi.encode(address(controller))
        );

        CodexNemesisSwapZeroLocalHarness singleton = new CodexNemesisSwapZeroLocalHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );

        sucker = CodexNemesisSwapZeroLocalHarness(
            payable(LibClone.cloneDeterministic(address(singleton), bytes32("nemesis-zero-local")))
        );
        sucker.initialize(PROJECT_ID);
    }

    function test_claimStillMintsWhenBatchConversionRateIsZero() external {
        sucker.test_setConversionRate({
            token: address(usdc), nonce: 1, leafTotal: 100e6, localTotal: 0, batchStart: 0, batchEnd: 1
        });

        sucker.test_handleClaim({
            terminalToken: address(usdc),
            terminalTokenAmount: 100e6,
            projectTokenAmount: 5e18,
            leafIndex: 0,
            beneficiary: bytes32(uint256(uint160(address(this))))
        });

        assertEq(terminal.lastToken(), address(usdc), "claim should still target the terminal token");
        assertEq(terminal.lastAmount(), 0, "scaled backing added to the terminal is zero");
        assertEq(controller.lastMintAmount(), 5e18, "project tokens are still minted");
        assertEq(controller.lastBeneficiary(), address(this), "beneficiary still receives the minted tokens");
    }
}
