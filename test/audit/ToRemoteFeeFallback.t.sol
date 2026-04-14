// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBSucker.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBOptimismSucker.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/deployers/JBOptimismSuckerDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/interfaces/IJBSuckerRegistry.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/interfaces/IOPMessenger.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/interfaces/IOPStandardBridge.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/structs/JBRemoteToken.sol";

contract OptimismFeeHarness is JBOptimismSucker {
    constructor(
        JBOptimismSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        IJBSuckerRegistry registry
    )
        JBOptimismSucker(deployer, directory, permissions, tokens, 1, registry, address(0))
    {}

    function seedOutbox(address token, bytes32 remoteToken) external {
        _remoteTokenFor[token] =
            JBRemoteToken({addr: remoteToken, enabled: true, emergencyHatch: false, minGas: 200_000});
        _insertIntoTree({
            projectTokenCount: 0,
            token: token,
            terminalTokenAmount: 0,
            beneficiary: bytes32(uint256(uint160(address(0xBEEF))))
        });
    }
}

contract ToRemoteFeeFallbackTest is Test {
    address internal constant DIRECTORY = address(0x1000);
    address internal constant PERMISSIONS = address(0x2000);
    address internal constant TOKENS = address(0x3000);
    address internal constant REGISTRY = address(0x4000);
    address internal constant FEE_TERMINAL = address(0x5000);

    OptimismFeeHarness internal sucker;

    function setUp() public {
        JBOptimismSuckerDeployer deployer = new JBOptimismSuckerDeployer({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            configurator: address(this),
            trustedForwarder: address(0)
        });

        deployer.setChainSpecificConstants({
            messenger: IOPMessenger(address(0xB0B)), bridge: IOPStandardBridge(address(0xCAFE))
        });

        OptimismFeeHarness singleton = new OptimismFeeHarness({
            deployer: deployer,
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            registry: IJBSuckerRegistry(REGISTRY)
        });

        sucker =
        // forge-lint: disable-next-line(unsafe-typecast)
        OptimismFeeHarness(payable(LibClone.cloneDeterministic(address(singleton), bytes32("op_fee_dos"))));
        sucker.initialize(1);
        sucker.seedOutbox(JBConstants.NATIVE_TOKEN, bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))));

        vm.mockCall(REGISTRY, abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(1)));

        // Mock DIRECTORY.controllerOf() so the try-catch in _sendRoot() doesn't revert under via-IR.
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.controllerOf, (uint256(1))), abi.encode(address(0)));

        // Mock DIRECTORY.terminalsOf() so _buildETHAggregate() in _sendRoot() doesn't revert.
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.terminalsOf, (uint256(1))),
            abi.encode(new IJBTerminal[](0))
        );
    }

    function test_toRemoteSucceedsIfFeeTerminalIsMissing() external {
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, JBConstants.NATIVE_TOKEN)),
            abi.encode(IJBTerminal(address(0)))
        );
        vm.mockCall(address(0xB0B), abi.encodeWithSelector(IOPMessenger.sendMessage.selector), abi.encode());

        // Fee ETH stays in the contract; bridge proceeds without revert.
        sucker.toRemote{value: 1}(JBConstants.NATIVE_TOKEN);
        assertEq(address(sucker).balance, 1, "fee ETH retained in contract when terminal missing");
    }

    function test_toRemoteSucceedsIfFeeTerminalPayReverts() external {
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, JBConstants.NATIVE_TOKEN)),
            abi.encode(IJBTerminal(FEE_TERMINAL))
        );
        vm.mockCallRevert(
            FEE_TERMINAL, abi.encodeWithSelector(IJBTerminal.pay.selector), bytes("fee terminal reverted")
        );
        vm.mockCall(address(0xB0B), abi.encodeWithSelector(IOPMessenger.sendMessage.selector), abi.encode());

        // Fee ETH stays in the contract; bridge proceeds without revert.
        sucker.toRemote{value: 1}(JBConstants.NATIVE_TOKEN);
        assertEq(address(sucker).balance, 1, "fee ETH retained in contract when pay reverts");
    }

    function test_toRemoteSucceedsIfFeeTerminalAcceptsPayment() external {
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, JBConstants.NATIVE_TOKEN)),
            abi.encode(IJBTerminal(FEE_TERMINAL))
        );
        vm.mockCall(FEE_TERMINAL, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(0)));
        vm.mockCall(address(0xB0B), abi.encodeWithSelector(IOPMessenger.sendMessage.selector), abi.encode());

        sucker.toRemote{value: 1}(JBConstants.NATIVE_TOKEN);
    }
}
