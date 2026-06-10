// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBPeerChainAdjustedAccountsLib} from "../../src/libraries/JBPeerChainAdjustedAccountsLib.sol";
import {JBSourceContext} from "../../src/structs/JBSourceContext.sol";

contract PeerChainAdjustedAccountsLibHarness {
    function decode(bytes memory data) external pure returns (uint256 supply, JBSourceContext[] memory contexts) {
        return JBPeerChainAdjustedAccountsLib.decode(data);
    }
}

contract PeerChainAdjustedAccountsLibTest is Test {
    PeerChainAdjustedAccountsLibHarness internal harness;

    function setUp() public {
        harness = new PeerChainAdjustedAccountsLibHarness();
    }

    function test_decodeValidPeerChainAdjustedAccountsReturn() public view {
        JBSourceContext[] memory encodedContexts = new JBSourceContext[](1);
        encodedContexts[0] = JBSourceContext({
            token: bytes32(uint256(uint160(address(0xBEEF)))), decimals: 18, surplus: 10 ether, balance: 11 ether
        });

        (uint256 supply, JBSourceContext[] memory contexts) =
            harness.decode(abi.encode(uint256(100 ether), encodedContexts));

        assertEq(supply, 100 ether);
        assertEq(contexts.length, 1);
        assertEq(contexts[0].token, bytes32(uint256(uint160(address(0xBEEF)))));
        assertEq(contexts[0].decimals, 18);
        assertEq(contexts[0].surplus, 10 ether);
        assertEq(contexts[0].balance, 11 ether);
    }

    function test_decodeReturnsZeroForOutOfRangeContextField() public view {
        bytes memory data = abi.encode(
            uint256(100 ether),
            uint256(64),
            uint256(1),
            bytes32(uint256(uint160(address(0xBEEF)))),
            uint256(type(uint8).max) + 1,
            uint256(10 ether),
            uint256(11 ether)
        );

        (uint256 supply, JBSourceContext[] memory contexts) = harness.decode(data);

        assertEq(supply, 0);
        assertEq(contexts.length, 0);
    }

    function test_decodeReturnsZeroForShortReturnData() public view {
        (uint256 supply, JBSourceContext[] memory contexts) = harness.decode(hex"1234");

        assertEq(supply, 0);
        assertEq(contexts.length, 0);
    }

    function test_decodeReturnsZeroWhenContextCountExceedsPayload() public view {
        bytes memory data = abi.encode(uint256(100 ether), uint256(64), uint256(1));

        (uint256 supply, JBSourceContext[] memory contexts) = harness.decode(data);

        assertEq(supply, 0);
        assertEq(contexts.length, 0);
    }

    function test_decodeReturnsZeroWhenOffsetPointsIntoHead() public view {
        bytes memory data = abi.encode(uint256(100 ether), uint256(32), uint256(0));

        (uint256 supply, JBSourceContext[] memory contexts) = harness.decode(data);

        assertEq(supply, 0);
        assertEq(contexts.length, 0);
    }
}
