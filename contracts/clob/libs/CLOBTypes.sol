// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title CLOBTypes
 * @notice Shared type definitions for CLOB prediction markets
 * @dev Self-contained library with no external dependencies
 */
library CLOBTypes {
    /// @notice Market outcome states
    enum Outcome {
        UNRESOLVED,
        YES,
        NO,
        INVALID
    }

    /// @notice Order side
    enum Side {
        BUY,  // Buy YES tokens (bet on YES outcome)
        SELL  // Sell YES tokens (bet on NO outcome)
    }

    /// @notice Order status
    enum OrderStatus {
        OPEN,
        FILLED,
        CANCELLED,
        EXPIRED
    }

    /// @notice Market configuration
    struct Market {
        uint256 marketId;
        address creator;
        string question;
        uint256 endTime;
        uint256 resolveTime;
        Outcome outcome;
        bytes32 oracleConditionId;  // Stork condition identifier
        uint16 feeBps;              // Fee in basis points (0-500 = 0-5%)
        bool resolved;
        bool paused;
    }

    /// @notice Order structure for offchain matching
    struct Order {
        uint256 orderId;
        uint256 marketId;
        address maker;
        Side side;
        uint256 price;          // Price in basis points (0-10000 = 0-100%)
        uint256 size;           // Amount of tokens
        uint256 filled;         // Amount filled
        uint256 nonce;
        uint256 expiry;
        bytes signature;        // EIP-712 signature
    }

    /// @notice Matched trade to be settled onchain
    struct Fill {
        uint256 orderId;
        uint256 marketId;
        address maker;
        address taker;
        Side makerSide;
        uint256 price;
        uint256 size;
        uint256 timestamp;
    }

    /// @notice Position state for a user in a market
    struct Position {
        uint256 yesTokens;
        uint256 noTokens;
        uint256 collateral;     // Total collateral locked
    }

    /// @notice Market resolution data from oracle
    struct ResolutionData {
        uint256 marketId;
        bytes32 conditionId;
        Outcome outcome;
        uint256 timestamp;
        bytes oracleSignature;  // Stork oracle signature
    }

    /// @notice Fee configuration
    struct FeeConfig {
        uint16 defaultFeeBps;   // Default fee (e.g., 200 = 2%)
        uint16 maxFeeBps;       // Maximum fee cap (e.g., 500 = 5%)
        address feeRecipient;
    }

    // Constants
    uint256 constant BPS_DIVISOR = 10000;
    uint16 constant MAX_FEE_BPS = 500;     // 5% maximum
    uint16 constant DEFAULT_FEE_BPS = 200; // 2% default
    uint256 constant YES_TOKEN_ID_OFFSET = 0;
    uint256 constant NO_TOKEN_ID_OFFSET = 1;
}
