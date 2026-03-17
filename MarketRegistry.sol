// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract MarketRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    // Roles
    bytes32 public constant MARKET_REGISTRAR_ROLE = keccak256("MARKET_REGISTRAR_ROLE");
    bytes32 public constant SETTLER_ROLE          = keccak256("SETTLER_ROLE");   // MatchSettlement
    bytes32 public constant RESOLVER_ROLE         = keccak256("RESOLVER_ROLE");  // OracleModule
    uint256 public constant MAX_CATEGORICAL_OUTCOMES = 16;

    // Types

    /// @notice Resolution result for BINARY markets.
    enum Outcome { PENDING, YES, NO, INVALID }

    /// @notice Whether trading resolves to a binary YES/NO or one of N outcomes.
    enum MarketType { BINARY, CATEGORICAL }

    /**
     * @notice One possible outcome in a CATEGORICAL market.
     * @param id    Unique identifier — typically keccak256(abi.encodePacked(label)).
     * @param label Human-readable label, e.g. "Trump", "Harris", "Field".
     */
    struct OutcomeDef {
        bytes32 id;
        string  label;
    }

    /// @notice Full on-chain market record.
    struct MarketConfig {
        // Identity
        bytes32  metadataHash;
        string   question;
        string   category;
        string   subCategory;
        string   assetSymbol;
        // Structure
        MarketType   marketType;
        OutcomeDef[] outcomes;
        // Pricing
        uint256  strike;
        uint256  feeBps;
        // Timing
        uint64   startTime;
        uint64   closeTime;
        uint64   createdAt;
        uint64   resolvedAt;
        // Resolution state
        bool     resolved;
        Outcome  outcome;
        bytes32  winningOutcomeId;
        string   reasonURI;
        // Resolution authority
        address  resolver;
        string   resolutionSource;
        // Trading constraints
        uint256  minOrderSize;
        uint256  tickSize;
        uint256  volumeCap;
        // Discovery
        string   groupId;
        string   groupItemTitle;
        address  creatorAddress;
        // Flags
        bool     exists;
        bool     disabled;
    }

    /**
     * @notice Input parameters for registerMarket — avoids stack-too-deep.
     *
     * For BINARY markets:      outcomes should be empty.
     * For CATEGORICAL markets: outcomes must contain >= 2 entries with unique non-zero IDs.
     */
    struct MarketParams {
        bytes32      metadataHash;
        string       question;
        string       category;
        string       subCategory;
        string       assetSymbol;
        MarketType   marketType;
        OutcomeDef[] outcomes;
        uint256      strike;
        uint256      feeBps;
        uint64       startTime;
        uint64       closeTime;
        address      resolver;
        string       resolutionSource;
        uint256      minOrderSize;
        uint256      tickSize;
        uint256      volumeCap;
        string       groupId;
        string       groupItemTitle;
        address      creatorAddress;
    }

    mapping(bytes32 => MarketConfig) private _markets;

    // Events
    event MarketRegistered(
        bytes32    indexed marketId,
        string     question,
        string     category,
        string     subCategory,
        MarketType marketType,
        uint64     closeTime
    );

    event TradeSettled(
        bytes32 indexed marketId,
        address indexed buyer,
        address indexed seller,
        uint256 quantity,
        uint256 price,
        uint256 feeAmount,
        uint256 batchId
    );

    /// @notice Emitted when a BINARY market is resolved.
    event MarketResolved(
        bytes32 indexed marketId,
        Outcome indexed outcome,
        uint64  resolvedAt,
        string  reasonURI
    );

    /// @notice Emitted when a CATEGORICAL market is resolved.
    event MarketResolvedCategorical(
        bytes32 indexed marketId,
        bytes32 indexed winningOutcomeId,
        uint64  resolvedAt,
        string  reasonURI
    );

    event MarketDisabled(bytes32 indexed marketId, bool disabled);

    // Errors
    error MarketNotFound(bytes32 marketId);
    error MarketAlreadyExists(bytes32 marketId);
    error MarketNotTradable(bytes32 marketId);
    error MarketAlreadyResolved(bytes32 marketId);
    error Unauthorized();
    error ZeroAddress();
    error InvalidCloseTime();
    error InvalidStartTime();
    error WrongMarketType(bytes32 marketId);
    error TooFewOutcomes(bytes32 marketId);
    error TooManyOutcomes(bytes32 marketId, uint256 provided);
    error InvalidOutcomeId(bytes32 marketId, bytes32 outcomeId);
    error SelfTradeNotAllowed(address trader);

    // constructor
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE,    admin);
        _grantRole(MARKET_REGISTRAR_ROLE, admin);
        _grantRole(SETTLER_ROLE,          admin);
        _grantRole(RESOLVER_ROLE,         admin);
    }

    // Market Registration

    /**
     * @notice Register a new prediction market.
     * @param marketId  Unique market ID — recommended: keccak256(abi.encode(question, closeTime, creatorAddress)).
     * @param p         Full market parameters — see MarketParams.
     */
    function registerMarket(
        bytes32           marketId,
        MarketParams calldata p
    ) external onlyRole(MARKET_REGISTRAR_ROLE) {
        if (_markets[marketId].exists)       revert MarketAlreadyExists(marketId);
        if (p.closeTime <= block.timestamp)  revert InvalidCloseTime();
        if (p.startTime != 0 && p.startTime >= p.closeTime) revert InvalidStartTime();

        if (p.marketType == MarketType.CATEGORICAL) {
            if (p.outcomes.length < 2) revert TooFewOutcomes(marketId);
            if (p.outcomes.length > MAX_CATEGORICAL_OUTCOMES) {
                revert TooManyOutcomes(marketId, p.outcomes.length);
            }
            for (uint256 i = 0; i < p.outcomes.length; i++) {
                if (p.outcomes[i].id == bytes32(0)) revert InvalidOutcomeId(marketId, bytes32(0));
                for (uint256 j = i + 1; j < p.outcomes.length; j++) {
                    if (p.outcomes[i].id == p.outcomes[j].id)
                        revert InvalidOutcomeId(marketId, p.outcomes[i].id);
                }
            }
        }

        MarketConfig storage m = _markets[marketId];
        m.metadataHash     = p.metadataHash;
        m.question         = p.question;
        m.category         = p.category;
        m.subCategory      = p.subCategory;
        m.assetSymbol      = p.assetSymbol;
        m.marketType       = p.marketType;
        m.strike           = p.strike;
        m.feeBps           = p.feeBps;
        m.startTime        = p.startTime;
        m.closeTime        = p.closeTime;
        m.createdAt        = uint64(block.timestamp);
        m.resolvedAt       = 0;
        m.resolved         = false;
        m.outcome          = Outcome.PENDING;
        m.winningOutcomeId = bytes32(0);
        m.reasonURI        = "";
        m.resolver         = p.resolver;
        m.resolutionSource = p.resolutionSource;
        m.minOrderSize     = p.minOrderSize;
        m.tickSize         = p.tickSize;
        m.volumeCap        = p.volumeCap;
        m.groupId          = p.groupId;
        m.groupItemTitle   = p.groupItemTitle;
        m.creatorAddress   = p.creatorAddress;
        m.exists           = true;
        m.disabled         = false;

        // Copy outcomes array into storage
        for (uint256 i = 0; i < p.outcomes.length; i++) {
            m.outcomes.push(p.outcomes[i]);
        }

        emit MarketRegistered(
            marketId,
            p.question,
            p.category,
            p.subCategory,
            p.marketType,
            p.closeTime
        );
    }

    // Trade Recording

    /**
     * @notice Record a matched trade — emits on-chain audit event.
     *         Called exclusively by MatchSettlement (SETTLER_ROLE).
     */
    function recordTrade(
        bytes32 marketId,
        address buyer,
        address seller,
        uint256 quantity,
        uint256 price,
        uint256 feeAmount,
        uint256 batchId
    ) external onlyRole(SETTLER_ROLE) {
        if (!isTradable(marketId)) revert MarketNotTradable(marketId);
        if (buyer == seller) revert SelfTradeNotAllowed(buyer);
        emit TradeSettled(marketId, buyer, seller, quantity, price, feeAmount, batchId);
    }

    // Market Resolution

    /**
     * @notice Resolve a BINARY market with YES, NO, or INVALID.
     *         Callable by the designated resolver or any RESOLVER_ROLE holder.
     *         Used by OracleModule (Stork) and AdminOracle.
     */
    function resolveMarket(
        bytes32          marketId,
        Outcome          outcome,
        string  calldata reasonURI
    ) external {
        MarketConfig storage market = _markets[marketId];
        if (!market.exists)                         revert MarketNotFound(marketId);
        if (market.resolved)                        revert MarketAlreadyResolved(marketId);
        if (market.marketType != MarketType.BINARY) revert WrongMarketType(marketId);

        if (msg.sender != market.resolver && !hasRole(RESOLVER_ROLE, msg.sender)) {
            revert Unauthorized();
        }

        market.resolved   = true;
        market.outcome    = outcome;
        market.resolvedAt = uint64(block.timestamp);
        market.reasonURI  = reasonURI;

        emit MarketResolved(marketId, outcome, uint64(block.timestamp), reasonURI);
    }

    /**
     * @notice Resolve a CATEGORICAL market by specifying the winning outcome ID.
     *         The ID must match one of the registered OutcomeDef entries.
     *         Callable by the designated resolver or any RESOLVER_ROLE holder.
     */
    function resolveMarketCategorical(
        bytes32          marketId,
        bytes32          winningOutcomeId,
        string  calldata reasonURI
    ) external {
        MarketConfig storage market = _markets[marketId];
        if (!market.exists)                               revert MarketNotFound(marketId);
        if (market.resolved)                              revert MarketAlreadyResolved(marketId);
        if (market.marketType != MarketType.CATEGORICAL)  revert WrongMarketType(marketId);

        if (msg.sender != market.resolver && !hasRole(RESOLVER_ROLE, msg.sender)) {
            revert Unauthorized();
        }

        bool found = false;
        for (uint256 i = 0; i < market.outcomes.length; i++) {
            if (market.outcomes[i].id == winningOutcomeId) {
                found = true;
                break;
            }
        }
        if (!found) revert InvalidOutcomeId(marketId, winningOutcomeId);

        market.resolved         = true;
        market.winningOutcomeId = winningOutcomeId;
        market.resolvedAt       = uint64(block.timestamp);
        market.reasonURI        = reasonURI;

        emit MarketResolvedCategorical(
            marketId,
            winningOutcomeId,
            uint64(block.timestamp),
            reasonURI
        );
    }

    // Admin

    /**
     * @notice Admin kill-switch — disables/re-enables trading without resolving.
     */
    function setMarketDisabled(bytes32 marketId, bool disabled)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!_markets[marketId].exists) revert MarketNotFound(marketId);
        _markets[marketId].disabled = disabled;
        emit MarketDisabled(marketId, disabled);
    }

    // Views

    /**
     * @notice True if the market is currently open for trading.
     *         Requires: exists & not disabled & not resolved & within [startTime, closeTime).
     */
    function isTradable(bytes32 marketId) public view returns (bool) {
        MarketConfig storage m = _markets[marketId];
        uint64 t = uint64(block.timestamp);
        return (
            m.exists &&
            !m.disabled &&
            !m.resolved &&
            (m.startTime == 0 || t >= m.startTime) &&
            t < m.closeTime
        );
    }

    function isResolvable(bytes32 marketId) external view returns (bool) {
        MarketConfig storage m = _markets[marketId];
        return m.exists && !m.disabled && !m.resolved;
    }

    function getMarket(bytes32 marketId) external view returns (MarketConfig memory) {
        if (!_markets[marketId].exists) revert MarketNotFound(marketId);
        return _markets[marketId];
    }

    function getOutcomes(bytes32 marketId) external view returns (OutcomeDef[] memory) {
        if (!_markets[marketId].exists) revert MarketNotFound(marketId);
        return _markets[marketId].outcomes;
    }

    function marketExists(bytes32 marketId) external view returns (bool) {
        return _markets[marketId].exists;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[50] private _gap;
}
