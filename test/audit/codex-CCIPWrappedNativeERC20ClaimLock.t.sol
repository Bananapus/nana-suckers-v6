// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBCCIPSucker} from "../../src/JBCCIPSucker.sol";
import {JBCCIPSuckerDeployer} from "../../src/deployers/JBCCIPSuckerDeployer.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "../../src/structs/JBClaim.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBLeaf} from "../../src/structs/JBLeaf.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBSucker} from "../../src/JBSucker.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

contract CodexMockWETH {
    mapping(address => uint256) public balanceOf;

    receive() external payable {}

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH send failed");
    }
}

contract CodexCCIPWrappedNativeHarness is JBCCIPSucker {
    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBCCIPSucker(deployer, directory, tokens, permissions, 1, IJBSuckerRegistry(address(1)), address(0))
    {}
}

contract CodexCCIPWrappedNativeERC20ClaimLockTest is Test {
    address internal constant MOCK_DEPLOYER = address(0xDE);
    address internal constant MOCK_DIRECTORY = address(0xD1);
    address internal constant MOCK_TOKENS = address(0xD2);
    address internal constant MOCK_PERMISSIONS = address(0xD3);
    address internal constant MOCK_ROUTER = address(0xD4);

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant REMOTE_CHAIN_ID = 42_161;
    uint64 internal constant REMOTE_CHAIN_SELECTOR = 4_949_039_107_694_359_620;

    CodexMockWETH internal weth;
    JBCCIPSucker internal sucker;

    function setUp() external {
        weth = new CodexMockWETH();
        vm.etch(MOCK_ROUTER, hex"01");

        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(REMOTE_CHAIN_ID));
        vm.mockCall(
            MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(REMOTE_CHAIN_SELECTOR)
        );
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(MOCK_ROUTER));
        vm.mockCall(MOCK_ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(weth)));

        // Mock DIRECTORY.PROJECTS() so the JBSucker constructor succeeds.
        vm.mockCall(
            MOCK_DIRECTORY,
            abi.encodeWithSignature("PROJECTS()"),
            abi.encode(address(0x1234))
        );

        JBCCIPSuckerDeployer deployer = new JBCCIPSuckerDeployer({
            directory: IJBDirectory(MOCK_DIRECTORY),
            permissions: IJBPermissions(MOCK_PERMISSIONS),
            tokens: IJBTokens(MOCK_TOKENS),
            configurator: address(this),
            trustedForwarder: address(0)
        });

        deployer.setChainSpecificConstants({
            remoteChainId: REMOTE_CHAIN_ID,
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            router: ICCIPRouter(MOCK_ROUTER)
        });

        JBCCIPSucker singleton = new JBCCIPSucker({
            deployer: deployer,
            directory: IJBDirectory(MOCK_DIRECTORY),
            permissions: IJBPermissions(MOCK_PERMISSIONS),
            tokens: IJBTokens(MOCK_TOKENS),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(1)),
            trustedForwarder: address(0)
        });

        sucker =
            JBCCIPSucker(payable(LibClone.cloneDeterministic(address(singleton), bytes32("codex-ccip-weth-lock"))));
        sucker.initialize(PROJECT_ID);
    }

    /// @notice Verify fix: when root.token is the WETH ERC-20 (not NATIVE_TOKEN), WETH is NOT unwrapped.
    /// Previously, ccipReceive unconditionally unwrapped all WETH before decoding the message,
    /// destroying the ERC-20 balance and making claims permanently unclaimable (NM-001/SI-001/FF-001).
    function test_wethNotUnwrappedWhenClaimTokenIsWethERC20() external {
        uint256 amount = 10 ether;

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(address(weth)))),
            amount: amount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xdead))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 18,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        Client.EVMTokenAmount[] memory destTokenAmounts = new Client.EVMTokenAmount[](1);
        destTokenAmounts[0] = Client.EVMTokenAmount({token: address(weth), amount: amount});

        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)),
            data: abi.encode(root),
            destTokenAmounts: destTokenAmounts
        });

        vm.deal(address(weth), amount);
        weth.mint(address(sucker), amount);

        vm.prank(MOCK_ROUTER);
        sucker.ccipReceive(ccipMessage);

        // Fix verified: WETH is preserved (not unwrapped to ETH).
        assertEq(weth.balanceOf(address(sucker)), amount, "WETH should NOT be unwrapped when root.token is WETH");
        assertEq(address(sucker).balance, 0, "no ETH should appear from unwrapping");
        assertEq(sucker.amountToAddToBalanceOf(address(weth)), amount, "claim accounting should see WETH backing");
    }
}
