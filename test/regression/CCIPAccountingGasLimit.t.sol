// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {JBCCIPSucker} from "../../src/JBCCIPSucker.sol";
import {JBCCIPSuckerDeployer} from "../../src/deployers/JBCCIPSuckerDeployer.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {IJBCCIPSuckerDeployer} from "../../src/interfaces/IJBCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {IWrappedNativeToken} from "../../src/interfaces/IWrappedNativeToken.sol";
import {JBAccountingSnapshot} from "../../src/structs/JBAccountingSnapshot.sol";
import {JBChainAccounting} from "../../src/structs/JBChainAccounting.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBSourceContext} from "../../src/structs/JBSourceContext.sol";

contract RecordingCCIPRouter is ICCIPRouter {
    uint256 public fee = 1 ether;
    uint64 public lastDestinationChainSelector;
    address public lastFeeToken;
    uint256 public lastGasLimit;
    uint256 public lastMsgValue;
    uint256 public lastTokenAmountCount;

    function ccipSend(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage calldata message
    )
        external
        payable
        returns (bytes32 messageId)
    {
        lastDestinationChainSelector = destinationChainSelector;
        lastFeeToken = message.feeToken;
        lastGasLimit = _gasLimitFrom({extraArgs: message.extraArgs});
        lastMsgValue = msg.value;
        lastTokenAmountCount = message.tokenAmounts.length;

        return keccak256("messageId");
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }

    function getWrappedNative() external pure returns (IWrappedNativeToken) {
        return IWrappedNativeToken(address(0xCAFE));
    }

    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }

    function _gasLimitFrom(bytes calldata extraArgs) private pure returns (uint256 gasLimit) {
        assert(bytes4(extraArgs) == Client.EVM_EXTRA_ARGS_V1_TAG);
        return abi.decode(extraArgs[4:], (uint256));
    }
}

contract CCIPGasLimitSuckerHarness is JBCCIPSucker {
    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBCCIPSucker(deployer, directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function test_messagingGasLimit(uint256 sourceContextCount) external pure returns (uint256) {
        // Wrap the contexts in a single-record bundle; the gas budget sums contexts across every record.
        JBChainAccounting[] memory accounts = new JBChainAccounting[](1);
        accounts[0] = JBChainAccounting({
            chainId: 1, totalSupply: 0, contexts: new JBSourceContext[](sourceContextCount), timestamp: 0
        });
        return _messagingGasLimit({accounts: accounts});
    }

    function test_sendAccountingSnapshot(
        uint256 transportPayment,
        JBAccountingSnapshot memory snapshot
    )
        external
        payable
    {
        _sendAccountingSnapshotOverAMB({transportPayment: transportPayment, snapshot: snapshot});
    }

    function test_sendRoot(
        uint256 transportPayment,
        address token,
        uint256 amount,
        JBRemoteToken memory remoteToken,
        JBMessageRoot memory message
    )
        external
        payable
    {
        _sendRootOverAMB(transportPayment, 0, token, amount, remoteToken, message);
    }
}

/// @notice Regression coverage for CCIP destination gas sizing.
contract CCIPAccountingGasLimitTest is Test {
    address internal constant DEPLOYER = address(0x1001);
    address internal constant DIRECTORY = address(0x1002);
    address internal constant PERMISSIONS = address(0x1003);
    address internal constant PROJECTS = address(0x1004);
    address internal constant TOKENS = address(0x1005);

    uint256 internal constant REMOTE_CHAIN_ID = 42_161;
    uint64 internal constant REMOTE_CHAIN_SELECTOR = 4_949_039_107_694_359_620;
    uint256 internal constant TRANSPORT_PAYMENT = 1 ether;

    CCIPGasLimitSuckerHarness internal sucker;
    RecordingCCIPRouter internal router;

    function setUp() external {
        router = new RecordingCCIPRouter();

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(DEPLOYER, abi.encodeCall(IJBCCIPSuckerDeployer.ccipRemoteChainId, ()), abi.encode(REMOTE_CHAIN_ID));
        vm.mockCall(
            DEPLOYER,
            abi.encodeCall(IJBCCIPSuckerDeployer.ccipRemoteChainSelector, ()),
            abi.encode(REMOTE_CHAIN_SELECTOR)
        );
        vm.mockCall(DEPLOYER, abi.encodeCall(IJBCCIPSuckerDeployer.ccipRouter, ()), abi.encode(router));

        sucker = new CCIPGasLimitSuckerHarness(
            JBCCIPSuckerDeployer(DEPLOYER), IJBDirectory(DIRECTORY), IJBTokens(TOKENS), IJBPermissions(PERMISSIONS)
        );
    }

    function test_accountingSendScalesCcipGasBySourceContexts() external {
        uint256 sourceContextCount = 5;
        JBAccountingSnapshot memory snapshot = _accountingSnapshot({sourceContextCount: sourceContextCount});

        sucker.test_sendAccountingSnapshot{value: TRANSPORT_PAYMENT}({
            transportPayment: TRANSPORT_PAYMENT, snapshot: snapshot
        });

        assertEq(router.lastDestinationChainSelector(), REMOTE_CHAIN_SELECTOR, "destination selector");
        assertEq(router.lastGasLimit(), sucker.test_messagingGasLimit(sourceContextCount), "accounting gas limit");
        assertEq(router.lastMsgValue(), TRANSPORT_PAYMENT, "native fee paid");
        assertEq(router.lastTokenAmountCount(), 0, "no token transfer");
    }

    function test_rootSendIncludesSourceContextGasAndTokenGas() external {
        uint256 sourceContextCount = 3;
        uint256 remoteTokenGas = 250_000;
        address token = makeAddr("token");
        uint256 amount = 1 ether;

        vm.mockCall(token, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        JBRemoteToken memory remoteToken = JBRemoteToken({
            enabled: true,
            emergencyHatch: false,
            minGas: uint32(remoteTokenGas),
            addr: bytes32(uint256(uint160(makeAddr("remoteToken"))))
        });

        sucker.test_sendRoot{value: TRANSPORT_PAYMENT}({
            transportPayment: TRANSPORT_PAYMENT,
            token: token,
            amount: amount,
            remoteToken: remoteToken,
            message: _rootMessage({token: token, amount: amount, sourceContextCount: sourceContextCount})
        });

        assertEq(
            router.lastGasLimit(), sucker.test_messagingGasLimit(sourceContextCount) + remoteTokenGas, "root gas limit"
        );
        assertEq(router.lastMsgValue(), TRANSPORT_PAYMENT, "native fee paid");
        assertEq(router.lastTokenAmountCount(), 1, "token transfer");
    }

    function _accountingSnapshot(uint256 sourceContextCount)
        internal
        pure
        returns (JBAccountingSnapshot memory snapshot)
    {
        JBChainAccounting[] memory accounts = new JBChainAccounting[](1);
        accounts[0] = JBChainAccounting({
            chainId: REMOTE_CHAIN_ID,
            totalSupply: 100 ether,
            contexts: _sourceContexts({sourceContextCount: sourceContextCount}),
            timestamp: 1
        });

        return JBAccountingSnapshot({version: 1, accounts: accounts});
    }

    function _rootMessage(
        address token,
        uint256 amount,
        uint256 sourceContextCount
    )
        internal
        pure
        returns (JBMessageRoot memory message)
    {
        JBChainAccounting[] memory accounts = new JBChainAccounting[](1);
        accounts[0] = JBChainAccounting({
            chainId: REMOTE_CHAIN_ID,
            totalSupply: 100 ether,
            contexts: _sourceContexts({sourceContextCount: sourceContextCount}),
            timestamp: 1
        });

        return JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(token))),
            amount: amount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(1))}),
            accounts: accounts
        });
    }

    function _sourceContexts(uint256 sourceContextCount)
        internal
        pure
        returns (JBSourceContext[] memory sourceContexts)
    {
        sourceContexts = new JBSourceContext[](sourceContextCount);

        for (uint256 i; i < sourceContextCount;) {
            sourceContexts[i] = JBSourceContext({
                token: bytes32(uint256(uint160(0xBEEF + i))),
                decimals: 18,
                surplus: uint128(1 ether + i),
                balance: uint128(2 ether + i)
            });

            unchecked {
                ++i;
            }
        }
    }
}
