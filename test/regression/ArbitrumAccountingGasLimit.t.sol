// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";

import {JBArbitrumSucker} from "../../src/JBArbitrumSucker.sol";
import {JBArbitrumSuckerDeployer} from "../../src/deployers/JBArbitrumSuckerDeployer.sol";
import {JBLayer} from "../../src/enums/JBLayer.sol";
import {IArbGatewayRouter} from "../../src/interfaces/IArbGatewayRouter.sol";
import {IJBArbitrumSuckerDeployer} from "../../src/interfaces/IJBArbitrumSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBAccountingSnapshot} from "../../src/structs/JBAccountingSnapshot.sol";
import {JBChainAccounting} from "../../src/structs/JBChainAccounting.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBSourceContext} from "../../src/structs/JBSourceContext.sol";

/// @notice Captures the L2 `gasLimit` the Arbitrum sucker provisions on its L1->L2 retryable ticket. Only implements
/// the inbox methods the send path touches; the address is cast to `IInbox` and dispatches by selector.
contract RecordingArbInbox {
    uint256 public lastGasLimit;
    uint256 public lastMaxSubmissionCost;
    uint256 public lastValue;
    uint256 public submissionFee;

    function calculateRetryableSubmissionFee(uint256, uint256) external view returns (uint256) {
        return submissionFee;
    }

    function unsafeCreateRetryableTicket(
        address,
        uint256,
        uint256 maxSubmissionCost,
        address,
        address,
        uint256 gasLimit,
        uint256,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        lastMaxSubmissionCost = maxSubmissionCost;
        lastGasLimit = gasLimit;
        lastValue = msg.value;
        return 1;
    }
}

contract ArbGasLimitSuckerHarness is JBArbitrumSucker {
    constructor(
        JBArbitrumSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBArbitrumSucker(deployer, directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
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

    function test_sendRoot(uint256 transportPayment, JBMessageRoot memory message) external payable {
        JBRemoteToken memory remoteToken;
        // Native token + zero amount: no gateway transfer, only the retryable ticket carrying the message.
        _sendRootOverAMB(transportPayment, 0, JBConstants.NATIVE_TOKEN, 0, remoteToken, message);
    }
}

/// @notice Regression coverage that the Arbitrum L1->L2 sucker scales its retryable-ticket gas with the gossip bundle.
contract ArbitrumAccountingGasLimitTest is Test {
    address internal constant DEPLOYER = address(0x1001);
    address internal constant DIRECTORY = address(0x1002);
    address internal constant PERMISSIONS = address(0x1003);
    address internal constant PROJECTS = address(0x1004);
    address internal constant TOKENS = address(0x1005);

    uint256 internal constant REMOTE_CHAIN_ID = 42_161;
    uint256 internal constant TRANSPORT_PAYMENT = 1 ether;

    ArbGasLimitSuckerHarness internal sucker;
    RecordingArbInbox internal inbox;

    function setUp() external {
        inbox = new RecordingArbInbox();

        // Zero the base fee so the required transport payment reduces to the (zero) submission fee, isolating the
        // gas-limit assertion from L1 fee dynamics.
        vm.fee(0);

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(
            DEPLOYER, abi.encodeCall(IJBArbitrumSuckerDeployer.arbInbox, ()), abi.encode(IInbox(address(inbox)))
        );
        vm.mockCall(
            DEPLOYER,
            abi.encodeCall(IJBArbitrumSuckerDeployer.arbGatewayRouter, ()),
            abi.encode(IArbGatewayRouter(address(0x6A7E)))
        );
        vm.mockCall(DEPLOYER, abi.encodeCall(IJBArbitrumSuckerDeployer.arbLayer, ()), abi.encode(JBLayer.L1));

        sucker = new ArbGasLimitSuckerHarness(
            JBArbitrumSuckerDeployer(DEPLOYER), IJBDirectory(DIRECTORY), IJBTokens(TOKENS), IJBPermissions(PERMISSIONS)
        );
    }

    function test_accountingSendScalesGasBySourceContexts() external {
        uint256 sourceContextCount = 5;
        sucker.test_sendAccountingSnapshot{value: TRANSPORT_PAYMENT}({
            transportPayment: TRANSPORT_PAYMENT, snapshot: _accountingSnapshot({sourceContextCount: sourceContextCount})
        });

        assertEq(
            inbox.lastGasLimit(),
            sucker.test_messagingGasLimit(sourceContextCount),
            "accounting retryable gas scales with contexts"
        );
        assertGt(
            inbox.lastGasLimit(), sucker.MESSENGER_BASE_GAS_LIMIT(), "scaled above the base for a non-empty bundle"
        );
    }

    function test_rootSendScalesGasBySourceContexts() external {
        uint256 sourceContextCount = 3;
        sucker.test_sendRoot{value: TRANSPORT_PAYMENT}({
            transportPayment: TRANSPORT_PAYMENT, message: _rootMessage({sourceContextCount: sourceContextCount})
        });

        assertEq(
            inbox.lastGasLimit(),
            sucker.test_messagingGasLimit(sourceContextCount),
            "root retryable gas scales with contexts"
        );
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

    function _rootMessage(uint256 sourceContextCount) internal pure returns (JBMessageRoot memory message) {
        JBChainAccounting[] memory accounts = new JBChainAccounting[](1);
        accounts[0] = JBChainAccounting({
            chainId: REMOTE_CHAIN_ID,
            totalSupply: 100 ether,
            contexts: _sourceContexts({sourceContextCount: sourceContextCount}),
            timestamp: 1
        });

        return JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: 0,
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
