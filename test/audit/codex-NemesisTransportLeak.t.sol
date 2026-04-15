// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBOptimismSucker} from "../../src/JBOptimismSucker.sol";
import {JBCCIPSucker} from "../../src/JBCCIPSucker.sol";
import {JBSucker} from "../../src/JBSucker.sol";
import {JBOptimismSuckerDeployer} from "../../src/deployers/JBOptimismSuckerDeployer.sol";
import {JBCCIPSuckerDeployer} from "../../src/deployers/JBCCIPSuckerDeployer.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {IOPMessenger} from "../../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../../src/interfaces/IOPStandardBridge.sol";
import {JBPayRemoteMessage} from "../../src/structs/JBPayRemoteMessage.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract CodexOptimismPayRemoteHarness is JBOptimismSucker {
    constructor(
        JBOptimismSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        IJBSuckerRegistry registry
    )
        JBOptimismSucker(deployer, directory, permissions, tokens, 1, registry, address(0))
    {}

    function test_setRemoteToken(address token, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[token] = remoteToken;
    }
}

contract CodexCCIPPayFromRemoteHarness is JBCCIPSucker {
    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions,
        IJBSuckerRegistry registry
    )
        JBCCIPSucker(deployer, directory, tokens, permissions, 1, registry, address(0))
    {}

    function test_setRemoteToken(address token, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[token] = remoteToken;
    }

    function test_outboxCount(address token) external view returns (uint256) {
        return _outboxOf[token].tree.count;
    }

    function test_numberOfClaimsSent(address token) external view returns (uint256) {
        return _outboxOf[token].numberOfClaimsSent;
    }
}

contract CodexNemesisTransportLeakTest is Test {
    address internal constant DIRECTORY = address(0x1000);
    address internal constant PERMISSIONS = address(0x2000);
    address internal constant TOKENS = address(0x3000);
    address internal constant PROJECTS = address(0x4000);
    address internal constant REGISTRY = address(0x5000);

    address internal constant OP_MESSENGER = address(0x6000);
    address internal constant OP_BRIDGE = address(0x7000);

    address internal constant CCIP_ROUTER = address(0x8000);
    address internal constant TERMINAL = address(0x9000);

    uint256 internal constant PROJECT_ID = 1;

    function setUp() public {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));
        vm.mockCall(REGISTRY, abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));

        vm.etch(OP_MESSENGER, hex"01");
        vm.etch(OP_BRIDGE, hex"01");
        vm.etch(CCIP_ROUTER, hex"01");
        vm.etch(TERMINAL, hex"01");
    }

    function test_payRemote_freeBridgeRetainsEntireUnusedTransportBudget() external {
        ERC20Mock token = new ERC20Mock("MOCK", "MOCK", address(this), 10 ether);

        JBOptimismSuckerDeployer deployer = new JBOptimismSuckerDeployer({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            configurator: address(this),
            trustedForwarder: address(0)
        });
        deployer.setChainSpecificConstants({
            messenger: IOPMessenger(OP_MESSENGER),
            bridge: IOPStandardBridge(OP_BRIDGE)
        });

        CodexOptimismPayRemoteHarness singleton = new CodexOptimismPayRemoteHarness({
            deployer: deployer,
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            registry: IJBSuckerRegistry(REGISTRY)
        });

        CodexOptimismPayRemoteHarness sucker = CodexOptimismPayRemoteHarness(
            payable(LibClone.cloneDeterministic(address(singleton), bytes32("codex-op-payremote")))
        );
        sucker.initialize(PROJECT_ID);
        sucker.test_setRemoteToken(
            address(token),
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: sucker.MESSENGER_ERC20_MIN_GAS_LIMIT(),
                addr: bytes32(uint256(uint160(address(0xBEEF))))
            })
        );

        vm.mockCall(OP_MESSENGER, abi.encodeWithSelector(IOPMessenger.sendMessage.selector), abi.encode());
        vm.mockCall(OP_BRIDGE, abi.encodeWithSelector(IOPStandardBridge.bridgeERC20To.selector), abi.encode());

        uint256 amount = 1 ether;
        uint256 extraTransport = 0.4 ether;

        token.approve(address(sucker), amount);

        sucker.payRemote{value: extraTransport}({
            token: address(token),
            amount: amount,
            beneficiary: bytes32(uint256(uint160(address(0xBEEF)))),
            minTokensOut: 0,
            metadata: ""
        });

        assertEq(
            address(sucker).balance,
            extraTransport,
            "unused payRemote transport budget remains trapped in the sucker on free bridges"
        );
    }

    function test_payFromRemote_failedAutoReturnLeavesPrepaidTransportUnusable() external {
        JBCCIPSuckerDeployer deployer = new JBCCIPSuckerDeployer({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            configurator: address(this),
            trustedForwarder: address(0)
        });
        deployer.setChainSpecificConstants({
            remoteChainId: 42161,
            remoteChainSelector: 4949039107694359620,
            router: ICCIPRouter(CCIP_ROUTER)
        });

        CodexCCIPPayFromRemoteHarness singleton = new CodexCCIPPayFromRemoteHarness({
            deployer: deployer,
            directory: IJBDirectory(DIRECTORY),
            tokens: IJBTokens(TOKENS),
            permissions: IJBPermissions(PERMISSIONS),
            registry: IJBSuckerRegistry(REGISTRY)
        });

        CodexCCIPPayFromRemoteHarness sucker = CodexCCIPPayFromRemoteHarness(
            payable(LibClone.cloneDeterministic(address(singleton), bytes32("codex-ccip-payfromremote")))
        );
        sucker.initialize(PROJECT_ID);
        sucker.test_setRemoteToken(
            JBConstants.NATIVE_TOKEN,
            JBRemoteToken({
                enabled: true,
                emergencyHatch: false,
                minGas: sucker.MESSENGER_ERC20_MIN_GAS_LIMIT(),
                addr: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
            })
        );

        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(IJBTerminal(TERMINAL))
        );
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(10)));
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBCashOutTerminal.cashOutTokensOf.selector), abi.encode(uint256(0)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(address(0)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(new IJBTerminal[](0)));

        // Force the auto-return sendRoot to fail by making the mocked CCIP fee exceed the prepaid budget.
        vm.mockCall(CCIP_ROUTER, abi.encodeWithSignature("getFee(uint64,(bytes,bytes,(address,uint256)[],bytes,address))"), abi.encode(uint256(2 ether)));
        vm.mockCall(
            CCIP_ROUTER,
            abi.encodeWithSignature("ccipSend(uint64,(bytes,bytes,(address,uint256)[],bytes,address))"),
            abi.encode(bytes32(0))
        );

        uint256 prepaidReturnTransport = 1 ether;
        vm.deal(address(sucker), prepaidReturnTransport);

        JBPayRemoteMessage memory message = JBPayRemoteMessage({
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: 0,
            returnTransport: prepaidReturnTransport,
            beneficiary: bytes32(uint256(uint160(address(0xCAFE)))),
            minTokensOut: 0,
            metadata: ""
        });

        vm.prank(address(sucker));
        sucker.payFromRemote(message);

        assertEq(address(sucker).balance, prepaidReturnTransport, "failed auto-return leaves prepaid ETH in contract");
        assertEq(sucker.test_outboxCount(JBConstants.NATIVE_TOKEN), 1, "return leaf stays queued for manual send");
        assertEq(sucker.test_numberOfClaimsSent(JBConstants.NATIVE_TOKEN), 0, "failed auto-return never marks leaf sent");

        vm.expectRevert(JBSucker.JBSucker_ExpectedMsgValue.selector);
        sucker.toRemote{value: 0}(JBConstants.NATIVE_TOKEN);
    }
}
