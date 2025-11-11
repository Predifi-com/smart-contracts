// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../libs/CLOBTypes.sol";

/**
 * @title IYesNoToken
 * @notice Interface for YES/NO outcome tokens (ERC1155)
 */
interface IYesNoToken {
    function mint(address to, uint256 marketId, bool isYes, uint256 amount) external;
    function burn(address from, uint256 marketId, bool isYes, uint256 amount) external;
    function getTokenId(uint256 marketId, bool isYes) external pure returns (uint256);
    function balanceOfYes(address account, uint256 marketId) external view returns (uint256);
    function balanceOfNo(address account, uint256 marketId) external view returns (uint256);
}

/**
 * @title IMarketFactory
 * @notice Interface for creating and managing prediction markets
 */
interface IMarketFactory {
    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        uint256 endTime,
        uint256 resolveTime,
        bytes32 oracleConditionId,
        uint16 feeBps
    );
    
    event MarketResolved(
        uint256 indexed marketId,
        CLOBTypes.Outcome outcome,
        uint256 timestamp
    );
    
    event MarketPaused(uint256 indexed marketId, bool paused);
    event FeeUpdated(uint256 indexed marketId, uint16 feeBps);

    function createMarket(
        string calldata question,
        uint256 endTime,
        uint256 resolveTime,
        bytes32 oracleConditionId,
        uint16 feeBps
    ) external returns (uint256 marketId);

    function resolveMarket(uint256 marketId, CLOBTypes.ResolutionData calldata data) external;
    function pauseMarket(uint256 marketId, bool paused) external;
    function updateFee(uint256 marketId, uint16 feeBps) external;
    function getMarket(uint256 marketId) external view returns (CLOBTypes.Market memory);
}

/**
 * @title IOrderBook
 * @notice Interface for order management
 */
interface IOrderBook {
    event OrderPlaced(
        uint256 indexed orderId,
        uint256 indexed marketId,
        address indexed maker,
        CLOBTypes.Side side,
        uint256 price,
        uint256 size
    );
    
    event OrderCancelled(uint256 indexed orderId, address indexed maker);
    event OrderFilled(uint256 indexed orderId, uint256 fillSize, uint256 remainingSize);

    function placeOrder(CLOBTypes.Order calldata order) external returns (uint256 orderId);
    function cancelOrder(uint256 orderId) external;
    function updateOrderFill(uint256 orderId, uint256 fillSize) external;
    function getOrder(uint256 orderId) external view returns (CLOBTypes.Order memory);
    function getUserNonce(address user) external view returns (uint256);
}

/**
 * @title ISettlement
 * @notice Interface for settling matched trades
 */
interface ISettlement {
    event TradeFilled(
        uint256 indexed marketId,
        address indexed maker,
        address indexed taker,
        uint256 orderId,
        uint256 size,
        uint256 price,
        uint256 makerFee,
        uint256 takerFee
    );

    function settleTrade(CLOBTypes.Fill calldata fill) external;
    function settleMultipleTrades(CLOBTypes.Fill[] calldata fills) external;
    function claimWinnings(uint256 marketId) external returns (uint256 payout);
}

/**
 * @title IOracleAdapter
 * @notice Interface for Stork oracle integration
 */
interface IOracleAdapter {
    event OracleUpdated(address indexed newOracle);
    
    function verifyResolution(
        bytes32 conditionId,
        CLOBTypes.Outcome outcome,
        uint256 timestamp,
        bytes calldata signature
    ) external view returns (bool);
    
    function getStorkOracle() external view returns (address);
}

/**
 * @title IFeeCollector
 * @notice Interface for fee collection and distribution
 */
interface IFeeCollector {
    event FeeCollected(
        uint256 indexed marketId,
        address indexed from,
        uint256 amount,
        uint16 feeBps
    );
    
    event FeeWithdrawn(address indexed recipient, uint256 amount);
    event FeeConfigUpdated(uint16 defaultFeeBps, uint16 maxFeeBps);

    function collectFee(uint256 marketId, address from, uint256 amount) external returns (uint256 fee);
    function withdrawFees(address recipient, uint256 amount) external;
    function updateFeeConfig(uint16 defaultFeeBps, uint16 maxFeeBps) external;
    function getFeeConfig() external view returns (CLOBTypes.FeeConfig memory);
}
