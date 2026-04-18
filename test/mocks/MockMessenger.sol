// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IOPMessenger} from "../../src/interfaces/IOPMessenger.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./ERC20Mock.sol";

// FROM
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/d3ff81b37f3c773b44dcaf5fda212c7176eef0e2/contracts/mocks/ERC20Mock.sol

contract MockMessenger is IOPMessenger {
    address public xDomainMessageSender;

    mapping(address _localToken => address _remoteToken) tokens;

    function sendMessage(address _target, bytes memory _message, uint32 _gasLimit) external payable {
        // Update the sender
        xDomainMessageSender = msg.sender;
        // Perform the 'crosschain' call
        (bool _success,) = _target.call{value: msg.value, gas: _gasLimit}(_message);
        require(_success);
    }

    function bridgeERC20To(
        address localToken,
        address remoteToken,
        address to,
        uint256 amount,
        uint32,
        bytes memory
    )
        external
    {
        // TODO: implement mock.
        assert(tokens[localToken] == remoteToken);
        // Mint the 'L1' tokens to the recipient.
        ERC20Mock(remoteToken).mint(to, amount);
    }

    function setRemoteToken(address localToken, address remoteToken) external {
        tokens[localToken] = remoteToken;
    }
}
