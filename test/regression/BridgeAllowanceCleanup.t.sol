// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {JBArbitrumSucker} from "../../src/JBArbitrumSucker.sol";
import {JBArbitrumSuckerDeployer} from "../../src/deployers/JBArbitrumSuckerDeployer.sol";
import {JBLayer} from "../../src/enums/JBLayer.sol";
import {IArbGatewayRouter} from "../../src/interfaces/IArbGatewayRouter.sol";
import {IArbL2GatewayRouter} from "../../src/interfaces/IArbL2GatewayRouter.sol";
import {ICCIPRouter, IWrappedNativeToken} from "../../src/interfaces/ICCIPRouter.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBCCIPLib} from "../../src/libraries/JBCCIPLib.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";

contract BridgeAllowanceToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PartialPullCCIPRouter is ICCIPRouter {
    BridgeAllowanceToken public immutable bridgeToken;
    uint256 public immutable fee;

    constructor(BridgeAllowanceToken _bridgeToken, uint256 _fee) {
        bridgeToken = _bridgeToken;
        fee = _fee;
    }

    function isChainSupported(uint64) external pure override returns (bool) {
        return true;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view override returns (uint256) {
        return fee;
    }

    function getWrappedNative() external pure override returns (IWrappedNativeToken) {
        return IWrappedNativeToken(address(0));
    }

    function ccipSend(uint64, Client.EVM2AnyMessage calldata message) external payable override returns (bytes32) {
        if (message.feeToken != address(0)) {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(message.feeToken).transferFrom(msg.sender, address(this), fee / 2);
        }

        for (uint256 i; i < message.tokenAmounts.length; i++) {
            IERC20(message.tokenAmounts[i].token)
                .transferFrom({from: msg.sender, to: address(this), value: message.tokenAmounts[i].amount / 2});
        }

        return keccak256("partial-pull");
    }
}

contract CCIPAllowanceHarness {
    receive() external payable {}

    function sendWithNativeFee(ICCIPRouter router, address token, uint256 amount, uint256 transportPayment) external {
        (Client.EVMTokenAmount[] memory tokenAmounts,) =
            JBCCIPLib.prepareTokenAmounts({ccipRouter: router, token: token, amount: amount});

        JBCCIPLib.sendCCIPMessage({
            ccipRouter: router,
            remoteChainSelector: 1,
            peerAddress: address(0xBEEF),
            transportPayment: transportPayment,
            feeToken: address(0),
            feeTokenPayer: address(0),
            gasLimit: 300_000,
            encodedPayload: "",
            tokenAmounts: tokenAmounts,
            refundRecipient: address(this)
        });
    }

    function sendWithFeeToken(ICCIPRouter router, address feeToken, address feeTokenPayer) external {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0);

        JBCCIPLib.sendCCIPMessage({
            ccipRouter: router,
            remoteChainSelector: 1,
            peerAddress: address(0xBEEF),
            transportPayment: 0,
            feeToken: feeToken,
            feeTokenPayer: feeTokenPayer,
            gasLimit: 300_000,
            encodedPayload: "",
            tokenAmounts: tokenAmounts,
            refundRecipient: address(this)
        });
    }
}

contract PartialPullArbitrumGateway {
    function pull(address token, address from, uint256 amount) external {
        IERC20(token).transferFrom({from: from, to: address(this), value: amount / 2});
    }
}

contract PartialPullArbitrumGatewayRouter is IArbGatewayRouter, IArbL2GatewayRouter {
    address public immutable localGateway;
    address public immutable localToken;
    address public immutable remoteGateway;
    address public immutable remoteToken;

    constructor(address _localGateway, address _localToken, address _remoteGateway, address _remoteToken) {
        localGateway = _localGateway;
        localToken = _localToken;
        remoteGateway = _remoteGateway;
        remoteToken = _remoteToken;
    }

    function defaultGateway() external view override returns (address) {
        return remoteGateway;
    }

    function getGateway(address token) external view override returns (address) {
        return token == remoteToken ? remoteGateway : localGateway;
    }

    function outboundTransfer(
        address l1Token,
        address,
        uint256 amount,
        bytes calldata
    )
        external
        payable
        override
        returns (bytes memory)
    {
        require(l1Token == remoteToken, "wrong L1 token");
        PartialPullArbitrumGateway(remoteGateway).pull({token: localToken, from: msg.sender, amount: amount});
        return "";
    }
}

contract ArbitrumL2AllowanceHarness is JBArbitrumSucker {
    constructor(
        JBArbitrumSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        IJBSuckerRegistry registry
    )
        JBArbitrumSucker(deployer, directory, permissions, tokens, 1, registry, address(0))
    {}

    function sendTokenToL1(address token, address remoteToken, uint256 amount) external {
        _toL1({
            token: token,
            amount: amount,
            data: "",
            remoteToken: JBRemoteToken({
                addr: bytes32(uint256(uint160(remoteToken))), enabled: true, emergencyHatch: false, minGas: 200_000
            })
        });
    }
}

contract BridgeAllowanceCleanupTest is Test {
    address internal constant DIRECTORY = address(0x1000);
    address internal constant PERMISSIONS = address(0x2000);
    address internal constant TOKENS = address(0x3000);
    address internal constant REGISTRY = address(0x4000);

    function test_ccipNativeFee_clearsBridgeTokenAllowanceAfterPartialPull() external {
        BridgeAllowanceToken token = new BridgeAllowanceToken("Bridge", "BRG");
        PartialPullCCIPRouter router = new PartialPullCCIPRouter(token, 1 ether);
        CCIPAllowanceHarness harness = new CCIPAllowanceHarness();

        token.mint(address(harness), 100 ether);
        vm.deal(address(harness), 1 ether);

        harness.sendWithNativeFee({router: router, token: address(token), amount: 100 ether, transportPayment: 1 ether});

        assertEq(token.balanceOf(address(router)), 50 ether, "router should have partially pulled bridge tokens");
        assertEq(token.allowance(address(harness), address(router)), 0, "bridge token allowance must be revoked");
    }

    function test_ccipFeeToken_clearsFeeAllowanceAfterPartialPull() external {
        BridgeAllowanceToken link = new BridgeAllowanceToken("Link", "LINK");
        PartialPullCCIPRouter router = new PartialPullCCIPRouter(link, 10 ether);
        CCIPAllowanceHarness harness = new CCIPAllowanceHarness();
        address feePayer = makeAddr("feePayer");

        link.mint(feePayer, 10 ether);
        vm.prank(feePayer);
        link.approve(address(harness), 10 ether);

        harness.sendWithFeeToken({router: router, feeToken: address(link), feeTokenPayer: feePayer});

        assertEq(link.balanceOf(address(router)), 5 ether, "router should have partially pulled LINK fee");
        assertEq(link.allowance(address(harness), address(router)), 0, "fee token allowance must be revoked");
    }

    function test_arbitrumL2_approvesRemoteGatewayAndClearsGatewayAllowanceAfterPartialPull() external {
        BridgeAllowanceToken token = new BridgeAllowanceToken("Bridge", "BRG");
        address remoteToken = makeAddr("remoteToken");
        PartialPullArbitrumGateway localGateway = new PartialPullArbitrumGateway();
        PartialPullArbitrumGateway remoteGateway = new PartialPullArbitrumGateway();
        PartialPullArbitrumGatewayRouter router = new PartialPullArbitrumGatewayRouter({
            _localGateway: address(localGateway),
            _localToken: address(token),
            _remoteGateway: address(remoteGateway),
            _remoteToken: remoteToken
        });

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(address(0)));

        JBArbitrumSuckerDeployer deployer = new JBArbitrumSuckerDeployer({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            configurator: address(this),
            trustedForwarder: address(0)
        });
        deployer.setChainSpecificConstants({
            layer: JBLayer.L2, inbox: IInbox(address(0)), gatewayRouter: IArbGatewayRouter(address(router))
        });

        ArbitrumL2AllowanceHarness harness = new ArbitrumL2AllowanceHarness({
            deployer: deployer,
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            registry: IJBSuckerRegistry(REGISTRY)
        });

        token.mint({to: address(harness), amount: 100 ether});

        vm.etch(address(100), hex"00");
        vm.mockCall(address(100), abi.encodeWithSignature("sendTxToL1(address,bytes)"), abi.encode(uint256(0)));

        harness.sendTokenToL1({token: address(token), remoteToken: remoteToken, amount: 100 ether});

        assertEq(token.balanceOf(address(remoteGateway)), 50 ether, "remote gateway should pull bridge tokens");
        assertEq(token.balanceOf(address(localGateway)), 0, "local gateway should not be used for L1-token route");
        assertEq(
            token.allowance(address(harness), address(remoteGateway)), 0, "remote gateway allowance must be revoked"
        );
    }
}
