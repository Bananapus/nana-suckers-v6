// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBCCIPSucker} from "../../src/JBCCIPSucker.sol";
import {JBCCIPSuckerDeployer} from "../../src/deployers/JBCCIPSuckerDeployer.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBSucker} from "../../src/JBSucker.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @notice Regression test: a trusted forwarder must NOT be able to spoof `ccipReceive()`.
/// @dev Before the fix, `ccipReceive()` used `_msgSender()`, which let a trusted forwarder
/// append the CCIP router address via the ERC-2771 calldata suffix.
/// After the fix, `ccipReceive()` uses `msg.sender` directly, so the forwarder's own address
/// is checked against `CCIP_ROUTER` and the call reverts with `JBSucker_NotPeer`.
contract TrustedForwarderSpoofCCIPTest is Test {
    address internal constant DIRECTORY = address(0x1000);
    address internal constant PERMISSIONS = address(0x2000);
    address internal constant TOKENS = address(0x3000);
    address internal constant REGISTRY = address(0x4000);
    address internal constant CONTROLLER = address(0x5000);
    address internal constant FORWARDER = address(0x6000);
    address internal constant TOKEN = address(0x7000);
    address internal constant CCIP_ROUTER = address(0x8000);

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant REMOTE_CHAIN_ID = 42_161;
    uint64 internal constant REMOTE_CHAIN_SELECTOR = 4_949_039_107_694_359_620;
    uint256 internal constant FORGED_TOKEN_COUNT = 123 ether;

    JBCCIPSucker internal sucker;

    function setUp() external {
        // Mock DIRECTORY.PROJECTS() so the JBSucker constructor can initialize the PROJECTS immutable.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(address(0)));

        JBCCIPSuckerDeployer deployer = new JBCCIPSuckerDeployer({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            configurator: address(this),
            trustedForwarder: FORWARDER
        });

        deployer.setChainSpecificConstants({
            remoteChainId: REMOTE_CHAIN_ID, remoteChainSelector: REMOTE_CHAIN_SELECTOR, router: ICCIPRouter(CCIP_ROUTER)
        });

        JBCCIPSucker singleton = new JBCCIPSucker({
            deployer: deployer,
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            feeProjectId: 1,
            registry: IJBSuckerRegistry(REGISTRY),
            trustedForwarder: FORWARDER
        });

        sucker = JBCCIPSucker(payable(LibClone.cloneDeterministic(address(singleton), bytes32("codex-ccip-spoof"))));
        sucker.initialize(PROJECT_ID);

        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(CONTROLLER));
    }

    /// @notice Verify that a trusted forwarder cannot forge a `ccipReceive()` call via ERC-2771.
    /// @dev The forwarder appends the CCIP router address to the calldata, but `ccipReceive()`
    /// now checks `msg.sender` (the forwarder itself), which is not the CCIP router.
    function test_trustedForwarderCannotForgeCcipReceiveAfterFix() external {
        bytes32 beneficiary = bytes32(uint256(uint160(address(this))));
        bytes32[32] memory proof;

        bytes32 forgedRoot =
            MerkleLib.branchRoot(keccak256(abi.encode(FORGED_TOKEN_COUNT, uint256(0), beneficiary)), proof, 0);

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(TOKEN))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: forgedRoot}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        // Build a crafted CCIP message with attacker-controlled sender and chain selector.
        Client.EVMTokenAmount[] memory destTokenAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory ccipMsg = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)), // spoof the peer address
            data: abi.encode(uint8(0), abi.encode(root)),
            destTokenAmounts: destTokenAmounts
        });

        // Build the spoofed ERC-2771 calldata: real `ccipReceive` encoding + 20-byte suffix
        // that _msgSender() would have decoded as the CCIP router address.
        bytes memory forwardedCalldata =
            bytes.concat(abi.encodeWithSelector(JBCCIPSucker.ccipReceive.selector, ccipMsg), bytes20(CCIP_ROUTER));

        // The call should revert because msg.sender is FORWARDER, not CCIP_ROUTER.
        vm.prank(FORWARDER);
        (bool ok, bytes memory returnData) = address(sucker).call(forwardedCalldata);
        assertFalse(ok, "forged ccipReceive via trusted forwarder must revert");
        assertEq(bytes4(returnData), JBSucker.JBSucker_NotPeer.selector, "revert reason must be JBSucker_NotPeer");
    }
}
