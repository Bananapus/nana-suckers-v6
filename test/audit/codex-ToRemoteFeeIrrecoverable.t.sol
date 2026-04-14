// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../../src/JBSucker.sol";
import "../../src/interfaces/IJBSuckerRegistry.sol";
import "../../src/structs/JBClaim.sol";
import "../../src/structs/JBInboxTreeRoot.sol";
import "../../src/structs/JBLeaf.sol";
import "../../src/structs/JBMessageRoot.sol";
import "../../src/structs/JBRemoteToken.sol";
import "../../src/utils/MerkleLib.sol";

contract CodexFeeIrrecoverableHarness is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    bool internal _skipNextProofCheck;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        IJBSuckerRegistry registry
    )
        JBSucker(directory, permissions, tokens, 1, registry, address(0))
    {}

    function peerChainId() external view override returns (uint256) {
        return block.chainid;
    }

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == _toAddress(peer());
    }

    function _sendRootOverAMB(
        uint256,
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBMessageRoot memory
    )
        internal
        override
    {}

    function _validateBranchRoot(
        bytes32 expectedRoot,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        bytes32 beneficiary,
        uint256 index,
        bytes32[_TREE_DEPTH] calldata leaves
    )
        internal
        override
    {
        if (_skipNextProofCheck) {
            _skipNextProofCheck = false;
            return;
        }

        super._validateBranchRoot(expectedRoot, projectTokenCount, terminalTokenAmount, beneficiary, index, leaves);
    }

    function test_setRemoteToken(address token, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[token] = remoteToken;
    }

    function test_insertIntoTree(
        uint256 projectTokenCount,
        address token,
        uint256 terminalTokenAmount,
        bytes32 beneficiary
    )
        external
    {
        _insertIntoTree(projectTokenCount, token, terminalTokenAmount, beneficiary);
    }

    function test_setInboxRoot(address token, uint64 nonce, bytes32 root) external {
        _inboxOf[token] = JBInboxTreeRoot({nonce: nonce, root: root});
    }

    function test_skipNextProofCheck() external {
        _skipNextProofCheck = true;
    }
}

contract CodexTerminalStub {
    uint256 public totalReceived;

    function addToBalanceOf(uint256, address, uint256 amount, bool, string calldata, bytes calldata) external payable {
        totalReceived += amount;
    }
}

contract CodexToRemoteFeeIrrecoverableTest is Test {
    address internal constant DIRECTORY = address(0x1000);
    address internal constant PERMISSIONS = address(0x2000);
    address internal constant TOKENS = address(0x3000);
    address internal constant REGISTRY = address(0x4000);
    address internal constant PROJECT = address(0x5000);
    address internal constant CONTROLLER = address(0x6000);
    address internal constant TERMINAL = address(0x7000);

    uint256 internal constant PROJECT_ID = 2;
    uint256 internal constant FEE = 1;

    CodexFeeIrrecoverableHarness internal sucker;
    CodexTerminalStub internal terminal;

    function setUp() public {
        terminal = new CodexTerminalStub();

        // Mock DIRECTORY.PROJECTS() so the JBSucker constructor can initialize the PROJECTS immutable.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));

        CodexFeeIrrecoverableHarness singleton = new CodexFeeIrrecoverableHarness({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            registry: IJBSuckerRegistry(REGISTRY)
        });

        sucker = CodexFeeIrrecoverableHarness(
            payable(address(LibClone.cloneDeterministic(address(singleton), bytes32("codex-fee-stuck"))))
        );
        sucker.initialize(PROJECT_ID);

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECT));
        vm.mockCall(PROJECT, abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(IJBTerminal(address(terminal)))
        );
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.mintTokensOf, (PROJECT_ID, 1, address(0xBEEF), "", false)),
            abi.encode(uint256(1))
        );
        vm.mockCall(
            CONTROLLER, abi.encodeCall(IERC165.supportsInterface, (type(IJBController).interfaceId)), abi.encode(true)
        );
        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(0))
        );
        vm.mockCall(REGISTRY, abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(FEE));

        // Mock DIRECTORY.terminalsOf() so _buildETHAggregate() in _sendRoot() doesn't revert.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(new IJBTerminal[](0)));
    }

    function test_feeEthRemainsStuckAfterLaterNativeClaim() external {
        sucker.test_setRemoteToken(
            JBConstants.NATIVE_TOKEN,
            JBRemoteToken({
                addr: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
                enabled: true,
                emergencyHatch: false,
                minGas: 200_000
            })
        );

        sucker.test_insertIntoTree({
            projectTokenCount: 0,
            token: JBConstants.NATIVE_TOKEN,
            terminalTokenAmount: 0,
            beneficiary: bytes32(uint256(uint160(address(0xABCD))))
        });

        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, JBConstants.NATIVE_TOKEN)),
            abi.encode(IJBTerminal(address(0)))
        );

        sucker.toRemote{value: FEE}(JBConstants.NATIVE_TOKEN);
        assertEq(address(sucker).balance, FEE, "fee should remain in the sucker after failed fee payment");

        vm.deal(address(sucker), FEE + 1);
        sucker.test_setInboxRoot(JBConstants.NATIVE_TOKEN, 1, bytes32(uint256(1)));
        sucker.test_skipNextProofCheck();

        sucker.claim(
            JBClaim({
                token: JBConstants.NATIVE_TOKEN,
                leaf: JBLeaf({
                    index: 0,
                    beneficiary: bytes32(uint256(uint160(address(0xBEEF)))),
                    projectTokenCount: 1,
                    terminalTokenAmount: 1
                }),
                proof: [
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0),
                    bytes32(0)
                ]
            })
        );

        assertEq(address(sucker).balance, FEE, "later native claims do not sweep the retained fee ETH");
        assertEq(address(terminal).balance, 1, "claim should forward only the leaf amount");
        assertEq(sucker.amountToAddToBalanceOf(JBConstants.NATIVE_TOKEN), FEE, "fee ETH stays addable but unreachable");
    }
}
