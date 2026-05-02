// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {SuckerForkHelpers} from "./helpers/SuckerForkHelpers.sol";
import {IJBSucker} from "../src/interfaces/IJBSucker.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBTokenMapping} from "../src/structs/JBTokenMapping.sol";
import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";

import {IOPMessenger} from "../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../src/interfaces/IOPStandardBridge.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
import {JBOptimismSuckerDeployer} from "src/deployers/JBOptimismSuckerDeployer.sol";
import {JBBaseSuckerDeployer} from "src/deployers/JBBaseSuckerDeployer.sol";
import {JBOptimismSucker} from "../src/JBOptimismSucker.sol";
import {JBBaseSucker} from "../src/JBBaseSucker.sol";

/// @notice Abstract base for OP Stack native bridge fork tests (Optimism, Base).
///
/// Tests native ETH transfers via the OP native bridge (messenger + standard bridge).
/// Unlike Celo, both Optimism and Base use ETH as native gas, so no WETH wrapping is needed —
/// it's a simpler NATIVE_TOKEN → NATIVE_TOKEN mapping.
///
/// Two directions are tested:
///   - test_l1NativeTransfer: L1 (Ethereum) → L2 via OP bridge.
///   - test_l2NativeTransfer: L2 → L1 (Ethereum) via OP bridge.
abstract contract OPStackNativeBridgeForkTestBase is SuckerForkHelpers {
    // ── L1 (Ethereum) side
    JBOptimismSuckerDeployer suckerDeployerL1;
    IJBSucker suckerL1;
    IJBToken projectToken;

    // ── L2 side
    JBOptimismSuckerDeployer suckerDeployerL2;
    IJBSucker suckerL2;
    IJBToken l2ProjectToken;

    uint256 l1Fork;
    uint256 l2Fork;

    // ── L2 OP predeploy addresses (same for all OP Stack chains)
    IOPMessenger constant L2_MESSENGER = IOPMessenger(0x4200000000000000000000000000000000000007);
    IOPStandardBridge constant L2_BRIDGE = IOPStandardBridge(0x4200000000000000000000000000000000000010);

    // ── Chain-specific overrides
    function _l2RpcUrl() internal pure virtual returns (string memory);
    function _l1Messenger() internal pure virtual returns (IOPMessenger);
    function _l1Bridge() internal pure virtual returns (IOPStandardBridge);
    function _createDeployer(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address configurator
    )
        internal
        virtual
        returns (JBOptimismSuckerDeployer);
    function _createSingleton(
        JBOptimismSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        internal
        virtual
        returns (JBOptimismSucker);

    // ── Setup
    function setUp() public override {
        _initMetadata();

        // ── L1 (Ethereum, roll back a few blocks to avoid RPC race where latest block isn't fully executed)
        l1Fork = vm.createSelectFork("ethereum");
        vm.rollFork(block.number - 5);
        super.setUp();
        vm.stopPrank();

        // Deploy sucker deployer on L1.
        vm.startPrank(address(0x1112222));
        suckerDeployerL1 = _createDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this));
        vm.stopPrank();

        suckerDeployerL1.setChainSpecificConstants(_l1Messenger(), _l1Bridge());

        vm.startPrank(address(0x1112222));
        JBOptimismSucker singletonL1 = _createSingleton(suckerDeployerL1, jbDirectory(), jbPermissions(), jbTokens());
        vm.stopPrank();

        suckerDeployerL1.configureSingleton(singletonL1);
        suckerL1 = suckerDeployerL1.createForSender(1, "l1-salt", bytes32(0));
        vm.label(address(suckerL1), "suckerL1");

        // Grant sucker mint permission on L1.
        uint8[] memory ids = new uint8[](1);
        ids[0] = JBPermissionIds.MINT_TOKENS;
        JBPermissionsData memory permsL1 =
            JBPermissionsData({operator: address(suckerL1), projectId: 1, permissionIds: ids});

        vm.startPrank(multisig());
        jbPermissions().setPermissionsFor(multisig(), permsL1);
        _launchProject();
        projectToken = jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));
        vm.stopPrank();

        // ── L2 (roll back a few blocks to avoid RPC race where latest block isn't fully executed)
        l2Fork = vm.createSelectFork(_l2RpcUrl());
        vm.rollFork(block.number - 5);
        super.setUp();
        vm.stopPrank();

        vm.startPrank(address(0x1112222));
        suckerDeployerL2 = _createDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this));
        vm.stopPrank();

        suckerDeployerL2.setChainSpecificConstants(L2_MESSENGER, L2_BRIDGE);

        vm.startPrank(address(0x1112222));
        JBOptimismSucker singletonL2 = _createSingleton(suckerDeployerL2, jbDirectory(), jbPermissions(), jbTokens());
        vm.stopPrank();

        suckerDeployerL2.configureSingleton(singletonL2);
        suckerL2 = suckerDeployerL2.createForSender(1, "l2-salt", bytes32(0));
        vm.label(address(suckerL2), "suckerL2");

        // Grant L2 sucker mint permission and launch L2 project.
        JBPermissionsData memory permsL2 =
            JBPermissionsData({operator: address(suckerL2), projectId: 1, permissionIds: ids});

        vm.startPrank(multisig());
        jbPermissions().setPermissionsFor(multisig(), permsL2);
        _launchProject();
        l2ProjectToken = jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));
        vm.stopPrank();

        vm.mockCall(address(0), abi.encodeCall(IJBSuckerRegistry.toRemoteFee, ()), abi.encode(uint256(0)));
    }

    // ── Tests

    /// @notice Test native ETH transfer from L1 (Ethereum) → L2 via OP native bridge.
    ///
    /// Verifies the full send-side flow:
    ///   1. Pay into JB terminal, receive project tokens
    ///   2. Prepare cash out via sucker (builds merkle tree)
    ///   3. toRemote() sends native ETH through the real mainnet OP bridge/messenger
    ///   4. Outbox is cleared, bridge/messenger emit events
    function test_l1NativeTransfer() external {
        address user = makeAddr("user");
        uint256 amountToSend = 0.05 ether;
        uint256 maxCashedOut = amountToSend / 2;

        // Start on L1.
        vm.selectFork(l1Fork);
        vm.deal(user, amountToSend);

        // Map native token (ETH → ETH, same on both sides).
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        vm.prank(multisig());
        suckerL1.mapToken(map);

        // Pay into L1 terminal → receive project tokens.
        vm.startPrank(user);
        uint256 projectTokenAmount =
            jbMultiTerminal().pay{value: amountToSend}(1, JBConstants.NATIVE_TOKEN, amountToSend, user, 0, "", "");

        // Prepare cash out via sucker.
        IERC20(address(projectToken)).approve(address(suckerL1), projectTokenAmount);
        suckerL1.prepare(projectTokenAmount, bytes32(uint256(uint160(user))), maxCashedOut, JBConstants.NATIVE_TOKEN);
        vm.stopPrank();

        // Record logs to verify bridging behavior.
        vm.recordLogs();

        // Send to L2 — OP bridge does not require msg.value for transport.
        vm.prank(user);
        suckerL1.toRemote(JBConstants.NATIVE_TOKEN);

        // Verify outbox cleared on L1.
        assertEq(suckerL1.outboxOf(JBConstants.NATIVE_TOKEN).balance, 0, "Outbox should be cleared");

        // Verify that the OP bridge/messenger emitted events (proves mainnet contracts accepted our call).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundBridgeEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(_l1Bridge()) || logs[i].emitter == address(_l1Messenger())) {
                foundBridgeEvent = true;
                break;
            }
        }
        assertTrue(foundBridgeEvent, "OP bridge/messenger should have emitted events");
    }

    /// @notice Test native ETH transfer from L2 → L1 (Ethereum) via OP native bridge.
    ///
    /// Same flow as L1 → L2 but in the other direction, using L2 predeploy contracts.
    function test_l2NativeTransfer() external {
        address user = makeAddr("user");
        uint256 amountToSend = 0.05 ether;
        uint256 maxCashedOut = amountToSend / 2;

        // Start on L2.
        vm.selectFork(l2Fork);
        vm.deal(user, amountToSend);

        // Map native token on L2 side.
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        vm.prank(multisig());
        suckerL2.mapToken(map);

        // Pay into L2 terminal → receive project tokens (ERC20 was deployed in setUp).
        vm.startPrank(user);
        uint256 projectTokenAmount =
            jbMultiTerminal().pay{value: amountToSend}(1, JBConstants.NATIVE_TOKEN, amountToSend, user, 0, "", "");

        // Prepare cash out via sucker.
        IERC20(address(l2ProjectToken)).approve(address(suckerL2), projectTokenAmount);
        suckerL2.prepare(projectTokenAmount, bytes32(uint256(uint160(user))), maxCashedOut, JBConstants.NATIVE_TOKEN);
        vm.stopPrank();

        vm.recordLogs();

        // Send to L1 — OP bridge does not require msg.value for transport.
        vm.prank(user);
        suckerL2.toRemote(JBConstants.NATIVE_TOKEN);

        // Verify outbox cleared on L2.
        assertEq(suckerL2.outboxOf(JBConstants.NATIVE_TOKEN).balance, 0, "Outbox should be cleared");

        // Verify L2 predeploy messenger emitted events.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundBridgeEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(L2_BRIDGE) || logs[i].emitter == address(L2_MESSENGER)) {
                foundBridgeEvent = true;
                break;
            }
        }
        assertTrue(foundBridgeEvent, "OP L2 bridge/messenger should have emitted events");
    }
}

// ─── Concrete chain pair tests
// ────────────────────────────────────────────────

/// @notice Ethereum ↔ Optimism native bridge fork test.
contract ForkOptimismTest is OPStackNativeBridgeForkTestBase {
    function _l2RpcUrl() internal pure override returns (string memory) {
        return "optimism";
    }

    function _l1Messenger() internal pure override returns (IOPMessenger) {
        return IOPMessenger(0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1);
    }

    function _l1Bridge() internal pure override returns (IOPStandardBridge) {
        return IOPStandardBridge(0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1);
    }

    function _createDeployer(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address configurator
    )
        internal
        override
        returns (JBOptimismSuckerDeployer)
    {
        return new JBOptimismSuckerDeployer(directory, permissions, tokens, configurator, address(0));
    }

    function _createSingleton(
        JBOptimismSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        internal
        override
        returns (JBOptimismSucker)
    {
        return new JBOptimismSucker({
            deployer: deployer,
            directory: directory,
            permissions: permissions,
            tokens: tokens,
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
    }
}

/// @notice Ethereum ↔ Base native bridge fork test.
contract ForkBaseTest is OPStackNativeBridgeForkTestBase {
    function _l2RpcUrl() internal pure override returns (string memory) {
        return "base";
    }

    function _l1Messenger() internal pure override returns (IOPMessenger) {
        return IOPMessenger(0x866E82a600A1414e583f7F13623F1aC5d58b0Afa);
    }

    function _l1Bridge() internal pure override returns (IOPStandardBridge) {
        return IOPStandardBridge(0x3154Cf16ccdb4C6d922629664174b904d80F2C35);
    }

    function _createDeployer(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        address configurator
    )
        internal
        override
        returns (JBOptimismSuckerDeployer)
    {
        return new JBBaseSuckerDeployer(directory, permissions, tokens, configurator, address(0));
    }

    function _createSingleton(
        JBOptimismSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        internal
        override
        returns (JBOptimismSucker)
    {
        return new JBBaseSucker({
            deployer: deployer,
            directory: directory,
            permissions: permissions,
            tokens: tokens,
            feeProjectId: 1,
            registry: IJBSuckerRegistry(address(0)),
            trustedForwarder: address(0)
        });
    }
}
