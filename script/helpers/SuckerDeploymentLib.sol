// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {SphinxConstants, NetworkInfo} from "@sphinx-labs/contracts/contracts/foundry/SphinxConstants.sol";

import {IJBSuckerRegistry} from "./../../src/interfaces/IJBSuckerRegistry.sol";
import {IJBSuckerDeployer} from "./../../src/interfaces/IJBSuckerDeployer.sol";

struct SuckerDeployment {
    IJBSuckerRegistry registry;
    /// @dev only those that are deployed on the requested chain contain an address.
    IJBSuckerDeployer optimismDeployer;
    IJBSuckerDeployer baseDeployer;
    IJBSuckerDeployer arbitrumDeployer;
}

library SuckerDeploymentLib {
    // Cheat code address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    // forge-lint: disable-next-line(screaming-snake-case-const)
    Vm internal constant vm = Vm(VM_ADDRESS);

    function getDeployment(string memory path) internal returns (SuckerDeployment memory deployment) {
        // Match the current chain ID to the Sphinx network name used in deployment artifacts.
        uint256 chainId = block.chainid;

        // `SphinxConstants` exposes Sphinx's supported chain ID to network name mapping.
        SphinxConstants sphinxConstants = new SphinxConstants();
        NetworkInfo[] memory networks = sphinxConstants.getNetworkInfoArray();

        for (uint256 _i; _i < networks.length; _i++) {
            if (networks[_i].chainId == chainId) {
                return getDeployment({path: path, networkName: networks[_i].name});
            }
        }

        revert("ChainID is not (currently) supported by Sphinx.");
    }

    function getDeployment(
        string memory path,
        string memory networkName
    )
        internal
        view
        returns (SuckerDeployment memory deployment)
    {
        // Is deployed on all (supported) chains.
        deployment.registry = IJBSuckerRegistry(
            _getDeploymentAddress({
                path: path, projectName: "nana-suckers-v6", networkName: networkName, contractName: "JBSuckerRegistry"
            })
        );

        bytes32 networkHash = keccak256(abi.encodePacked(networkName));
        bool isMainnet = networkHash == keccak256("ethereum") || networkHash == keccak256("ethereum_sepolia");
        bool isOp = networkHash == keccak256("optimism") || networkHash == keccak256("optimism_sepolia");
        bool isBase = networkHash == keccak256("base") || networkHash == keccak256("base_sepolia");
        bool isArb = networkHash == keccak256("arbitrum") || networkHash == keccak256("arbitrum_sepolia");

        if (isMainnet || isOp) {
            deployment.optimismDeployer = IJBSuckerDeployer(
                _getDeploymentAddress({
                    path: path,
                    projectName: "nana-suckers-v6",
                    networkName: networkName,
                    contractName: "JBOptimismSuckerDeployer"
                })
            );
        }

        if (isMainnet || isBase) {
            deployment.baseDeployer = IJBSuckerDeployer(
                _getDeploymentAddress({
                    path: path,
                    projectName: "nana-suckers-v6",
                    networkName: networkName,
                    contractName: "JBBaseSuckerDeployer"
                })
            );
        }

        if (isMainnet || isArb) {
            deployment.arbitrumDeployer = IJBSuckerDeployer(
                _getDeploymentAddress({
                    path: path,
                    projectName: "nana-suckers-v6",
                    networkName: networkName,
                    contractName: "JBArbitrumSuckerDeployer"
                })
            );
        }
    }

    /// @notice Get the address of a contract that was deployed by the Deploy script.
    /// @dev Reverts if the contract was not found.
    /// @param path The path to the deployment file.
    /// @param contractName The name of the contract to get the address of.
    /// @return The address of the contract.
    function _getDeploymentAddress(
        string memory path,
        string memory projectName,
        string memory networkName,
        string memory contractName
    )
        internal
        view
        returns (address)
    {
        string memory deploymentJson =
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.readFile(string.concat(path, projectName, "/", networkName, "/", contractName, ".json"));
        return stdJson.readAddress({json: deploymentJson, key: ".address"});
    }
}
