// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {CoreDeployment, CoreDeploymentLib} from "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";

import {JBArbitrumSucker} from "../src/JBArbitrumSucker.sol";
import {JBBaseSucker} from "../src/JBBaseSucker.sol";
import {JBCCIPSucker} from "../src/JBCCIPSucker.sol";
import {JBOptimismSucker} from "../src/JBOptimismSucker.sol";
import {JBSuckerRegistry} from "../src/JBSuckerRegistry.sol";
import {IJBSuckerRegistry} from "../src/interfaces/IJBSuckerRegistry.sol";
import {JBArbitrumSuckerDeployer} from "../src/deployers/JBArbitrumSuckerDeployer.sol";
import {JBBaseSuckerDeployer} from "../src/deployers/JBBaseSuckerDeployer.sol";
import {JBCCIPSuckerDeployer} from "../src/deployers/JBCCIPSuckerDeployer.sol";
import {JBOptimismSuckerDeployer} from "../src/deployers/JBOptimismSuckerDeployer.sol";
import {JBLayer} from "../src/enums/JBLayer.sol";
import {IArbGatewayRouter} from "../src/interfaces/IArbGatewayRouter.sol";
import {ICCIPRouter} from "../src/interfaces/ICCIPRouter.sol";
import {IOPMessenger} from "../src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "../src/interfaces/IOPStandardBridge.sol";
import {ARBAddresses} from "../src/libraries/ARBAddresses.sol";
import {CCIPHelper} from "../src/libraries/CCIPHelper.sol";

contract DeployScript is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;
    /// @notice Tracks the addresses of deployers that will get pre-approved.
    address[] private preApprovedDeployers;
    address private trustedForwarder;

    /// @notice the nonces that are used to deploy the contracts.
    bytes32 private constant _OP_SALT = "_SUCKER_ETH_OP_V6_";
    bytes32 private constant _BASE_SALT = "_SUCKER_ETH_BASE_V6_";
    bytes32 private constant _ARB_SALT = "_SUCKER_ETH_ARB_V6_";
    bytes32 private constant _ARB_BASE_SALT = "_SUCKER_ARB_BASE_V6_";
    bytes32 private constant _ARB_OP_SALT = "_SUCKER_ARB_OP_V6_";
    bytes32 private constant _OP_BASE_SALT = "_SUCKER_OP_BASE_V6_";
    bytes32 private constant _TEMPO_SALT = "_SUCKER_ETH_TEMPO_V6_";
    IJBSuckerRegistry private registry;
    bytes32 private constant _REGISTRY_SALT = "REGISTRYV6";

    function configureSphinx() public override {
        // Safe owners and threshold are resolved by the Sphinx project config.
        sphinxConfig.projectName = "nana-suckers-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum", "tempo"];
        sphinxConfig.testnets =
            ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia", "tempo_moderato"];
    }

    function run() public {
        // Get the deployment addresses for the nana CORE for this chain.
        // We want to do this outside of the `sphinx` modifier.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );

        // We use the same trusted forwarder as the core deployment.
        trustedForwarder = core.permissions.trustedForwarder();

        // Perform the deployment transactions.
        deploy();
    }

    /// @dev Ownership transfer ordering: This function deploys multiple contracts and performs configuration in a
    /// specific sequence. If the deployment is interrupted (e.g., by an out-of-gas error or a revert in one of the
    /// deployer steps), intermediate states are possible where some deployers are created but not yet approved in the
    /// registry, or the registry's ownership has not yet been transferred. When using Sphinx for deployment, the
    /// entire `deploy()` function executes atomically within a single Gnosis Safe transaction, so partial deployment
    /// states are not possible on-chain. However, if this script is used outside of Sphinx (e.g., via `forge script`
    /// with `--broadcast`), each internal call would be a separate transaction, and an interruption could leave the
    /// system in a partially configured state requiring manual intervention.
    function deploy() public sphinx {
        // Deploy the registry first — singletons need its address as an immutable.
        // If the registry is already deployed we don't have to deploy it
        // (and we can't add more pre_approved deployers etc.)
        bool registryAlreadyDeployed = _isDeployed({
            salt: _REGISTRY_SALT,
            creationCode: type(JBSuckerRegistry).creationCode,
            arguments: abi.encode(core.directory, core.permissions, safeAddress(), trustedForwarder)
        });

        if (!registryAlreadyDeployed) {
            registry = IJBSuckerRegistry(
                address(
                    new JBSuckerRegistry{salt: _REGISTRY_SALT}({
                        directory: core.directory,
                        permissions: core.permissions,
                        initialOwner: safeAddress(),
                        trustedForwarder: trustedForwarder
                    })
                )
            );
        } else {
            // Compute the existing registry address.
            registry = IJBSuckerRegistry(
                vm.computeCreate2Address({
                    salt: _REGISTRY_SALT,
                    initCodeHash: keccak256(
                        abi.encodePacked(
                            type(JBSuckerRegistry).creationCode,
                            abi.encode(core.directory, core.permissions, safeAddress(), trustedForwarder)
                        )
                    ),
                    deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
                })
            );
        }

        // Perform the deployments for this chain.
        _optimismSucker();
        _baseSucker();
        _arbitrumSucker();
        _ccipSucker();

        // Synchronize any deployers discovered or resumed during this run into the registry as long as the
        // current safe still controls it. This keeps partial-deployment recovery idempotent.
        if (preApprovedDeployers.length != 0 && Ownable(address(registry)).owner() == safeAddress()) {
            registry.allowSuckerDeployers(preApprovedDeployers);
        }

        if (!registryAlreadyDeployed) {
            // Check what safe this is, if this is the same one as the fee-project owner, then we do not need to
            // transfer. If its not then we transfer to the fee-project safe.
            // NOTE: If this is ran after the configuration of the fee-project, this would transfer it to the
            // REVNET_DEPLOYER. which is *NOT* what we want to happen. In our regular deployment procedure this should
            // never happen though.
            address feeProjectOwner = core.projects.ownerOf(1);
            if (feeProjectOwner != address(0) && feeProjectOwner != safeAddress()) {
                // Transfer ownership to JBDAO.
                Ownable(address(registry)).transferOwnership(feeProjectOwner);
            }
        }
    }

    /// @notice handles the deployment and configuration regarding optimism (this also includes the mainnet
    /// configuration).
    function _optimismSucker() internal {
        // Check if the deployer already exists at the CREATE2 address.
        bool alreadyDeployed = _isDeployed({
            salt: _OP_SALT,
            creationCode: type(JBOptimismSuckerDeployer).creationCode,
            arguments: abi.encode(core.directory, core.permissions, core.tokens, safeAddress(), trustedForwarder)
        });

        // If already deployed, verify the full pipeline completed (singleton + registry allowlisting).
        // Only skip if everything is fully configured; otherwise fall through to resume.
        if (alreadyDeployed) {
            address deployerAddr = _computeAddress({
                salt: _OP_SALT,
                creationCode: type(JBOptimismSuckerDeployer).creationCode,
                arguments: abi.encode(core.directory, core.permissions, core.tokens, safeAddress(), trustedForwarder)
            });
            bool singletonSet = address(JBOptimismSuckerDeployer(deployerAddr).singleton()) != address(0);
            bool registryAllowed = registry.suckerDeployerIsAllowed(deployerAddr);
            if (singletonSet && registryAllowed) return;
        }

        // Check if we should do the L1 portion.
        // ETH Mainnet and ETH Sepolia.
        if (block.chainid == 1 || block.chainid == 11_155_111) {
            JBOptimismSuckerDeployer _opDeployer;

            if (alreadyDeployed) {
                // Resume from a partial deployment — deployer exists, recompute its address.
                _opDeployer = JBOptimismSuckerDeployer(
                    _computeAddress({
                        salt: _OP_SALT,
                        creationCode: type(JBOptimismSuckerDeployer).creationCode,
                        arguments: abi.encode(
                            core.directory, core.permissions, core.tokens, safeAddress(), trustedForwarder
                        )
                    })
                );
            } else {
                _opDeployer = new JBOptimismSuckerDeployer{salt: _OP_SALT}({
                    directory: core.directory,
                    permissions: core.permissions,
                    tokens: core.tokens,
                    configurator: safeAddress(),
                    trustedForwarder: trustedForwarder
                });
            }

            if (address(_opDeployer.opMessenger()) == address(0)) {
                _opDeployer.setChainSpecificConstants({
                    messenger: IOPMessenger(
                        block.chainid == 1
                            ? address(0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1)
                            : address(0x58Cc85b8D04EA49cC6DBd3CbFFd00B4B8D6cb3ef)
                    ),
                    bridge: IOPStandardBridge(
                        block.chainid == 1
                            ? address(0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1)
                            : address(0xFBb0621E0B23b5478B630BD55a5f21f67730B0F1)
                    )
                });
            }

            if (address(_opDeployer.singleton()) == address(0)) {
                // Deploy the singleton instance.
                JBOptimismSucker _singleton = new JBOptimismSucker{salt: _OP_SALT}({
                    deployer: _opDeployer,
                    directory: core.directory,
                    permissions: core.permissions,
                    prices: core.prices,
                    tokens: core.tokens,
                    feeProjectId: 1,
                    registry: registry,
                    trustedForwarder: trustedForwarder
                });

                // Configure the deployer to use the singleton instance.
                _opDeployer.configureSingleton(_singleton);
            }

            preApprovedDeployers.push(address(_opDeployer));
        }

        // Check if we should do the L2 portion.
        // OP & OP Sepolia.
        if (block.chainid == 10 || block.chainid == 11_155_420) {
            JBOptimismSuckerDeployer _opDeployer;

            if (alreadyDeployed) {
                _opDeployer = JBOptimismSuckerDeployer(
                    _computeAddress({
                        salt: _OP_SALT,
                        creationCode: type(JBOptimismSuckerDeployer).creationCode,
                        arguments: abi.encode(
                            core.directory, core.permissions, core.tokens, safeAddress(), trustedForwarder
                        )
                    })
                );
            } else {
                _opDeployer = new JBOptimismSuckerDeployer{salt: _OP_SALT}({
                    directory: core.directory,
                    permissions: core.permissions,
                    tokens: core.tokens,
                    configurator: safeAddress(),
                    trustedForwarder: trustedForwarder
                });
            }

            if (address(_opDeployer.opMessenger()) == address(0)) {
                _opDeployer.setChainSpecificConstants({
                    messenger: IOPMessenger(0x4200000000000000000000000000000000000007),
                    bridge: IOPStandardBridge(0x4200000000000000000000000000000000000010)
                });
            }

            if (address(_opDeployer.singleton()) == address(0)) {
                // Deploy the singleton instance.
                JBOptimismSucker _singleton = new JBOptimismSucker{salt: _OP_SALT}({
                    deployer: _opDeployer,
                    directory: core.directory,
                    permissions: core.permissions,
                    prices: core.prices,
                    tokens: core.tokens,
                    feeProjectId: 1,
                    registry: registry,
                    trustedForwarder: trustedForwarder
                });

                // Configure the deployer to use the singleton instance.
                _opDeployer.configureSingleton(_singleton);
            }

            preApprovedDeployers.push(address(_opDeployer));
        }
    }

    /// @notice handles the deployment and configuration regarding base (this also includes the mainnet configuration).
    function _baseSucker() internal {
        // Check if the deployer already exists at the CREATE2 address.
        bool alreadyDeployed = _isDeployed({
            salt: _BASE_SALT,
            creationCode: type(JBBaseSuckerDeployer).creationCode,
            arguments: abi.encode(core.directory, core.permissions, core.tokens, safeAddress(), trustedForwarder)
        });

        // If already deployed, verify the full pipeline completed (singleton + registry allowlisting).
        // Only skip if everything is fully configured; otherwise fall through to resume.
        if (alreadyDeployed) {
            address deployerAddr = _computeAddress({
                salt: _BASE_SALT,
                creationCode: type(JBBaseSuckerDeployer).creationCode,
                arguments: abi.encode(core.directory, core.permissions, core.tokens, safeAddress(), trustedForwarder)
            });
            bool singletonSet = address(JBBaseSuckerDeployer(deployerAddr).singleton()) != address(0);
            bool registryAllowed = registry.suckerDeployerIsAllowed(deployerAddr);
            if (singletonSet && registryAllowed) return;
        }

        // Check if we should do the L1 portion.
        // ETH Mainnet and ETH Sepolia.
        if (block.chainid == 1 || block.chainid == 11_155_111) {
            JBBaseSuckerDeployer _baseDeployer;

            if (alreadyDeployed) {
                _baseDeployer = JBBaseSuckerDeployer(
                    _computeAddress({
                        salt: _BASE_SALT,
                        creationCode: type(JBBaseSuckerDeployer).creationCode,
                        arguments: abi.encode(
                            core.directory, core.permissions, core.tokens, safeAddress(), trustedForwarder
                        )
                    })
                );
            } else {
                _baseDeployer = new JBBaseSuckerDeployer{salt: _BASE_SALT}({
                    directory: core.directory,
                    permissions: core.permissions,
                    tokens: core.tokens,
                    configurator: safeAddress(),
                    trustedForwarder: trustedForwarder
                });
            }

            if (address(_baseDeployer.opMessenger()) == address(0)) {
                _baseDeployer.setChainSpecificConstants({
                    messenger: IOPMessenger(
                        block.chainid == 1
                            ? address(0x866E82a600A1414e583f7F13623F1aC5d58b0Afa)
                            : address(0xC34855F4De64F1840e5686e64278da901e261f20)
                    ),
                    bridge: IOPStandardBridge(
                        block.chainid == 1
                            ? address(0x3154Cf16ccdb4C6d922629664174b904d80F2C35)
                            : address(0xfd0Bf71F60660E2f608ed56e1659C450eB113120)
                    )
                });
            }

            if (address(_baseDeployer.singleton()) == address(0)) {
                // Deploy the singleton instance.
                JBBaseSucker _singleton = new JBBaseSucker{salt: _BASE_SALT}({
                    deployer: _baseDeployer,
                    directory: core.directory,
                    permissions: core.permissions,
                    prices: core.prices,
                    tokens: core.tokens,
                    feeProjectId: 1,
                    registry: registry,
                    trustedForwarder: trustedForwarder
                });

                // Configure the deployer to use the singleton instance.
                _baseDeployer.configureSingleton(_singleton);
            }

            preApprovedDeployers.push(address(_baseDeployer));
        }

        // Check if we should do the L2 portion.
        // BASE & BASE Sepolia.
        if (block.chainid == 8453 || block.chainid == 84_532) {
            JBBaseSuckerDeployer _baseDeployer;

            if (alreadyDeployed) {
                _baseDeployer = JBBaseSuckerDeployer(
                    _computeAddress({
                        salt: _BASE_SALT,
                        creationCode: type(JBBaseSuckerDeployer).creationCode,
                        arguments: abi.encode(
                            core.directory, core.permissions, core.tokens, safeAddress(), trustedForwarder
                        )
                    })
                );
            } else {
                _baseDeployer = new JBBaseSuckerDeployer{salt: _BASE_SALT}({
                    directory: core.directory,
                    permissions: core.permissions,
                    tokens: core.tokens,
                    configurator: safeAddress(),
                    trustedForwarder: trustedForwarder
                });
            }

            if (address(_baseDeployer.opMessenger()) == address(0)) {
                _baseDeployer.setChainSpecificConstants({
                    messenger: IOPMessenger(0x4200000000000000000000000000000000000007),
                    bridge: IOPStandardBridge(0x4200000000000000000000000000000000000010)
                });
            }

            if (address(_baseDeployer.singleton()) == address(0)) {
                // Deploy the singleton instance.
                JBBaseSucker _singleton = new JBBaseSucker{salt: _BASE_SALT}({
                    deployer: _baseDeployer,
                    directory: core.directory,
                    permissions: core.permissions,
                    prices: core.prices,
                    tokens: core.tokens,
                    feeProjectId: 1,
                    registry: registry,
                    trustedForwarder: trustedForwarder
                });

                // Configure the deployer to use the singleton instance.
                _baseDeployer.configureSingleton(_singleton);
            }

            preApprovedDeployers.push(address(_baseDeployer));
        }
    }

    /// @notice handles the deployment and configuration regarding arbitrum (this also includes the mainnet
    /// configuration).
    function _arbitrumSucker() internal {
        // Check if the deployer already exists at the CREATE2 address.
        bool alreadyDeployed = _isDeployed({
            salt: _ARB_SALT,
            creationCode: type(JBArbitrumSuckerDeployer).creationCode,
            arguments: abi.encode(core.directory, core.permissions, core.tokens, safeAddress(), trustedForwarder)
        });

        // If already deployed, verify the full pipeline completed (singleton + registry allowlisting).
        // Only skip if everything is fully configured; otherwise fall through to resume.
        if (alreadyDeployed) {
            address deployerAddr = _computeAddress({
                salt: _ARB_SALT,
                creationCode: type(JBArbitrumSuckerDeployer).creationCode,
                arguments: abi.encode(core.directory, core.permissions, core.tokens, safeAddress(), trustedForwarder)
            });
            bool singletonSet = address(JBArbitrumSuckerDeployer(deployerAddr).singleton()) != address(0);
            bool registryAllowed = registry.suckerDeployerIsAllowed(deployerAddr);
            if (singletonSet && registryAllowed) return;
        }

        // Check if we should do the L1 portion.
        // ETH Mainnet and ETH Sepolia.
        if (block.chainid == 1 || block.chainid == 11_155_111) {
            JBArbitrumSuckerDeployer _arbDeployer;

            if (alreadyDeployed) {
                _arbDeployer = JBArbitrumSuckerDeployer(
                    _computeAddress({
                        salt: _ARB_SALT,
                        creationCode: type(JBArbitrumSuckerDeployer).creationCode,
                        arguments: abi.encode(
                            core.directory, core.permissions, core.tokens, safeAddress(), trustedForwarder
                        )
                    })
                );
            } else {
                _arbDeployer = new JBArbitrumSuckerDeployer{salt: _ARB_SALT}({
                    directory: core.directory,
                    permissions: core.permissions,
                    tokens: core.tokens,
                    configurator: safeAddress(),
                    trustedForwarder: trustedForwarder
                });
            }

            if (address(_arbDeployer.arbGatewayRouter()) == address(0)) {
                _arbDeployer.setChainSpecificConstants({
                    layer: JBLayer.L1,
                    inbox: IInbox(block.chainid == 1 ? ARBAddresses.L1_ETH_INBOX : ARBAddresses.L1_SEP_INBOX),
                    gatewayRouter: IArbGatewayRouter(
                        block.chainid == 1 ? ARBAddresses.L1_GATEWAY_ROUTER : ARBAddresses.L1_SEP_GATEWAY_ROUTER
                    )
                });
            }

            if (address(_arbDeployer.singleton()) == address(0)) {
                // Deploy the singleton instance.
                JBArbitrumSucker _singleton = new JBArbitrumSucker{salt: _ARB_SALT}({
                    deployer: _arbDeployer,
                    directory: core.directory,
                    permissions: core.permissions,
                    prices: core.prices,
                    tokens: core.tokens,
                    feeProjectId: 1,
                    registry: registry,
                    trustedForwarder: trustedForwarder
                });

                // Configure the deployer to use the singleton instance.
                _arbDeployer.configureSingleton(_singleton);
            }

            preApprovedDeployers.push(address(_arbDeployer));
        }

        // Check if we should do the L2 portion.
        // ARB & ARB Sepolia.
        if (block.chainid == 42_161 || block.chainid == 421_614) {
            JBArbitrumSuckerDeployer _arbDeployer;

            if (alreadyDeployed) {
                _arbDeployer = JBArbitrumSuckerDeployer(
                    _computeAddress({
                        salt: _ARB_SALT,
                        creationCode: type(JBArbitrumSuckerDeployer).creationCode,
                        arguments: abi.encode(
                            core.directory, core.permissions, core.tokens, safeAddress(), trustedForwarder
                        )
                    })
                );
            } else {
                _arbDeployer = new JBArbitrumSuckerDeployer{salt: _ARB_SALT}({
                    directory: core.directory,
                    permissions: core.permissions,
                    tokens: core.tokens,
                    configurator: safeAddress(),
                    trustedForwarder: trustedForwarder
                });
            }

            if (address(_arbDeployer.arbGatewayRouter()) == address(0)) {
                _arbDeployer.setChainSpecificConstants({
                    layer: JBLayer.L2,
                    inbox: IInbox(address(0)),
                    gatewayRouter: IArbGatewayRouter(
                        block.chainid == 42_161 ? ARBAddresses.L2_GATEWAY_ROUTER : ARBAddresses.L2_SEP_GATEWAY_ROUTER
                    )
                });
            }

            if (address(_arbDeployer.singleton()) == address(0)) {
                // Deploy the singleton instance.
                JBArbitrumSucker _singleton = new JBArbitrumSucker{salt: _ARB_SALT}({
                    deployer: _arbDeployer,
                    directory: core.directory,
                    permissions: core.permissions,
                    prices: core.prices,
                    tokens: core.tokens,
                    feeProjectId: 1,
                    registry: registry,
                    trustedForwarder: trustedForwarder
                });

                // Configure the deployer to use the singleton instance.
                _arbDeployer.configureSingleton(_singleton);
            }

            preApprovedDeployers.push(address(_arbDeployer));
        }
    }

    function _ccipSucker() internal {
        // Deploy all the L1 suckers.
        if (block.chainid == 1 || block.chainid == 11_155_111) {
            // Optimsim
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _OP_SALT, remoteChainId: block.chainid == 1 ? CCIPHelper.OP_ID : CCIPHelper.OP_SEP_ID
                    })
                )
            );

            // Base
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _BASE_SALT,
                        remoteChainId: block.chainid == 1 ? CCIPHelper.BASE_ID : CCIPHelper.BASE_SEP_ID
                    })
                )
            );

            // Arbitrum
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _ARB_SALT, remoteChainId: block.chainid == 1 ? CCIPHelper.ARB_ID : CCIPHelper.ARB_SEP_ID
                    })
                )
            );

            // Tempo
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _TEMPO_SALT,
                        remoteChainId: block.chainid == 1 ? CCIPHelper.TEMPO_ID : CCIPHelper.TEMPO_MOD_ID
                    })
                )
            );
        }

        // Check if we should do the L2 portion.
        // ARB & ARB Sepolia.
        if (block.chainid == 42_161 || block.chainid == 421_614) {
            // L1.
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _ARB_SALT,
                        remoteChainId: block.chainid == 42_161 ? CCIPHelper.ETH_ID : CCIPHelper.ETH_SEP_ID
                    })
                )
            );

            // ARB -> OP.
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _ARB_OP_SALT,
                        remoteChainId: block.chainid == 42_161 ? CCIPHelper.OP_ID : CCIPHelper.OP_SEP_ID
                    })
                )
            );

            // ARB -> BASE.
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _ARB_BASE_SALT,
                        remoteChainId: block.chainid == 42_161 ? CCIPHelper.BASE_ID : CCIPHelper.BASE_SEP_ID
                    })
                )
            );

            // OP & OP Sepolia.
        } else if (block.chainid == 10 || block.chainid == 11_155_420) {
            // L1.
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _OP_SALT, remoteChainId: block.chainid == 10 ? CCIPHelper.ETH_ID : CCIPHelper.ETH_SEP_ID
                    })
                )
            );

            // OP -> ARB.
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _ARB_OP_SALT,
                        remoteChainId: block.chainid == 10 ? CCIPHelper.ARB_ID : CCIPHelper.ARB_SEP_ID
                    })
                )
            );

            // OP -> BASE.
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _OP_BASE_SALT,
                        remoteChainId: block.chainid == 10 ? CCIPHelper.BASE_ID : CCIPHelper.BASE_SEP_ID
                    })
                )
            );

            // BASE & BASE Sepolia.
        } else if (block.chainid == 8453 || block.chainid == 84_532) {
            // L1.
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _BASE_SALT,
                        remoteChainId: block.chainid == 8453 ? CCIPHelper.ETH_ID : CCIPHelper.ETH_SEP_ID
                    })
                )
            );

            // BASE -> OP.
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _OP_BASE_SALT,
                        remoteChainId: block.chainid == 8453 ? CCIPHelper.OP_ID : CCIPHelper.OP_SEP_ID
                    })
                )
            );

            // BASE -> ARB.
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _ARB_BASE_SALT,
                        remoteChainId: block.chainid == 8453 ? CCIPHelper.ARB_ID : CCIPHelper.ARB_SEP_ID
                    })
                )
            );
        }

        // Tempo / Tempo Moderato.
        if (block.chainid == 4217 || block.chainid == 42_431) {
            // Tempo -> ETH.
            preApprovedDeployers.push(
                address(
                    _deployCCIPSuckerFor({
                        salt: _TEMPO_SALT,
                        remoteChainId: block.chainid == 4217 ? CCIPHelper.ETH_ID : CCIPHelper.ETH_SEP_ID
                    })
                )
            );
        }
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function _deployCCIPSuckerFor(bytes32 salt, uint256 remoteChainId)
        internal
        returns (JBCCIPSuckerDeployer deployer)
    {
        return _deployCCIPSuckerWith({
            salt: salt,
            directory: core.directory,
            permissions: core.permissions,
            prices: core.prices,
            tokens: core.tokens,
            configurator: safeAddress(),
            forwarder: trustedForwarder,
            remoteChainId: remoteChainId,
            // Get the selector of the other side.
            remoteChainSelector: CCIPHelper.selectorOfChain(remoteChainId),
            // Get the router for this side.
            router: ICCIPRouter(CCIPHelper.routerOfChain(block.chainid))
        });
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function _deployCCIPSuckerWith(
        bytes32 salt,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBPrices prices,
        IJBTokens tokens,
        address configurator,
        address forwarder,
        uint256 remoteChainId,
        uint64 remoteChainSelector,
        ICCIPRouter router
    )
        internal
        returns (JBCCIPSuckerDeployer deployer)
    {
        // Check if this CCIP deployer is already deployed on this chain.
        bool alreadyDeployed = _isDeployed({
            salt: salt,
            creationCode: type(JBCCIPSuckerDeployer).creationCode,
            arguments: abi.encode(directory, permissions, tokens, configurator, forwarder)
        });

        if (alreadyDeployed) {
            deployer = JBCCIPSuckerDeployer(
                _computeAddress({
                    salt: salt,
                    creationCode: type(JBCCIPSuckerDeployer).creationCode,
                    arguments: abi.encode(directory, permissions, tokens, configurator, forwarder)
                })
            );

            // If the full pipeline is complete (singleton configured + registry allowlisted), return early.
            bool singletonSet = address(deployer.singleton()) != address(0);
            bool registryAllowed = registry.suckerDeployerIsAllowed(address(deployer));
            if (singletonSet && registryAllowed) return deployer;

            // Otherwise, resume the partial deployment below.
        } else {
            deployer = new JBCCIPSuckerDeployer{salt: salt}({
                directory: directory,
                permissions: permissions,
                tokens: tokens,
                configurator: configurator,
                trustedForwarder: forwarder
            });
        }

        if (deployer.ccipRemoteChainId() == 0) {
            deployer.setChainSpecificConstants({
                remoteChainId: remoteChainId, remoteChainSelector: remoteChainSelector, router: router
            });
        }

        if (address(deployer.singleton()) == address(0)) {
            // Deploy the singleton instance.
            JBCCIPSucker singleton = new JBCCIPSucker{salt: salt}({
                deployer: deployer,
                directory: directory,
                tokens: tokens,
                permissions: permissions,
                prices: prices,
                feeProjectId: 1,
                registry: registry,
                trustedForwarder: forwarder
            });

            // Configure the singleton.
            deployer.configureSingleton(singleton);
        }
    }

    function _isDeployed(bytes32 salt, bytes memory creationCode, bytes memory arguments) internal view returns (bool) {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            // Arachnid/deterministic-deployment-proxy address.
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        // Return if code is already present at this address.
        return address(_deployedTo).code.length != 0;
    }

    function _computeAddress(
        bytes32 salt,
        bytes memory creationCode,
        bytes memory arguments
    )
        internal
        pure
        returns (address)
    {
        return vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            // Arachnid/deterministic-deployment-proxy address.
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });
    }
}
