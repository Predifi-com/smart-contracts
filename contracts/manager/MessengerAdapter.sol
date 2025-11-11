// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "../interfaces/IMessengerAdapter.sol";
import "../interfaces/IL2ToL2CrossDomainMessenger.sol";
import "../interfaces/IBetManager.sol";
import "../libs/Types.sol";

interface ISettlementAuthority {
    function settleFromMessenger(bytes32 orderId, uint256 amountDelta, uint256 feeDelta) external;
}

/**
 * @title MessengerAdapter
 * @notice Adapter for cross-chain messaging between protocol components
 * @dev Primary: OP Superchain L2ToL2CrossDomainMessenger for Superchain-to-Superchain
 *      Fallback: ViaLabs for non-Superchain communication
 */
contract MessengerAdapter is 
    IMessengerAdapter,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // Roles
    bytes32 public constant ESCROW_ROLE = keccak256("ESCROW_ROLE");
    bytes32 public constant BET_MANAGER_ROLE = keccak256("BET_MANAGER_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");

    // State variables
    address public protocolConfig;
    // Optimism Superchain L2->L2 messenger (primary for Superchain-to-Superchain)
    address public l2ToL2Messenger;
    
    // Chain type mappings: true = OP Superchain, false = external (use ViaLabs)
    mapping(uint256 => bool) public isSuperchainId;
    
    // Chain ID => Remote MessengerAdapter address
    mapping(uint256 => address) public remoteAdapters;
    
    // Chain ID => BetManager address
    mapping(uint256 => address) public chainBetManagers;
    
    // Chain ID => SettlementAuthority address
    mapping(uint256 => address) public chainSettlementAuthorities;
    
    // Message tracking
    mapping(bytes32 => bool) public processedMessages;
    mapping(bytes32 => Types.MessageStatus) public messageStatuses;
    
    uint256 private _messageNonce;
    uint256 public currentChainId;

    // Message types
    bytes32 private constant BET_INTENT_TYPE = keccak256("BET_INTENT");
    bytes32 private constant SETTLEMENT_TYPE = keccak256("SETTLEMENT");
    bytes32 private constant STATUS_UPDATE_TYPE = keccak256("STATUS_UPDATE");

    // Constants
    uint256 private constant MESSAGE_TIMEOUT = 1 hours;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the messenger adapter
     * @param config Protocol configuration contract
     */
    function initialize(address config) external initializer {
        if (config == address(0)) revert Types.ZeroAddress();

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        protocolConfig = config;
        currentChainId = block.chainid;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSE_ROLE, msg.sender);
    }

    /**
     * @notice Send bet intent to venue chain
     * @param intent Bet intent to send
     * @param targetChainId Target venue chain ID
     * @return messageId Generated message ID
     */
    function sendBetIntent(
        Types.BetIntent calldata intent,
        uint256 targetChainId
    ) external onlyRole(ESCROW_ROLE) whenNotPaused returns (bytes32 messageId) {
        if (remoteAdapters[targetChainId] == address(0)) revert Types.ChainNotSupported();
        if (chainBetManagers[targetChainId] == address(0)) revert Types.BetManagerNotSet();

        messageId = _generateMessageId(BET_INTENT_TYPE, targetChainId);
        
        // Store message status
        messageStatuses[messageId] = Types.MessageStatus({
            messageType: BET_INTENT_TYPE,
            sourceChain: currentChainId,
            targetChain: targetChainId,
            timestamp: uint64(block.timestamp),
            processed: false,
            failed: false
        });

        // Emit event for monitoring
        emit BetIntentSent(
            messageId,
            intent.intentId,
            currentChainId,
            targetChainId,
            intent.user,
            intent.amount,
            intent.marketId,
            intent.outcomeId
        );

        // Route based on chain type
        if (isSuperchainId[targetChainId]) {
            // PRIMARY: Use OP Superchain L2->L2 messenger for Superchain-to-Superchain
            if (l2ToL2Messenger == address(0)) revert Types.InvalidConfiguration();
            
            bytes memory callData = abi.encodeWithSelector(
                IMessengerAdapter.receiveBetIntent.selector,
                messageId,
                currentChainId,
                intent
            );
            IL2ToL2CrossDomainMessenger(l2ToL2Messenger).sendMessage(
                targetChainId,
                remoteAdapters[targetChainId],
                callData
            );
        } else {
            // FALLBACK: Use ViaLabs or off-chain relay for non-Superchain communication
            bytes memory message = abi.encode(intent);
            emit CrossChainMessage(
                messageId,
                currentChainId,
                targetChainId,
                remoteAdapters[targetChainId],
                chainBetManagers[targetChainId],
                BET_INTENT_TYPE,
                message
            );
        }
    }

    /**
     * @notice Receive and process bet intent from origin chain
     * @param messageId Message ID from origin
     * @param sourceChainId Source chain ID
     * @param intent Bet intent data
     * @return releaseId Release ID from bet manager
     */
    function receiveBetIntent(
        bytes32 messageId,
        uint256 sourceChainId,
        Types.BetIntent calldata intent
    ) external onlyRole(RELAYER_ROLE) nonReentrant whenNotPaused returns (bytes32 releaseId) {
        if (processedMessages[messageId]) revert Types.AlreadyProcessed();
        if (remoteAdapters[sourceChainId] == address(0)) revert Types.ChainNotSupported();
        
        // Mark as processed
        processedMessages[messageId] = true;
        
        // Forward to local bet manager
        address betManager = chainBetManagers[currentChainId];
        if (betManager == address(0)) revert Types.BetManagerNotSet();

        // Call bet manager to handle intent
        try IBetManager(betManager).handleBetIntent(intent) returns (bytes32 _releaseId) {
            releaseId = _releaseId;
            
            emit BetIntentReceived(
                messageId,
                intent.intentId,
                sourceChainId,
                currentChainId,
                releaseId
            );
        } catch Error(string memory reason) {
            emit MessageFailed(messageId, reason);
            revert Types.MessageProcessingFailed();
        }
    }

    /**
     * @notice Send settlement message to origin chain
     * @param intentId Original intent ID
     * @param settlement Settlement data
     * @param targetChainId Target origin chain ID
     * @return messageId Generated message ID
     */
    function sendSettlement(
        bytes32 intentId,
        Types.SettlementData calldata settlement,
        uint256 targetChainId
    ) external onlyRole(BET_MANAGER_ROLE) whenNotPaused returns (bytes32 messageId) {
        if (remoteAdapters[targetChainId] == address(0)) revert Types.ChainNotSupported();

        messageId = _generateMessageId(SETTLEMENT_TYPE, targetChainId);
        
        messageStatuses[messageId] = Types.MessageStatus({
            messageType: SETTLEMENT_TYPE,
            sourceChain: currentChainId,
            targetChain: targetChainId,
            timestamp: uint64(block.timestamp),
            processed: false,
            failed: false
        });

        emit SettlementSent(
            messageId,
            intentId,
            currentChainId,
            targetChainId,
            settlement.outcome,
            settlement.payout
        );

        // Route based on chain type
        if (isSuperchainId[targetChainId]) {
            // PRIMARY: Use OP Superchain L2->L2 messenger for Superchain-to-Superchain
            if (l2ToL2Messenger == address(0)) revert Types.InvalidConfiguration();
            
            bytes memory callData = abi.encodeWithSelector(
                IMessengerAdapter.receiveSettlement.selector,
                messageId,
                currentChainId,
                intentId,
                settlement
            );
            IL2ToL2CrossDomainMessenger(l2ToL2Messenger).sendMessage(
                targetChainId,
                remoteAdapters[targetChainId],
                callData
            );
        } else {
            // FALLBACK: Use ViaLabs or off-chain relay for non-Superchain communication
            bytes memory message = abi.encode(intentId, settlement);
            emit CrossChainMessage(
                messageId,
                currentChainId,
                targetChainId,
                remoteAdapters[targetChainId],
                address(0), // No longer using EscrowVault
                SETTLEMENT_TYPE,
                message
            );
        }
    }

    /**
     * @notice Receive settlement from venue chain
     * @dev Settlement is now handled by StagingEscrowVault via SettlementAuthority
     * @param messageId Message ID
     * @param sourceChainId Source chain ID
     * @param intentId Intent ID
     * @param settlement Settlement data
     */
    function receiveSettlement(
        bytes32 messageId,
        uint256 sourceChainId,
        bytes32 intentId,
        Types.SettlementData calldata settlement
    ) external onlyRole(RELAYER_ROLE) nonReentrant whenNotPaused {
        if (processedMessages[messageId]) revert Types.AlreadyProcessed();
        if (remoteAdapters[sourceChainId] == address(0)) revert Types.ChainNotSupported();
        
        processedMessages[messageId] = true;
        
        // Call SettlementAuthority which will release funds from StagingEscrowVault
        address settlementAuthority = chainSettlementAuthorities[currentChainId];
        if (settlementAuthority != address(0)) {
            try ISettlementAuthority(settlementAuthority).settleFromMessenger(
                intentId, 
                settlement.payout, 
                0 // feeDelta - can be extracted from settlement data if needed
            ) {
                // Settlement successful
            } catch {
                // Settlement failed - log and continue
            }
        }
        
        emit SettlementReceived(
            messageId,
            intentId,
            sourceChainId,
            currentChainId,
            settlement.outcome,
            settlement.payout
        );
    }

    /**
     * @notice Send status update message
     * @param intentId Intent ID
     * @param status New status
     * @param targetChainId Target chain ID
     * @return messageId Generated message ID
     */
    function sendStatusUpdate(
        bytes32 intentId,
        Types.IntentState status,
        uint256 targetChainId
    ) external onlyRole(BET_MANAGER_ROLE) whenNotPaused returns (bytes32 messageId) {
        if (remoteAdapters[targetChainId] == address(0)) revert Types.ChainNotSupported();

        messageId = _generateMessageId(STATUS_UPDATE_TYPE, targetChainId);
        
        messageStatuses[messageId] = Types.MessageStatus({
            messageType: STATUS_UPDATE_TYPE,
            sourceChain: currentChainId,
            targetChain: targetChainId,
            timestamp: uint64(block.timestamp),
            processed: false,
            failed: false
        });

        emit StatusUpdateSent(messageId, intentId, currentChainId, targetChainId, status);

        {
            bytes memory message = abi.encode(intentId, status);
            emit CrossChainMessage(
                messageId,
                currentChainId,
                targetChainId,
                remoteAdapters[targetChainId],
                address(0), // No longer using EscrowVault
                STATUS_UPDATE_TYPE,
                message
            );
        }
    }

    // Configuration functions
    function setRemoteAdapter(uint256 chainId, address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0)) revert Types.ZeroAddress();
        remoteAdapters[chainId] = adapter;
        emit RemoteAdapterSet(chainId, adapter);
    }

    function setBetManager(uint256 chainId, address betManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (betManager == address(0)) revert Types.ZeroAddress();
        chainBetManagers[chainId] = betManager;
        emit BetManagerSet(chainId, betManager);
    }

    function setSettlementAuthority(uint256 chainId, address settlementAuthority) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (settlementAuthority == address(0)) revert Types.ZeroAddress();
        chainSettlementAuthorities[chainId] = settlementAuthority;
        emit SettlementAuthoritySet(chainId, settlementAuthority);
    }

    /**
     * @notice Configure the Optimism Superchain L2->L2 messenger (primary for Superchain)
     * @param messenger Address of the L2ToL2CrossDomainMessenger predeploy (typically 0x4200000000000000000000000000000000000023)
     */
    function setL2ToL2Messenger(address messenger) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (messenger == address(0)) revert Types.ZeroAddress();
        l2ToL2Messenger = messenger;
        emit L2MessengerSet(messenger);
    }

    /**
     * @notice Mark a chain as part of the OP Superchain
     * @param chainId Chain ID to configure
     * @param isSuperchain True if OP Superchain chain (uses L2ToL2), false if external (uses ViaLabs)
     */
    function setChainType(uint256 chainId, bool isSuperchain) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isSuperchainId[chainId] = isSuperchain;
        emit ChainTypeSet(chainId, isSuperchain);
    }

    // View functions
    function getMessageStatus(bytes32 messageId) external view returns (Types.MessageStatus memory) {
        return messageStatuses[messageId];
    }

    function isChainSupported(uint256 chainId) external view returns (bool) {
        return remoteAdapters[chainId] != address(0);
    }

    function getRemoteAdapter(uint256 chainId) external view returns (address) {
        return remoteAdapters[chainId];
    }

    // Pausable functions
    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSE_ROLE) {
        _unpause();
    }

    // Emergency functions
    function emergencyMarkProcessed(bytes32 messageId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        processedMessages[messageId] = true;
        emit EmergencyMessageMarked(messageId);
    }

    // Internal functions
    function _generateMessageId(bytes32 messageType, uint256 targetChain) internal returns (bytes32) {
        return keccak256(abi.encodePacked(
            messageType,
            currentChainId,
            targetChain,
            ++_messageNonce,
            block.timestamp
        ));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // Gap for future storage variables
    uint256[50] private __gap;
}