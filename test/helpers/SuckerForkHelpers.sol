// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {CCIPHelper} from "../../src/libraries/CCIPHelper.sol";

/// @notice Shared helpers for sucker fork tests.
/// Consolidates `_launchProject()`, metadata initialization, LINK/CCIP registration,
/// and token etching that were duplicated across 4+ fork test base classes.
abstract contract SuckerForkHelpers is TestBaseWorkflow {
    JBRulesetMetadata _metadata;

    /// @dev Override to change the terminal token (default: native ETH).
    function _terminalToken() internal view virtual returns (address) {
        return JBConstants.NATIVE_TOKEN;
    }

    /// @notice Initialize the shared JBRulesetMetadata used by all fork tests.
    function _initMetadata() internal {
        _metadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT / 2,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }

    /// @notice Launch a project that accepts `_terminalToken()`.
    function _launchProject() internal {
        address token = _terminalToken();

        // Ensure baseCurrency matches the terminal token so no price feed is needed.
        _metadata.baseCurrency = uint32(uint160(token));

        JBCurrencyAmount[] memory surplusAllowances = new JBCurrencyAmount[](1);
        surplusAllowances[0] = JBCurrencyAmount({amount: 5 * 10 ** 18, currency: uint32(uint160(token))});

        JBFundAccessLimitGroup[] memory fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: token,
            payoutLimits: new JBCurrencyAmount[](0),
            surplusAllowances: surplusAllowances
        });

        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0].mustStartAtOrAfter = 0;
        rulesetConfigurations[0].duration = 0;
        rulesetConfigurations[0].weight = 1000 * 10 ** 18;
        rulesetConfigurations[0].weightCutPercent = 0;
        rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigurations[0].metadata = _metadata;
        rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigurations[0].fundAccessLimitGroups = fundAccessLimitGroup;

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        jbController().launchProjectFor({
            owner: multisig(),
            projectUri: "fork-test",
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });
    }

    /// @dev Deploy mock ERC20 at the terminal token address if it has no code on the current fork.
    /// Etches WETH bytecode as a minimal ERC20 substitute and sets 18 decimals.
    function _ensureTerminalTokenExists() internal {
        address token = _terminalToken();
        if (token != JBConstants.NATIVE_TOKEN && token.code.length == 0) {
            vm.etch(token, CCIPHelper.wethOfChain(block.chainid).code);
            vm.store(token, bytes32(uint256(2)), bytes32(uint256(18)));
        }
    }

    /// @notice LINK token address per mainnet chain.
    function _linkTokenOf(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        if (chainId == 42_161) return 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
        if (chainId == 10) return 0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6;
        if (chainId == 8453) return 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
        if (chainId == 4217) return 0x15C03488B29e27d62BAf10E30b0c474bf60E0264;
        revert("Unsupported chain for LINK token");
    }

    /// @notice Register mainnet network details for CCIPLocalSimulatorFork.
    function _registerMainnetDetails(CCIPLocalSimulatorFork ccipSim, uint256 chainId) internal {
        Register.NetworkDetails memory details = Register.NetworkDetails({
            chainSelector: CCIPHelper.selectorOfChain(chainId),
            routerAddress: CCIPHelper.routerOfChain(chainId),
            linkAddress: _linkTokenOf(chainId),
            wrappedNativeAddress: CCIPHelper.wethOfChain(chainId),
            ccipBnMAddress: address(0),
            ccipLnMAddress: address(0),
            rmnProxyAddress: address(0),
            registryModuleOwnerCustomAddress: address(0),
            tokenAdminRegistryAddress: address(0)
        });
        ccipSim.setNetworkDetails(chainId, details);
    }
}
