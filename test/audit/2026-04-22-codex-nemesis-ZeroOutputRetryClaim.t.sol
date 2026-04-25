// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {JBSwapCCIPSucker} from "../../src/JBSwapCCIPSucker.sol";
import {JBSwapCCIPSuckerDeployer} from "../../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "../../src/structs/JBClaim.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBLeaf} from "../../src/structs/JBLeaf.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

contract ZeroOutputRetryHarness is JBSwapCCIPSucker {
    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBSwapCCIPSucker(deployer, directory, tokens, permissions, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function testSetInbox(address token, bytes32 root, uint64 nonce) external {
        _inboxOf[token] = JBInboxTreeRoot({nonce: nonce, root: root});
    }

    function testSetBatchAndRate(
        address token,
        uint64 nonce,
        uint256 leafTotal,
        uint256 localTotal,
        uint256 batchStart,
        uint256 batchEnd
    )
        external
    {
        _batchStartOf[token][nonce] = batchStart;
        _batchEndOf[token][nonce] = batchEnd;
        _highestReceivedNonce[token] = nonce;
        _conversionRateOf[token][nonce] = ConversionRate({leafTotal: leafTotal, localTotal: localTotal});
    }

    function testProofForSingleLeaf() external pure returns (bytes32[32] memory proof) {
        proof[0] = bytes32(0);
        for (uint256 i = 1; i < 32; i++) {
            proof[i] = keccak256(abi.encodePacked(proof[i - 1], proof[i - 1]));
        }
    }

    function testRootForLeaf(
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        uint256 index,
        bytes32[32] memory proof
    )
        external
        pure
        returns (bytes32)
    {
        return MerkleLib.branchRoot(
            keccak256(abi.encodePacked(projectTokenCount, terminalTokenAmount, beneficiary)), proof, index
        );
    }
}

contract ZeroOutputRetryClaimTest is Test {
    address internal constant DIRECTORY = address(0x1001);
    address internal constant PROJECTS = address(0x1002);
    address internal constant PERMISSIONS = address(0x1003);
    address internal constant TOKENS = address(0x1004);
    address internal constant CONTROLLER = address(0x1005);
    address internal constant TERMINAL = address(0x1006);
    address internal constant BRIDGE_TOKEN = address(0x1007);
    address internal constant WETH = address(0x1008);
    address internal constant CCIP_ROUTER = address(0x1009);
    address internal constant LOCAL_TOKEN = address(0x1010);
    address internal constant BENEFICIARY = address(0xBEEF);

    JBSwapCCIPSuckerDeployer internal deployer;
    ZeroOutputRetryHarness internal sucker;

    function setUp() public {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(PROJECTS, abi.encodeWithSignature("ownerOf(uint256)", 1), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (1)), abi.encode(CONTROLLER));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, LOCAL_TOKEN)), abi.encode(TERMINAL));
        vm.mockCall(CONTROLLER, abi.encodeWithSelector(IJBController.mintTokensOf.selector), abi.encode(uint256(0)));
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());
        vm.mockCall(LOCAL_TOKEN, abi.encodeWithSignature("balanceOf(address)", address(0)), abi.encode(uint256(0)));

        deployer = new JBSwapCCIPSuckerDeployer({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            configurator: address(this),
            trustedForwarder: address(0)
        });
        deployer.setChainSpecificConstants({remoteChainId: 2, remoteChainSelector: 2, router: ICCIPRouter(CCIP_ROUTER)});
        deployer.setSwapConstants({
            _bridgeToken: IERC20(BRIDGE_TOKEN),
            _poolManager: IPoolManager(address(0)),
            _v3Factory: IUniswapV3Factory(address(0)),
            _univ4Hook: address(0),
            _weth: WETH
        });

        ZeroOutputRetryHarness singleton = new ZeroOutputRetryHarness({
            deployer: deployer,
            directory: IJBDirectory(DIRECTORY),
            tokens: IJBTokens(TOKENS),
            permissions: IJBPermissions(PERMISSIONS)
        });
        deployer.configureSingleton(singleton);

        sucker = ZeroOutputRetryHarness(payable(address(deployer.createForSender(1, bytes32("ZERO_OUTPUT")))));

        vm.mockCall(LOCAL_TOKEN, abi.encodeWithSignature("balanceOf(address)", address(sucker)), abi.encode(uint256(0)));
    }

    function test_claim_mintsEvenWhenBatchRateWasClearedToZero() public {
        bytes32[32] memory proof = sucker.testProofForSingleLeaf();
        bytes32 beneficiary = bytes32(uint256(uint160(BENEFICIARY)));
        bytes32 root = sucker.testRootForLeaf({
            projectTokenCount: 10e18,
            terminalTokenAmount: 100e6,
            beneficiary: beneficiary,
            index: 0,
            proof: proof
        });

        sucker.testSetInbox({token: LOCAL_TOKEN, root: root, nonce: 1});
        sucker.testSetBatchAndRate({
            token: LOCAL_TOKEN,
            nonce: 1,
            leafTotal: 100e6,
            localTotal: 0,
            batchStart: 0,
            batchEnd: 1
        });

        vm.expectCall(
            CONTROLLER,
            abi.encodeWithSelector(
                IJBController.mintTokensOf.selector,
                1,
                10e18,
                BENEFICIARY,
                "",
                false
            )
        );
        vm.expectCall(
            TERMINAL,
            abi.encodeWithSelector(
                IJBTerminal.addToBalanceOf.selector,
                1,
                LOCAL_TOKEN,
                0,
                false,
                "",
                ""
            )
        );

        sucker.claim(
            JBClaim({
                token: LOCAL_TOKEN,
                leaf: JBLeaf({
                    index: 0,
                    beneficiary: beneficiary,
                    projectTokenCount: 10e18,
                    terminalTokenAmount: 100e6
                }),
                proof: proof
            })
        );
    }
}
