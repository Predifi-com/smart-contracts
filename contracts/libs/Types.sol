// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title Types
 * @notice Shared type definitions for the Predifi protocol
 */
library Types {
    /// @notice Intent states for bet lifecycle tracking
    enum IntentState {
        Deposited,  // Funds deposited, intent created
        Placed,     // Intent sent to venue chain
        Settled     // Bet settled, funds distributed
    }

    /// @notice Bet intent structure for cross-chain betting
    struct BetIntent {
        bytes32 intentId;       // Unique intent identifier
        address user;           // User who created the intent
        address token;          // Token being bet
        uint256 amount;         // Amount being bet
        bytes32 marketId;       // Market identifier
        uint256 outcomeId;      // Outcome being bet on
        uint256 targetChainId;  // Target venue chain
        uint64 expiry;          // Intent expiry timestamp
        IntentState state;      // Current intent state
    }

    /// @notice Release tracking for venue operations
    struct Release {
        bytes32 intentId;       // Associated intent ID
        address token;          // Token being released
        uint256 amount;         // Amount released
        address recipient;      // Recipient of the release
        uint64 releaseTime;     // When funds were released
        bool reclaimed;         // Whether unused funds were reclaimed
        bytes32 venueOrderId;   // Venue-specific order ID
    }

    /// @notice Protocol configuration parameters
    struct ProtocolParams {
        uint256 minBetAmount;       // Minimum bet amount
        uint256 maxBetAmount;       // Maximum bet amount
        uint256 maxIntentDuration;  // Maximum intent duration
        uint256 baseFeeRate;        // Base fee rate (basis points)
        uint256 maxFeeRate;         // Maximum fee rate (basis points)
        uint256 treasuryFeeRate;    // Treasury fee rate (basis points)
        uint256 lpYieldRate;        // LP yield rate (basis points)
    }

    /// @notice Chain configuration
    struct ChainConfig {
        address messengerAdapter;   // Messenger adapter address
        bool enabled;               // Whether chain is enabled
    }

    /// @notice Venue configuration 
    struct VenueConfig {
        address traderSafe;         // Trading safe address
        address bufferVault;        // Buffer vault address (optional)
        bool useBufferVault;        // Whether to use buffer vault
        bool enabled;               // Whether venue is enabled
    }

    /// @notice Settlement data
    struct SettlementData {
        bool outcome;               // Settlement outcome
        uint256 payout;             // Payout amount
    }

    /// @notice Message status tracking
    struct MessageStatus {
        bytes32 messageType;        // Type of message
        uint256 sourceChain;        // Source chain ID
        uint256 targetChain;        // Target chain ID  
        uint64 timestamp;           // Message timestamp
        bool processed;             // Whether processed
        bool failed;                // Whether failed
    }

    // Custom errors for protocol operations
    error Expired();
    error Unauthorized();
    error CapExceeded();
    error InvalidProof();
    error AlreadyProcessed();
    error NotReleased();
    error ReleaseActive();
    error InvalidAmount();
    error InvalidChain();
    error InvalidMarket();
    error InvalidOutcome();
    error TokenNotAccepted();
    error InsufficientBalance();
    error TransferFailed();
    error InvalidConfiguration();
    error RateLimitExceeded();
    error MarketPaused();
    error VenueDisabled();
    error InvalidSlippage();
    error IntentNotFound();
    error InvalidState();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidLength();
    error InvalidPauseId();
    error InvalidChainId();
    error ChainNotSupported();
    error BetManagerNotSet();
    error SettlementAuthorityNotSet();
    error MessageProcessingFailed();
    error InvalidDuration();
    error InvalidFeeRate();
    error InvalidBasisPoints();
    error TooManyRecipients();
}