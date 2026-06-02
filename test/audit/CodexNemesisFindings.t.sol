// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBSucker} from "../../src/JBSucker.sol";
import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {IJBSucker} from "../../src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "../../src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {JBInboxTreeRoot} from "../../src/structs/JBInboxTreeRoot.sol";
import {JBMessageRoot} from "../../src/structs/JBMessageRoot.sol";
import {JBPeerChainContext} from "../../src/structs/JBPeerChainContext.sol";
import {JBPeerChainValue} from "../../src/structs/JBPeerChainValue.sol";
import {JBRemoteToken} from "../../src/structs/JBRemoteToken.sol";
import {JBSourceContext} from "../../src/structs/JBSourceContext.sol";
import {JBSuckerDeployerConfig} from "../../src/structs/JBSuckerDeployerConfig.sol";
import {JBTokenMapping} from "../../src/structs/JBTokenMapping.sol";

contract CodexNemesisSuckerHarness is JBSucker {
    uint256 internal _peerChainId = 10;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens
    )
        JBSucker(directory, permissions, tokens, 1, IJBSuckerRegistry(address(1)), address(0))
    {}

    function test_setPeerChainId(uint256 chainId) external {
        _peerChainId = chainId;
    }

    function test_acceptSnapshot(uint256 supply, JBSourceContext[] memory contexts, uint256 freshness) external {
        JBMessageRoot memory root = JBMessageRoot({
            version: MESSAGE_VERSION,
            token: bytes32(uint256(uint160(address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)))),
            amount: 0,
            remoteRoot: JBInboxTreeRoot({nonce: uint64(freshness), root: bytes32(uint256(0xBEEF))}),
            sourceTotalSupply: supply,
            sourceContexts: contexts,
            sourceTimestamp: freshness
        });

        this.fromRemote(root);
    }

    function peerChainId() public view override returns (uint256) {
        return _peerChainId;
    }

    function _isRemotePeer(address) internal pure override returns (bool) {
        return true;
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
}

contract CodexNemesisMockDeployer is IJBSuckerDeployer {
    IJBSucker internal _sucker;

    function setSucker(IJBSucker sucker) external {
        _sucker = sucker;
    }

    function DIRECTORY() external pure returns (IJBDirectory) {
        return IJBDirectory(address(0));
    }

    function LAYER_SPECIFIC_CONFIGURATOR() external pure returns (address) {
        return address(0);
    }

    function TOKENS() external pure returns (IJBTokens) {
        return IJBTokens(address(0));
    }

    function isSucker(address sucker) external view returns (bool) {
        return sucker == address(_sucker);
    }

    function createForSender(uint256, bytes32, bytes32) external view returns (IJBSucker) {
        return _sucker;
    }
}

contract CodexNemesisRevertingPrices {
    function pricePerUnitOf(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        revert("NO_FEED");
    }
}

contract CodexNemesisFindingsTest is Test {
    address internal constant DIRECTORY = address(0xD1);
    address internal constant PERMISSIONS = address(0xD2);
    address internal constant PROJECTS = address(0xD3);
    address internal constant TOKENS = address(0xD4);
    address internal constant TERMINAL = address(0xD5);

    uint256 internal constant PROJECT_ID = 1;
    uint32 internal constant USD = 2;

    JBSuckerRegistry internal registry;
    CodexNemesisSuckerHarness internal singleton;

    function setUp() public {
        vm.mockCall(DIRECTORY, abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(PROJECTS));
        vm.mockCall(PROJECTS, abi.encodeWithSelector(IERC721.ownerOf.selector, PROJECT_ID), abi.encode(address(this)));
        vm.mockCall(PERMISSIONS, abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true));

        registry = new JBSuckerRegistry({
            directory: IJBDirectory(DIRECTORY),
            permissions: IJBPermissions(PERMISSIONS),
            prices: IJBPrices(address(new CodexNemesisRevertingPrices())),
            initialOwner: address(this),
            trustedForwarder: address(0)
        });

        singleton =
            new CodexNemesisSuckerHarness(IJBDirectory(DIRECTORY), IJBPermissions(PERMISSIONS), IJBTokens(TOKENS));
    }

    // Regression for the mixed-decimal merge fix: same-currency source contexts that carry DIFFERENT decimals must
    // NOT be summed under one decimal scale (their raw amounts are on different scales). They are kept as separate
    // per-(currency, decimals) entries so the registry can decimal-adjust each independently before summing.
    function test_codexNemesis_mixedDecimalsSameCurrencyAreKeptSeparateAndValuedCorrectly() external {
        CodexNemesisSuckerHarness sucker = _clone("mixed-decimals");

        address usdc = makeAddr("USDC");
        address dai = makeAddr("DAI");
        _mockAuthoritativeContext(usdc, 6, USD);
        _mockAuthoritativeContext(dai, 18, USD);

        JBSourceContext[] memory contexts = new JBSourceContext[](2);
        contexts[0] = _ctx(usdc, 6, 1_000_000, 0); // 1 USD with 6 decimals.
        contexts[1] = _ctx(dai, 18, 1 ether, 0); // 1 USD with 18 decimals.

        sucker.test_acceptSnapshot({supply: 0, contexts: contexts, freshness: 1});

        (JBPeerChainContext[] memory stored,,) = sucker.peerChainContextsOf();
        // The fix: the two mixed-decimal contexts are NOT collapsed; each keeps its own decimals and raw amount.
        assertEq(stored.length, 2, "mixed-decimal same-currency contexts are kept separate, not collapsed");
        assertEq(stored[0].currency, USD, "first stored under USD");
        assertEq(stored[0].decimals, 6, "first keeps its 6 decimals");
        assertEq(stored[0].surplus, 1_000_000, "first holds only the 6-decimal raw amount");
        assertEq(stored[1].currency, USD, "second stored under USD");
        assertEq(stored[1].decimals, 18, "second keeps its 18 decimals");
        assertEq(stored[1].surplus, 1 ether, "second holds only the 18-decimal raw amount");

        // The registry now decimal-adjusts each entry to the target before summing, yielding the correct 2 USD.
        JBPeerChainValue memory valued = registry.remoteSurplusOf(address(sucker), PROJECT_ID, USD, 6);
        assertEq(valued.value, 2_000_000, "1 USD (6dec) + 1 USD (18dec adjusted to 6dec) = 2 USD at 6 decimals");
        assertEq(valued.value, _normalizedTwoUsd(), "matches the correct normalized 2 USD at 6 decimals");
    }

    function test_codexNemesis_missingPriceFeedDropsSurplusButKeepsSupply() external {
        CodexNemesisSuckerHarness sucker = _clone("missing-feed");
        sucker.test_setPeerChainId(42_161);

        address foreignToken = makeAddr("FOREIGN_TOKEN");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 foreignCurrency = uint32(uint160(foreignToken));
        vm.mockCall(
            DIRECTORY,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, foreignToken)),
            abi.encode(address(0))
        );

        JBSourceContext[] memory contexts = new JBSourceContext[](1);
        contexts[0] = _ctx(foreignToken, 18, 500 ether, 0);
        sucker.test_acceptSnapshot({supply: 1000 ether, contexts: contexts, freshness: 1});

        CodexNemesisMockDeployer deployer = new CodexNemesisMockDeployer();
        deployer.setSucker(IJBSucker(address(sucker)));
        registry.allowSuckerDeployer(address(deployer));

        JBSuckerDeployerConfig[] memory configs = new JBSuckerDeployerConfig[](1);
        configs[0] = JBSuckerDeployerConfig({deployer: deployer, peer: bytes32(0), mappings: new JBTokenMapping[](0)});
        registry.deploySuckersFor({projectId: PROJECT_ID, salt: keccak256("missing-feed"), configurations: configs});

        assertEq(registry.remoteTotalSupplyOf(PROJECT_ID), 1000 ether, "supply remains included");
        assertEq(
            registry.totalRemoteSurplusOf(PROJECT_ID, USD, 18),
            0,
            "surplus is skipped when the cross-currency feed reverts"
        );
        assertTrue(foreignCurrency != USD, "test must force a price lookup");
    }

    function _clone(bytes memory salt) internal returns (CodexNemesisSuckerHarness clone) {
        clone = CodexNemesisSuckerHarness(
            payable(address(LibClone.cloneDeterministic(address(singleton), keccak256(salt))))
        );
        clone.initialize(PROJECT_ID);
    }

    function _ctx(
        address token,
        uint8 decimals,
        uint128 surplus,
        uint128 balance
    )
        internal
        pure
        returns (JBSourceContext memory)
    {
        return JBSourceContext({
            token: bytes32(uint256(uint160(token))), decimals: decimals, surplus: surplus, balance: balance
        });
    }

    function _mockAuthoritativeContext(address token, uint8 decimals, uint32 currency) internal {
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, token)), abi.encode(TERMINAL)
        );
        vm.mockCall(
            TERMINAL,
            abi.encodeCall(IJBTerminal.accountingContextForTokenOf, (PROJECT_ID, token)),
            abi.encode(JBAccountingContext({token: token, decimals: decimals, currency: currency}))
        );
    }

    function _normalizedTwoUsd() internal pure returns (uint256) {
        return 2_000_000;
    }
}
