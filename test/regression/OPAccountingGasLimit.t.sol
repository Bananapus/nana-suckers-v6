// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {JBOptimismSucker} from "../../src/JBOptimismSucker.sol";
import {JBOptimismSuckerDeployer} from "../../src/deployers/JBOptimismSuckerDeployer.sol";
import {IJBOpSuckerDeployer} from "../../src/interfaces/IJBOpSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {IOPMessenger} from "../../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../../src/interfaces/IOPStandardBridge.sol";
import {JBAccountingSnapshot} from "../../src/structs/JBAccountingSnapshot.sol";
import {JBChainAccounting} from "../../src/structs/JBChainAccounting.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBSourceContext} from "../../src/structs/JBSourceContext.sol";

/// @notice Captures the destination `gasLimit` the OP sucker asks the messenger to deliver a message with.
contract RecordingOPMessenger is IOPMessenger {
    uint32 public lastGasLimit;
    address public lastTarget;
    uint256 public lastValue;

    function sendMessage(address target, bytes memory, uint32 gasLimit) external payable {
        lastTarget = target;
        lastGasLimit = gasLimit;
        lastValue = msg.value;
    }

    function bridgeERC20To(address, address, address, uint256, uint32, bytes calldata) external {}

    function xDomainMessageSender() external pure returns (address) {
        return address(0);
    }
}

contract OPGasLimitSuckerHarness is JBOptimismSucker {
    constructor(
        JBOptimismSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBOptimismSucker(deployer, directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function test_messagingGasLimit(uint256 sourceContextCount) external pure returns (uint256) {
        // Wrap the contexts in a single-record bundle; the gas budget sums contexts across every record.
        JBChainAccounting[] memory accounts = new JBChainAccounting[](1);
        accounts[0] = JBChainAccounting({
            chainId: 1, totalSupply: 0, contexts: new JBSourceContext[](sourceContextCount), timestamp: 0
        });
        return _messagingGasLimit({accounts: accounts});
    }

    function test_sendAccountingSnapshot(JBAccountingSnapshot memory snapshot) external {
        // OP rejects native transport payment for accounting-only messages.
        _sendAccountingSnapshotOverAMB({transportPayment: 0, snapshot: snapshot});
    }

    function test_sendRoot(JBMessageRoot memory message) external {
        JBRemoteToken memory remoteToken;
        // Native token + zero amount: no OP bridge transfer, only the messenger `sendMessage`.
        _sendRootOverAMB(0, 0, JBConstants.NATIVE_TOKEN, 0, remoteToken, message);
    }
}

/// @notice Regression coverage that the OP sucker scales its destination gas with the gossip bundle.
contract OPAccountingGasLimitTest is Test {
    address internal constant DEPLOYER = address(0x1001);
    address internal constant DIRECTORY = address(0x1002);
    address internal constant PERMISSIONS = address(0x1003);
    address internal constant PROJECTS = address(0x1004);
    address internal constant TOKENS = address(0x1005);

    uint256 internal constant REMOTE_CHAIN_ID = 10;

    OPGasLimitSuckerHarness internal sucker;
    RecordingOPMessenger internal messenger;

    function setUp() external {
        messenger = new RecordingOPMessenger();

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(DEPLOYER, abi.encodeCall(IJBOpSuckerDeployer.opMessenger, ()), abi.encode(messenger));
        vm.mockCall(
            DEPLOYER, abi.encodeCall(IJBOpSuckerDeployer.opBridge, ()), abi.encode(IOPStandardBridge(address(0xB81D)))
        );

        sucker = new OPGasLimitSuckerHarness(
            JBOptimismSuckerDeployer(DEPLOYER), IJBDirectory(DIRECTORY), IJBTokens(TOKENS), IJBPermissions(PERMISSIONS)
        );
    }

    function test_accountingSendScalesGasBySourceContexts() external {
        uint256 sourceContextCount = 5;
        sucker.test_sendAccountingSnapshot(_accountingSnapshot({sourceContextCount: sourceContextCount}));

        assertEq(
            uint256(messenger.lastGasLimit()),
            sucker.test_messagingGasLimit(sourceContextCount),
            "accounting gas limit scales with contexts"
        );
        assertGt(
            messenger.lastGasLimit(), sucker.MESSENGER_BASE_GAS_LIMIT(), "scaled above the base for a non-empty bundle"
        );
    }

    function test_rootSendScalesGasBySourceContexts() external {
        uint256 sourceContextCount = 3;
        sucker.test_sendRoot(_rootMessage({sourceContextCount: sourceContextCount}));

        assertEq(
            uint256(messenger.lastGasLimit()),
            sucker.test_messagingGasLimit(sourceContextCount),
            "root gas limit scales with contexts"
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
