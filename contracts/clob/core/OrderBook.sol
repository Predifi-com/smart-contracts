// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../libs/CLOBTypes.sol";
import "../libs/CLOBErrors.sol";
import "../interfaces/ICLOBCore.sol";

/**
 * @title OrderBook
 * @notice Manages orders for offchain matching with onchain settlement
 * @dev Uses EIP-712 for order signatures, stores orders for validation
 * @custom:security-contact security@predifi.com
 */
contract OrderBook is 
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IOrderBook
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Market factory reference
    IMarketFactory public marketFactory;

    /// @notice Next order ID
    uint256 public nextOrderId;

    /// @notice Order registry
    mapping(uint256 => CLOBTypes.Order) public orders;

    /// @notice User nonces for replay protection
    mapping(address => uint256) public userNonces;

    /// @notice EIP-712 domain separator
    bytes32 private _domainSeparator;

    /// @notice EIP-712 type hash for orders
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint256 orderId,uint256 marketId,address maker,uint8 side,uint256 price,uint256 size,uint256 nonce,uint256 expiry)"
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param admin Address to receive admin roles
     * @param marketFactory_ Market factory address
     */
    function initialize(
        address admin,
        address marketFactory_
    ) public initializer {
        if (admin == address(0) || marketFactory_ == address(0)) {
            revert CLOBErrors.ZeroAddress();
        }

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);

        marketFactory = IMarketFactory(marketFactory_);
        nextOrderId = 1;

        _domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PredifiOrderBook"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Place a new order with EIP-712 signature
     * @param order Order details with signature
     * @return orderId The created order ID
     */
    function placeOrder(CLOBTypes.Order calldata order) 
        external 
        nonReentrant 
        returns (uint256 orderId) 
    {
        // Validate market is active
        CLOBTypes.Market memory market = marketFactory.getMarket(order.marketId);
        if (market.paused) revert CLOBErrors.MarketPaused(order.marketId);
        if (market.resolved) revert CLOBErrors.MarketAlreadyResolved(order.marketId);
        if (block.timestamp >= market.endTime) revert CLOBErrors.MarketExpired(order.marketId);

        // Validate order parameters
        if (order.size == 0) revert CLOBErrors.InvalidOrderSize(order.size);
        if (order.price == 0 || order.price >= CLOBTypes.BPS_DIVISOR) {
            revert CLOBErrors.InvalidOrderPrice(order.price);
        }
        if (order.expiry <= block.timestamp) revert CLOBErrors.OrderExpired(0);

        // Verify nonce
        if (order.nonce < userNonces[order.maker]) {
            revert CLOBErrors.OrderNonceTooLow(order.nonce);
        }

        // Verify signature
        _verifyOrderSignature(order);

        // Assign order ID and store
        orderId = nextOrderId++;
        
        orders[orderId] = CLOBTypes.Order({
            orderId: orderId,
            marketId: order.marketId,
            maker: order.maker,
            side: order.side,
            price: order.price,
            size: order.size,
            filled: 0,
            nonce: order.nonce,
            expiry: order.expiry,
            signature: order.signature
        });

        // Update nonce
        userNonces[order.maker] = order.nonce + 1;

        emit OrderPlaced(
            orderId,
            order.marketId,
            order.maker,
            order.side,
            order.price,
            order.size
        );
    }

    /**
     * @notice Cancel an order
     * @param orderId Order to cancel
     */
    function cancelOrder(uint256 orderId) external nonReentrant {
        CLOBTypes.Order storage order = orders[orderId];
        
        if (order.orderId == 0) revert CLOBErrors.OrderNotFound(orderId);
        if (msg.sender != order.maker && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert CLOBErrors.UnauthorizedCancellation(msg.sender, order.maker);
        }
        if (order.filled == order.size) revert CLOBErrors.OrderAlreadyFilled(orderId);

        // Mark as fully filled (cancelled)
        order.filled = order.size;

        emit OrderCancelled(orderId, order.maker);
    }

    /**
     * @notice Update order fill amount (called by Settlement)
     * @param orderId Order ID
     * @param fillSize Amount filled
     */
    function updateOrderFill(uint256 orderId, uint256 fillSize) 
        external 
        onlyRole(OPERATOR_ROLE) 
    {
        CLOBTypes.Order storage order = orders[orderId];
        
        if (order.orderId == 0) revert CLOBErrors.OrderNotFound(orderId);
        if (order.filled + fillSize > order.size) {
            revert CLOBErrors.InvalidFillSize(fillSize);
        }

        order.filled += fillSize;

        emit OrderFilled(orderId, fillSize, order.size - order.filled);
    }

    /**
     * @notice Verify EIP-712 order signature
     * @param order Order to verify
     */
    function _verifyOrderSignature(CLOBTypes.Order calldata order) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.orderId,
                order.marketId,
                order.maker,
                uint8(order.side),
                order.price,
                order.size,
                order.nonce,
                order.expiry
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator, structHash)
        );

        address signer = digest.recover(order.signature);
        
        if (signer != order.maker) revert CLOBErrors.InvalidSignature();
    }

    /**
     * @notice Get order details
     * @param orderId Order identifier
     * @return Order struct
     */
    function getOrder(uint256 orderId) external view returns (CLOBTypes.Order memory) {
        CLOBTypes.Order memory order = orders[orderId];
        if (order.orderId == 0) revert CLOBErrors.OrderNotFound(orderId);
        return order;
    }

    /**
     * @notice Get user's current nonce
     * @param user User address
     * @return Current nonce
     */
    function getUserNonce(address user) external view returns (uint256) {
        return userNonces[user];
    }

    /**
     * @notice Check if order is fillable
     * @param orderId Order ID
     * @return True if order can be filled
     */
    function isOrderFillable(uint256 orderId) external view returns (bool) {
        CLOBTypes.Order memory order = orders[orderId];
        
        if (order.orderId == 0) return false;
        if (order.filled >= order.size) return false;
        if (block.timestamp >= order.expiry) return false;

        CLOBTypes.Market memory market = marketFactory.getMarket(order.marketId);
        if (market.paused || market.resolved || block.timestamp >= market.endTime) {
            return false;
        }

        return true;
    }

    /**
     * @notice Get domain separator
     * @return EIP-712 domain separator
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator;
    }

    /**
     * @notice Authorize upgrades (UUPS pattern)
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(UPGRADER_ROLE) 
    {
        // Authorization check via modifier
    }
}
