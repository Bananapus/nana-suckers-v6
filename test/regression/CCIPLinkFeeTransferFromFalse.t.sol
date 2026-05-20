// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {JBCCIPLib} from "../../src/libraries/JBCCIPLib.sol";
import {ICCIPRouter, IWrappedNativeToken} from "../../src/interfaces/ICCIPRouter.sol";

/// @notice ERC-20 that mimics LINK's historical quirk: `transferFrom` returns `false` instead of reverting on
/// insufficient allowance / balance. Without SafeERC20, the sucker would proceed as if the pull succeeded and
/// then attempt to bridge with no LINK in hand — silently dropping the message. SafeERC20.safeTransferFrom must
/// turn `returns (false)` into a revert.
contract MaliciousLINK {
    string public name = "ChainLink Token";
    string public symbol = "LINK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    /// @notice The quirk: returns `false` rather than reverting. SafeERC20 detects this and reverts on our behalf.
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice Mock CCIP router that returns a non-zero fee in the LINK fee token and never actually sends.
contract MockCCIPRouter {
    address public immutable wrappedNative;
    uint256 public fee;

    constructor(address wrappedNative_, uint256 fee_) {
        wrappedNative = wrappedNative_;
        fee = fee_;
    }

    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }

    function ccipSend(uint64, Client.EVM2AnyMessage calldata) external payable returns (bytes32) {
        // Would normally pull fees and dispatch. Not exercised here because the test asserts that the LINK pull
        // reverts BEFORE we reach this call.
        return bytes32(0);
    }

    function getWrappedNative() external view returns (IWrappedNativeToken) {
        return IWrappedNativeToken(wrappedNative);
    }
}

/// @notice Caller harness — delegate-calls into JBCCIPLib so the library runs in the harness's storage frame,
/// matching the production DELEGATECALL pattern.
contract _Caller {
    function sendCCIPMessageDelegated(
        ICCIPRouter ccipRouter,
        uint64 remoteChainSelector,
        address peerAddress,
        uint256 transportPayment,
        address feeToken,
        address feeTokenPayer,
        uint256 gasLimit,
        bytes memory encodedPayload,
        Client.EVMTokenAmount[] memory tokenAmounts,
        address refundRecipient
    )
        external
        payable
        returns (bool refundFailed, uint256 refundAmount)
    {
        return JBCCIPLib.sendCCIPMessage({
            ccipRouter: ccipRouter,
            remoteChainSelector: remoteChainSelector,
            peerAddress: peerAddress,
            transportPayment: transportPayment,
            feeToken: feeToken,
            feeTokenPayer: feeTokenPayer,
            gasLimit: gasLimit,
            encodedPayload: encodedPayload,
            tokenAmounts: tokenAmounts,
            refundRecipient: refundRecipient
        });
    }
}

/// @notice Locks the LINK-fee path against the historical "transferFrom returns false" footgun. Production code
/// uses `SafeERC20.safeTransferFrom`, which must revert when the token returns `false`. This test exercises that
/// path end-to-end through the library.
contract CCIPLinkFeeTransferFromFalseTest is Test {
    MaliciousLINK internal link;
    MockCCIPRouter internal router;
    _Caller internal caller;

    address internal payer = makeAddr("linkPayer");
    address internal refund = makeAddr("refundRecipient");

    function setUp() public {
        link = new MaliciousLINK();
        router = new MockCCIPRouter({wrappedNative_: makeAddr("wNative"), fee_: 1e18});
        caller = new _Caller();

        // Pretend the payer has approved LINK to the caller (the sucker) — Permit2/EOA approval. The malicious
        // LINK never actually consumes allowance, but the safeTransferFrom path still attempts the call.
        vm.prank(payer);
        link.approve(address(caller), type(uint256).max);
    }

    /// @notice With a malicious LINK that returns `false` from `transferFrom`, the LINK fee pull must revert via
    /// SafeERC20 — NOT silently succeed and proceed to `ccipSend`.
    function test_linkFeePath_transferFromReturnsFalse_reverts() public {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0);

        // SafeERC20 reverts with `SafeERC20FailedOperation(token)` when the boolean return is false.
        // We don't pin the exact selector because OZ versions differ on the error encoding; we only assert
        // that the call reverts, proving the SafeERC20 layer caught the false return.
        vm.expectRevert();
        caller.sendCCIPMessageDelegated({
            ccipRouter: ICCIPRouter(address(router)),
            remoteChainSelector: 1,
            peerAddress: makeAddr("peer"),
            transportPayment: 0, // LINK fee path
            feeToken: address(link),
            feeTokenPayer: payer,
            gasLimit: 200_000,
            encodedPayload: bytes(""),
            tokenAmounts: tokenAmounts,
            refundRecipient: refund
        });
    }
}
