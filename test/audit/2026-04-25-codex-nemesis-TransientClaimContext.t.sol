// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSwapCCIPSucker} from "../../src/JBSwapCCIPSucker.sol";
import {JBSwapCCIPSuckerDeployer} from "../../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "../../src/structs/JBClaim.sol";
import {JBLeaf} from "../../src/structs/JBLeaf.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract TransientContextTerminal {
    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

contract TransientContextSwapHarness is JBSwapCCIPSucker {
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
        if (nonce > _highestReceivedNonce[token]) _highestReceivedNonce[token] = nonce;
    }

    function test_setRemoteToken(address token, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[token] = remoteToken;
    }

    function test_setOutboxBalance(address token, uint256 amount) external {
        _outboxOf[token].balance = amount;
    }

    function _validateBranchRoot(
        bytes32,
        uint256,
        uint256,
        bytes32,
        uint256,
        bytes32[32] calldata
    )
        internal
        pure
        override
    {}

    function peerChainId() external view override returns (uint256) {
        return block.chainid;
    }
}

contract TransientClaimContextPoC is Test {
    address private constant MOCK_DEPLOYER = address(0xDE);
    address private constant MOCK_DIRECTORY = address(0xD1);
    address private constant MOCK_TOKENS = address(0xD2);
    address private constant MOCK_PERMISSIONS = address(0xD3);
    address private constant MOCK_ROUTER = address(0xD4);
    address private constant MOCK_PROJECTS = address(0xD5);
    address private constant MOCK_CONTROLLER = address(0xD6);

    ERC20Mock private token;
    ERC20Mock private weth;
    TransientContextTerminal private terminal;
    TransientContextSwapHarness private sucker;

    function setUp() public {
        token = new ERC20Mock("Token", "TOK", address(this), 0);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        terminal = new TransientContextTerminal();

        vm.etch(MOCK_ROUTER, hex"01");
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(uint256(4217)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(uint64(1)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(MOCK_ROUTER));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("bridgeToken()"), abi.encode(address(token)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("poolManager()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("v3Factory()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("univ4Hook()"), abi.encode(address(0)));
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("weth()"), abi.encode(address(weth)));

        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSelector(IJBDirectory.PROJECTS.selector), abi.encode(MOCK_PROJECTS));
        vm.mockCall(
            MOCK_DIRECTORY,
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(address(terminal))
        );
        vm.mockCall(
            MOCK_DIRECTORY, abi.encodeWithSelector(IJBDirectory.controllerOf.selector), abi.encode(MOCK_CONTROLLER)
        );
        vm.mockCall(MOCK_PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));
        vm.mockCall(
            MOCK_CONTROLLER, abi.encodeWithSelector(IJBController.mintTokensOf.selector), abi.encode(uint256(0))
        );

        TransientContextSwapHarness singleton = new TransientContextSwapHarness(
            JBSwapCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
        sucker = TransientContextSwapHarness(payable(LibClone.cloneDeterministic(address(singleton), bytes32("ctx"))));
        sucker.initialize(1);
    }

    function test_claimContextLeaksIntoEmergencyExitInSameTransaction() external {
        address localToken = address(token);

        sucker.test_setConversionRate({
            token: localToken, nonce: 1, leafTotal: 100, localTotal: 200, batchStart: 0, batchEnd: 1
        });
        sucker.test_setRemoteToken({
            token: localToken,
            remoteToken: JBRemoteToken({
                enabled: false, emergencyHatch: true, minGas: 200_000, addr: bytes32(uint256(uint160(address(token))))
            })
        });
        sucker.test_setOutboxBalance(localToken, 100);

        token.mint(address(sucker), 300);

        JBClaim memory inbound = JBClaim({
            token: localToken,
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 1,
                terminalTokenAmount: 10
            }),
            proof: [
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0)
            ]
        });
        JBClaim memory emergency = JBClaim({
            token: localToken,
            leaf: JBLeaf({
                index: 1,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 1,
                terminalTokenAmount: 100
            }),
            proof: [
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0),
                bytes32(0)
            ]
        });

        sucker.claim(inbound);
        uint256 afterInboundClaim = token.balanceOf(address(terminal));

        sucker.exitThroughEmergencyHatch(emergency);

        uint256 emergencyDelta = token.balanceOf(address(terminal)) - afterInboundClaim;
        // Fixed: emergency exit no longer inherits the stale conversion rate from the prior claim.
        assertEq(emergencyDelta, 100, "emergency exit should use raw terminal token amount");
    }
}
