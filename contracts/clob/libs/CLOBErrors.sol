// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./CLOBTypes.sol";

/**
 * @title CLOBErrors
 * @notice Custom errors for CLOB system
 * @dev Centralized error definitions for gas efficiency
 */
library CLOBErrors {
    // Market errors
    error MarketNotFound(uint256 marketId);
    error MarketAlreadyResolved(uint256 marketId);
    error MarketNotResolved(uint256 marketId);
    error MarketExpired(uint256 marketId);
    error MarketNotExpired(uint256 marketId);
    error MarketPaused(uint256 marketId);
    error InvalidMarketTime(uint256 endTime, uint256 resolveTime);
    error InvalidOutcome(CLOBTypes.Outcome outcome);

    // Order errors
    error OrderNotFound(uint256 orderId);
    error OrderExpired(uint256 orderId);
    error OrderAlreadyFilled(uint256 orderId);
    error OrderAlreadyCancelled(uint256 orderId);
    error InvalidOrderSize(uint256 size);
    error InvalidOrderPrice(uint256 price);
    error InvalidSignature();
    error OrderNonceTooLow(uint256 nonce);
    error UnauthorizedCancellation(address caller, address maker);

    // Settlement errors
    error InsufficientCollateral(uint256 required, uint256 available);
    error InvalidFillSize(uint256 size);
    error PriceMismatch(uint256 expected, uint256 actual);
    error MarketMismatch(uint256 expected, uint256 actual);

    // Fee errors
    error FeeTooHigh(uint16 feeBps, uint16 maxFeeBps);
    error InvalidFeeRecipient(address recipient);

    // Access control
    error Unauthorized(address caller);
    error OnlyFactory(address caller);
    error OnlySettlement(address caller);

    // Oracle errors
    error InvalidOracleSignature();
    error OracleDataStale(uint256 timestamp);
    error ConditionIdMismatch(bytes32 expected, bytes32 actual);

    // Token errors
    error InvalidTokenId(uint256 tokenId);
    error InsufficientBalance(uint256 required, uint256 available);
    error TransferFailed();

    // General
    error ZeroAddress();
    error ZeroAmount();
    error ArrayLengthMismatch();
}
