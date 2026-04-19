// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {ICCIPRouter} from "./interfaces/ICCIPRouter.sol";
import {IJBSuckerRegistry} from "./interfaces/IJBSuckerRegistry.sol";
import {IJBSuckerTerminal} from "./interfaces/IJBSuckerTerminal.sol";
import {CCIPHelper} from "./libraries/CCIPHelper.sol";
import {JBCCIPLib} from "./libraries/JBCCIPLib.sol";
import {JBRelayBeneficiary} from "./libraries/JBRelayBeneficiary.sol";
import {JBProxyConfig} from "./structs/JBProxyConfig.sol";
import {JBRelayCashOutClaimMessage} from "./structs/JBRelayCashOutClaimMessage.sol";
import {JBRelayPayMessage} from "./structs/JBRelayPayMessage.sol";

/// @notice A factory and payment router that creates proxy projects backed by real project tokens. On the home chain,
/// routes payments locally. On remote chains, bridges funds via CCIP to the home chain. Proxy projects allow suckers to
/// mint tokens on behalf of cross-chain bridgers through the standard JB mint permission system.
contract JBSuckerTerminal is
    ERC165,
    JBPermissioned,
    IERC721Receiver,
    IJBSuckerTerminal,
    IJBRulesetDataHook,
    IAny2EVMMessageReceiver
{
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBSuckerTerminal_InvalidRouter(address caller);
    error JBSuckerTerminal_NoERC20(uint256 realProjectId);
    error JBSuckerTerminal_NoPeer();
    error JBSuckerTerminal_NotAProxy(uint256 proxyProjectId);
    error JBSuckerTerminal_NotPeer(address origin, uint64 sourceChainSelector);
    error JBSuckerTerminal_NotSupported();
    error JBSuckerTerminal_NoTerminal(uint256 projectId, address token);
    error JBSuckerTerminal_ProxyAlreadyExists(uint256 realProjectId);
    error JBSuckerTerminal_UnknownMessageType(uint8 messageType);
    error JBSuckerTerminal_WrongChain();

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Permission ID for `createProxy`. Will move to `JBPermissionIds` once the package is published.
    uint8 internal constant _CREATE_PROXY_PERMISSION_ID = 41;

    /// @notice CCIP message type for pay messages.
    uint8 internal constant _MSG_TYPE_PAY = 1;

    /// @notice CCIP message type for cash out claim messages (delivering reclaimed ETH to remote chain).
    uint8 internal constant _MSG_TYPE_CASH_OUT_CLAIM = 2;

    /// @notice Gas limit for CCIP pay message execution on the home chain.
    uint256 internal constant _CCIP_PAY_GAS_LIMIT = 600_000;

    /// @notice Gas limit for CCIP cash out claim message execution on the remote chain.
    uint256 internal constant _CCIP_CASH_OUT_CLAIM_GAS_LIMIT = 200_000;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @inheritdoc IJBSuckerTerminal
    ICCIPRouter public immutable override CCIP_ROUTER;

    /// @inheritdoc IJBSuckerTerminal
    IJBController public immutable override CONTROLLER;

    /// @inheritdoc IJBSuckerTerminal
    IJBDirectory public immutable override DIRECTORY;

    /// @inheritdoc IJBSuckerTerminal
    IJBTerminal public immutable override MULTI_TERMINAL;

    /// @inheritdoc IJBSuckerTerminal
    address public immutable override PEER;

    /// @inheritdoc IJBSuckerTerminal
    IJBProjects public immutable override PROJECTS;

    /// @inheritdoc IJBSuckerTerminal
    uint64 public immutable override REMOTE_CHAIN_SELECTOR;

    /// @inheritdoc IJBSuckerTerminal
    IJBTerminal public immutable override ROUTER_TERMINAL;

    /// @inheritdoc IJBSuckerTerminal
    IJBSuckerRegistry public immutable override SUCKER_REGISTRY;

    /// @inheritdoc IJBSuckerTerminal
    IJBTokens public immutable override TOKENS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @inheritdoc IJBSuckerTerminal
    mapping(uint256 realProjectId => mapping(address deployer => uint256 proxyProjectId))
        public
        override proxyProjectIdOf;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @dev Maps proxy project IDs to their configuration. Use `proxyConfigOf()` for external access.
    mapping(uint256 proxyProjectId => JBProxyConfig) internal _proxyConfigOf;

    /// @dev The canonical home-chain proxy for each real project, used by inbound CCIP payments.
    /// Stored separately from `proxyProjectIdOf` (which is keyed by deployer) to avoid breaking
    /// when the real project's ownership is transferred after proxy creation.
    mapping(uint256 realProjectId => uint256 proxyProjectId) internal _homeProxyOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param controller The Juicebox controller.
    /// @param directory The Juicebox directory.
    /// @param permissions A contract storing permissions.
    /// @param multiTerminal The canonical JBMultiTerminal on this chain.
    /// @param suckerRegistry The sucker registry.
    /// @param tokens The Juicebox token store.
    /// @param ccipRouter The CCIP router on this chain (address(0) if no CCIP).
    /// @param remoteChainSelector The CCIP chain selector of the peer chain (0 if no peer).
    /// @param peer The address of the JBSuckerTerminal on the peer chain (address(0) if no peer).
    /// @param routerTerminal The router terminal for swap-based fallback (address(0) if not needed).
    constructor(
        IJBController controller,
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTerminal multiTerminal,
        IJBSuckerRegistry suckerRegistry,
        IJBTokens tokens,
        ICCIPRouter ccipRouter,
        uint64 remoteChainSelector,
        address peer,
        IJBTerminal routerTerminal
    )
        JBPermissioned(permissions)
    {
        CCIP_ROUTER = ccipRouter;
        CONTROLLER = controller;
        DIRECTORY = directory;
        MULTI_TERMINAL = multiTerminal;
        // slither-disable-next-line missing-zero-check
        PEER = peer;
        PROJECTS = directory.PROJECTS();
        REMOTE_CHAIN_SELECTOR = remoteChainSelector;
        ROUTER_TERMINAL = routerTerminal;
        SUCKER_REGISTRY = suckerRegistry;
        TOKENS = tokens;
    }

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Accept native token transfers (needed for CCIP WETH unwrapping and terminal returns).
    receive() external payable virtual {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @inheritdoc IJBTerminal
    /// @dev No-op. This terminal does not track accounting contexts.
    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    /// @inheritdoc IJBTerminal
    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        override
    {
        // Accept the tokens.
        if (token == JBConstants.NATIVE_TOKEN) {
            amount = msg.value;
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        emit AddToBalance(projectId, amount, 0, memo, metadata, msg.sender);
    }

    /// @inheritdoc IJBSuckerTerminal
    function cashOut(
        uint256 proxyProjectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minReclaimAmount,
        address payable beneficiary,
        bytes calldata metadata
    )
        external
        payable
        override
        returns (uint256 reclaimAmount)
    {
        // Look up the proxy config.
        JBProxyConfig memory config = _proxyConfigOf[proxyProjectId];
        if (config.realProjectId == 0) revert JBSuckerTerminal_NotAProxy(proxyProjectId);

        // Cash out is only available on the home chain.
        if (config.homeChainSelector != 0) revert JBSuckerTerminal_WrongChain();

        // Must have a peer to bridge the reclaimed ETH back.
        if (PEER == address(0)) revert JBSuckerTerminal_NoPeer();

        // Step 1: Cash out proxy tokens → real tokens (0% tax).
        // Step 2: Cash out real tokens → ETH.
        reclaimAmount = _cashOutProxyAndReal({
            proxyProjectId: proxyProjectId,
            realProjectId: config.realProjectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            minReclaimAmount: minReclaimAmount,
            metadata: metadata
        });

        emit CashOut(proxyProjectId, config.realProjectId, cashOutCount, reclaimAmount, beneficiary, msg.sender);

        // Step 3: Wrap ETH → WETH (if native) or approve router (if ERC-20) and CCIP send to peer on remote chain.
        _sendCashOutClaim({
            proxyProjectId: proxyProjectId,
            tokenToReclaim: tokenToReclaim,
            reclaimAmount: reclaimAmount,
            beneficiary: beneficiary
        });
    }

    /// @notice Called by the CCIP router to deliver a cross-chain message.
    /// @param any2EvmMessage The CCIP message containing the bridged funds and payment details.
    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage) external override {
        // Only the CCIP router can call this.
        if (msg.sender != address(CCIP_ROUTER)) revert JBSuckerTerminal_InvalidRouter(msg.sender);

        // Verify the message came from our peer.
        address origin = abi.decode(any2EvmMessage.sender, (address));
        if (origin != PEER || any2EvmMessage.sourceChainSelector != REMOTE_CHAIN_SELECTOR) {
            revert JBSuckerTerminal_NotPeer(origin, any2EvmMessage.sourceChainSelector);
        }

        // Decode the typed message.
        (uint8 messageType, bytes memory payload) = abi.decode(any2EvmMessage.data, (uint8, bytes));

        if (messageType == _MSG_TYPE_PAY) {
            _handleCCIPPay({payload: payload, destTokenAmounts: any2EvmMessage.destTokenAmounts});
        } else if (messageType == _MSG_TYPE_CASH_OUT_CLAIM) {
            _handleCCIPCashOutClaim({payload: payload, destTokenAmounts: any2EvmMessage.destTokenAmounts});
        } else {
            revert JBSuckerTerminal_UnknownMessageType(messageType);
        }
    }

    /// @inheritdoc IJBSuckerTerminal
    function createProxy(
        uint256 realProjectId,
        uint64 homeChainSelector,
        string calldata name,
        string calldata symbol,
        bytes32 salt
    )
        external
        override
        returns (uint256 proxyProjectId)
    {
        // Only one proxy per (realProjectId, deployer). Each deployer gets their own slot.
        if (proxyProjectIdOf[realProjectId][msg.sender] != 0) {
            revert JBSuckerTerminal_ProxyAlreadyExists(realProjectId);
        }

        // On the home chain, only the project owner (or an authorized operator) can create a proxy.
        if (homeChainSelector == 0) {
            _requirePermissionFrom({
                account: PROJECTS.ownerOf(realProjectId),
                projectId: realProjectId,
                permissionId: _CREATE_PROXY_PERMISSION_ID
            });
        }

        // Determine the token and terminal based on whether this is the home chain or a remote chain.
        address proxyToken;
        IJBTerminal terminal;

        if (homeChainSelector == 0) {
            // Home chain: the real project must have an ERC-20 token deployed.
            proxyToken = address(TOKENS.tokenOf(realProjectId));
            if (proxyToken == address(0)) revert JBSuckerTerminal_NoERC20(realProjectId);

            // Use the canonical multi-terminal.
            terminal = MULTI_TERMINAL;
        } else {
            // Remote chain: use native token and this contract as the terminal.
            proxyToken = JBConstants.NATIVE_TOKEN;
            terminal = IJBTerminal(address(this));
        }

        // Build the proxy ruleset: permanent, 1:1 weight, no tax, no reserves, owner minting allowed, data hook =
        // this.
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: uint32(uint160(proxyToken)),
                // On remote chains, direct payments are paused — funds must bridge via CCIP to the home
                // chain. On the home chain, pay() is open so the sucker terminal can deposit real tokens.
                pausePay: homeChainSelector != 0,
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
                dataHook: address(this),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        // Build the terminal config.
        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: proxyToken, decimals: 18, currency: uint32(uint160(proxyToken))});
        terminalConfigs[0] = JBTerminalConfig({terminal: terminal, accountingContextsToAccept: contexts});

        // Launch the proxy project owned by this contract (locked — no reconfiguration possible).
        proxyProjectId = CONTROLLER.launchProjectFor({
            owner: address(this),
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        // Deploy an ERC-20 for the proxy so tokens are transferable.
        // slither-disable-next-line unused-return
        CONTROLLER.deployERC20For({projectId: proxyProjectId, name: name, symbol: symbol, salt: salt});

        // Store the mapping in both directions.
        _proxyConfigOf[proxyProjectId] =
            JBProxyConfig({realProjectId: realProjectId, homeChainSelector: homeChainSelector});
        // slither-disable-next-line reentrancy-no-eth
        proxyProjectIdOf[realProjectId][msg.sender] = proxyProjectId;

        // On the home chain, store a deployer-independent reference for inbound CCIP payments.
        // This survives project ownership transfers (the deployer-keyed mapping does not).
        // Only one home proxy per real project — a new owner cannot overwrite and redirect CCIP mints.
        if (homeChainSelector == 0) {
            if (_homeProxyOf[realProjectId] != 0) revert JBSuckerTerminal_ProxyAlreadyExists(realProjectId);
            _homeProxyOf[realProjectId] = proxyProjectId;
        }

        emit CreateProxy(realProjectId, proxyProjectId, proxyToken, homeChainSelector, msg.sender);
    }

    /// @notice Pays a real project through its proxy, minting proxy tokens for the beneficiary.
    /// @dev On the home chain (homeChainSelector == 0), routes the payment locally.
    /// On a remote chain (homeChainSelector != 0), bridges funds via CCIP to the home chain.
    /// When called as IJBTerminal.pay(), the proxyProjectId is the projectId parameter.
    /// @param proxyProjectId The ID of the proxy project to pay through.
    /// @param token The token to pay with (NATIVE_TOKEN or ERC-20 address).
    /// @param amount The amount of tokens to pay. For native tokens, must match msg.value.
    /// @param beneficiary The address to receive proxy tokens.
    /// @param minReturnedTokens The minimum number of proxy tokens to receive (home chain only, ignored on remote).
    /// @param memo A memo to attach to the payment.
    /// @param metadata Additional metadata forwarded to the payment.
    /// @return proxyTokenCount The number of proxy tokens minted (0 on remote chains — tokens mint asynchronously).
    function pay(
        uint256 proxyProjectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        override(IJBTerminal)
        returns (uint256 proxyTokenCount)
    {
        // Look up the proxy config.
        JBProxyConfig memory config = _proxyConfigOf[proxyProjectId];
        if (config.realProjectId == 0) revert JBSuckerTerminal_NotAProxy(proxyProjectId);

        if (config.homeChainSelector == 0) {
            // ── Home chain: route locally ──
            proxyTokenCount = _payLocal({
                proxyProjectId: proxyProjectId,
                realProjectId: config.realProjectId,
                token: token,
                amount: amount,
                beneficiary: beneficiary,
                minReturnedTokens: minReturnedTokens,
                memo: memo,
                metadata: metadata
            });
        } else {
            // ── Remote chain: bridge via CCIP ──
            _payRemote({
                proxyProjectId: proxyProjectId,
                realProjectId: config.realProjectId,
                token: token,
                amount: amount,
                beneficiary: beneficiary,
                memo: memo,
                metadata: metadata
            });
            // Returns 0 — tokens mint asynchronously on the home chain.
            proxyTokenCount = 0;
        }
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @inheritdoc IJBTerminal
    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        override
        returns (JBAccountingContext memory)
    {
        uint8 decimals = 18;

        if (token != JBConstants.NATIVE_TOKEN) {
            try IJBToken(token).decimals() returns (uint8 resolvedDecimals) {
                decimals = resolvedDecimals;
            } catch {
                // Non-standard ERC-20s that omit or break `decimals()` remain discoverable with a synthetic fallback.
            }
        }

        projectId; // Unused.

        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: decimals, currency: uint32(uint160(token))});
    }

    /// @inheritdoc IJBTerminal
    /// @dev Returns an empty array — this terminal accepts tokens dynamically.
    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory) {
        return new JBAccountingContext[](0);
    }

    /// @notice Not used — `useDataHookForCashOut` is false on proxy rulesets.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata)
        external
        pure
        override
        returns (uint256, uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        revert();
    }

    /// @notice Not used — `useDataHookForPay` is false on proxy rulesets.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata)
        external
        pure
        override
        returns (uint256, JBPayHookSpecification[] memory)
    {
        revert();
    }

    /// @inheritdoc IJBTerminal
    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure override returns (uint256) {
        // This terminal holds no surplus — balances are forwarded to the home chain via CCIP.
        return 0;
    }

    /// @notice Returns whether an address has permission to mint a project's tokens on-demand.
    /// @dev Grants mint permission to any sucker registered for the project.
    /// @param projectId The ID of the project.
    /// @param addr The address to check.
    /// @return flag True if `addr` is a registered sucker for `projectId`.
    function hasMintPermissionFor(
        uint256 projectId,
        JBRuleset memory,
        address addr
    )
        external
        view
        override
        returns (bool flag)
    {
        return SUCKER_REGISTRY.isSuckerOf({projectId: projectId, addr: addr});
    }

    /// @inheritdoc IJBTerminal
    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        revert JBSuckerTerminal_NotSupported();
    }

    /// @dev Required to receive the project NFT when creating proxy projects.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @inheritdoc IJBTerminal
    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        pure
        override
        returns (JBRuleset memory, uint256, uint256, JBPayHookSpecification[] memory)
    {
        revert JBSuckerTerminal_NotSupported();
    }

    /// @inheritdoc IJBSuckerTerminal
    function proxyConfigOf(uint256 proxyProjectId) external view override returns (JBProxyConfig memory) {
        return _proxyConfigOf[proxyProjectId];
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBSuckerTerminal).interfaceId || interfaceId == type(IJBRulesetDataHook).interfaceId
            || interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || super.supportsInterface(interfaceId);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Bridges an already-held token via CCIP to the home chain.
    /// @dev Assumes the contract already holds `amount` of `token` (or native ETH via msg.value).
    /// Transport payment for CCIP is calculated from msg.value minus the native token amount (if any).
    /// @param proxyProjectId The ID of the proxy project (used for event emission).
    /// @param realProjectId The ID of the real project on the home chain.
    /// @param token The token being bridged (NATIVE_TOKEN or ERC-20 address).
    /// @param amount The amount of tokens to bridge.
    /// @param beneficiary The address to receive proxy tokens on the home chain.
    /// @param memo A memo to attach to the payment on the home chain.
    /// @param metadata Additional metadata forwarded to the home chain payment.
    function _bridgePay(
        uint256 proxyProjectId,
        uint256 realProjectId,
        address token,
        uint256 amount,
        address beneficiary,
        string calldata memo,
        bytes calldata metadata
    )
        internal
        virtual
    {
        // Must have a peer configured.
        if (PEER == address(0)) revert JBSuckerTerminal_NoPeer();

        // For native: msg.value = amount + transport. For ERC-20: msg.value = transport only.
        uint256 transportPayment = token == JBConstants.NATIVE_TOKEN ? msg.value - amount : msg.value;

        // Wrap ETH → WETH (for native) or approve router (for ERC-20), and build CCIP token amounts.
        // slither-disable-next-line unused-return
        (Client.EVMTokenAmount[] memory tokenAmounts,) =
            JBCCIPLib.prepareTokenAmounts({ccipRouter: CCIP_ROUTER, token: token, amount: amount});

        // Build the pay message payload.
        bytes memory encodedPayload = abi.encode(
            _MSG_TYPE_PAY,
            abi.encode(
                JBRelayPayMessage({
                    realProjectId: realProjectId, beneficiary: beneficiary, memo: memo, metadata: metadata
                })
            )
        );

        // Send the CCIP message.
        address feeToken = transportPayment == 0 ? CCIPHelper.linkOfChain(block.chainid) : address(0);
        (bool refundFailed, uint256 refundAmount) = JBCCIPLib.sendCCIPMessage({
            ccipRouter: CCIP_ROUTER,
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            peerAddress: PEER,
            transportPayment: transportPayment,
            feeToken: feeToken,
            gasLimit: _CCIP_PAY_GAS_LIMIT,
            encodedPayload: encodedPayload,
            tokenAmounts: tokenAmounts,
            refundRecipient: msg.sender
        });

        // Emit an event if the excess transport payment refund failed.
        if (refundFailed) emit TransportPaymentRefundFailed(msg.sender, refundAmount);

        emit CCIPPaySent(proxyProjectId, realProjectId, amount, beneficiary, msg.sender);
    }

    /// @notice Transfers proxy tokens from the caller, cashes out proxy → real tokens, then real tokens → ETH.
    /// @param proxyProjectId The ID of the proxy project whose tokens are being cashed out.
    /// @param realProjectId The ID of the real project backing the proxy.
    /// @param cashOutCount The number of proxy tokens to cash out.
    /// @param tokenToReclaim The token to reclaim from the real project (typically NATIVE_TOKEN).
    /// @param minReclaimAmount The minimum amount of tokens to reclaim (reverts if not met).
    /// @param metadata Extra metadata forwarded to the cash out calls.
    /// @return reclaimAmount The amount of tokens reclaimed from the real project.
    function _cashOutProxyAndReal(
        uint256 proxyProjectId,
        uint256 realProjectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minReclaimAmount,
        bytes calldata metadata
    )
        internal
        returns (uint256 reclaimAmount)
    {
        address proxyToken = address(TOKENS.tokenOf(proxyProjectId));
        address realToken = address(TOKENS.tokenOf(realProjectId));

        // Transfer proxy ERC-20 tokens from the caller.
        IERC20(proxyToken).safeTransferFrom(msg.sender, address(this), cashOutCount);

        // Cash out proxy tokens → receive real project tokens (0% tax on proxy).
        // The proxy terminal accepts the real token (not the proxy token).
        uint256 realTokenReceived;
        {
            uint256 realTokenBefore = IERC20(realToken).balanceOf(address(this));
            IJBTerminal proxyTerminal = DIRECTORY.primaryTerminalOf({projectId: proxyProjectId, token: realToken});
            // slither-disable-next-line unused-return
            IJBCashOutTerminal(address(proxyTerminal))
                .cashOutTokensOf({
                    holder: address(this),
                    projectId: proxyProjectId,
                    cashOutCount: cashOutCount,
                    tokenToReclaim: realToken,
                    minTokensReclaimed: 0,
                    beneficiary: payable(address(this)),
                    metadata: metadata
                });
            realTokenReceived = IERC20(realToken).balanceOf(address(this)) - realTokenBefore;
        }

        // Cash out real tokens → receive ETH.
        {
            IJBTerminal realTerminal = DIRECTORY.primaryTerminalOf({projectId: realProjectId, token: tokenToReclaim});
            if (address(realTerminal) == address(0)) {
                revert JBSuckerTerminal_NoTerminal(realProjectId, tokenToReclaim);
            }
            reclaimAmount = IJBCashOutTerminal(address(realTerminal))
                .cashOutTokensOf({
                    holder: address(this),
                    projectId: realProjectId,
                    cashOutCount: realTokenReceived,
                    tokenToReclaim: tokenToReclaim,
                    minTokensReclaimed: minReclaimAmount,
                    beneficiary: payable(address(this)),
                    metadata: metadata
                });
        }
    }

    /// @notice Pays the real project and returns the delta in real tokens received.
    /// @dev Uses a before/after balance snapshot to measure tokens minted, preventing sweeping of pre-existing
    /// balances.
    /// @param projectId The ID of the real project to pay.
    /// @param payToken The token to pay with (NATIVE_TOKEN or ERC-20 address).
    /// @param amount The amount of tokens to pay.
    /// @param nativeValue The native ETH to forward (0 for ERC-20 payments).
    /// @param beneficiary The real beneficiary of the payment (injected into metadata as relay beneficiary).
    /// @param memo A memo to attach.
    /// @param metadata Additional metadata.
    /// @param allowRouterFallback Whether to fall back to ROUTER_TERMINAL when no primary terminal is found.
    /// @return realTokensReceived The number of real tokens minted to this contract.
    function _payRealProject(
        uint256 projectId,
        address payToken,
        uint256 amount,
        uint256 nativeValue,
        address beneficiary,
        string memory memo,
        bytes memory metadata,
        bool allowRouterFallback
    )
        internal
        returns (uint256 realTokensReceived)
    {
        IJBTerminal realTerminal = DIRECTORY.primaryTerminalOf({projectId: projectId, token: payToken});
        if (address(realTerminal) == address(0)) {
            if (!allowRouterFallback || address(ROUTER_TERMINAL) == address(0)) {
                revert JBSuckerTerminal_NoTerminal(projectId, payToken);
            }
            realTerminal = ROUTER_TERMINAL;
        }

        if (payToken != JBConstants.NATIVE_TOKEN) {
            IERC20(payToken).forceApprove(address(realTerminal), amount);
        }

        address realToken = address(TOKENS.tokenOf(projectId));
        uint256 realTokenBefore = IERC20(realToken).balanceOf(address(this));

        // Inject the real beneficiary into the metadata so that data hooks (e.g. 721 hooks) can resolve
        // the actual user instead of seeing this contract as the beneficiary.
        bytes memory enrichedMetadata = JBMetadataResolver.addToMetadata({
            originalMetadata: metadata, idToAdd: JBRelayBeneficiary.ID, dataToAdd: abi.encode(beneficiary)
        });

        // slither-disable-next-line arbitrary-send-eth,unused-return
        realTerminal.pay{value: nativeValue}({
            projectId: projectId,
            token: payToken,
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: memo,
            metadata: enrichedMetadata
        });

        realTokensReceived = IERC20(realToken).balanceOf(address(this)) - realTokenBefore;
    }

    /// @notice Deposits real tokens held by this contract into a proxy project.
    /// @param proxyProjectId The proxy project to deposit into.
    /// @param realProjectId The real project whose token was received.
    /// @param beneficiary The address to receive proxy tokens.
    /// @param minReturnedTokens The minimum proxy tokens to receive.
    /// @param memo A memo to attach.
    /// @param metadata Additional metadata.
    /// @param realTokensReceived The number of real tokens to deposit (caller computes via before/after delta).
    /// @return proxyTokenCount The number of proxy tokens minted.
    function _depositIntoProxy(
        uint256 proxyProjectId,
        uint256 realProjectId,
        address beneficiary,
        uint256 minReturnedTokens,
        string memory memo,
        bytes memory metadata,
        uint256 realTokensReceived
    )
        internal
        returns (uint256 proxyTokenCount)
    {
        // Get the real project's ERC-20 token address.
        address realToken = address(TOKENS.tokenOf(realProjectId));

        // Find the proxy project's terminal for the real token.
        IJBTerminal proxyTerminal = DIRECTORY.primaryTerminalOf({projectId: proxyProjectId, token: realToken});

        // Approve the proxy terminal to spend the real tokens.
        IERC20(realToken).forceApprove(address(proxyTerminal), realTokensReceived);

        // Pay into the proxy project — proxy tokens are minted to the beneficiary.
        proxyTokenCount = proxyTerminal.pay({
            projectId: proxyProjectId,
            token: realToken,
            amount: realTokensReceived,
            beneficiary: beneficiary,
            minReturnedTokens: minReturnedTokens,
            memo: memo,
            metadata: metadata
        });
    }

    /// @notice Handles a received CCIP cash out claim message on the remote chain.
    /// @param payload The ABI-encoded JBRelayCashOutClaimMessage.
    /// @param destTokenAmounts The token amounts delivered by CCIP.
    function _handleCCIPCashOutClaim(
        bytes memory payload,
        Client.EVMTokenAmount[] calldata destTokenAmounts
    )
        internal
        virtual
    {
        // Decode the cash out claim message.
        JBRelayCashOutClaimMessage memory claimMsg = abi.decode(payload, (JBRelayCashOutClaimMessage));

        // Determine the delivered token and amount.
        address deliveredToken;
        uint256 amount;
        if (destTokenAmounts.length > 0) {
            deliveredToken = destTokenAmounts[0].token;
            amount = destTokenAmounts[0].amount;
        }

        // If delivered token is wrapped native, unwrap and send ETH. Otherwise, transfer ERC-20.
        address wrappedNative = address(CCIP_ROUTER.getWrappedNative());
        if (deliveredToken == wrappedNative) {
            // Unwrap WETH → ETH.
            JBCCIPLib.unwrapReceivedTokens({ccipRouter: CCIP_ROUTER, destTokenAmounts: destTokenAmounts});
            // Transfer ETH to the beneficiary.
            // slither-disable-next-line arbitrary-send-eth
            (bool sent,) = claimMsg.beneficiary.call{value: amount}("");
            require(sent, "ETH transfer failed");
        } else {
            // Transfer ERC-20 to the beneficiary.
            IERC20(deliveredToken).safeTransfer(claimMsg.beneficiary, amount);
        }

        emit CCIPCashOutClaimReceived(claimMsg.beneficiary, amount);
    }

    /// @notice Handles a received CCIP pay message on the home chain.
    /// @dev Pays the real project with the bridged funds, then deposits the received real tokens into the proxy project
    /// to mint proxy tokens for the beneficiary.
    /// @param payload The ABI-encoded JBRelayPayMessage containing the real project ID, beneficiary, memo, and
    /// metadata. @param destTokenAmounts The token amounts delivered by CCIP (typically WETH which gets unwrapped).
    function _handleCCIPPay(bytes memory payload, Client.EVMTokenAmount[] calldata destTokenAmounts) internal virtual {
        // Decode the pay message.
        JBRelayPayMessage memory payMsg = abi.decode(payload, (JBRelayPayMessage));

        // Determine the delivered token, amount, and the token to pay the real project with.
        address payToken;
        uint256 amount;
        uint256 nativeValue;

        {
            address deliveredToken;
            if (destTokenAmounts.length > 0) {
                deliveredToken = destTokenAmounts[0].token;
                amount = destTokenAmounts[0].amount;
            }

            if (deliveredToken == address(CCIP_ROUTER.getWrappedNative())) {
                // Unwrap WETH → ETH and pay with native token.
                JBCCIPLib.unwrapReceivedTokens({ccipRouter: CCIP_ROUTER, destTokenAmounts: destTokenAmounts});
                payToken = JBConstants.NATIVE_TOKEN;
                nativeValue = amount;
            } else {
                payToken = deliveredToken;
            }
        }

        // Pay the real project and measure the delta in real tokens received.
        uint256 realTokensReceived = _payRealProject({
            projectId: payMsg.realProjectId,
            payToken: payToken,
            amount: amount,
            nativeValue: nativeValue,
            beneficiary: payMsg.beneficiary,
            memo: payMsg.memo,
            metadata: payMsg.metadata,
            allowRouterFallback: true
        });

        // Deposit real tokens into the proxy project, minting proxy tokens for the beneficiary.
        // Uses _homeProxyOf (deployer-independent) so ownership transfers don't break inbound payments.
        uint256 proxyTokenCount = _depositIntoProxy({
            proxyProjectId: _homeProxyOf[payMsg.realProjectId],
            realProjectId: payMsg.realProjectId,
            beneficiary: payMsg.beneficiary,
            minReturnedTokens: 0,
            memo: payMsg.memo,
            metadata: payMsg.metadata,
            realTokensReceived: realTokensReceived
        });

        emit CCIPPayReceived(payMsg.realProjectId, payMsg.beneficiary, amount, proxyTokenCount);
    }

    /// @notice Pays a real project locally and deposits received real tokens into the proxy project.
    /// @dev Used on the home chain where no bridging is needed. Accepts the payment token from the caller,
    /// pays the real project, then deposits the minted real tokens into the proxy project.
    /// @param proxyProjectId The ID of the proxy project to deposit real tokens into.
    /// @param realProjectId The ID of the real project to pay.
    /// @param token The token to pay with (NATIVE_TOKEN or ERC-20 address).
    /// @param amount The amount of tokens to pay.
    /// @param beneficiary The address to receive proxy tokens.
    /// @param minReturnedTokens The minimum number of proxy tokens to receive (reverts if not met).
    /// @param memo A memo to attach to the payment.
    /// @param metadata Additional metadata forwarded to the payment.
    /// @return proxyTokenCount The number of proxy tokens minted to the beneficiary.
    function _payLocal(
        uint256 proxyProjectId,
        uint256 realProjectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    )
        internal
        returns (uint256 proxyTokenCount)
    {
        // Accept the payment token from the caller.
        uint256 nativeValue;
        if (token == JBConstants.NATIVE_TOKEN) {
            nativeValue = msg.value;
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        // Pay the real project and measure the delta in real tokens received.
        uint256 realTokensReceived = _payRealProject({
            projectId: realProjectId,
            payToken: token,
            amount: amount,
            nativeValue: nativeValue,
            beneficiary: beneficiary,
            memo: memo,
            metadata: metadata,
            allowRouterFallback: false
        });

        // Deposit received real tokens into the proxy project, minting proxy tokens for the beneficiary.
        proxyTokenCount = _depositIntoProxy({
            proxyProjectId: proxyProjectId,
            realProjectId: realProjectId,
            beneficiary: beneficiary,
            minReturnedTokens: minReturnedTokens,
            memo: memo,
            metadata: metadata,
            realTokensReceived: realTokensReceived
        });
    }

    /// @notice Bridges a payment via CCIP to the home chain.
    /// @dev Accepts the token from the caller, then delegates to `_bridgePay`.
    /// @param proxyProjectId The ID of the proxy project (used for event emission).
    /// @param realProjectId The ID of the real project on the home chain.
    /// @param token The token being paid (NATIVE_TOKEN or ERC-20 address).
    /// @param amount The amount of tokens to bridge.
    /// @param beneficiary The address to receive proxy tokens on the home chain.
    /// @param memo A memo to attach to the payment on the home chain.
    /// @param metadata Additional metadata forwarded to the home chain payment.
    function _payRemote(
        uint256 proxyProjectId,
        uint256 realProjectId,
        address token,
        uint256 amount,
        address beneficiary,
        string calldata memo,
        bytes calldata metadata
    )
        internal
        virtual
    {
        // Accept the token from the caller.
        if (token != JBConstants.NATIVE_TOKEN) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        // Bridge the already-held token via CCIP.
        _bridgePay({
            proxyProjectId: proxyProjectId,
            realProjectId: realProjectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            memo: memo,
            metadata: metadata
        });
    }

    /// @notice Wraps ETH (if native) or approves the router (if ERC-20) and sends a CCIP message to deliver cash out
    /// proceeds to the remote chain.
    /// @param proxyProjectId The ID of the proxy project (used for event emission).
    /// @param tokenToReclaim The token being sent (NATIVE_TOKEN or ERC-20 address).
    /// @param reclaimAmount The amount of tokens to send to the remote chain.
    /// @param beneficiary The address to receive the tokens on the remote chain.
    function _sendCashOutClaim(
        uint256 proxyProjectId,
        address tokenToReclaim,
        uint256 reclaimAmount,
        address payable beneficiary
    )
        internal
        virtual
    {
        // slither-disable-next-line unused-return
        (Client.EVMTokenAmount[] memory tokenAmounts,) =
            JBCCIPLib.prepareTokenAmounts({ccipRouter: CCIP_ROUTER, token: tokenToReclaim, amount: reclaimAmount});

        bytes memory encodedPayload =
            abi.encode(_MSG_TYPE_CASH_OUT_CLAIM, abi.encode(JBRelayCashOutClaimMessage({beneficiary: beneficiary})));

        address feeToken = msg.value == 0 ? CCIPHelper.linkOfChain(block.chainid) : address(0);
        (bool refundFailed, uint256 refundAmount) = JBCCIPLib.sendCCIPMessage({
            ccipRouter: CCIP_ROUTER,
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            peerAddress: PEER,
            transportPayment: msg.value,
            feeToken: feeToken,
            gasLimit: _CCIP_CASH_OUT_CLAIM_GAS_LIMIT,
            encodedPayload: encodedPayload,
            tokenAmounts: tokenAmounts,
            refundRecipient: msg.sender
        });

        if (refundFailed) emit TransportPaymentRefundFailed(msg.sender, refundAmount);

        emit CCIPCashOutClaimSent(proxyProjectId, reclaimAmount, beneficiary, msg.sender);
    }
}
