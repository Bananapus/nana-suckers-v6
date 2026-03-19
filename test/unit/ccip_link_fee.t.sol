// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBCCIPSucker} from "../../src/JBCCIPSucker.sol";
import {JBSucker} from "../../src/JBSucker.sol";
import {JBCCIPSuckerDeployer} from "../../src/deployers/JBCCIPSuckerDeployer.sol";

import {IJBCCIPSuckerDeployer} from "../../src/interfaces/IJBCCIPSuckerDeployer.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";
import {CCIPHelper} from "../../src/libraries/CCIPHelper.sol";

/// @notice Harness that exposes internal state for testing.
contract CCIPLinkFeeHarness is JBCCIPSucker {
    using MerkleLib for MerkleLib.Tree;

    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions,
        address trusted_forwarder
    )
        JBCCIPSucker(deployer, directory, tokens, permissions, 1, IJBSuckerRegistry(address(1)), trusted_forwarder)
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

    function test_getOutboxBalance(address token) external view returns (uint256) {
        return _outboxOf[token].balance;
    }
}

/// @title CCIPLinkFeeTest
/// @notice Tests the LINK fee payment path in JBCCIPSucker._sendRootOverAMB.
contract CCIPLinkFeeTest is Test {
    address constant DIRECTORY = address(0x1001);
    address constant PERMISSIONS = address(0x1002);
    address constant TOKENS = address(0x1003);
    address constant MOCK_ROUTER = address(0x2001);
    address constant FORWARDER = address(0x3001);
    address constant PROJECT = address(0x4001);

    uint256 constant PROJECT_ID = 42;
    uint256 constant REMOTE_CHAIN_ID = 137;
    uint64 constant REMOTE_CHAIN_SELECTOR = 4_051_577_828_743_386_545;

    CCIPLinkFeeHarness sucker;
    address linkToken;

    function setUp() public {
        // Set chain ID to Ethereum Sepolia so CCIPHelper.linkOfChain works.
        vm.chainId(CCIPHelper.ETH_SEP_ID);
        linkToken = CCIPHelper.linkOfChain(CCIPHelper.ETH_SEP_ID);

        // Mock the deployer interface for the constructor.
        address mockDeployer = address(0x5001);
        vm.mockCall(
            mockDeployer, abi.encodeCall(IJBCCIPSuckerDeployer.ccipRemoteChainId, ()), abi.encode(REMOTE_CHAIN_ID)
        );
        vm.mockCall(
            mockDeployer,
            abi.encodeCall(IJBCCIPSuckerDeployer.ccipRemoteChainSelector, ()),
            abi.encode(REMOTE_CHAIN_SELECTOR)
        );
        vm.mockCall(mockDeployer, abi.encodeCall(IJBCCIPSuckerDeployer.ccipRouter, ()), abi.encode(MOCK_ROUTER));

        // Deploy singleton harness.
        CCIPLinkFeeHarness singleton = new CCIPLinkFeeHarness(
            JBCCIPSuckerDeployer(payable(mockDeployer)),
            IJBDirectory(DIRECTORY),
            IJBTokens(TOKENS),
            IJBPermissions(PERMISSIONS),
            FORWARDER
        );

        // Clone and initialize.
        sucker = CCIPLinkFeeHarness(payable(LibClone.cloneDeterministic(address(singleton), "ccip_link_fee_test")));
        sucker.initialize(PROJECT_ID);

        // Mock directory for ownerOf.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));

        // Mock primaryTerminalOf to return address(0).
        vm.mockCall(DIRECTORY, abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector), abi.encode(address(0)));

        // Mock the registry's toRemoteFee() to return 0.
        vm.mockCall(address(1), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));

        // Put code at MOCK_ROUTER so etch works.
        vm.etch(MOCK_ROUTER, bytes("0x1"));
    }

    function _mockCCIPSuccess(uint256 fee) internal {
        vm.mockCall(MOCK_ROUTER, abi.encodeWithSelector(IRouterClient.getFee.selector), abi.encode(fee));
        vm.mockCall(
            MOCK_ROUTER, abi.encodeWithSelector(IRouterClient.ccipSend.selector), abi.encode(bytes32(uint256(0xabcdef)))
        );
    }

    function _setupOutbox(address token, uint256 amount) internal {
        sucker.test_setRemoteToken(
            token,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000,
                addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
            })
        );
        sucker.test_insertIntoTree(1 ether, token, amount, bytes32(uint256(uint160(address(this)))));
    }

    // =========================================================================
    // LINK fee path — transportPayment == 0
    // =========================================================================

    /// @notice When transportPayment == 0 and the sucker has LINK, fees are paid in LINK.
    function test_toRemote_linkFee_succeeds() public {
        address erc20 = makeAddr("bridgedERC20");
        uint256 bridgeFee = 1 ether; // fee in LINK

        _setupOutbox(erc20, 10 ether);
        _mockCCIPSuccess(bridgeFee);

        // Mock ERC20 approve for the bridged token.
        vm.mockCall(erc20, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))), abi.encode(true));

        // Mock LINK token approve (forceApprove calls approve).
        vm.mockCall(linkToken, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))), abi.encode(true));

        // Mock LINK balanceOf to have enough.
        vm.mockCall(
            linkToken, abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(sucker)), abi.encode(10 ether)
        );

        // Call toRemote with 0 msg.value — triggers LINK fee path.
        sucker.toRemote(erc20);

        assertEq(sucker.test_getOutboxBalance(erc20), 0, "Outbox should be cleared");
    }

    /// @notice When transportPayment == 0 but LINK approve fails, the send reverts.
    function test_toRemote_linkFee_insufficientLink_reverts() public {
        address erc20 = makeAddr("bridgedERC20");
        uint256 bridgeFee = 1 ether;

        _setupOutbox(erc20, 10 ether);
        _mockCCIPSuccess(bridgeFee);

        vm.mockCall(erc20, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))), abi.encode(true));

        // Mock LINK approve to return false (insufficient balance / allowance failure).
        vm.mockCall(linkToken, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))), abi.encode(false));

        // SafeERC20.forceApprove reverts when approve returns false after a zero-allowance reset.
        vm.expectRevert();
        sucker.toRemote(erc20);
    }

    // =========================================================================
    // Native fee path — backward compatibility
    // =========================================================================

    /// @notice The native fee path (transportPayment > 0) still works identically.
    function test_toRemote_nativeFee_backwardCompat() public {
        address erc20 = makeAddr("bridgedERC20");
        uint256 bridgeFee = 0.05 ether;
        uint256 transportPayment = 0.1 ether;

        _setupOutbox(erc20, 10 ether);
        _mockCCIPSuccess(bridgeFee);

        vm.mockCall(erc20, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))), abi.encode(true));

        vm.deal(address(this), transportPayment);
        sucker.toRemote{value: transportPayment}(erc20);

        assertEq(sucker.test_getOutboxBalance(erc20), 0, "Outbox should be cleared");
    }

    /// @notice The native fee path still reverts when msg.value < fee.
    function test_toRemote_nativeFee_insufficientValue_reverts() public {
        address erc20 = makeAddr("bridgedERC20");
        uint256 bridgeFee = 0.5 ether;
        uint256 transportPayment = 0.1 ether;

        _setupOutbox(erc20, 10 ether);
        _mockCCIPSuccess(bridgeFee);

        vm.mockCall(erc20, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))), abi.encode(true));

        vm.deal(address(this), transportPayment);
        vm.expectRevert(
            abi.encodeWithSelector(JBSucker.JBSucker_InsufficientMsgValue.selector, transportPayment, bridgeFee)
        );
        sucker.toRemote{value: transportPayment}(erc20);
    }

    receive() external payable {}
}
