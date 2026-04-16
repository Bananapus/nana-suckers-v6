// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {JBSuckerRegistry} from "../../src/JBSuckerRegistry.sol";
import {JBSuckerTerminal} from "../../src/JBSuckerTerminal.sol";
import {ICCIPRouter} from "../../src/interfaces/ICCIPRouter.sol";
import {IJBSuckerRegistry} from "../../src/interfaces/IJBSuckerRegistry.sol";
import {IJBSuckerTerminal} from "../../src/interfaces/IJBSuckerTerminal.sol";
import {JBProxyConfig} from "../../src/structs/JBProxyConfig.sol";

contract CodexProxySquattingTest is Test, TestBaseWorkflow, IERC721Receiver {
    JBSuckerRegistry internal registry;
    JBSuckerTerminal internal terminal;
    uint256 internal realProjectId;

    address internal attacker = address(0xBEEF);

    function setUp() public override {
        super.setUp();

        registry = new JBSuckerRegistry(jbDirectory(), jbPermissions(), address(this), address(0));

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesets = new JBRulesetConfig[](1);
        rulesets[0].mustStartAtOrAfter = 0;
        rulesets[0].duration = 0;
        rulesets[0].weight = 1000 * 10 ** 18;
        rulesets[0].weightCutPercent = 0;
        rulesets[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesets[0].metadata = metadata;
        rulesets[0].splitGroups = new JBSplitGroup[](0);
        rulesets[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](1);
        terminals[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: contexts});

        realProjectId = jbController()
            .launchProjectFor({
                owner: address(this),
                projectUri: "real-project",
                rulesetConfigurations: rulesets,
                terminalConfigurations: terminals,
                memo: ""
            });

        jbController().deployERC20For(realProjectId, "RealToken", "REAL", bytes32(0));

        terminal = new JBSuckerTerminal({
            controller: IJBController(address(jbController())),
            directory: IJBDirectory(address(jbDirectory())),
            multiTerminal: IJBTerminal(address(jbMultiTerminal())),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            tokens: IJBTokens(address(jbTokens())),
            ccipRouter: ICCIPRouter(address(0)),
            remoteChainSelector: 0,
            peer: address(0),
            routerTerminal: IJBTerminal(address(0))
        });
    }

    /// @notice Verify the squatting attack is now blocked: attacker can't create proxy on home chain.
    function test_squattingBlockedOnHomeChain() external {
        // Attacker tries to squat the proxy — reverts because they're not the project owner.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(JBSuckerTerminal.JBSuckerTerminal_Unauthorized.selector));
        terminal.createProxy(realProjectId, 0, "FakeProxy", "FAKE", bytes32("bad"));

        // Owner can still create the proxy.
        uint256 proxyProjectId = terminal.createProxy(realProjectId, 0, "CorrectProxy", "CPROXY", bytes32("good"));
        assertEq(
            terminal.proxyProjectIdOf(realProjectId, address(this)), proxyProjectId, "owner's proxy should be stored"
        );

        // Attacker's slot is empty — their squatting attempt never landed.
        assertEq(terminal.proxyProjectIdOf(realProjectId, attacker), 0, "attacker's slot should be empty");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
