// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../../src/JBCCIPSucker.sol";
import "../../src/JBSucker.sol";
import {JBCCIPSuckerDeployer} from "../../src/deployers/JBCCIPSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "../../src/structs/JBClaim.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBLeaf} from "../../src/structs/JBLeaf.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";

contract CodexMockWETH {
    mapping(address => uint256) public balanceOf;

    receive() external payable {}

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth send failed");
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
}

contract CodexCCIPHarness is JBCCIPSucker {
    constructor(
        JBCCIPSuckerDeployer deployer,
        IJBDirectory directory,
        IJBTokens tokens,
        IJBPermissions permissions
    )
        JBCCIPSucker(deployer, directory, tokens, permissions, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function peerChainId() external pure override returns (uint256) {
        return 1;
    }

    function inboxRootOf(address token) external view returns (bytes32) {
        return _inboxOf[token].root;
    }
}

contract CodexCCIPWrappedNativeMisunwrapTest is Test {
    address constant DEPLOYER = address(0xDE);
    address constant DIRECTORY = address(0xD1);
    address constant TOKENS = address(0xD2);
    address constant PERMISSIONS = address(0xD3);
    address constant ROUTER = address(0xD4);

    uint256 constant PROJECT_ID = 1;
    uint64 constant REMOTE_CHAIN_SELECTOR = 99;

    CodexCCIPHarness sucker;
    CodexMockWETH weth;

    function setUp() public {
        weth = new CodexMockWETH();

        vm.etch(ROUTER, hex"01");
        vm.mockCall(DEPLOYER, abi.encodeWithSignature("ccipRemoteChainId()"), abi.encode(uint256(2)));
        vm.mockCall(DEPLOYER, abi.encodeWithSignature("ccipRemoteChainSelector()"), abi.encode(REMOTE_CHAIN_SELECTOR));
        vm.mockCall(DEPLOYER, abi.encodeWithSignature("ccipRouter()"), abi.encode(ROUTER));
        vm.mockCall(ROUTER, abi.encodeWithSignature("getWrappedNative()"), abi.encode(address(weth)));
        vm.mockCall(ROUTER, abi.encodeWithSelector(IRouterClient.getFee.selector), abi.encode(uint256(0.01 ether)));
        vm.mockCall(ROUTER, abi.encodeWithSelector(IRouterClient.ccipSend.selector), abi.encode(bytes32(uint256(1))));

        CodexCCIPHarness singleton = new CodexCCIPHarness(
            JBCCIPSuckerDeployer(DEPLOYER), IJBDirectory(DIRECTORY), IJBTokens(TOKENS), IJBPermissions(PERMISSIONS)
        );
        sucker = CodexCCIPHarness(payable(LibClone.cloneDeterministic(address(singleton), bytes32("codex-ccip-weth"))));
        sucker.initialize(PROJECT_ID);
    }

    /// @notice When root.token is the WETH address (not NATIVE_TOKEN), WETH is correctly
    /// kept as ERC-20 — no unwrap occurs. This ensures claim settlement can find WETH balance.
    function test_ccipReceive_keepsWethWhenRootTokenIsWethAddress() external {
        uint256 amount = 1 ether;
        address beneficiary = makeAddr("beneficiary");

        vm.deal(address(weth), amount);
        vm.store(address(weth), keccak256(abi.encode(address(sucker), uint256(0))), bytes32(amount));

        bytes32[32] memory proof;
        proof[0] = bytes32(0);
        proof[1] = 0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5;
        proof[2] = 0xb4c11951957c6f8f642c4af61cd6b24640fec6dc7fc607ee8206a99e92410d30;
        proof[3] = 0x21ddb9a356815c3fac1026b6dec5df3124afbadb485c9ba5a3e3398a04b7ba85;
        proof[4] = 0xe58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344;
        proof[5] = 0x0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d;
        proof[6] = 0x887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968;
        proof[7] = 0xffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83;
        proof[8] = 0x9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af;
        proof[9] = 0xcefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0;
        proof[10] = 0xf9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5;
        proof[11] = 0xf8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892;
        proof[12] = 0x3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c;
        proof[13] = 0xc1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb;
        proof[14] = 0x5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc;
        proof[15] = 0xda7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2;
        proof[16] = 0x2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f;
        proof[17] = 0xe1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a;
        proof[18] = 0x5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0;
        proof[19] = 0xb46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0;
        proof[20] = 0xc65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2;
        proof[21] = 0xf4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9;
        proof[22] = 0x5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377;
        proof[23] = 0x4df84f40ae0c8229d0d6069e5c8f39a7c299677a09d367fc7b05e3bc380ee652;
        proof[24] = 0xcdc72595f74c7b1043d0e1ffbab734648c838dfb0527d971b602bc216c9619ef;
        proof[25] = 0x0abf5ac974a1ed57f4050aa510dd9c74f508277b39d7973bb2dfccc5eeb0618d;
        proof[26] = 0xb8cd74046ff337f0a7bf2c8e03e10f642c1886798d71806ab1e888d9e5ee87d0;
        proof[27] = 0x838c5655cb21c6cb83313b5a631175dff4963772cce9108188b34ac87c81c41e;
        proof[28] = 0x662ee4dd2dd7b2bc707961b1e646c4047669dcb6584f0d8d770daf5d7e7deb2e;
        proof[29] = 0x388ab20e2573d171a88108e79d820e98f26c0b84aa8b2f4aa4968dbb818ea322;
        proof[30] = 0x93237c50ba75ee485f4c22adf2f741400bdf8d6a9cc7df7ecae576221665d735;
        proof[31] = 0x8448818bb4ae4562849e949e17ac16e0be16688e156b5cf15e098c627c0056a9;

        JBMessageRoot memory root = JBMessageRoot({
            version: 1,
            token: bytes32(uint256(uint160(address(weth)))),
            amount: amount,
            remoteRoot: JBInboxTreeRoot({
                nonce: 1,
                root: MerkleLib.branchRoot({
                    _item: keccak256(abi.encode(uint256(10 ether), amount, bytes32(uint256(uint160(beneficiary))))),
                    _branch: proof,
                    _index: 0
                })
            }),
            sourceTotalSupply: 0,
            sourceCurrency: 0,
            sourceDecimals: 0,
            sourceSurplus: 0,
            sourceBalance: 0
        });

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(weth), amount: amount});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: REMOTE_CHAIN_SELECTOR,
            sender: abi.encode(address(sucker)),
            data: abi.encode(root),
            destTokenAmounts: tokenAmounts
        });

        vm.prank(ROUTER);
        sucker.ccipReceive(message);

        // WETH is NOT unwrapped — root.token is the WETH address, not NATIVE_TOKEN.
        assertEq(address(sucker).balance, 0, "no native ETH - WETH was correctly kept as ERC-20");
        assertEq(weth.balanceOf(address(sucker)), amount, "WETH remains available for claim settlement");
        assertEq(sucker.inboxRootOf(address(weth)), root.remoteRoot.root, "root is stored under the WETH key");
    }

    receive() external payable {}
}
