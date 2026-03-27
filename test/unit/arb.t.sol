// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

contract ArbitrumTest is Test {
    uint256 maxFeePerGas = 0.2 gwei;

    function setUp() public {}

    /// Pulled from ETH Arb Inbox impl: https://etherscan.io/address/0x5aed5f8a1e3607476f1f81c3d8fe126deb0afe94#code
    function calculateRetryableSubmissionFee(uint256 dataLength, uint256 baseFee) public view returns (uint256) {
        // Use current block basefee if baseFee parameter is 0
        return (1400 + 6 * dataLength) * (baseFee == 0 ? block.basefee : baseFee);
    }

    function testMaxSubmissionCostZeroDataLength() public view {
        uint256 maxSubmissionCostERC20 = calculateRetryableSubmissionFee({dataLength: 0, baseFee: maxFeePerGas});

        assertGt(maxSubmissionCostERC20, 0);
        assertEq(maxSubmissionCostERC20, maxFeePerGas * 1400);
    }

    function testERC20CallDataLength() public pure {
        assertEq(abi.encode(uint256(0), bytes("")).length, 96);
    }
}
