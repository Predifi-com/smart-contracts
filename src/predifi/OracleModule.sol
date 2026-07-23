// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IStorkAggregator} from "./interfaces/IStorkAggregator.sol";
import {MarketRegistry} from "./MarketRegistry.sol";
import {IOracleConfigValidator} from "../interfaces/IOracleConfigValidator.sol";

contract OracleModule is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, IOracleConfigValidator {
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    struct SymbolConfig {
        bytes32 assetId;
        uint32 maxAgeSec;
        uint16 twapWindowSec;
        uint64 disputeBuffer;
        uint8 targetDecimals;
    }

    struct PriceReading {
        int256 price;
        uint256 timestamp;
        uint8 decimals;
        bool isValid;
    }

    IStorkAggregator public stork;
    MarketRegistry public registry;
    
    mapping(bytes32 => SymbolConfig) public symbols;

    event OracleSet(
        bytes32 indexed marketId,
        MarketRegistry.Outcome indexed outcome,
        uint256 resolveTs,
        uint256 closePx,
        uint256 strike,
        string symbol
    );

    event SymbolConfigSet(
        bytes32 indexed symbolHash,
        string symbol,
        bytes32 assetId,
        uint32 maxAgeSec,
        uint16 twapWindowSec,
        uint64 disputeBuffer,
        uint8 targetDecimals
    );

    event StorkAggregatorUpdated(address indexed newAggregator);

    error TooEarly(uint256 currentTime, uint256 allowedTime);
    error OracleUnavailable(string reason);
    error AlreadyResolved();
    error UnsupportedSymbol(string symbol);
    error StalePrice(uint256 age, uint32 maxAge);
    error InvalidMarket();
    error InvalidSymbolConfig();
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin, address _stork, address _registry) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        if (admin == address(0) || _stork == address(0) || _registry == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RESOLVER_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        stork = IStorkAggregator(_stork);
        registry = MarketRegistry(_registry);
    }

    function autoResolve(
        bytes32 marketId,
        string calldata reasonURI
    ) external onlyRole(RESOLVER_ROLE) nonReentrant {
        MarketRegistry.MarketConfig memory marketInfo = registry.getMarket(marketId);
        if (marketInfo.resolved) revert AlreadyResolved();

        bytes32 symbolHash = keccak256(bytes(marketInfo.assetSymbol));
        SymbolConfig memory config = symbols[symbolHash];
        
        if (config.assetId == bytes32(0)) {
            revert UnsupportedSymbol(marketInfo.assetSymbol);
        }

        uint256 earliestResolveTime = marketInfo.closeTime + config.disputeBuffer;
        if (block.timestamp < earliestResolveTime) {
            revert TooEarly(block.timestamp, earliestResolveTime);
        }

        uint256 closePx = _getClosePrice(config, marketInfo.closeTime);
        MarketRegistry.Outcome outcome = closePx >= marketInfo.strike ?
            MarketRegistry.Outcome.YES :
            MarketRegistry.Outcome.NO;

        registry.resolveMarket(marketId, outcome, reasonURI);

        emit OracleSet(
            marketId,
            outcome,
            block.timestamp,
            closePx,
            marketInfo.strike,
            marketInfo.assetSymbol
        );
    }

    function _getClosePrice(
        SymbolConfig memory config,
        uint256 endsAt
    ) internal view returns (uint256) {
        if (_hasHistoricalSupport(config.assetId, endsAt)) {
            return _getHistoricalTwap(config, endsAt);
        }
        return _getCurrentPrice(config, endsAt);
    }

    function _tryGetClosePrice(
        SymbolConfig memory config,
        uint256 endsAt
    ) internal view returns (bool ok, uint256 price) {
        if (_hasHistoricalSupport(config.assetId, endsAt)) {
            return _tryGetHistoricalTwap(config, endsAt);
        }
        return _tryGetCurrentPrice(config, endsAt);
    }

    function _getHistoricalTwap(
        SymbolConfig memory config,
        uint256 endsAt
    ) internal view returns (uint256) {
        uint256[] memory prices = new uint256[](3);
        uint256 validCount;

        uint256[3] memory timestamps = [
            endsAt - config.twapWindowSec,
            endsAt,
            endsAt + config.twapWindowSec
        ];

        for (uint256 i = 0; i < 3; i++) {
            try stork.atOrBefore(config.assetId, timestamps[i]) 
                returns (int256 price, uint256 ts, uint8 decimals) {
                
                if (ts > endsAt) continue;
                uint256 age = endsAt - ts;
                if (age <= config.maxAgeSec && price > 0) {
                    prices[validCount] = _scaleToTarget(
                        uint256(price),
                        decimals,
                        config.targetDecimals
                    );
                    validCount++;
                }
            } catch {
            }
        }

        if (validCount == 0) {
            revert OracleUnavailable("No valid historical prices");
        }

        return _calculateMedian(prices, validCount);
    }

    function _tryGetHistoricalTwap(
        SymbolConfig memory config,
        uint256 endsAt
    ) internal view returns (bool ok, uint256 price) {
        uint256[] memory prices = new uint256[](3);
        uint256 validCount;
        uint256[3] memory timestamps = [
            endsAt - config.twapWindowSec,
            endsAt,
            endsAt + config.twapWindowSec
        ];

        for (uint256 i = 0; i < 3; i++) {
            try stork.atOrBefore(config.assetId, timestamps[i])
                returns (int256 reading, uint256 ts, uint8 decimals)
            {
                if (ts > endsAt) continue;
                uint256 age = endsAt - ts;
                if (age <= config.maxAgeSec && reading > 0) {
                    prices[validCount] = _scaleToTarget(
                        uint256(reading),
                        decimals,
                        config.targetDecimals
                    );
                    validCount++;
                }
            } catch {}
        }

        if (validCount == 0) {
            return (false, 0);
        }

        return (true, _calculateMedian(prices, validCount));
    }

    function _getCurrentPrice(
        SymbolConfig memory config,
        uint256 endsAt
    ) internal view returns (uint256) {
        try stork.latest(config.assetId) 
            returns (int256 price, uint256 ts, uint8 decimals) {

            if (ts > endsAt) {
                revert OracleUnavailable("Current price is newer than market close");
            }

            uint256 age = endsAt - ts;
            if (age > config.maxAgeSec) {
                revert StalePrice(age, config.maxAgeSec);
            }
            
            if (price <= 0) {
                revert OracleUnavailable("Invalid price reading");
            }

            return _scaleToTarget(uint256(price), decimals, config.targetDecimals);
            
        } catch Error(string memory reason) {
            revert OracleUnavailable(reason);
        } catch {
            revert OracleUnavailable("Stork aggregator call failed");
        }
    }

    function _tryGetCurrentPrice(
        SymbolConfig memory config,
        uint256 endsAt
    ) internal view returns (bool ok, uint256 price) {
        try stork.latest(config.assetId)
            returns (int256 reading, uint256 ts, uint8 decimals)
        {
            if (ts > endsAt) {
                return (false, 0);
            }

            uint256 age = endsAt - ts;
            if (age > config.maxAgeSec || reading <= 0) {
                return (false, 0);
            }

            return (
                true,
                _scaleToTarget(uint256(reading), decimals, config.targetDecimals)
            );
        } catch {
            return (false, 0);
        }
    }

    function _calculateMedian(
        uint256[] memory prices,
        uint256 count
    ) internal pure returns (uint256) {
        if (count == 1) return prices[0];
        if (count == 2) return (prices[0] + prices[1]) / 2;

        if (prices[0] > prices[1]) {
            (prices[0], prices[1]) = (prices[1], prices[0]);
        }
        if (prices[1] > prices[2]) {
            (prices[1], prices[2]) = (prices[2], prices[1]);
        }
        if (prices[0] > prices[1]) {
            (prices[0], prices[1]) = (prices[1], prices[0]);
        }

        return prices[1];
    }

    function _scaleToTarget(
        uint256 price,
        uint8 srcDecimals,
        uint8 targetDecimals
    ) internal pure returns (uint256) {
        if (srcDecimals == targetDecimals) {
            return price;
        } else if (srcDecimals > targetDecimals) {
            return price / (10 ** (srcDecimals - targetDecimals));
        } else {
            return price * (10 ** (targetDecimals - srcDecimals));
        }
    }

    function _hasHistoricalSupport(bytes32 assetId, uint256 tsHint) internal view returns (bool) {
        try stork.atOrBefore(assetId, tsHint) returns (int256, uint256, uint8) {
            return true;
        } catch {
            return false;
        }
    }

    function setSymbolConfig(
        string calldata symbol,
        SymbolConfig calldata config
    ) external onlyRole(CONFIG_ROLE) {
        if (config.assetId == bytes32(0) || 
            config.maxAgeSec == 0 ||
            config.disputeBuffer == 0 ||
            config.targetDecimals > 18) {
            revert InvalidSymbolConfig();
        }

        bytes32 symbolHash = keccak256(bytes(symbol));
        symbols[symbolHash] = config;

        emit SymbolConfigSet(
            symbolHash,
            symbol,
            config.assetId,
            config.maxAgeSec,
            config.twapWindowSec,
            config.disputeBuffer,
            config.targetDecimals
        );
    }

    function setStorkAggregator(
        address newAggregator
    ) external onlyRole(CONFIG_ROLE) {
        if (newAggregator == address(0)) revert ZeroAddress();
        stork = IStorkAggregator(newAggregator);
        emit StorkAggregatorUpdated(newAggregator);
    }

    function getSymbolConfig(string calldata symbol) external view returns (SymbolConfig memory) {
        return symbols[keccak256(bytes(symbol))];
    }

    function getSymbolValidation(string calldata symbol) external view returns (bool supported, uint8 targetDecimals) {
        SymbolConfig memory config = symbols[keccak256(bytes(symbol))];
        return (config.assetId != bytes32(0), config.targetDecimals);
    }

    function previewResolution(
        bytes32 marketId
    ) external view returns (
        MarketRegistry.Outcome outcome,
        uint256 price,
        bool canResolve,
        bool alreadyResolved
    ) {
        MarketRegistry.MarketConfig memory marketInfo = registry.getMarket(marketId);
        if (marketInfo.resolved) {
            return (MarketRegistry.Outcome.INVALID, 0, false, true);
        }
        bytes32 symbolHash = keccak256(bytes(marketInfo.assetSymbol));
        SymbolConfig memory config = symbols[symbolHash];

        if (config.assetId == bytes32(0)) {
            return (MarketRegistry.Outcome.INVALID, 0, false, false);
        }

        canResolve = block.timestamp >= marketInfo.closeTime + config.disputeBuffer;
        
        if (canResolve) {
            (bool ok, uint256 closePrice) = _tryGetClosePrice(config, marketInfo.closeTime);
            if (ok) {
                price = closePrice;
                outcome = closePrice >= marketInfo.strike ?
                    MarketRegistry.Outcome.YES :
                    MarketRegistry.Outcome.NO;
            } else {
                outcome = MarketRegistry.Outcome.INVALID;
            }
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[50] private _gap;
}