// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/JBOptimismSucker.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/deployers/JBOptimismSuckerDeployer.sol";

import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";

import {JBSuckerRegistry} from "./../../src/JBSuckerRegistry.sol";

contract RegistryUnitTest is Test {
    /// @dev Valuation never runs in this deploy-only test, so any non-zero prices address suffices.
    address internal constant PRICES = address(0xA4);

    function testDeployNoProjectCheck() public {
        JBProjects _projects = new JBProjects(msg.sender, address(0), address(0));
        JBPermissions _permissions = new JBPermissions(address(0));
        JBDirectory _directory = new JBDirectory(_permissions, _projects, address(100));
        new JBSuckerRegistry(_directory, _permissions, IJBPrices(PRICES), address(100), address(0));
    }
}
