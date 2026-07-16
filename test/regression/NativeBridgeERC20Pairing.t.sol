// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {JBArbitrumSucker} from "../../src/JBArbitrumSucker.sol";
import {JBOptimismSucker} from "../../src/JBOptimismSucker.sol";
import {JBSucker} from "../../src/JBSucker.sol";
import {JBArbitrumSuckerDeployer} from "../../src/deployers/JBArbitrumSuckerDeployer.sol";
import {JBOptimismSuckerDeployer} from "../../src/deployers/JBOptimismSuckerDeployer.sol";
import {JBLayer} from "../../src/enums/JBLayer.sol";
import {IArbGatewayRouter} from "../../src/interfaces/IArbGatewayRouter.sol";
import {IArbL1GatewayRouter} from "../../src/interfaces/IArbL1GatewayRouter.sol";
import {IArbL2GatewayRouter} from "../../src/interfaces/IArbL2GatewayRouter.sol";
import {IJBArbitrumSuckerDeployer} from "../../src/interfaces/IJBArbitrumSuckerDeployer.sol";
import {IJBOpSuckerDeployer} from "../../src/interfaces/IJBOpSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {IL1ArbitrumGateway} from "../../src/interfaces/IL1ArbitrumGateway.sol";
import {IOPMessenger} from "../../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../../src/interfaces/IOPStandardBridge.sol";
import {JBChainAccounting} from "../../src/structs/JBChainAccounting.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";

contract NativeBridgePairingToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address beneficiary, uint256 amount) external {
        _mint(beneficiary, amount);
    }
}

/// @notice Minimal OP mintable-token shape checked by the destination StandardBridge.
contract MockOptimismMintableToken is NativeBridgePairingToken {
    address public immutable remoteToken;
    address public immutable bridge;

    constructor(address _remoteToken, address _bridge) NativeBridgePairingToken("OP bridge token", "opBRG") {
        remoteToken = _remoteToken;
        bridge = _bridge;
    }
}

contract PairCheckingOPBridge is IOPStandardBridge {
    error InvalidTokenPair(address localToken, address remoteToken);

    address public pendingLocalToken;
    address public pendingRemoteToken;
    address public pendingBeneficiary;
    uint256 public pendingAmount;

    function bridgeERC20To(
        address localToken,
        address remoteToken,
        address to,
        uint256 amount,
        uint32,
        bytes calldata
    )
        external
    {
        SafeERC20.safeTransferFrom(IERC20(localToken), msg.sender, address(this), amount);
        pendingLocalToken = localToken;
        pendingRemoteToken = remoteToken;
        pendingBeneficiary = to;
        pendingAmount = amount;
    }

    /// @notice Models the destination StandardBridge's pair check, which happens after source-side escrow succeeds.
    function relayPendingTransfer() external {
        (bool remoteTokenCallSucceeded, bytes memory remoteTokenData) =
            pendingRemoteToken.staticcall(abi.encodeWithSignature("remoteToken()"));
        (bool bridgeCallSucceeded, bytes memory bridgeData) =
            pendingRemoteToken.staticcall(abi.encodeWithSignature("bridge()"));

        if (
            !remoteTokenCallSucceeded || remoteTokenData.length != 32 || !bridgeCallSucceeded || bridgeData.length != 32
                || abi.decode(remoteTokenData, (address)) != pendingLocalToken
                || abi.decode(bridgeData, (address)) != address(this)
        ) {
            revert InvalidTokenPair(pendingLocalToken, pendingRemoteToken);
        }

        NativeBridgePairingToken(pendingRemoteToken).mint(pendingBeneficiary, pendingAmount);
    }
}

contract RecordingOPMessenger is IOPMessenger {
    address public lastTarget;
    bytes public lastMessage;

    function sendMessage(address target, bytes memory message, uint32) external payable {
        lastTarget = target;
        lastMessage = message;
    }

    function bridgeERC20To(address, address, address, uint256, uint32, bytes calldata) external {}

    function xDomainMessageSender() external pure returns (address) {
        return address(0);
    }
}

contract OPPairingSuckerHarness is JBOptimismSucker {
    constructor(
        JBOptimismSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        JBOptimismSucker(deployer, directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function validateMapping(JBTokenMapping calldata map) external pure {
        _validateTokenMapping(map);
    }

    function sendToken(address localToken, address remoteToken, uint256 amount, JBMessageRoot memory message) external {
        _sendRootOverAMB(
            0,
            0,
            localToken,
            amount,
            JBRemoteToken({
                enabled: true, emergencyHatch: false, minGas: 200_000, addr: bytes32(uint256(uint160(remoteToken)))
            }),
            message
        );
    }
}

contract RecordingArbInbox {
    bytes public lastData;
    uint256 public lastGasLimit;
    uint256 public lastValue;

    function calculateRetryableSubmissionFee(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function unsafeCreateRetryableTicket(
        address,
        uint256,
        uint256,
        address,
        address,
        uint256 gasLimit,
        uint256,
        bytes calldata data
    )
        external
        payable
        returns (uint256)
    {
        lastData = data;
        lastGasLimit = gasLimit;
        lastValue = msg.value;
        return 1;
    }
}

contract MockArbL1Gateway is IL1ArbitrumGateway {
    NativeBridgePairingToken public immutable remoteToken;

    constructor(NativeBridgePairingToken _remoteToken) {
        remoteToken = _remoteToken;
    }

    function getOutboundCalldata(
        address token,
        address from,
        address to,
        uint256 amount,
        bytes calldata data
    )
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(token, from, to, amount, data);
    }

    function bridge(address token, address from, address to, uint256 amount) external {
        SafeERC20.safeTransferFrom(IERC20(token), from, address(this), amount);
        remoteToken.mint(to, amount);
    }
}

contract MockArbL1GatewayRouter is IArbGatewayRouter, IArbL1GatewayRouter {
    MockArbL1Gateway public immutable gateway;
    address public lastToken;

    constructor(MockArbL1Gateway _gateway) {
        gateway = _gateway;
    }

    function defaultGateway() external view returns (address) {
        return address(gateway);
    }

    function getGateway(address) external view returns (address) {
        return address(gateway);
    }

    function outboundTransferCustomRefund(
        address token,
        address,
        address to,
        uint256 amount,
        uint256,
        uint256,
        bytes calldata
    )
        external
        payable
        returns (bytes memory)
    {
        lastToken = token;
        gateway.bridge({token: token, from: msg.sender, to: to, amount: amount});
        return bytes("");
    }
}

contract MockArbL2Gateway {
    error MissingPairedToken(address pairedToken, address account, uint256 amount);

    IERC20 public immutable pairedToken;

    constructor(IERC20 _pairedToken) {
        pairedToken = _pairedToken;
    }

    function bridge(address from, uint256 amount) external {
        if (pairedToken.balanceOf(from) < amount) {
            revert MissingPairedToken(address(pairedToken), from, amount);
        }
        SafeERC20.safeTransferFrom(pairedToken, from, address(this), amount);
    }
}

contract MockArbL2GatewayRouter is IArbGatewayRouter, IArbL2GatewayRouter {
    MockArbL2Gateway public immutable gateway;

    constructor(MockArbL2Gateway _gateway) {
        gateway = _gateway;
    }

    function defaultGateway() external view returns (address) {
        return address(gateway);
    }

    function getGateway(address) external view returns (address) {
        return address(gateway);
    }

    function outboundTransfer(address, address, uint256 amount, bytes calldata)
        external
        payable
        returns (bytes memory)
    {
        gateway.bridge({from: msg.sender, amount: amount});
        return bytes("");
    }
}

contract ArbPairingSuckerHarness is JBArbitrumSucker {
    constructor(
        JBArbitrumSuckerDeployer deployer,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        JBArbitrumSucker(deployer, directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function sendToken(
        address localToken,
        address remoteToken,
        uint256 amount,
        JBMessageRoot memory message
    )
        external
        payable
    {
        _sendRootOverAMB(
            msg.value,
            0,
            localToken,
            amount,
            JBRemoteToken({
                enabled: true, emergencyHatch: false, minGas: 200_000, addr: bytes32(uint256(uint160(remoteToken)))
            }),
            message
        );
    }
}

/// @notice Regression coverage for ERC-20 mappings used with OP and Arbitrum native bridges.
/// @dev A mapping records the token the root will name. It does not configure or validate the native bridge's token
/// pair. The bridge-compatible counterpart must be selected independently in both directions.
contract NativeBridgeERC20PairingTest is Test {
    address internal constant DIRECTORY = address(0x1001);
    address internal constant PERMISSIONS = address(0x1002);
    address internal constant PROJECTS = address(0x1003);
    address internal constant TOKENS = address(0x1004);
    address internal constant OP_DEPLOYER = address(0x2001);
    address internal constant ARB_L1_DEPLOYER = address(0x2002);
    address internal constant ARB_L2_DEPLOYER = address(0x2003);

    uint256 internal constant AMOUNT = 100e6;

    function setUp() external {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
    }

    function test_opCanonicalRemoteTokenEscrowsLocallyThenFailsDestinationPairCheck() external {
        NativeBridgePairingToken localCanonical = new NativeBridgePairingToken("L1 canonical", "L1C");
        NativeBridgePairingToken remoteCanonical = new NativeBridgePairingToken("L2 canonical", "L2C");
        PairCheckingOPBridge bridge = new PairCheckingOPBridge();
        RecordingOPMessenger messenger = new RecordingOPMessenger();
        OPPairingSuckerHarness sucker = _opSucker(bridge, messenger);

        // Native-sucker validation checks token kind and minGas, not the bridge's registered pair.
        sucker.validateMapping(
            JBTokenMapping({
                localToken: address(localCanonical),
                minGas: 200_000,
                remoteToken: bytes32(uint256(uint160(address(remoteCanonical))))
            })
        );

        localCanonical.mint(address(sucker), AMOUNT);
        JBMessageRoot memory message = _message(address(remoteCanonical), AMOUNT);
        sucker.sendToken(address(localCanonical), address(remoteCanonical), AMOUNT, message);

        assertEq(localCanonical.balanceOf(address(bridge)), AMOUNT, "source bridge escrows the local token");
        assertEq(remoteCanonical.balanceOf(address(sucker)), 0, "canonical remote token was not delivered");
        assertEq(
            keccak256(messenger.lastMessage()),
            keccak256(abi.encodeCall(JBSucker.fromRemote, (message))),
            "root still names the incompatible canonical token"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PairCheckingOPBridge.InvalidTokenPair.selector, address(localCanonical), address(remoteCanonical)
            )
        );
        bridge.relayPendingTransfer();

        assertEq(localCanonical.balanceOf(address(bridge)), AMOUNT, "failed relay leaves source funds escrowed");
        assertEq(remoteCanonical.balanceOf(address(sucker)), 0, "failed relay leaves the root without backing");
    }

    function test_opRegisteredBridgePairBacksTheMappedRoot() external {
        NativeBridgePairingToken localToken = new NativeBridgePairingToken("L1 token", "L1T");
        PairCheckingOPBridge bridge = new PairCheckingOPBridge();
        MockOptimismMintableToken remoteToken = new MockOptimismMintableToken(address(localToken), address(bridge));
        RecordingOPMessenger messenger = new RecordingOPMessenger();
        OPPairingSuckerHarness sucker = _opSucker(bridge, messenger);

        localToken.mint(address(sucker), AMOUNT);
        sucker.sendToken(address(localToken), address(remoteToken), AMOUNT, _message(address(remoteToken), AMOUNT));
        bridge.relayPendingTransfer();

        assertEq(remoteToken.balanceOf(address(sucker)), AMOUNT, "registered remote token backs the mapped root");
    }

    function test_arbitrumL1ToL2GatewayTokenCanDifferFromMappedRootToken() external {
        NativeBridgePairingToken l1Canonical = new NativeBridgePairingToken("L1 canonical", "L1C");
        NativeBridgePairingToken l2Canonical = new NativeBridgePairingToken("L2 canonical", "L2C");
        NativeBridgePairingToken l2GatewayToken = new NativeBridgePairingToken("L2 gateway token", "L2G");
        MockArbL1Gateway gateway = new MockArbL1Gateway(l2GatewayToken);
        MockArbL1GatewayRouter router = new MockArbL1GatewayRouter(gateway);
        RecordingArbInbox inbox = new RecordingArbInbox();
        ArbPairingSuckerHarness sucker = _arbSucker(ARB_L1_DEPLOYER, JBLayer.L1, address(router), address(inbox));

        l1Canonical.mint(address(sucker), AMOUNT);
        JBMessageRoot memory message = _message(address(l2Canonical), AMOUNT);

        // Empty accounting bundles use 300k message gas; ERC-20 delivery uses the configured 200k minGas.
        vm.fee(1);
        sucker.sendToken{value: 500_000}(address(l1Canonical), address(l2Canonical), AMOUNT, message);

        assertEq(router.lastToken(), address(l1Canonical), "gateway routing keys off the local L1 token");
        assertEq(l2GatewayToken.balanceOf(address(sucker)), AMOUNT, "gateway delivers its registered L2 token");
        assertEq(l2Canonical.balanceOf(address(sucker)), 0, "mapped canonical token is not delivered");
        assertEq(
            keccak256(inbox.lastData()),
            keccak256(abi.encodeCall(JBSucker.fromRemote, (message))),
            "independent root message names the mapped canonical token"
        );
    }

    function test_arbitrumL2ToL1CanonicalTokenRevertsWhenGatewayExpectsPairedToken() external {
        NativeBridgePairingToken l2Canonical = new NativeBridgePairingToken("L2 canonical", "L2C");
        NativeBridgePairingToken l2GatewayToken = new NativeBridgePairingToken("L2 gateway token", "L2G");
        NativeBridgePairingToken l1Canonical = new NativeBridgePairingToken("L1 canonical", "L1C");
        MockArbL2Gateway gateway = new MockArbL2Gateway(l2GatewayToken);
        MockArbL2GatewayRouter router = new MockArbL2GatewayRouter(gateway);
        ArbPairingSuckerHarness sucker = _arbSucker(ARB_L2_DEPLOYER, JBLayer.L2, address(router), address(0));

        l2Canonical.mint(address(sucker), AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                MockArbL2Gateway.MissingPairedToken.selector, address(l2GatewayToken), address(sucker), AMOUNT
            )
        );
        sucker.sendToken(address(l2Canonical), address(l1Canonical), AMOUNT, _message(address(l1Canonical), AMOUNT));

        assertEq(l2Canonical.balanceOf(address(sucker)), AMOUNT, "failed send leaves canonical token recoverable");
        assertEq(l2GatewayToken.balanceOf(address(gateway)), 0, "gateway cannot burn the missing paired token");
    }

    function _opSucker(
        PairCheckingOPBridge bridge,
        RecordingOPMessenger messenger
    )
        internal
        returns (OPPairingSuckerHarness sucker)
    {
        vm.mockCall(
            OP_DEPLOYER, abi.encodeCall(IJBOpSuckerDeployer.opMessenger, ()), abi.encode(IOPMessenger(messenger))
        );
        vm.mockCall(
            OP_DEPLOYER, abi.encodeCall(IJBOpSuckerDeployer.opBridge, ()), abi.encode(IOPStandardBridge(bridge))
        );

        sucker = new OPPairingSuckerHarness(
            JBOptimismSuckerDeployer(OP_DEPLOYER),
            IJBDirectory(DIRECTORY),
            IJBPermissions(PERMISSIONS),
            IJBTokens(TOKENS)
        );
    }

    function _arbSucker(
        address deployer,
        JBLayer layer,
        address router,
        address inbox
    )
        internal
        returns (ArbPairingSuckerHarness sucker)
    {
        vm.mockCall(
            deployer,
            abi.encodeCall(IJBArbitrumSuckerDeployer.arbGatewayRouter, ()),
            abi.encode(IArbGatewayRouter(router))
        );
        vm.mockCall(deployer, abi.encodeCall(IJBArbitrumSuckerDeployer.arbInbox, ()), abi.encode(IInbox(inbox)));
        vm.mockCall(deployer, abi.encodeCall(IJBArbitrumSuckerDeployer.arbLayer, ()), abi.encode(layer));

        sucker = new ArbPairingSuckerHarness(
            JBArbitrumSuckerDeployer(deployer), IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS)
        );
    }

    function _message(address remoteToken, uint256 amount) internal pure returns (JBMessageRoot memory message) {
        message = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(remoteToken))),
            amount: amount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: keccak256("root")}),
            accounts: new JBChainAccounting[](0)
        });
    }
}
