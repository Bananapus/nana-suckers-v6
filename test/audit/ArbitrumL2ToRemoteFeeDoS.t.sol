// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBArbitrumSucker.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/deployers/JBArbitrumSuckerDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/enums/JBLayer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/interfaces/IArbGatewayRouter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/interfaces/IJBSuckerRegistry.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/structs/JBRemoteToken.sol";

contract ArbitrumL2FeeHarness is JBArbitrumSucker {
    constructor(
        JBArbitrumSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        IJBSuckerRegistry registry
    )
        JBArbitrumSucker(deployer, directory, permissions, tokens, 1, registry, address(0))
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

/// @title ArbitrumL2ToRemoteFeeDoSTest
/// @notice Regression tests for the Arbitrum L2→L1 transportPayment fix.
/// Before the fix, `_toL1` checked `msg.value != 0` instead of `transportPayment != 0`.
/// When a non-zero registry fee existed, `msg.value` was non-zero even though all of it was
/// consumed by the fee — causing `_toL1` to revert and making L2→L1 bridging impossible.
/// The fix passes `transportPayment` (msg.value minus fee) into `_toL1`, so the check
/// correctly passes when all value goes to the fee.
contract ArbitrumL2ToRemoteFeeDoSTest is Test {
    address internal constant DIRECTORY = address(0x1000);
    address internal constant PERMISSIONS = address(0x2000);
    address internal constant TOKENS = address(0x3000);
    address internal constant REGISTRY = address(0x4000);
    address internal constant TERMINAL = address(0x5000);

    ArbitrumL2FeeHarness internal sucker;

    function setUp() public {
        JBArbitrumSuckerDeployer deployer = new JBArbitrumSuckerDeployer({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            configurator: address(this),
            trustedForwarder: address(0)
        });

        deployer.setChainSpecificConstants({
            layer: JBLayer.L2, inbox: IInbox(address(0)), gatewayRouter: IArbGatewayRouter(address(0xB0B))
        });

        ArbitrumL2FeeHarness singleton = new ArbitrumL2FeeHarness({
            deployer: deployer,
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            tokens: IJBTokens(TOKENS),
            registry: IJBSuckerRegistry(REGISTRY)
        });

        // forge-lint: disable-next-line(unsafe-typecast)
        sucker = ArbitrumL2FeeHarness(payable(LibClone.cloneDeterministic(address(singleton), bytes32("arb_fee_dos"))));
        sucker.initialize(1);
        sucker.seedOutbox(JBConstants.NATIVE_TOKEN, bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))));

        // Mock the registry fee and fee terminal.
        vm.mockCall(REGISTRY, abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(1)));
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, JBConstants.NATIVE_TOKEN)),
            abi.encode(IJBTerminal(TERMINAL))
        );
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(0)));

        // Mock ArbSys precompile at address(100) so sendTxToL1 succeeds.
        vm.etch(address(100), hex"00");
        vm.mockCall(address(100), abi.encodeWithSignature("sendTxToL1(address,bytes)"), abi.encode(uint256(0)));
    }

    /// @notice L2→L1 bridging succeeds when msg.value exactly covers the registry fee.
    /// Before the fix, this reverted because _toL1 checked `msg.value != 0`.
    /// After the fix, transportPayment = msg.value - fee = 0, so _toL1 passes.
    function test_toRemoteSucceedsWhenMsgValueCoversFeeExactly() external {
        // msg.value = 1, fee = 1 → transportPayment = 0 → _toL1 accepts
        sucker.toRemote{value: 1}(JBConstants.NATIVE_TOKEN);
    }

    /// @notice L2→L1 bridging reverts when msg.value exceeds the fee (excess transportPayment).
    /// Sending a message from L2→L1 via ArbSys.sendTxToL1 is free — any leftover transportPayment is invalid.
    function test_toRemoteRevertsWhenExcessTransportPayment() external {
        // msg.value = 2, fee = 1 → transportPayment = 1 → _toL1 reverts
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_UnexpectedMsgValue.selector, 1));
        sucker.toRemote{value: 2}(JBConstants.NATIVE_TOKEN);
    }

    /// @notice L2→L1 bridging reverts when msg.value is insufficient for the fee.
    function test_toRemoteRevertsWhenMsgValueBelowFee() external {
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_InsufficientMsgValue.selector, 0, 1));
        sucker.toRemote{value: 0}(JBConstants.NATIVE_TOKEN);
    }
}
