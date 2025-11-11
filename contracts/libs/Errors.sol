// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Errors
 * @notice Centralized custom errors for the Predifi protocol
 * @dev Using custom errors saves gas compared to require strings
 *      and provides structured error data for better debugging
 */
library Errors {
    // ========================================
    // COMMON ERRORS
    // ========================================
    
    /// @notice Zero address provided where non-zero address required
    error ZeroAddress();
    
    /// @notice Zero amount provided where non-zero amount required
    error ZeroAmount();
    
    /// @notice Insufficient balance for operation
    /// @param required Amount required
    /// @param available Amount available
    error InsufficientBalance(uint256 required, uint256 available);
    
    /// @notice Operation would exceed configured cap
    /// @param newAmount Proposed new amount
    /// @param cap Maximum allowed amount
    error CapExceeded(uint256 newAmount, uint256 cap);
    
    /// @notice Caller is not authorized for this operation
    /// @param caller Address of the caller
    /// @param requiredRole Role required for operation
    error UnauthorizedCaller(address caller, bytes32 requiredRole);
    
    /// @notice Operation is not allowed in current contract state
    /// @param currentState Description of current state
    error InvalidState(string currentState);
    
    /// @notice Array lengths do not match
    /// @param length1 Length of first array
    /// @param length2 Length of second array
    error ArrayLengthMismatch(uint256 length1, uint256 length2);
    
    /// @notice Invalid parameter provided
    /// @param parameter Name of the invalid parameter
    /// @param reason Reason why parameter is invalid
    error InvalidParameter(string parameter, string reason);
    
    // ========================================
    // ORDER/RESERVATION ERRORS
    // ========================================
    
    /// @notice Order ID is invalid (zero or malformed)
    /// @param orderId The invalid order ID
    error InvalidOrderId(bytes32 orderId);
    
    /// @notice Order already exists with this ID
    /// @param orderId The duplicate order ID
    error OrderAlreadyExists(bytes32 orderId);
    
    /// @notice Order not found
    /// @param orderId The missing order ID
    error OrderNotFound(bytes32 orderId);
    
    /// @notice Order has expired
    /// @param orderId The expired order ID
    /// @param expiry Expiry timestamp
    /// @param currentTime Current block timestamp
    error OrderExpired(bytes32 orderId, uint64 expiry, uint64 currentTime);
    
    /// @notice Order is not active
    /// @param orderId The inactive order ID
    error OrderNotActive(bytes32 orderId);
    
    /// @notice Insufficient fee cap for operation
    /// @param required Fee amount required
    /// @param available Fee cap available
    error InsufficientFeeCap(uint256 required, uint256 available);
    
    /// @notice Invalid release amounts (would exceed reserved)
    /// @param amountDelta Amount delta requested
    /// @param feeDelta Fee delta requested
    /// @param reservedAmount Total reserved amount
    error InvalidReleaseAmount(uint256 amountDelta, uint256 feeDelta, uint256 reservedAmount);
    
    // ========================================
    // VAULT ERRORS
    // ========================================
    
    /// @notice Balance mismatch detected between actual and tracked
    /// @param token Token address
    /// @param actual Actual ERC20 balance
    /// @param tracked Internally tracked balance
    error BalanceMismatch(address token, uint256 actual, uint256 tracked);
    
    /// @notice Balance is already synchronized
    /// @param token Token address
    error BalanceAlreadySynced(address token);
    
    /// @notice Sync amount doesn't match expected
    /// @param expected Expected sync amount
    /// @param actual Actual sync amount
    error InvalidSyncAmount(uint256 expected, uint256 actual);
    
    /// @notice Unexpected token receipt
    /// @param token Token address
    /// @param amount Amount received
    error UnexpectedTokenReceipt(address token, uint256 amount);
    
    /// @notice Bridge adapter not configured
    error NoBridgeAdapter();
    
    /// @notice Hub vault address not configured
    error NoHubVault();
    
    /// @notice Cannot withdraw while deposits are locked
    /// @param unlockTime When withdrawals will be enabled
    error WithdrawalsLocked(uint256 unlockTime);
    
    // ========================================
    // BET/VENUE ERRORS
    // ========================================
    
    /// @notice Venue is not configured
    /// @param venueId The venue ID
    error VenueNotConfigured(uint256 venueId);
    
    /// @notice Venue is disabled
    /// @param venueId The venue ID
    error VenueDisabled(uint256 venueId);
    
    /// @notice Invalid venue ID
    /// @param venueId The invalid venue ID
    error InvalidVenue(uint256 venueId);
    
    /// @notice Bet intent is invalid
    /// @param reason Reason why intent is invalid
    error InvalidBetIntent(string reason);
    
    /// @notice Market does not exist
    /// @param marketId The market ID
    error MarketNotFound(bytes32 marketId);
    
    /// @notice Market is not active for betting
    /// @param marketId The market ID
    /// @param status Current market status
    error MarketNotActive(bytes32 marketId, string status);
    
    // ========================================
    // BRIDGE/MESSAGING ERRORS
    // ========================================
    
    /// @notice Message already processed
    /// @param messageId The message ID
    error MessageAlreadyProcessed(bytes32 messageId);
    
    /// @notice Invalid message nonce
    /// @param expected Expected nonce
    /// @param actual Actual nonce
    error InvalidNonce(uint256 expected, uint256 actual);
    
    /// @notice Message sender not authorized
    /// @param sender Message sender
    /// @param expectedSender Expected sender
    error InvalidMessageSender(address sender, address expectedSender);
    
    /// @notice Invalid source chain
    /// @param sourceChainId Source chain ID
    error InvalidSourceChain(uint256 sourceChainId);
    
    /// @notice Bridge operation failed
    /// @param reason Failure reason
    error BridgeFailed(string reason);
    
    /// @notice CCTP attestation failed
    /// @param messageHash Message hash
    error AttestationFailed(bytes32 messageHash);
    
    // ========================================
    // TOKEN/ERC ERRORS
    // ========================================
    
    /// @notice Token transfer failed
    /// @param token Token address
    /// @param from Sender address
    /// @param to Recipient address
    /// @param amount Amount
    error TransferFailed(address token, address from, address to, uint256 amount);
    
    /// @notice Insufficient allowance
    /// @param token Token address
    /// @param owner Token owner
    /// @param spender Spender address
    /// @param required Required allowance
    /// @param actual Actual allowance
    error InsufficientAllowance(address token, address owner, address spender, uint256 required, uint256 actual);
    
    /// @notice Token not supported
    /// @param token Token address
    error TokenNotSupported(address token);
    
    // ========================================
    // CLOB ERRORS
    // ========================================
    
    /// @notice Invalid price for order
    /// @param price Invalid price value
    error InvalidPrice(uint256 price);
    
    /// @notice Invalid size for order
    /// @param size Invalid size value
    error InvalidSize(uint256 size);
    
    /// @notice Order cannot be filled
    /// @param orderId Order ID
    /// @param reason Reason for failure
    error CannotFillOrder(bytes32 orderId, string reason);
    
    /// @notice Market already settled
    /// @param marketId Market ID
    error MarketAlreadySettled(bytes32 marketId);
    
    /// @notice Market not yet resolvable
    /// @param marketId Market ID
    /// @param earliestResolution Earliest resolution time
    error MarketNotResolvable(bytes32 marketId, uint256 earliestResolution);
    
    /// @notice Invalid market outcome
    /// @param outcome Provided outcome
    error InvalidOutcome(uint8 outcome);
    
    // ========================================
    // ORACLE ERRORS
    // ========================================
    
    /// @notice Oracle price is stale
    /// @param feedId Feed identifier
    /// @param lastUpdate Last update timestamp
    /// @param maxAge Maximum allowed age
    error StalePriceData(bytes32 feedId, uint256 lastUpdate, uint256 maxAge);
    
    /// @notice Oracle price is invalid
    /// @param feedId Feed identifier
    /// @param price Invalid price value
    error InvalidOraclePrice(bytes32 feedId, int256 price);
    
    /// @notice Oracle not initialized
    /// @param feedId Feed identifier
    error OracleNotInitialized(bytes32 feedId);
    
    // ========================================
    // SETTLEMENT ERRORS
    // ========================================
    
    /// @notice Attestation is invalid
    /// @param orderId Order ID
    /// @param reason Reason for invalidity
    error InvalidAttestation(bytes32 orderId, string reason);
    
    /// @notice Settlement amount exceeds reserved
    /// @param orderId Order ID
    /// @param requested Requested settlement amount
    /// @param available Available amount
    error SettlementExceedsReserved(bytes32 orderId, uint256 requested, uint256 available);
    
    /// @notice Insufficient authority to settle
    /// @param caller Caller address
    error InsufficientSettlementAuthority(address caller);
    
    // ========================================
    // TIMELOCK/ACCESS ERRORS
    // ========================================
    
    /// @notice Operation is timelocked
    /// @param operation Operation identifier
    /// @param unlockTime When operation will be available
    error OperationTimelocked(bytes32 operation, uint256 unlockTime);
    
    /// @notice Timelock delay too short
    /// @param provided Provided delay
    /// @param minimum Minimum required delay
    error TimelockDelayTooShort(uint256 provided, uint256 minimum);
    
    /// @notice Timelock delay too long
    /// @param provided Provided delay
    /// @param maximum Maximum allowed delay
    error TimelockDelayTooLong(uint256 provided, uint256 maximum);
    
    // ========================================
    // PAUSABLE ERRORS
    // ========================================
    
    /// @notice Operation not allowed while paused
    error ContractPaused();
    
    /// @notice Operation not allowed while not paused
    error ContractNotPaused();
    
    // ========================================
    // REENTRANCY ERRORS
    // ========================================
    
    /// @notice Reentrant call detected
    error ReentrantCall();
    
    // ========================================
    // MATH/OVERFLOW ERRORS
    // ========================================
    
    /// @notice Arithmetic operation resulted in overflow
    error MathOverflow();
    
    /// @notice Arithmetic operation resulted in underflow
    error MathUnderflow();
    
    /// @notice Division by zero attempted
    error DivisionByZero();
    
    /// @notice Percentage value exceeds 100%
    /// @param percentage Invalid percentage value
    error InvalidPercentage(uint256 percentage);
}
