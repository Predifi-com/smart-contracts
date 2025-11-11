// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../libs/CLOBTypes.sol";
import "../libs/CLOBErrors.sol";
import "../interfaces/ICLOBCore.sol";

/**
 * @title MarketFactory
 * @notice Creates and manages prediction markets
 * @dev Central registry for all markets with lifecycle management
 * @custom:security-contact security@predifi.com
 */
contract MarketFactory is 
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IMarketFactory
{
    bytes32 public constant MARKET_CREATOR_ROLE = keccak256("MARKET_CREATOR_ROLE");
    bytes32 public constant MARKET_RESOLVER_ROLE = keccak256("MARKET_RESOLVER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Oracle adapter for verifying resolutions
    IOracleAdapter public oracleAdapter;

    /// @notice Next market ID
    uint256 public nextMarketId;

    /// @notice Market registry
    mapping(uint256 => CLOBTypes.Market) public markets;

    /// @notice Minimum time between market end and resolve
    uint256 public minResolveDelay;

    /// @notice Maximum time for market resolution after end
    uint256 public maxResolveDelay;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param admin Address to receive admin roles
     * @param oracleAdapter_ Oracle adapter address
     * @param minResolveDelay_ Minimum delay between end and resolve (seconds)
     * @param maxResolveDelay_ Maximum delay for resolution (seconds)
     */
    function initialize(
        address admin,
        address oracleAdapter_,
        uint256 minResolveDelay_,
        uint256 maxResolveDelay_
    ) public initializer {
        if (admin == address(0) || oracleAdapter_ == address(0)) {
            revert CLOBErrors.ZeroAddress();
        }

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(MARKET_CREATOR_ROLE, admin);
        _grantRole(MARKET_RESOLVER_ROLE, admin);

        oracleAdapter = IOracleAdapter(oracleAdapter_);
        minResolveDelay = minResolveDelay_;
        maxResolveDelay = maxResolveDelay_;
        nextMarketId = 1;
    }

    /**
     * @notice Create a new prediction market
     * @param question Market question
     * @param endTime Market end timestamp
     * @param resolveTime Expected resolution timestamp
     * @param oracleConditionId Stork oracle condition identifier
     * @param feeBps Fee in basis points (0-500 = 0-5%)
     * @return marketId The created market ID
     */
    function createMarket(
        string calldata question,
        uint256 endTime,
        uint256 resolveTime,
        bytes32 oracleConditionId,
        uint16 feeBps
    ) external onlyRole(MARKET_CREATOR_ROLE) nonReentrant returns (uint256 marketId) {
        // Validate timing
        if (endTime <= block.timestamp) {
            revert CLOBErrors.InvalidMarketTime(endTime, resolveTime);
        }
        if (resolveTime < endTime + minResolveDelay) {
            revert CLOBErrors.InvalidMarketTime(endTime, resolveTime);
        }
        if (resolveTime > endTime + maxResolveDelay) {
            revert CLOBErrors.InvalidMarketTime(endTime, resolveTime);
        }

        // Validate fee
        if (feeBps == 0) {
            feeBps = CLOBTypes.DEFAULT_FEE_BPS;
        }
        if (feeBps > CLOBTypes.MAX_FEE_BPS) {
            revert CLOBErrors.FeeTooHigh(feeBps, CLOBTypes.MAX_FEE_BPS);
        }

        // Create market
        marketId = nextMarketId++;
        markets[marketId] = CLOBTypes.Market({
            marketId: marketId,
            creator: msg.sender,
            question: question,
            endTime: endTime,
            resolveTime: resolveTime,
            outcome: CLOBTypes.Outcome.UNRESOLVED,
            oracleConditionId: oracleConditionId,
            feeBps: feeBps,
            resolved: false,
            paused: false
        });

        emit MarketCreated(
            marketId,
            msg.sender,
            question,
            endTime,
            resolveTime,
            oracleConditionId,
            feeBps
        );
    }

    /**
     * @notice Resolve a market using oracle data
     * @param marketId Market to resolve
     * @param data Resolution data with oracle signature
     */
    function resolveMarket(
        uint256 marketId,
        CLOBTypes.ResolutionData calldata data
    ) external onlyRole(MARKET_RESOLVER_ROLE) nonReentrant {
        CLOBTypes.Market storage market = markets[marketId];

        // Validate market exists
        if (market.marketId == 0) revert CLOBErrors.MarketNotFound(marketId);
        
        // Check not already resolved
        if (market.resolved) revert CLOBErrors.MarketAlreadyResolved(marketId);

        // Check market has ended
        if (block.timestamp < market.endTime) {
            revert CLOBErrors.MarketNotExpired(marketId);
        }

        // Verify condition ID matches
        if (data.conditionId != market.oracleConditionId) {
            revert CLOBErrors.ConditionIdMismatch(market.oracleConditionId, data.conditionId);
        }

        // Verify oracle signature
        bool valid = oracleAdapter.verifyResolution(
            data.conditionId,
            data.outcome,
            data.timestamp,
            data.oracleSignature
        );
        if (!valid) revert CLOBErrors.InvalidOracleSignature();

        // Validate outcome
        if (data.outcome == CLOBTypes.Outcome.UNRESOLVED) {
            revert CLOBErrors.InvalidOutcome(data.outcome);
        }

        // Resolve market
        market.outcome = data.outcome;
        market.resolved = true;

        emit MarketResolved(marketId, data.outcome, block.timestamp);
    }

    /**
     * @notice Pause or unpause a market
     * @param marketId Market to pause/unpause
     * @param paused True to pause, false to unpause
     */
    function pauseMarket(uint256 marketId, bool paused) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        CLOBTypes.Market storage market = markets[marketId];
        if (market.marketId == 0) revert CLOBErrors.MarketNotFound(marketId);

        market.paused = paused;
        emit MarketPaused(marketId, paused);
    }

    /**
     * @notice Update market fee
     * @param marketId Market to update
     * @param feeBps New fee in basis points
     */
    function updateFee(uint256 marketId, uint16 feeBps) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        CLOBTypes.Market storage market = markets[marketId];
        if (market.marketId == 0) revert CLOBErrors.MarketNotFound(marketId);
        if (market.resolved) revert CLOBErrors.MarketAlreadyResolved(marketId);

        if (feeBps > CLOBTypes.MAX_FEE_BPS) {
            revert CLOBErrors.FeeTooHigh(feeBps, CLOBTypes.MAX_FEE_BPS);
        }

        market.feeBps = feeBps;
        emit FeeUpdated(marketId, feeBps);
    }

    /**
     * @notice Get market details
     * @param marketId Market identifier
     * @return Market struct
     */
    function getMarket(uint256 marketId) external view returns (CLOBTypes.Market memory) {
        CLOBTypes.Market memory market = markets[marketId];
        if (market.marketId == 0) revert CLOBErrors.MarketNotFound(marketId);
        return market;
    }

    /**
     * @notice Check if market is active for trading
     * @param marketId Market identifier
     * @return True if market is active
     */
    function isMarketActive(uint256 marketId) external view returns (bool) {
        CLOBTypes.Market memory market = markets[marketId];
        return market.marketId != 0 
            && !market.resolved 
            && !market.paused 
            && block.timestamp < market.endTime;
    }

    /**
     * @notice Update oracle adapter
     * @param newAdapter New oracle adapter address
     */
    function updateOracleAdapter(address newAdapter) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (newAdapter == address(0)) revert CLOBErrors.ZeroAddress();
        oracleAdapter = IOracleAdapter(newAdapter);
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
