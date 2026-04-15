// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBCCIPSucker.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBSucker.sol";
import {JBCCIPSuckerDeployer} from "../../src/deployers/JBCCIPSuckerDeployer.sol";

import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBPayRemoteMessage} from "../../src/structs/JBPayRemoteMessage.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";
import {MerkleLib} from "../../src/utils/MerkleLib.sol";

/// @notice Minimal mock WETH for testing native token wrap/unwrap flows.
contract MockWETH {
    mapping(address => uint256) public balanceOf;

    receive() external payable {}

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "MockWETH: insufficient");
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "MockWETH: ETH transfer failed");
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function totalSupply() external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @notice CCIP test sucker exposing internals for testing.
contract CCIPTestSucker is JBCCIPSucker {
    using MerkleLib for MerkleLib.Tree;

    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBCCIPSucker(deployer, directory, tokens, permissions, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_validateTokenMapping(JBTokenMapping calldata map) external pure {
        _validateTokenMapping(map);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_sendRootOverAMB(
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

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_insertIntoTree(
        uint256 projectTokenCount,
        address token,
        uint256 terminalTokenAmount,
        bytes32 beneficiary
    )
        external
    {
        _insertIntoTree(projectTokenCount, token, terminalTokenAmount, beneficiary);
    }

    function test_setRemoteToken(address localToken, JBRemoteToken memory remoteToken) external {
        _remoteTokenFor[localToken] = remoteToken;
    }

    function test_getInboxRoot(address token) external view returns (bytes32) {
        return _inboxOf[token].root;
    }

    function test_getInboxNonce(address token) external view returns (uint64) {
        return _inboxOf[token].nonce;
    }

    function test_getOutboxRoot(address token) external view returns (bytes32) {
        return _outboxOf[token].tree.root();
    }
}

/// @notice Base sucker exposing _validateTokenMapping for comparison testing.
contract BaseTestSucker is JBSucker {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_validateTokenMapping(JBTokenMapping calldata map) external pure {
        _validateTokenMapping(map);
    }

    // forge-lint: disable-next-line(mixed-case-function)
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

    function _isRemotePeer(address sender) internal view override returns (bool) {
        return sender == address(this);
    }

    function peerChainId() external pure override returns (uint256) {
        return 1;
    }

    function _sendPayOverAMB(
        uint256,
        address,
        uint256,
        JBRemoteToken memory,
        JBPayRemoteMessage memory
    )
        internal
        override
    {}
}

/// @title CCIPNativeInteropTest
/// @notice Tests for cross-chain native token interop between chains with different native tokens.
///         Validates that the CCIP sucker correctly allows NATIVE_TOKEN -> ERC20 mappings
///         (e.g., ETH mainnet <-> Celo where ETH is an ERC20 on Celo).
contract CCIPNativeInteropTest is Test {
    address constant MOCK_DEPLOYER = address(0xDE);
    address constant MOCK_DIRECTORY = address(0xD1);
    address constant MOCK_TOKENS = address(0xD2);
    address constant MOCK_PERMISSIONS = address(0xD3);
    address constant MOCK_ROUTER = address(0xD4);
    address constant MOCK_PROJECTS = address(0xD5);

    uint256 constant PROJECT_ID = 1;
    uint256 constant REMOTE_CHAIN_ID = 42_220; // Celo
    uint64 constant REMOTE_CHAIN_SELECTOR = 1_311_226; // Celo CCIP selector

    /// @notice Represents ETH as an ERC20 on Celo.
    // forge-lint: disable-next-line(mixed-case-variable)
    address celoETH = makeAddr("celoETH");

    CCIPTestSucker ccipSucker;
    BaseTestSucker baseSucker;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockWETH mockWETH;

    function setUp() public {
        mockWETH = new MockWETH();

        vm.label(MOCK_DEPLOYER, "MOCK_DEPLOYER");
        vm.label(MOCK_DIRECTORY, "MOCK_DIRECTORY");
        vm.label(MOCK_ROUTER, "MOCK_ROUTER");
        vm.label(celoETH, "celoETH");

        // Etch code at mock router so high-level Solidity calls pass extcodesize check.
        vm.etch(MOCK_ROUTER, hex"01");

        // Mock deployer responses for CCIP sucker constructor.
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(REMOTE_CHAIN_ID));
        vm.mockCall(
            MOCK_DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(REMOTE_CHAIN_SELECTOR)
        );
        vm.mockCall(MOCK_DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(MOCK_ROUTER));

        // Mock CCIP router getWrappedNative.
        vm.mockCall(MOCK_ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(mockWETH)));

        // Mock CCIP router getFee and ccipSend.
        vm.mockCall(MOCK_ROUTER, abi.encodeWithSelector(IRouterClient.getFee.selector), abi.encode(uint256(0.01 ether)));
        vm.mockCall(
            MOCK_ROUTER, abi.encodeWithSelector(IRouterClient.ccipSend.selector), abi.encode(bytes32(uint256(1)))
        );

        // Mock directory.
        vm.mockCall(MOCK_DIRECTORY, abi.encodeWithSignature("PROJECTS()"), abi.encode(MOCK_PROJECTS));
        vm.mockCall(MOCK_PROJECTS, abi.encodeWithSignature("ownerOf(uint256)"), abi.encode(address(this)));

        // Deploy CCIP singleton and clone.
        CCIPTestSucker ccipSingleton = new CCIPTestSucker(
            JBCCIPSuckerDeployer(MOCK_DEPLOYER),
            IJBDirectory(MOCK_DIRECTORY),
            IJBTokens(MOCK_TOKENS),
            IJBPermissions(MOCK_PERMISSIONS)
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        ccipSucker = CCIPTestSucker(payable(LibClone.cloneDeterministic(address(ccipSingleton), bytes32("ccip"))));
        ccipSucker.initialize(PROJECT_ID);

        // Deploy base singleton and clone.
        BaseTestSucker baseSingleton =
            new BaseTestSucker(IJBDirectory(MOCK_DIRECTORY), IJBPermissions(MOCK_PERMISSIONS), IJBTokens(MOCK_TOKENS));
        // forge-lint: disable-next-line(unsafe-typecast)
        baseSucker = BaseTestSucker(payable(LibClone.cloneDeterministic(address(baseSingleton), bytes32("base"))));
        baseSucker.initialize(PROJECT_ID);
    }

    // =========================================================================
    // Test 1: CCIP sucker allows NATIVE_TOKEN -> ERC20 mapping
    // =========================================================================

    function test_mapToken_nativeToERC20_allowedOnCCIP() public view {
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN, minGas: 200_000, remoteToken: bytes32(uint256(uint160(celoETH)))
        });

        // Should NOT revert — CCIP sucker allows native -> ERC20 for cross-chain interop.
        ccipSucker.exposed_validateTokenMapping(map);
    }

    // =========================================================================
    // Test 2: Base sucker rejects NATIVE_TOKEN -> ERC20 mapping
    // =========================================================================

    function test_mapToken_nativeToERC20_rejectedOnBase() public {
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN, minGas: 200_000, remoteToken: bytes32(uint256(uint160(celoETH)))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                JBSucker.JBSucker_InvalidNativeRemoteAddress.selector, bytes32(uint256(uint160(celoETH)))
            )
        );
        baseSucker.exposed_validateTokenMapping(map);
    }

    // =========================================================================
    // Test 3: NATIVE_TOKEN -> NATIVE_TOKEN allowed on both
    // =========================================================================

    function test_mapToken_nativeToNative_allowedOnBoth() public view {
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        ccipSucker.exposed_validateTokenMapping(map);
        baseSucker.exposed_validateTokenMapping(map);
    }

    // =========================================================================
    // Test 4: NATIVE_TOKEN -> address(0) disables on both
    // =========================================================================

    function test_mapToken_nativeToZero_disablesOnBoth() public view {
        JBTokenMapping memory map =
            JBTokenMapping({localToken: JBConstants.NATIVE_TOKEN, minGas: 200_000, remoteToken: bytes32(0)});

        ccipSucker.exposed_validateTokenMapping(map);
        baseSucker.exposed_validateTokenMapping(map);
    }

    // =========================================================================
    // Test 5: CCIP enforces minGas for native token mappings
    // =========================================================================

    function test_mapToken_minGas_enforced_forNative() public {
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 100_000, // Below MESSENGER_ERC20_MIN_GAS_LIMIT (200_000)
            remoteToken: bytes32(uint256(uint160(celoETH)))
        });

        // CCIP sucker requires minGas for ALL tokens since native wraps to WETH.
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_BelowMinGas.selector, 100_000, 200_000));
        ccipSucker.exposed_validateTokenMapping(map);
    }

    // =========================================================================
    // Test 6: ccipReceive unwraps WETH when root.token == NATIVE_TOKEN
    // =========================================================================

    function test_ccipReceive_nativeToken_unwraps() public {
        uint256 bridgeAmount = 1 ether;

        // Give MockWETH ETH backing for the unwrap and credit WETH balance to the sucker.
        vm.deal(address(mockWETH), bridgeAmount);
        vm.store(
            address(mockWETH),
            keccak256(abi.encode(address(ccipSucker), uint256(0))), // balanceOf[sucker] at slot 0
            bytes32(bridgeAmount)
        );

        uint256 ethBefore = address(ccipSucker).balance;

        // Build CCIP message with NATIVE_TOKEN root.
        JBMessageRoot memory msgRoot = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: bridgeAmount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xdead))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(mockWETH), amount: bridgeAmount});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(ccipSucker)), // peer is address(this)
            data: abi.encode(uint8(0), abi.encode(msgRoot)),
            destTokenAmounts: tokenAmounts
        });

        vm.prank(MOCK_ROUTER);
        ccipSucker.ccipReceive(message);

        // Verify ETH was unwrapped.
        assertEq(address(ccipSucker).balance, ethBefore + bridgeAmount, "ETH should be unwrapped from WETH");

        // Verify inbox root was stored.
        assertEq(ccipSucker.test_getInboxRoot(JBConstants.NATIVE_TOKEN), bytes32(uint256(0xdead)));
        assertEq(ccipSucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN), 1);
    }

    // =========================================================================
    // Test 7: ccipReceive does NOT unwrap for ERC20 tokens
    // =========================================================================

    function test_ccipReceive_erc20Token_noUnwrap() public {
        uint256 bridgeAmount = 1 ether;

        JBMessageRoot memory msgRoot = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(celoETH))), // ERC20, not NATIVE_TOKEN
            amount: bridgeAmount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xbeef))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: celoETH, amount: bridgeAmount});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(2)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(ccipSucker)),
            data: abi.encode(uint8(0), abi.encode(msgRoot)),
            destTokenAmounts: tokenAmounts
        });

        uint256 ethBefore = address(ccipSucker).balance;

        vm.prank(MOCK_ROUTER);
        ccipSucker.ccipReceive(message);

        // Verify NO unwrap — ETH balance unchanged.
        assertEq(address(ccipSucker).balance, ethBefore, "ETH should NOT change for ERC20 token");

        // Verify inbox root was stored for the ERC20 token.
        assertEq(ccipSucker.test_getInboxRoot(celoETH), bytes32(uint256(0xbeef)));
    }

    // =========================================================================
    // Test 8: _sendRootOverAMB wraps native token to WETH before CCIP send
    // =========================================================================

    function test_sendRoot_nativeToken_wrapsToWETH() public {
        uint256 amount = 1 ether;
        uint256 transport = 0.01 ether;

        // Give the sucker ETH (simulating outbox balance).
        vm.deal(address(ccipSucker), amount);

        JBRemoteToken memory remoteToken = JBRemoteToken({
            enabled: true, emergencyHatch: false, minGas: 200_000, addr: bytes32(uint256(uint160(celoETH)))
        });

        JBMessageRoot memory msgRoot = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(celoETH))),
            amount: amount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xdead))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        // Verify MockWETH balance is 0 before.
        assertEq(mockWETH.balanceOf(address(ccipSucker)), 0);

        // Send root — this should wrap native ETH to WETH.
        ccipSucker.exposed_sendRootOverAMB{value: transport}(
            transport, JBConstants.NATIVE_TOKEN, amount, remoteToken, msgRoot
        );

        // After wrapping: MockWETH received 1 ETH via deposit, sucker got 1 WETH.
        // The mocked ccipSend doesn't actually transfer WETH, so sucker still has it.
        assertEq(mockWETH.balanceOf(address(ccipSucker)), amount, "WETH should be minted from native deposit");

        // MockWETH should hold the ETH backing.
        assertEq(address(mockWETH).balance, amount, "MockWETH should hold the deposited ETH");
    }

    // =========================================================================
    // Test 9: Full flow ETH mainnet -> Celo (native maps to ERC20)
    // =========================================================================

    function test_fullFlow_ethMainnet_to_celo() public {
        // Step 1: Validate that NATIVE -> celoETH mapping is accepted on CCIP.
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN, minGas: 200_000, remoteToken: bytes32(uint256(uint160(celoETH)))
        });
        ccipSucker.exposed_validateTokenMapping(map);

        // Step 2: Set up the token mapping on the sucker.
        ccipSucker.test_setRemoteToken(
            JBConstants.NATIVE_TOKEN,
            JBRemoteToken({
                enabled: true, emergencyHatch: false, minGas: 200_000, addr: bytes32(uint256(uint160(celoETH)))
            })
        );

        // Step 3: Insert a leaf into the outbox (simulating a user preparing to bridge).
        ccipSucker.exposed_insertIntoTree({
            projectTokenCount: 10 ether,
            token: JBConstants.NATIVE_TOKEN,
            terminalTokenAmount: 1 ether,
            beneficiary: bytes32(uint256(uint160(address(0x1234))))
        });

        bytes32 outboxRoot = ccipSucker.test_getOutboxRoot(JBConstants.NATIVE_TOKEN);
        assertTrue(outboxRoot != bytes32(0), "Outbox root should be non-zero");

        // Step 4: Simulate receiving on the "Celo side" — the message arrives with
        // root.token = celoETH (the ERC20 representation of ETH on Celo).
        JBMessageRoot memory msgRoot = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(celoETH))),
            amount: 1 ether,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: outboxRoot}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(3)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(ccipSucker)),
            data: abi.encode(uint8(0), abi.encode(msgRoot)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(MOCK_ROUTER);
        ccipSucker.ccipReceive(message);

        // Verify inbox stored correctly with celoETH as the token key.
        assertEq(ccipSucker.test_getInboxRoot(celoETH), outboxRoot, "Inbox root should match outbox root");
        assertEq(ccipSucker.test_getInboxNonce(celoETH), 1);
    }

    // =========================================================================
    // Test 10: Full flow Celo -> ETH mainnet (receive triggers WETH unwrap)
    // =========================================================================

    function test_fullFlow_celo_to_ethMainnet() public {
        uint256 bridgeAmount = 1 ether;

        // Give MockWETH ETH backing and credit sucker's WETH balance.
        vm.deal(address(mockWETH), bridgeAmount);
        vm.store(address(mockWETH), keccak256(abi.encode(address(ccipSucker), uint256(0))), bytes32(bridgeAmount));

        // Simulate receiving on ETH mainnet — root.token = NATIVE_TOKEN because
        // on mainnet, ETH is the native token. CCIP delivers WETH.
        JBMessageRoot memory msgRoot = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: bridgeAmount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xcafe))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(mockWETH), amount: bridgeAmount});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(4)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(ccipSucker)),
            data: abi.encode(uint8(0), abi.encode(msgRoot)),
            destTokenAmounts: tokenAmounts
        });

        uint256 ethBefore = address(ccipSucker).balance;

        vm.prank(MOCK_ROUTER);
        ccipSucker.ccipReceive(message);

        // Verify unwrapping occurred.
        assertEq(address(ccipSucker).balance, ethBefore + bridgeAmount, "Should unwrap WETH to ETH on receive");

        // Verify inbox stored under NATIVE_TOKEN.
        assertEq(ccipSucker.test_getInboxRoot(JBConstants.NATIVE_TOKEN), bytes32(uint256(0xcafe)));
    }

    // =========================================================================
    // Test 11: ETH round-trip — NATIVE_TOKEN on mainnet <-> ERC20 on Celo
    //
    // This is THE critical cross-chain interop case:
    //   ETH mainnet: ETH is NATIVE_TOKEN (address 0xEEE...EEE)
    //   Celo:        ETH is an ERC-20 (e.g., 0x2DEf4285787d58a2f811AF24755A8150622f4361)
    //
    // The mapping: NATIVE_TOKEN -> celoETH (an ERC-20 address)
    // Send path:   native ETH -> wrap to WETH -> CCIP bridges WETH -> Celo receives as ERC-20
    // Return path: Celo sends ERC-20 ETH -> CCIP delivers as WETH -> unwrap WETH -> native ETH
    // =========================================================================

    function test_eth_roundTrip_nativeToERC20_and_back() public {
        uint256 bridgeAmount = 2 ether;

        // --- Outbound: ETH mainnet -> Celo (NATIVE_TOKEN -> celoETH ERC-20) ---

        // 1. Validate the mapping is accepted.
        JBTokenMapping memory outboundMap = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN, minGas: 200_000, remoteToken: bytes32(uint256(uint160(celoETH)))
        });
        ccipSucker.exposed_validateTokenMapping(outboundMap);

        // 2. Set the mapping and simulate outbox.
        ccipSucker.test_setRemoteToken(
            JBConstants.NATIVE_TOKEN,
            JBRemoteToken({
                enabled: true, emergencyHatch: false, minGas: 200_000, addr: bytes32(uint256(uint160(celoETH)))
            })
        );

        // 3. Wrap native ETH -> WETH for CCIP transport.
        vm.deal(address(ccipSucker), bridgeAmount);
        assertEq(mockWETH.balanceOf(address(ccipSucker)), 0, "No WETH before send");

        JBRemoteToken memory remoteToken = JBRemoteToken({
            enabled: true, emergencyHatch: false, minGas: 200_000, addr: bytes32(uint256(uint160(celoETH)))
        });
        JBMessageRoot memory sendMsg = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(celoETH))),
            amount: bridgeAmount,
            remoteRoot: JBInboxTreeRoot({nonce: 1, root: bytes32(uint256(0xaaa))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });
        ccipSucker.exposed_sendRootOverAMB{value: 0.01 ether}(
            0.01 ether, JBConstants.NATIVE_TOKEN, bridgeAmount, remoteToken, sendMsg
        );

        // Verify native ETH was wrapped to WETH.
        assertEq(mockWETH.balanceOf(address(ccipSucker)), bridgeAmount, "ETH should be wrapped to WETH for CCIP send");
        assertEq(address(mockWETH).balance, bridgeAmount, "MockWETH holds the ETH backing");

        // --- Return: Celo -> ETH mainnet (celoETH ERC-20 -> NATIVE_TOKEN) ---

        // 4. Simulate CCIP delivering WETH back (router unwrap path).
        //    On mainnet, root.token = NATIVE_TOKEN, so ccipReceive unwraps WETH -> ETH.
        vm.deal(address(mockWETH), bridgeAmount);
        vm.store(address(mockWETH), keccak256(abi.encode(address(ccipSucker), uint256(0))), bytes32(bridgeAmount));

        uint256 ethBefore = address(ccipSucker).balance;

        JBMessageRoot memory recvMsg = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN))),
            amount: bridgeAmount,
            remoteRoot: JBInboxTreeRoot({nonce: 2, root: bytes32(uint256(0xbbb))}),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0,
            snapshotNonce: 1
        });

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(mockWETH), amount: bridgeAmount});

        Client.Any2EVMMessage memory ccipMsg = Client.Any2EVMMessage({
            messageId: bytes32(uint256(99)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(ccipSucker)),
            data: abi.encode(uint8(0), abi.encode(recvMsg)),
            destTokenAmounts: tokenAmounts
        });

        vm.prank(MOCK_ROUTER);
        ccipSucker.ccipReceive(ccipMsg);

        // 5. Verify WETH was unwrapped back to native ETH.
        assertEq(
            address(ccipSucker).balance,
            ethBefore + bridgeAmount,
            "Return path: WETH should be unwrapped back to native ETH"
        );

        // Verify inbox roots for both directions.
        assertEq(ccipSucker.test_getInboxRoot(JBConstants.NATIVE_TOKEN), bytes32(uint256(0xbbb)));
        assertEq(ccipSucker.test_getInboxNonce(JBConstants.NATIVE_TOKEN), 2);
    }

    // =========================================================================
    // Test 12: ERC20 -> ERC20 mapping works on both suckers
    // =========================================================================

    function test_mapToken_erc20ToERC20_allowedOnBoth() public view {
        JBTokenMapping memory map = JBTokenMapping({
            localToken: address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC-like
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(address(0xef4229c8c3250C675F21BCefa42f58EfbfF6002a)))) // celoUSDC-like
        });

        ccipSucker.exposed_validateTokenMapping(map);
        baseSucker.exposed_validateTokenMapping(map);
    }

    // =========================================================================
    // Test 12: Both suckers enforce minGas for ERC20 tokens
    // =========================================================================

    function test_mapToken_minGas_enforced_forERC20() public {
        JBTokenMapping memory map = JBTokenMapping({
            localToken: makeAddr("USDC"),
            minGas: 50_000, // Below MESSENGER_ERC20_MIN_GAS_LIMIT (200_000)
            remoteToken: bytes32(uint256(uint160(makeAddr("celoUSDC"))))
        });

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_BelowMinGas.selector, 50_000, 200_000));
        ccipSucker.exposed_validateTokenMapping(map);

        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_BelowMinGas.selector, 50_000, 200_000));
        baseSucker.exposed_validateTokenMapping(map);
    }

    // =========================================================================
    // Test 13: Base sucker skips minGas for native (no wrapping on OP/Arb)
    // =========================================================================

    function test_mapToken_base_skipsMinGas_forNative() public view {
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 0, // Zero minGas
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        // Base sucker skips minGas for native tokens (OP/Arb bridge natively).
        baseSucker.exposed_validateTokenMapping(map);
    }

    // =========================================================================
    // Test 14: CCIP enforces minGas even for native-to-native
    // =========================================================================

    function test_mapToken_ccip_enforcesMinGas_forNativeToNative() public {
        JBTokenMapping memory map = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 0, // Zero minGas
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        // CCIP sucker wraps native to WETH, so needs gas for ERC20 transfer even for native-to-native.
        vm.expectRevert(abi.encodeWithSelector(JBSucker.JBSucker_BelowMinGas.selector, 0, 200_000));
        ccipSucker.exposed_validateTokenMapping(map);
    }

    receive() external payable {}
}
