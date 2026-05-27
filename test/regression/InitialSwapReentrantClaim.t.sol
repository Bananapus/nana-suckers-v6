// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSwapCCIPSucker} from "../../src/JBSwapCCIPSucker.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {JBSwapCCIPSuckerDeployer} from "../../src/deployers/JBSwapCCIPSuckerDeployer.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "../../src/structs/JBClaim.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBLeaf} from "../../src/structs/JBLeaf.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBConversionRate} from "../../src/structs/JBConversionRate.sol";

contract InitialSwapReentrantTerminal {
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

contract InitialSwapReentrantToken is ERC20 {
    JBSwapCCIPSucker internal sucker;
    JBClaim internal claimData;
    bool internal armed;

    constructor() ERC20("Local", "LOC") {}

    function configure(JBSwapCCIPSucker sucker_, JBClaim memory claimData_) external {
        sucker = sucker_;
        claimData = claimData_;
    }

    function setArmed(bool armed_) external {
        armed = armed_;
    }

    function mintFromPool(address to, uint256 amount) external {
        _mint(to, amount);
        if (armed) {
            armed = false;
            sucker.claim(claimData);
        }
    }
}

contract InitialSwapBridgeToken is ERC20 {
    constructor() ERC20("Bridge", "BRG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IUnlockCallbackLike {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

contract InitialSwapReentrantPoolManager is IPoolManager {
    uint160 internal constant SQRT_PRICE_X96 = 79_228_162_514_264_337_593_543_950_336;

    InitialSwapReentrantToken internal immutable LOCAL_TOKEN;

    constructor(InitialSwapReentrantToken localToken) {
        LOCAL_TOKEN = localToken;
    }

    function unlock(bytes calldata data) external override returns (bytes memory) {
        return IUnlockCallbackLike(msg.sender).unlockCallback(data);
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
        SwapParams memory params,
        bytes calldata
    )
        external
        pure
        override
        returns (BalanceDelta)
    {
        int128 input = int128(uint128(uint256(-params.amountSpecified)));
        int128 output = input;
        return params.zeroForOne ? toBalanceDelta(-input, output) : toBalanceDelta(output, -input);
    }

    function donate(PoolKey memory, uint256, uint256, bytes calldata) external pure override returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function sync(Currency) external pure override {}

    function take(Currency, address to, uint256 amount) external override {
        LOCAL_TOKEN.mintFromPool(to, amount);
    }

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

    function protocolFeesAccrued(Currency) external pure override returns (uint256) {
        return 0;
    }

    function setProtocolFee(PoolKey memory, uint24) external pure override {}

    function setProtocolFeeController(address) external pure override {}

    function collectProtocolFees(address, Currency, uint256) external pure override returns (uint256) {
        return 0;
    }

    function protocolFeeController() external pure override returns (address) {
        return address(0);
    }

    function balanceOf(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function allowance(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function isOperator(address, address) external pure override returns (bool) {
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

    function extsload(bytes32) external pure override returns (bytes32) {
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

    function exttload(bytes32) external pure override returns (bytes32) {
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
        return 1e24;
    }
}

contract InitialSwapReentrantHarness is JBSwapCCIPSucker {
    constructor(
        JBSwapCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions,
        IJBSuckerRegistry registry
    )
        JBSwapCCIPSucker(deployer, directory, permissions, IJBPrices(address(1)), tokens, 1, registry, address(0))
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
        _conversionRateOf[token][nonce] = JBConversionRate({leafTotal: leafTotal, localTotal: localTotal});
        _batchStartOf[token][nonce] = batchStart;
        _batchEndOf[token][nonce] = batchEnd;
        uint64 priorCount = _populatedNonceCount[token];
        _populatedNonceByIndex[token][priorCount] = nonce;
        _populatedNonceCount[token] = priorCount + 1;
    }

    function exposed_conversionRateOf(
        address token,
        uint64 nonce
    )
        external
        view
        returns (uint256 leafTotal, uint256 localTotal)
    {
        JBConversionRate storage rate = _conversionRateOf[token][nonce];
        return (rate.leafTotal, rate.localTotal);
    }

    function _validateBranchRoot(bytes32, bytes32, uint256, bytes32[32] calldata) internal pure override {}
}

contract InitialSwapReentrantClaimTest is Test {
    address internal constant PROJECTS = address(0x1001);
    address internal constant DIRECTORY = address(0x1002);
    address internal constant PERMISSIONS = address(0x1003);
    address internal constant TOKENS = address(0x1004);
    address internal constant ROUTER = address(0x1005);
    uint256 internal constant PROJECT_ID = 1;
    uint64 internal constant REMOTE_SELECTOR = 7_281_642_695_469_137_430;

    InitialSwapBridgeToken internal bridgeToken;
    InitialSwapReentrantToken internal localToken;
    InitialSwapReentrantTerminal internal terminal;
    InitialSwapReentrantHarness internal sucker;

    function setUp() public {
        bridgeToken = new InitialSwapBridgeToken();
        localToken = new InitialSwapReentrantToken();
        terminal = new InitialSwapReentrantTerminal();

        vm.etch(ROUTER, hex"01");
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(IJBProjects(PROJECTS)));
        vm.mockCall(PROJECTS, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(
            DIRECTORY,
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(IJBTerminal(address(terminal)))
        );
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(address(0xCAFE)));
        vm.mockCall(
            address(0xCAFE), abi.encodeWithSelector(IJBController.mintTokensOf.selector), abi.encode(uint256(0))
        );

        JBSuckerRegistry registry =
            new JBSuckerRegistry(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), address(this), address(0));
        JBSwapCCIPSuckerDeployer deployer = new JBSwapCCIPSuckerDeployer(
            IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS), address(this), address(0)
        );
        deployer.setChainSpecificConstants(4217, REMOTE_SELECTOR, ICCIPRouter(ROUTER));
        deployer.setSwapConstants(
            IERC20(address(bridgeToken)),
            IPoolManager(address(new InitialSwapReentrantPoolManager(localToken))),
            IUniswapV3Factory(address(0)),
            address(0),
            address(0xBEEF)
        );

        InitialSwapReentrantHarness singleton = new InitialSwapReentrantHarness(
            deployer, IJBDirectory(DIRECTORY), IJBTokens(TOKENS), IJBPermissions(PERMISSIONS), registry
        );
        deployer.configureSingleton(singleton);
        sucker =
        // forge-lint: disable-next-line(unsafe-typecast)
        InitialSwapReentrantHarness(
            payable(LibClone.cloneDeterministic(address(singleton), keccak256(bytes("initial-swap-reentry"))))
        );
        sucker.initialize(PROJECT_ID);
    }

    function test_reentrantClaimDuringInitialSwapIsDeferredToPendingSwap() external {
        sucker.test_setConversionRate(address(localToken), 1, 100, 100, 0, 1);

        JBClaim memory oldClaim = JBClaim({
            token: address(localToken),
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(this)))),
                projectTokenCount: 1,
                terminalTokenAmount: 100,
                metadata: bytes32(0)
            }),
            proof: _emptyProof()
        });
        localToken.configure(sucker, oldClaim);
        localToken.setArmed(true);

        JBMessageRoot memory root = JBMessageRoot({
            token: bytes32(uint256(uint160(address(localToken)))),
            amount: 100,
            remoteRoot: JBInboxTreeRoot({nonce: 2, root: bytes32(uint256(2))}),
            sourceTotalSupply: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            sourceCurrency: 0,
            sourceDecimals: 18,
            sourceTimestamp: 2,
            version: 1
        });

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(bridgeToken), amount: 100});
        bridgeToken.mint(address(sucker), 100);

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256(bytes("reentrant-initial-swap")),
            sourceChainSelector: REMOTE_SELECTOR,
            sender: abi.encode(address(sucker)),
            data: abi.encode(uint8(0), abi.encode(root, uint256(1), uint256(2))),
            destTokenAmounts: tokenAmounts
        });

        vm.prank(ROUTER);
        sucker.ccipReceive(message);

        assertEq(localToken.balanceOf(address(terminal)), 0, "old claim must not consume fresh swap output");
        assertEq(localToken.balanceOf(address(sucker)), 0, "failed swap leaves no local output");
        assertEq(bridgeToken.balanceOf(address(sucker)), 100, "bridge tokens remain available for retry");

        (uint256 leafTotal, uint256 localTotal) = sucker.exposed_conversionRateOf(address(localToken), 2);
        assertEq(leafTotal, 0, "new batch must not be marked claimable");
        assertEq(localTotal, 0, "new batch must not record consumed liquidity as backing");

        (address pendingBridgeToken, uint256 pendingBridgeAmount, uint256 pendingLeafTotal) =
            sucker.pendingSwapOf(address(localToken), 2);
        assertEq(pendingBridgeToken, address(bridgeToken), "pending swap stores bridge token");
        assertEq(pendingBridgeAmount, 100, "pending swap stores bridge amount");
        assertEq(pendingLeafTotal, 100, "pending swap stores leaf total");
    }

    function _emptyProof() internal pure returns (bytes32[32] memory proof) {}
}
