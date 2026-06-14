// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "../unit/peer_chain_state.t.sol";

/// @notice Regression for the peer-chain accounting hook fail-soft model. A data hook that returns a well-formed-ABI
/// but oversized `supply` must not brick outbound bridge sends. `_snapshotAccountsOf` adds the hook's `supply` to the
/// controller supply under checked arithmetic; an oversized value would overflow and revert the whole snapshot, so
/// `toRemote` / `syncAccountingData` could not run while the hook stayed active. The snapshot instead fails soft to the
/// baseline — the overflowing hook contributes no extra supply or contexts.
contract PeerHookSupplyOverflowFailsSoftTest is PeerChainStateTest {
    function test_overflowingPeerHookSupplyFailsSoftToBaseline() public {
        _setRemoteTokenMapping();

        vm.deal(address(sucker), 1 ether);
        sucker.test_insertIntoTree(1 ether, TOKEN, 1 ether, bytes32(uint256(uint160(address(0xBEEF)))));

        vm.mockCall(
            CONTROLLER,
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (PROJECT_ID)),
            abi.encode(uint256(1000 ether))
        );
        _mockSingleETHTerminal({ethBalance: 50 ether, ethSurplus: 30 ether});

        // A hook returning supply = type(uint256).max would overflow `localTotalSupply += additionalSupply`.
        PeerChainAdjustedAccountsHookMock overflowingHook = new PeerChainAdjustedAccountsHookMock({
            supply: type(uint256).max,
            surplus: 0,
            balance: 0,
            token: TOKEN,
            decimals: 18
        });
        _mockCurrentRulesetDataHook(address(overflowingHook));

        // The send completes (does not revert), and the local record carries the baseline controller supply with the
        // overflowing hook contribution dropped.
        sucker.toRemote(TOKEN);

        JBMessageRoot memory sent = sucker.test_getLastSentMessage();
        assertEq(sent.accounts[0].totalSupply, 1000 ether, "baseline supply used; overflowing hook dropped");
    }
}
