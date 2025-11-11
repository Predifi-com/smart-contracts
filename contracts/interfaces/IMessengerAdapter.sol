// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../libs/Types.sol";

/**
 * @title IMessengerAdapter
 * @notice Interface for cross-chain messaging adapters
 */
interface IMessengerAdapter {
    // Events
    event BetIntentSent(
        bytes32 indexed messageId,
        bytes32 indexed intentId,
        uint256 sourceChain,
        uint256 targetChain,
        address user,
        uint256 amount,
        bytes32 marketId,
        uint256 outcomeId
    );

    event BetIntentReceived(
        bytes32 indexed messageId,
        bytes32 indexed intentId,
        uint256 sourceChain,
        uint256 targetChain,
        bytes32 releaseId
    );

    event SettlementSent(
        bytes32 indexed messageId,
        bytes32 indexed intentId,
        uint256 sourceChain,
        uint256 targetChain,
        bool outcome,
        uint256 payout
    );

    event SettlementReceived(
        bytes32 indexed messageId,
        bytes32 indexed intentId,
        uint256 sourceChain,
        uint256 targetChain,
        bool outcome,
        uint256 payout
    );

    event StatusUpdateSent(
        bytes32 indexed messageId,
        bytes32 indexed intentId,
        uint256 sourceChain,
        uint256 targetChain,
        Types.IntentState status
    );

    event CrossChainMessage(
        bytes32 indexed messageId,
        uint256 sourceChain,
        uint256 targetChain,
        address remoteAdapter,
        address targetContract,
        bytes32 messageType,
        bytes message
    );

    event MessageFailed(bytes32 indexed messageId, string reason);
    event RemoteAdapterSet(uint256 indexed chainId, address adapter);
    event BetManagerSet(uint256 indexed chainId, address betManager);
    event SettlementAuthoritySet(uint256 indexed chainId, address settlementAuthority);
    event EmergencyMessageMarked(bytes32 indexed messageId);
    event L2MessengerSet(address indexed messenger);
    event ChainTypeSet(uint256 indexed chainId, bool isSuperchain);

    // Functions
    function sendBetIntent(
        Types.BetIntent calldata intent,
        uint256 targetChainId
    ) external returns (bytes32 messageId);
    
    function receiveBetIntent(
        bytes32 messageId,
        uint256 sourceChainId,
        Types.BetIntent calldata intent
    ) external returns (bytes32 releaseId);
    
    function sendSettlement(
        bytes32 intentId,
        Types.SettlementData calldata settlement,
        uint256 targetChainId
    ) external returns (bytes32 messageId);

    function receiveSettlement(
        bytes32 messageId,
        uint256 sourceChainId,
        bytes32 intentId,
        Types.SettlementData calldata settlement
    ) external;

    // Configuration functions
    function setRemoteAdapter(uint256 chainId, address adapter) external;
    function setBetManager(uint256 chainId, address betManager) external;
    
    // View functions
    function getRemoteAdapter(uint256 chainId) external view returns (address);
    function isChainSupported(uint256 chainId) external view returns (bool);
}