// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {JBCCIPSucker} from "../../src/JBCCIPSucker.sol";
import {JBCCIPSuckerDeployer} from "../../src/deployers/JBCCIPSuckerDeployer.sol";
import {IJBCCIPSuckerDeployer} from "../../src/interfaces/IJBCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBPayRemoteMessage} from "../../src/structs/JBPayRemoteMessage.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

contract TerminalSink {
    uint256 public totalReceived;

    function addToBalanceOf(uint256, address, uint256 amount, bool, string calldata, bytes calldata) external payable {
        totalReceived += amount;
    }

    function pay(
        uint256,
        address,
        uint256 amount,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        return amount;
    }
}

contract ControllerStub {
    uint256 public lastMintAmount;

    function mintTokensOf(uint256, uint256 tokenCount, address, string calldata, bool) external returns (uint256) {
        lastMintAmount = tokenCount;
        return tokenCount;
    }
}

contract RouterStub {
    uint256 public fee;
    uint256 public totalFeeReceived;

    function setFee(uint256 newFee) external {
        fee = newFee;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }

    function ccipSend(uint64, Client.EVM2AnyMessage memory) external payable returns (bytes32) {
        totalFeeReceived += msg.value;
        return bytes32(uint256(1));
    }
}

contract ZeroCostBridgeSuckerHarness is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        uint256 feeProjectId,
        IJBSuckerRegistry registry,
        address trustedForwarder
    )
        JBSucker(directory, permissions, tokens, feeProjectId, registry, trustedForwarder)
    {}

    function peerChainId() external view override returns (uint256) {
        return block.chainid;
    }

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == _toAddress(peer());
    }

    function _sendRootOverAMB(
        uint256 transportPayment,
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBMessageRoot memory
    )
        internal
        pure
        override
    {
        if (transportPayment != 0) revert JBSucker_UnexpectedMsgValue(transportPayment);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function _sendPayOverAMB(uint256, address, uint256, JBRemoteToken memory, JBPayRemoteMessage memory)
        internal
        pure
        override
    {
        revert("not implemented");
    }

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

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

    function test_handleClaim(
        address token,
        uint256 terminalTokenAmount,
        uint256 projectTokenAmount,
        address beneficiary
    )
        external
    {
        _handleClaim(token, terminalTokenAmount, projectTokenAmount, bytes32(uint256(uint160(beneficiary))));
    }
}

contract CCIPSuckerHarness is JBCCIPSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions,
        uint256 feeProjectId,
        IJBSuckerRegistry registry,
        address trustedForwarder
    )
        JBCCIPSucker(deployer, directory, tokens, permissions, feeProjectId, registry, trustedForwarder)
    {}

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

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

    function test_handleClaim(
        address token,
        uint256 terminalTokenAmount,
        uint256 projectTokenAmount,
        address beneficiary
    )
        external
    {
        _handleClaim(token, terminalTokenAmount, projectTokenAmount, bytes32(uint256(uint160(beneficiary))));
    }
}

contract NonPayableCaller {
    function callToRemote(address sucker, address token) external payable {
        JBSucker(payable(sucker)).toRemote{value: msg.value}(token);
    }
}

contract CodexFeeLockingTest is Test {
    address constant DIRECTORY = address(0x1001);
    address constant PERMISSIONS = address(0x1002);
    address constant TOKENS = address(0x1003);
    address constant PROJECTS = address(0x1004);
    address constant REGISTRY = address(0x1007);
    address constant FORWARDER = address(0);
    address constant ERC20_TOKEN = address(0x2001);
    address constant REMOTE_TOKEN = address(0x2002);
    address constant ROUTER_ADDR = address(0x2003);

    uint256 constant PROJECT_ID = 42;
    uint256 constant FEE_PROJECT_ID = 1;
    uint256 constant TO_REMOTE_FEE = 0.001 ether;
    uint256 constant TRANSPORT_PAYMENT = 0.1 ether;
    uint256 constant CCIP_FEE = 0.05 ether;
    uint256 constant NATIVE_CLAIM_AMOUNT = 1 ether;

    TerminalSink terminal;
    ControllerStub controller;
    RouterStub router;

    function setUp() public {
        terminal = new TerminalSink();
        controller = new ControllerStub();
        router = new RouterStub();

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(PROJECTS, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(address(controller)));
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(terminal))
        );

        // Mock DIRECTORY.terminalsOf() so _buildETHAggregate() in _sendRoot() doesn't revert.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(new IJBTerminal[](0)));
    }

    function test_failedToRemoteFeePayment_staysLockedAfterLaterNativeClaim() public {
        ZeroCostBridgeSuckerHarness singleton = new ZeroCostBridgeSuckerHarness(
            IJBDirectory(DIRECTORY),
            IJBPermissions(PERMISSIONS),
            IJBTokens(TOKENS),
            FEE_PROJECT_ID,
            IJBSuckerRegistry(REGISTRY),
            FORWARDER
        );

        ZeroCostBridgeSuckerHarness sucker = ZeroCostBridgeSuckerHarness(
            payable(address(LibClone.cloneDeterministic(address(singleton), "codex-fee-lock")))
        );
        sucker.initialize(PROJECT_ID);

        vm.mockCall(REGISTRY, abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(TO_REMOTE_FEE));
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(0))
        );

        sucker.test_setRemoteToken(
            ERC20_TOKEN,
            JBRemoteToken({
                enabled: true, emergencyHatch: false, minGas: 200_000, addr: bytes32(uint256(uint160(REMOTE_TOKEN)))
            })
        );
        sucker.test_insertIntoTree(1, ERC20_TOKEN, 0, bytes32(uint256(uint160(address(this)))));

        sucker.toRemote{value: TO_REMOTE_FEE}(ERC20_TOKEN);
        assertEq(address(sucker).balance, TO_REMOTE_FEE, "failed fee payment should stay in the sucker");

        vm.deal(address(sucker), address(sucker).balance + NATIVE_CLAIM_AMOUNT);
        sucker.test_handleClaim(JBConstants.NATIVE_TOKEN, NATIVE_CLAIM_AMOUNT, 1, address(this));

        assertEq(address(sucker).balance, TO_REMOTE_FEE, "later native claims do not absorb the failed protocol fee");
    }

    function test_failedCcipRefund_staysLockedAfterLaterNativeClaim() public {
        address mockDeployer = address(0x3001);
        vm.mockCall(mockDeployer, abi.encodeCall(IJBCCIPSuckerDeployer.ccipRemoteChainId, ()), abi.encode(uint256(137)));
        vm.mockCall(
            mockDeployer,
            abi.encodeCall(IJBCCIPSuckerDeployer.ccipRemoteChainSelector, ()),
            abi.encode(uint64(4_051_577_828_743_386_545))
        );
        vm.mockCall(
            mockDeployer, abi.encodeCall(IJBCCIPSuckerDeployer.ccipRouter, ()), abi.encode(ICCIPRouter(ROUTER_ADDR))
        );

        CCIPSuckerHarness singleton = new CCIPSuckerHarness(
            JBCCIPSuckerDeployer(payable(mockDeployer)),
            IJBDirectory(DIRECTORY),
            IJBTokens(TOKENS),
            IJBPermissions(PERMISSIONS),
            FEE_PROJECT_ID,
            IJBSuckerRegistry(REGISTRY),
            FORWARDER
        );

        CCIPSuckerHarness sucker =
            CCIPSuckerHarness(payable(address(LibClone.cloneDeterministic(address(singleton), "codex-ccip-lock"))));
        sucker.initialize(PROJECT_ID);

        vm.mockCall(REGISTRY, abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(0))
        );
        vm.etch(ROUTER_ADDR, address(router).code);
        RouterStub(ROUTER_ADDR).setFee(CCIP_FEE);

        sucker.test_setRemoteToken(
            ERC20_TOKEN,
            JBRemoteToken({
                enabled: true, emergencyHatch: false, minGas: 200_000, addr: bytes32(uint256(uint160(REMOTE_TOKEN)))
            })
        );
        sucker.test_insertIntoTree(1, ERC20_TOKEN, 0, bytes32(uint256(uint160(address(this)))));

        NonPayableCaller caller = new NonPayableCaller();
        vm.deal(address(caller), TRANSPORT_PAYMENT);
        caller.callToRemote{value: TRANSPORT_PAYMENT}(address(sucker), ERC20_TOKEN);

        uint256 stuckRefund = TRANSPORT_PAYMENT - CCIP_FEE;
        assertEq(address(sucker).balance, stuckRefund, "failed refund should stay in the sucker");
        assertEq(RouterStub(ROUTER_ADDR).totalFeeReceived(), CCIP_FEE, "router should receive the bridge fee");

        vm.deal(address(sucker), address(sucker).balance + NATIVE_CLAIM_AMOUNT);
        sucker.test_handleClaim(JBConstants.NATIVE_TOKEN, NATIVE_CLAIM_AMOUNT, 1, address(this));

        assertEq(address(sucker).balance, stuckRefund, "later native claims do not absorb the failed refund");
    }
}
