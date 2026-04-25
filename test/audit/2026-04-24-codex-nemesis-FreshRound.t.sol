// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {JBCCIPSucker} from "../../src/JBCCIPSucker.sol";
import {JBSwapCCIPSucker} from "../../src/JBSwapCCIPSucker.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {JBCCIPSuckerDeployer} from "../../src/deployers/JBCCIPSuckerDeployer.sol";
import {JBSwapCCIPSuckerDeployer} from "../../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

contract CodexNemesisMockTerminal {
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
        if (token != address(0)) IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

contract CodexNemesisMockPoolManager is IPoolManager {
    uint160 internal constant SQRT_PRICE_X96 = 79_228_162_514_264_337_593_543_950_336;

    function unlock(bytes calldata) external pure override returns (bytes memory) {
        return abi.encode(uint256(0));
    }

    function initialize(PoolKey memory, uint160) external pure override returns (int24 tick) {
        return 0;
    }

    function modifyLiquidity(
        PoolKey memory,
        ModifyLiquidityParams memory,
        bytes calldata
    )
        external
        pure
        override
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function swap(
        PoolKey memory,
        SwapParams memory,
        bytes calldata
    )
        external
        pure
        override
        returns (BalanceDelta swapDelta)
    {
        return BalanceDelta.wrap(0);
    }

    function donate(
        PoolKey memory,
        uint256,
        uint256,
        bytes calldata
    )
        external
        pure
        override
        returns (BalanceDelta delta)
    {
        return BalanceDelta.wrap(0);
    }

    function sync(Currency) external pure override {}

    function take(Currency, address, uint256) external pure override {}

    function settle() external payable override returns (uint256 paid) {
        return 0;
    }

    function settleFor(address) external payable override returns (uint256 paid) {
        return 0;
    }

    function clear(Currency, uint256) external pure override {}

    function mint(address, uint256, uint256) external pure override {}

    function burn(address, uint256, uint256) external pure override {}

    function updateDynamicLPFee(PoolKey memory, uint24) external pure override {}

    function protocolFeesAccrued(Currency) external pure override returns (uint256 amount) {
        return 0;
    }

    function setProtocolFee(PoolKey memory, uint24) external pure override {}

    function setProtocolFeeController(address) external pure override {}

    function collectProtocolFees(address, Currency, uint256) external pure override returns (uint256 amountCollected) {
        return 0;
    }

    function protocolFeeController() external pure override returns (address) {
        return address(0);
    }

    function balanceOf(address, uint256) external pure override returns (uint256 amount) {
        return 0;
    }

    function allowance(address, address, uint256) external pure override returns (uint256 amount) {
        return 0;
    }

    function isOperator(address, address) external pure override returns (bool approved) {
        return false;
    }

    function transfer(address, uint256, uint256) external pure override returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256, uint256) external pure override returns (bool) {
        return true;
    }

    function approve(address, uint256, uint256) external pure override returns (bool) {
        return true;
    }

    function setOperator(address, bool) external pure override returns (bool) {
        return true;
    }

    function extsload(bytes32) external pure override returns (bytes32 value) {
        return bytes32(uint256(SQRT_PRICE_X96));
    }

    function extsload(bytes32, uint256) external pure override returns (bytes32[] memory values) {
        values = new bytes32[](2);
        values[0] = bytes32(uint256(SQRT_PRICE_X96));
        values[1] = bytes32(uint256(SQRT_PRICE_X96));
    }

    function extsload(bytes32[] calldata) external pure override returns (bytes32[] memory values) {
        values = new bytes32[](2);
        values[0] = bytes32(uint256(SQRT_PRICE_X96));
        values[1] = bytes32(uint256(SQRT_PRICE_X96));
    }

    function exttload(bytes32) external pure override returns (bytes32 value) {
        return bytes32(0);
    }

    function exttload(bytes32[] calldata) external pure override returns (bytes32[] memory values) {
        values = new bytes32[](0);
    }

    function getSlot0(PoolId)
        external
        pure
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return (SQRT_PRICE_X96, 0, 0, 0);
    }

    function getLiquidity(PoolId) external pure returns (uint128 liquidity) {
        return 1e18;
    }
}

contract CodexNemesisSwapHarness is JBSwapCCIPSucker {
    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions,
        IJBSuckerRegistry registry
    )
        JBSwapCCIPSucker(deployer, directory, tokens, permissions, 1, registry, address(0))
    {}

    function exposedAddToBalance(address token, uint256 amount, uint256 projectId, uint256 leafIndex) external {
        _currentClaimLeafIndex = leafIndex + 1;
        _addToBalance(token, amount, projectId);
    }
}

contract CodexNemesisFreshRoundTest is Test {
    address internal constant PROJECTS = address(0x1001);
    address internal constant DIRECTORY = address(0x1002);
    address internal constant PERMISSIONS = address(0x1003);
    address internal constant TOKENS = address(0x1004);
    address internal constant ROUTER = address(0x1005);
    uint256 internal constant PROJECT_ID = 1;
    uint64 internal constant REMOTE_SELECTOR = 7_281_642_695_469_137_430;

    ERC20Mock internal bridgeToken;
    ERC20Mock internal localToken;
    CodexNemesisMockTerminal internal terminal;

    function setUp() public {
        bridgeToken = new ERC20Mock("Bridge", "BRG", address(this), 0);
        localToken = new ERC20Mock("Local", "LOC", address(this), 0);
        terminal = new CodexNemesisMockTerminal();

        vm.etch(ROUTER, hex"01");
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(IJBProjects(PROJECTS)));
        vm.mockCall(PROJECTS, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(
            DIRECTORY,
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(IJBTerminal(address(terminal)))
        );
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(new IJBTerminal[](0)));
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(address(0xCAFE)));
        vm.mockCall(
            address(0xCAFE),
            abi.encodeWithSignature("mintTokensOf(uint256,uint256,address,string,bool)"),
            abi.encode(uint256(0))
        );
        vm.mockCall(TOKENS, abi.encodeCall(IJBTokens.tokenOf, (PROJECT_ID)), abi.encode(address(bridgeToken)));
    }

    function test_retrySwapZeroOutputClearsGateAndAllowsZeroBackedClaims() public {
        JBSuckerRegistry registry =
            new JBSuckerRegistry(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), address(this), address(0));
        JBSwapCCIPSuckerDeployer deployer = new JBSwapCCIPSuckerDeployer(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), address(this), address(0)
        );
        deployer.setChainSpecificConstants(4217, REMOTE_SELECTOR, ICCIPRouter(ROUTER));
        deployer.setSwapConstants(
            IERC20(address(bridgeToken)),
            IPoolManager(address(new CodexNemesisMockPoolManager())),
            IUniswapV3Factory(address(0)),
            address(0),
            address(localToken)
        );

        CodexNemesisSwapHarness singleton = new CodexNemesisSwapHarness(
            deployer, IJBDirectory(DIRECTORY), IJBTokens(TOKENS), IJBPermissions(PERMISSIONS), registry
        );
        deployer.configureSingleton(singleton);
        CodexNemesisSwapHarness sucker =
            CodexNemesisSwapHarness(payable(LibClone.cloneDeterministic(address(singleton), bytes32("retry"))));
        sucker.initialize(PROJECT_ID);

        JBMessageRoot memory root = JBMessageRoot({
            token: bytes32(uint256(uint160(address(localToken)))),
            amount: 100,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(1))}),
            sourceTotalSupply: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            sourceCurrency: 0,
            sourceDecimals: 18,
            snapshotNonce: 1,
            version: 1
        });

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(bridgeToken), amount: 100});
        bridgeToken.mint(address(sucker), 100);

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32("msg"),
            sourceChainSelector: REMOTE_SELECTOR,
            sender: abi.encode(address(sucker)),
            data: abi.encode(uint8(0), abi.encode(root, uint256(0), uint256(1))),
            destTokenAmounts: tokenAmounts
        });

        vm.prank(ROUTER);
        sucker.ccipReceive(message);

        (address pendingBridgeToken, uint256 pendingBridgeAmount, uint256 pendingLeafTotal) =
            sucker.pendingSwapOf(address(localToken), 1);
        assertEq(pendingBridgeToken, address(bridgeToken));
        assertEq(pendingBridgeAmount, 100);
        assertEq(pendingLeafTotal, 100);

        sucker.retrySwap(address(localToken), 1);

        (, pendingBridgeAmount,) = sucker.pendingSwapOf(address(localToken), 1);
        assertEq(pendingBridgeAmount, 0, "retry clears the pending gate");
        assertEq(localToken.balanceOf(address(sucker)), 0, "zero-output retry leaves no local backing");

        sucker.exposedAddToBalance(address(localToken), 100, PROJECT_ID, 0);
        assertEq(localToken.balanceOf(address(sucker)), 0, "claim path can proceed with zero local balance");
    }

    function test_peerTopologyDriftBreaksDefaultPeerAuthentication() public {
        JBSuckerRegistry registryA =
            new JBSuckerRegistry(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), address(this), address(0));
        JBSuckerRegistry registryB =
            new JBSuckerRegistry(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), address(0xBEEF), address(0));

        JBCCIPSuckerDeployer deployerA = new JBCCIPSuckerDeployer(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), address(this), address(0)
        );
        JBCCIPSuckerDeployer deployerB = new JBCCIPSuckerDeployer(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), address(this), address(0)
        );

        deployerA.setChainSpecificConstants(4217, REMOTE_SELECTOR, ICCIPRouter(ROUTER));
        deployerB.setChainSpecificConstants(4217, REMOTE_SELECTOR, ICCIPRouter(ROUTER));

        JBCCIPSucker singletonA = new JBCCIPSucker(
            deployerA, IJBDirectory(DIRECTORY), IJBTokens(TOKENS), IJBPermissions(PERMISSIONS), 1, registryA, address(0)
        );
        JBCCIPSucker singletonB = new JBCCIPSucker(
            deployerB, IJBDirectory(DIRECTORY), IJBTokens(TOKENS), IJBPermissions(PERMISSIONS), 1, registryB, address(0)
        );

        deployerA.configureSingleton(singletonA);
        deployerB.configureSingleton(singletonB);

        JBCCIPSucker suckerA = JBCCIPSucker(payable(address(deployerA.createForSender(PROJECT_ID, bytes32("peer")))));
        JBCCIPSucker suckerB = JBCCIPSucker(payable(address(deployerB.createForSender(PROJECT_ID, bytes32("peer")))));

        assertTrue(address(suckerA) != address(suckerB), "topology drift produces different sucker addresses");
        assertEq(uint256(suckerA.peer()), uint256(uint160(address(suckerA))), "default peer tracks local address");

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32("peer"),
            sourceChainSelector: REMOTE_SELECTOR,
            sender: abi.encode(address(suckerB)),
            data: abi.encode(
                uint8(0),
                abi.encode(
                    JBMessageRoot({
                        token: bytes32(0),
                        amount: 0,
                        remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(0)}),
                        sourceTotalSupply: 0,
                        sourceSurplus: 0,
                        sourceBalance: 0,
                        sourceCurrency: 0,
                        sourceDecimals: 18,
                        snapshotNonce: 1,
                        version: 1
                    })
                )
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(ROUTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("JBSucker_NotPeer(bytes32)")), bytes32(uint256(uint160(address(suckerB))))
            )
        );
        suckerA.ccipReceive(message);
    }
}
