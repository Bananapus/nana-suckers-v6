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

import {JBSuckerRegistry} from "./../../src/JBSuckerRegistry.sol";

contract RegistryUnitTest is Test {
    function testDeployNoProjectCheck() public {
        JBProjects _projects = new JBProjects(msg.sender, address(0), address(0));
        JBPermissions _permissions = new JBPermissions(address(0));
        JBDirectory _directory = new JBDirectory(_permissions, _projects, address(100));
        new JBSuckerRegistry(_directory, _permissions, address(100), address(0));
    }
}
