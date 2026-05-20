// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICCIPRouter, IWrappedNativeToken} from "../../src/interfaces/ICCIPRouter.sol";
import {JBCCIPLib} from "../../src/libraries/JBCCIPLib.sol";

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

contract BridgeAllowanceCleanupTest is Test {
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
}
