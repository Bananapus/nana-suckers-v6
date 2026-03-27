// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBSuckerDeployer} from "../interfaces/IJBSuckerDeployer.sol";
import {JBTokenMapping} from "./JBTokenMapping.sol";

/// @custom:member deployer The deployer to use.
/// @custom:member mappings The token mappings to use.
// forge-lint: disable-next-line(pascal-case-struct)
struct JBSuckerDeployerConfig {
    IJBSuckerDeployer deployer;
    JBTokenMapping[] mappings;
}
