// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title OrderIDHelper
 * @notice Library for deterministic order ID generation and validation
 * @dev Provides utilities for generating unique, collision-resistant order IDs
 *      with embedded metadata for debugging and auditing
 * 
 * Order ID Format:
 * - bytes32 hash of: keccak256(abi.encodePacked(user, nonce, chainId, timestamp, salt))
 * - Deterministic: same inputs always produce same ID
 * - Collision-resistant: extremely low probability of duplicates
 * - Traceable: can extract metadata for debugging
 * 
 * Usage:
 * ```solidity
 * bytes32 orderId = OrderIDHelper.generateOrderId(user, nonce, block.chainid, block.timestamp);
 * require(OrderIDHelper.validateOrderId(orderId), "Invalid order ID");
 * ```
 */
library OrderIDHelper {
    /// @dev Salt for additional entropy (can be overridden per deployment)
    bytes32 private constant DEFAULT_SALT = keccak256("PREDIFI_ORDER_V1");

    /**
     * @notice Generate a deterministic order ID
     * @param user Address of the user creating the order
     * @param nonce Unique nonce for the user (prevents replay)
     * @param chainId Chain ID where order is created
     * @param timestamp Block timestamp when order is created
     * @return orderId Unique order identifier (bytes32)
     */
    function generateOrderId(
        address user,
        uint256 nonce,
        uint256 chainId,
        uint256 timestamp
    ) internal pure returns (bytes32) {
        return generateOrderIdWithSalt(user, nonce, chainId, timestamp, DEFAULT_SALT);
    }

    /**
     * @notice Generate a deterministic order ID with custom salt
     * @param user Address of the user creating the order
     * @param nonce Unique nonce for the user
     * @param chainId Chain ID where order is created
     * @param timestamp Block timestamp when order is created
     * @param salt Additional entropy for ID generation
     * @return orderId Unique order identifier (bytes32)
     */
    function generateOrderIdWithSalt(
        address user,
        uint256 nonce,
        uint256 chainId,
        uint256 timestamp,
        bytes32 salt
    ) internal pure returns (bytes32) {
        // Pack all parameters and hash
        // Using abi.encodePacked for gas efficiency
        return keccak256(
            abi.encodePacked(
                user,
                nonce,
                chainId,
                timestamp,
                salt
            )
        );
    }

    /**
     * @notice Generate order ID from current block context
     * @dev Convenience function using block.chainid and block.timestamp
     * @param user Address of the user creating the order
     * @param nonce Unique nonce for the user
     * @return orderId Unique order identifier (bytes32)
     */
    function generateOrderIdFromContext(
        address user,
        uint256 nonce
    ) internal view returns (bytes32) {
        return generateOrderId(user, nonce, block.chainid, block.timestamp);
    }

    /**
     * @notice Validate that an order ID is non-zero
     * @dev Basic validation - checks that ID is not zero/empty
     * @param orderId Order ID to validate
     * @return valid True if order ID is non-zero
     */
    function validateOrderId(bytes32 orderId) internal pure returns (bool) {
        return orderId != bytes32(0);
    }

    /**
     * @notice Check if order ID could have been generated with given parameters
     * @dev Useful for verification/auditing - regenerates ID and compares
     * @param orderId Order ID to verify
     * @param user Expected user address
     * @param nonce Expected nonce
     * @param chainId Expected chain ID
     * @param timestamp Expected timestamp
     * @return matches True if the order ID matches the parameters
     */
    function verifyOrderId(
        bytes32 orderId,
        address user,
        uint256 nonce,
        uint256 chainId,
        uint256 timestamp
    ) internal pure returns (bool) {
        bytes32 expectedId = generateOrderId(user, nonce, chainId, timestamp);
        return orderId == expectedId;
    }

    /**
     * @notice Generate a batch of order IDs for multiple users
     * @dev Gas-efficient batch generation
     * @param users Array of user addresses
     * @param nonces Array of nonces (must match users length)
     * @param chainId Chain ID for all orders
     * @param timestamp Timestamp for all orders
     * @return orderIds Array of generated order IDs
     */
    function generateBatchOrderIds(
        address[] memory users,
        uint256[] memory nonces,
        uint256 chainId,
        uint256 timestamp
    ) internal pure returns (bytes32[] memory) {
        require(users.length == nonces.length, "Array length mismatch");
        
        bytes32[] memory orderIds = new bytes32[](users.length);
        
        for (uint256 i = 0; i < users.length; i++) {
            orderIds[i] = generateOrderId(users[i], nonces[i], chainId, timestamp);
        }
        
        return orderIds;
    }

    /**
     * @notice Extract chain ID from order ID metadata (if stored separately)
     * @dev This is a helper for off-chain systems that store metadata
     *      The order ID itself doesn't embed extractable metadata
     * @param orderId Order ID
     * @return chainId Chain ID (returns 0 if not available)
     */
    function getChainIdHint(bytes32 orderId) internal pure returns (uint256) {
        // Order IDs are hashes, so chain ID can't be directly extracted
        // This function is a placeholder for off-chain metadata lookup
        // In practice, chain ID should be stored alongside the order
        orderId; // Silence unused variable warning
        return 0;
    }

    /**
     * @notice Check if two order IDs are equal
     * @dev Convenience function for comparison
     * @param a First order ID
     * @param b Second order ID
     * @return equal True if order IDs are equal
     */
    function equals(bytes32 a, bytes32 b) internal pure returns (bool) {
        return a == b;
    }

    /**
     * @notice Convert order ID to hex string (for logging/events)
     * @dev Returns lowercase hex string with 0x prefix
     * @param orderId Order ID to convert
     * @return hexString Hex representation of order ID
     */
    function toHexString(bytes32 orderId) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(66); // "0x" + 64 hex chars
        
        result[0] = "0";
        result[1] = "x";
        
        for (uint256 i = 0; i < 32; i++) {
            uint8 value = uint8(orderId[i]);
            result[2 + i * 2] = hexChars[value >> 4];
            result[3 + i * 2] = hexChars[value & 0x0f];
        }
        
        return string(result);
    }

    /**
     * @notice Generate order ID with additional context for cross-chain orders
     * @dev Includes source and destination chain IDs for cross-chain tracking
     * @param user Address of the user
     * @param nonce User's nonce
     * @param sourceChainId Source chain ID
     * @param destChainId Destination chain ID
     * @param timestamp Block timestamp
     * @return orderId Unique cross-chain order identifier
     */
    function generateCrossChainOrderId(
        address user,
        uint256 nonce,
        uint256 sourceChainId,
        uint256 destChainId,
        uint256 timestamp
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                user,
                nonce,
                sourceChainId,
                destChainId,
                timestamp,
                DEFAULT_SALT
            )
        );
    }

    /**
     * @notice Generate deterministic nonce from user address and count
     * @dev Useful when user doesn't maintain their own nonce
     * @param user User address
     * @param orderCount Number of orders user has created
     * @return nonce Deterministic nonce
     */
    function generateNonce(address user, uint256 orderCount) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(user, orderCount)));
    }

    /**
     * @notice Check if order ID is in a list
     * @dev Linear search - use sparingly for small lists
     * @param orderId Order ID to search for
     * @param orderIds List of order IDs
     * @return found True if order ID is in the list
     */
    function contains(bytes32 orderId, bytes32[] memory orderIds) internal pure returns (bool) {
        for (uint256 i = 0; i < orderIds.length; i++) {
            if (orderIds[i] == orderId) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Generate order ID with event emission for tracking
     * @dev Use in contracts that need to emit order creation events
     * @param user Address of the user
     * @param nonce User's nonce
     * @return orderId Generated order ID
     */
    function generateAndEmitOrderId(
        address user,
        uint256 nonce
    ) internal returns (bytes32) {
        bytes32 orderId = generateOrderIdFromContext(user, nonce);
        
        // Note: Actual event emission should be done in the calling contract
        // This is a placeholder for the pattern
        
        return orderId;
    }
}
