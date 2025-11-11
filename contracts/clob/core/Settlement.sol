// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../libs/CLOBTypes.sol";
import "../libs/CLOBErrors.sol";
import "../interfaces/ICLOBCore.sol";

/**
 * @title Settlement
 * @notice Settles matched trades onchain and handles winnings claims
 * @dev Core settlement logic for CLOB prediction markets
 * @custom:security-contact security@predifi.com
 */
contract Settlement is 
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    ISettlement
{
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Market factory
    IMarketFactory public marketFactory;

    /// @notice Order book
    IOrderBook public orderBook;

    /// @notice YesNo tokens
    IYesNoToken public yesNoToken;

    /// @notice Fee collector
    IFeeCollector public feeCollector;

    /// @notice Collateral token (e.g., USDC)
    IERC20 public collateralToken;

    /// @notice User collateral balances per market
    mapping(address => mapping(uint256 => uint256)) public userCollateral;

    /// @notice Total collateral locked per market
    mapping(uint256 => uint256) public marketCollateral;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param admin Address to receive admin roles
     * @param marketFactory_ Market factory address
     * @param orderBook_ Order book address
     * @param yesNoToken_ YesNoToken address
     * @param feeCollector_ Fee collector address
     * @param collateralToken_ Collateral token address
     */
    function initialize(
        address admin,
        address marketFactory_,
        address orderBook_,
        address yesNoToken_,
        address feeCollector_,
        address collateralToken_
    ) public initializer {
        if (admin == address(0) || marketFactory_ == address(0) || 
            orderBook_ == address(0) || yesNoToken_ == address(0) ||
            feeCollector_ == address(0) || collateralToken_ == address(0)) {
            revert CLOBErrors.ZeroAddress();
        }

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(SETTLER_ROLE, admin);

        marketFactory = IMarketFactory(marketFactory_);
        orderBook = IOrderBook(orderBook_);
        yesNoToken = IYesNoToken(yesNoToken_);
        feeCollector = IFeeCollector(feeCollector_);
        collateralToken = IERC20(collateralToken_);
    }

    /**
     * @notice Settle a matched trade
     * @param fill Fill data from offchain matcher
     */
    function settleTrade(CLOBTypes.Fill calldata fill) 
        external 
        onlyRole(SETTLER_ROLE) 
        nonReentrant 
    {
        _settleTrade(fill);
    }

    /**
     * @notice Settle multiple trades in batch
     * @param fills Array of fill data
     */
    function settleMultipleTrades(CLOBTypes.Fill[] calldata fills) 
        external 
        onlyRole(SETTLER_ROLE) 
        nonReentrant 
    {
        for (uint256 i = 0; i < fills.length; i++) {
            _settleTrade(fills[i]);
        }
    }

    /**
     * @notice Internal trade settlement logic
     * @param fill Fill data
     */
    function _settleTrade(CLOBTypes.Fill calldata fill) internal {
        // Validate market
        CLOBTypes.Market memory market = marketFactory.getMarket(fill.marketId);
        if (market.paused) revert CLOBErrors.MarketPaused(fill.marketId);
        if (market.resolved) revert CLOBErrors.MarketAlreadyResolved(fill.marketId);
        if (block.timestamp >= market.endTime) revert CLOBErrors.MarketExpired(fill.marketId);

        // Validate order
        CLOBTypes.Order memory order = orderBook.getOrder(fill.orderId);
        if (order.maker != fill.maker) revert CLOBErrors.Unauthorized(fill.maker);
        if (order.marketId != fill.marketId) {
            revert CLOBErrors.MarketMismatch(order.marketId, fill.marketId);
        }
        if (order.price != fill.price) {
            revert CLOBErrors.PriceMismatch(order.price, fill.price);
        }

        // Calculate collateral requirements
        // For YES buyer: pay price * size
        // For NO buyer: pay (1 - price) * size
        uint256 makerCollateral;
        uint256 takerCollateral;

        if (fill.makerSide == CLOBTypes.Side.BUY) {
            // Maker buys YES, taker buys NO
            makerCollateral = (fill.size * fill.price) / CLOBTypes.BPS_DIVISOR;
            takerCollateral = fill.size - makerCollateral;
        } else {
            // Maker buys NO, taker buys YES
            takerCollateral = (fill.size * fill.price) / CLOBTypes.BPS_DIVISOR;
            makerCollateral = fill.size - takerCollateral;
        }

        // Transfer collateral from participants
        collateralToken.safeTransferFrom(fill.maker, address(this), makerCollateral);
        collateralToken.safeTransferFrom(fill.taker, address(this), takerCollateral);

        // Update collateral tracking
        userCollateral[fill.maker][fill.marketId] += makerCollateral;
        userCollateral[fill.taker][fill.marketId] += takerCollateral;
        marketCollateral[fill.marketId] += fill.size;

        // Mint position tokens
        if (fill.makerSide == CLOBTypes.Side.BUY) {
            yesNoToken.mint(fill.maker, fill.marketId, true, fill.size);   // YES tokens
            yesNoToken.mint(fill.taker, fill.marketId, false, fill.size);  // NO tokens
        } else {
            yesNoToken.mint(fill.maker, fill.marketId, false, fill.size);  // NO tokens
            yesNoToken.mint(fill.taker, fill.marketId, true, fill.size);   // YES tokens
        }

        // Update order fill status
        orderBook.updateOrderFill(fill.orderId, fill.size);

        emit TradeFilled(
            fill.marketId,
            fill.maker,
            fill.taker,
            fill.orderId,
            fill.size,
            fill.price,
            0, // No maker fee on trade execution
            0  // No taker fee on trade execution
        );
    }

    /**
     * @notice Claim winnings after market resolution
     * @param marketId Market to claim from
     * @return payout Amount paid out (after fees)
     */
    function claimWinnings(uint256 marketId) 
        external 
        nonReentrant 
        returns (uint256 payout) 
    {
        CLOBTypes.Market memory market = marketFactory.getMarket(marketId);
        
        if (!market.resolved) revert CLOBErrors.MarketNotResolved(marketId);
        if (market.outcome == CLOBTypes.Outcome.UNRESOLVED) {
            revert CLOBErrors.InvalidOutcome(market.outcome);
        }

        address user = msg.sender;
        uint256 winningTokens;

        // Determine winning tokens
        if (market.outcome == CLOBTypes.Outcome.YES) {
            winningTokens = yesNoToken.balanceOfYes(user, marketId);
            if (winningTokens > 0) {
                yesNoToken.burn(user, marketId, true, winningTokens);
            }
        } else if (market.outcome == CLOBTypes.Outcome.NO) {
            winningTokens = yesNoToken.balanceOfNo(user, marketId);
            if (winningTokens > 0) {
                yesNoToken.burn(user, marketId, false, winningTokens);
            }
        } else if (market.outcome == CLOBTypes.Outcome.INVALID) {
            // Return proportional collateral on invalid outcome
            uint256 userColl = userCollateral[user][marketId];
            if (userColl > 0) {
                userCollateral[user][marketId] = 0;
                collateralToken.safeTransfer(user, userColl);
                return userColl;
            }
        }

        if (winningTokens == 0) return 0;

        // Calculate gross payout (1:1 with tokens)
        uint256 grossPayout = winningTokens;

        // Collect fee from winner (fee-on-resolve model)
        uint256 fee = feeCollector.collectFee(marketId, user, grossPayout);

        // Net payout after fee
        payout = grossPayout - fee;

        // Transfer payout
        collateralToken.safeTransfer(user, payout);

        // Clear user collateral tracking
        userCollateral[user][marketId] = 0;
    }

    /**
     * @notice Deposit collateral for a market
     * @param marketId Market identifier
     * @param amount Amount to deposit
     */
    function depositCollateral(uint256 marketId, uint256 amount) 
        external 
        nonReentrant 
    {
        if (amount == 0) revert CLOBErrors.ZeroAmount();

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        userCollateral[msg.sender][marketId] += amount;
    }

    /**
     * @notice Withdraw unused collateral
     * @param marketId Market identifier
     * @param amount Amount to withdraw
     */
    function withdrawCollateral(uint256 marketId, uint256 amount) 
        external 
        nonReentrant 
    {
        if (amount == 0) revert CLOBErrors.ZeroAmount();

        uint256 available = userCollateral[msg.sender][marketId];
        if (amount > available) {
            revert CLOBErrors.InsufficientCollateral(amount, available);
        }

        userCollateral[msg.sender][marketId] -= amount;
        collateralToken.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Get user's position in a market
     * @param user User address
     * @param marketId Market identifier
     * @return position Position details
     */
    function getPosition(address user, uint256 marketId) 
        external 
        view 
        returns (CLOBTypes.Position memory position) 
    {
        position.yesTokens = yesNoToken.balanceOfYes(user, marketId);
        position.noTokens = yesNoToken.balanceOfNo(user, marketId);
        position.collateral = userCollateral[user][marketId];
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
