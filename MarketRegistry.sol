// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IOracleConfigValidator} from "../interfaces/IOracleConfigValidator.sol";

contract MarketRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant MARKET_REGISTRAR_ROLE = keccak256("MARKET_REGISTRAR_ROLE");
    bytes32 public constant SETTLER_ROLE          = keccak256("SETTLER_ROLE");
    bytes32 public constant RESOLVER_ROLE         = keccak256("RESOLVER_ROLE");
    uint256 public constant MAX_CATEGORICAL_OUTCOMES = 16;
    uint256 public constant MAX_FEE_BPS = 500;

    enum Outcome { PENDING, YES, NO, INVALID }

    enum MarketType { BINARY, CATEGORICAL }

    struct OutcomeDef {
        bytes32 id;
        string  label;
    }

    struct MarketConfig {
        bytes32  metadataHash;
        string   question;
        string   category;
        string   subCategory;
        string   assetSymbol;
        MarketType   marketType;
        OutcomeDef[] outcomes;
        uint256  strike;
        uint8    strikeDecimals;
        uint256  feeBps;
        uint64   startTime;
        uint64   closeTime;
        uint64   createdAt;
        uint64   resolvedAt;
        bool     resolved;
        Outcome  outcome;
        bytes32  winningOutcomeId;
        string   reasonURI;
        address  resolvedBy;
        address  resolver;
        string   resolutionSource;
        uint256  minOrderSize;
        uint256  tickSize;
        uint256  volumeCap;
        string   groupId;
        string   groupItemTitle;
        address  creatorAddress;
        bool     exists;
        bool     disabled;
    }

    struct MarketParams {
        bytes32      metadataHash;
        string       question;
        string       category;
        string       subCategory;
        string       assetSymbol;
        MarketType   marketType;
        OutcomeDef[] outcomes;
        uint256      strike;
        uint8        strikeDecimals;
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

    event MarketResolved(
        bytes32 indexed marketId,
        Outcome indexed outcome,
        uint64  resolvedAt,
        string  reasonURI
    );

    event MarketResolvedCategorical(
        bytes32 indexed marketId,
        bytes32 indexed winningOutcomeId,
        uint64  resolvedAt,
        string  reasonURI
    );

    event MarketResolvedCategoricalInvalid(
        bytes32 indexed marketId,
        uint64  resolvedAt,
        string  reasonURI
    );

    event MarketDisabled(bytes32 indexed marketId, bool disabled);
    event OracleConfigValidatorUpdated(address indexed validator);

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
    error FeeBpsTooHigh(uint256 provided, uint256 max);
    error MarketNotClosed(bytes32 marketId, uint64 closeTime);
    error InvalidOutcomePending(bytes32 marketId);
    error UnsupportedAssetSymbol(string symbol);
    error StrikeDecimalsMismatch(uint8 provided, uint8 expected);

    address public oracleConfigValidator;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address admin,
        address settler,
        address oracleModule,
        address adminOracle
    ) public initializer {
        __AccessControl_init();

        if (
            admin == address(0) ||
            settler == address(0) ||
            oracleModule == address(0) ||
            adminOracle == address(0)
        ) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE,    admin);
        _grantRole(MARKET_REGISTRAR_ROLE, admin);
        _grantRole(SETTLER_ROLE,          settler);
        _grantRole(RESOLVER_ROLE,         oracleModule);
        _grantRole(RESOLVER_ROLE,         adminOracle);
    }

    function registerMarket(
        bytes32           marketId,
        MarketParams calldata p
    ) external onlyRole(MARKET_REGISTRAR_ROLE) {
        if (_markets[marketId].exists)       revert MarketAlreadyExists(marketId);
        if (p.closeTime <= block.timestamp)  revert InvalidCloseTime();
        if (p.startTime != 0 && p.startTime >= p.closeTime) revert InvalidStartTime();
        if (p.feeBps > MAX_FEE_BPS)         revert FeeBpsTooHigh(p.feeBps, MAX_FEE_BPS);

        if (p.marketType == MarketType.BINARY) {
            if (p.outcomes.length != 0) revert TooManyOutcomes(marketId, p.outcomes.length);
            _validateOracleMarketConfig(p.assetSymbol, p.strikeDecimals);
        }

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
        m.strikeDecimals   = p.strikeDecimals;
        m.feeBps           = p.feeBps;
        m.startTime        = p.startTime;
        m.closeTime        = p.closeTime;
        m.createdAt        = uint64(block.timestamp);
        m.resolver         = p.resolver;
        m.resolutionSource = p.resolutionSource;
        m.minOrderSize     = p.minOrderSize;
        m.tickSize         = p.tickSize;
        m.volumeCap        = p.volumeCap;
        m.groupId          = p.groupId;
        m.groupItemTitle   = p.groupItemTitle;
        m.creatorAddress   = p.creatorAddress;
        m.exists           = true;

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

    function resolveMarket(
        bytes32          marketId,
        Outcome          outcome,
        string  calldata reasonURI
    ) external {
        MarketConfig storage market = _markets[marketId];
        if (!market.exists)                         revert MarketNotFound(marketId);
        if (market.resolved)                        revert MarketAlreadyResolved(marketId);
        if (market.marketType != MarketType.BINARY) revert WrongMarketType(marketId);
        if (block.timestamp < market.closeTime)     revert MarketNotClosed(marketId, market.closeTime);
        if (outcome == Outcome.PENDING)             revert InvalidOutcomePending(marketId);

        if (market.resolver != address(0)) {
            if (msg.sender != market.resolver && !hasRole(RESOLVER_ROLE, msg.sender)) {
                revert Unauthorized();
            }
        } else {
            if (!hasRole(RESOLVER_ROLE, msg.sender)) revert Unauthorized();
        }

        market.resolved   = true;
        market.outcome    = outcome;
        market.resolvedAt = uint64(block.timestamp);
        market.reasonURI  = reasonURI;
        market.resolvedBy = msg.sender;

        emit MarketResolved(marketId, outcome, uint64(block.timestamp), reasonURI);
    }

    function resolveMarketCategorical(
        bytes32          marketId,
        bytes32          winningOutcomeId,
        string  calldata reasonURI
    ) external {
        MarketConfig storage market = _markets[marketId];
        if (!market.exists)                               revert MarketNotFound(marketId);
        if (market.resolved)                              revert MarketAlreadyResolved(marketId);
        if (market.marketType != MarketType.CATEGORICAL)  revert WrongMarketType(marketId);
        if (block.timestamp < market.closeTime)           revert MarketNotClosed(marketId, market.closeTime);

        if (market.resolver != address(0)) {
            if (msg.sender != market.resolver && !hasRole(RESOLVER_ROLE, msg.sender)) {
                revert Unauthorized();
            }
        } else {
            if (!hasRole(RESOLVER_ROLE, msg.sender)) revert Unauthorized();
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
        market.resolvedBy       = msg.sender;

        emit MarketResolvedCategorical(
            marketId,
            winningOutcomeId,
            uint64(block.timestamp),
            reasonURI
        );
    }

    function resolveMarketCategoricalInvalid(
        bytes32          marketId,
        string  calldata reasonURI
    ) external {
        MarketConfig storage market = _markets[marketId];
        if (!market.exists)                               revert MarketNotFound(marketId);
        if (market.resolved)                              revert MarketAlreadyResolved(marketId);
        if (market.marketType != MarketType.CATEGORICAL)  revert WrongMarketType(marketId);
        if (block.timestamp < market.closeTime)           revert MarketNotClosed(marketId, market.closeTime);

        if (market.resolver != address(0)) {
            if (msg.sender != market.resolver && !hasRole(RESOLVER_ROLE, msg.sender)) {
                revert Unauthorized();
            }
        } else {
            if (!hasRole(RESOLVER_ROLE, msg.sender)) revert Unauthorized();
        }

        market.resolved   = true;
        market.outcome    = Outcome.INVALID;
        market.resolvedAt = uint64(block.timestamp);
        market.reasonURI  = reasonURI;
        market.resolvedBy = msg.sender;

        emit MarketResolvedCategoricalInvalid(marketId, uint64(block.timestamp), reasonURI);
    }

    function setMarketDisabled(bytes32 marketId, bool disabled)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!_markets[marketId].exists) revert MarketNotFound(marketId);
        _markets[marketId].disabled = disabled;
        emit MarketDisabled(marketId, disabled);
    }

    function setOracleConfigValidator(address validator)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        oracleConfigValidator = validator;
        emit OracleConfigValidatorUpdated(validator);
    }

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

    function _validateOracleMarketConfig(string calldata assetSymbol, uint8 strikeDecimals) internal view {
        address validator = oracleConfigValidator;
        if (validator == address(0)) return;

        (bool supported, uint8 targetDecimals) = IOracleConfigValidator(validator).getSymbolValidation(assetSymbol);
        if (!supported) revert UnsupportedAssetSymbol(assetSymbol);
        if (strikeDecimals != targetDecimals) revert StrikeDecimalsMismatch(strikeDecimals, targetDecimals);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[50] private _gap;
}
