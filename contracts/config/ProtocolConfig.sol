// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "../libs/Types.sol";

/**
 * @title ProtocolConfig
 * @notice Central configuration contract for protocol parameters
 * @dev Deployed on hub chain, provides configuration for all protocol components
 */
contract ProtocolConfig is 
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    // Roles
    bytes32 public constant CONFIG_ADMIN_ROLE = keccak256("CONFIG_ADMIN_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");

    // Protocol parameters
    Types.ProtocolParams public protocolParams;
    
    // Chain configurations
    mapping(uint256 => Types.ChainConfig) public chainConfigs;
    mapping(uint256 => bool) public supportedChains;
    
    // Venue configurations
    mapping(uint256 => Types.VenueConfig) public venueConfigs;
    mapping(uint256 => bool) public enabledVenues;
    
    // Fee configurations
    mapping(address => uint256) public tokenMinAmounts;
    mapping(address => bool) public supportedTokens;
    
    // Emergency controls
    bool public globalEmergencyPause;
    mapping(uint256 => bool) public chainEmergencyPause;
    
    // Version tracking
    uint256 public configVersion;
    mapping(uint256 => uint256) public chainConfigVersions;

    // Events
    event ProtocolParamsUpdated(Types.ProtocolParams params, uint256 version);
    event ChainConfigUpdated(uint256 chainId, Types.ChainConfig config, uint256 version);
    event VenueConfigUpdated(uint256 chainId, Types.VenueConfig config);
    event TokenConfigUpdated(address token, uint256 minAmount, bool supported);
    event EmergencyPauseToggled(uint256 chainId, bool paused);
    event GlobalEmergencyPauseToggled(bool paused);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the protocol config
     * @param initialParams Initial protocol parameters
     */
    function initialize(
        Types.ProtocolParams memory initialParams
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CONFIG_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSE_ROLE, msg.sender);

        protocolParams = initialParams;
        configVersion = 1;
    }

    /**
     * @notice Update protocol parameters
     * @param params New protocol parameters
     */
    function updateProtocolParams(
        Types.ProtocolParams calldata params
    ) external onlyRole(CONFIG_ADMIN_ROLE) {
        if (params.maxBetAmount < params.minBetAmount) revert Types.InvalidAmount();
        if (params.maxIntentDuration == 0) revert Types.InvalidDuration();
        if (params.baseFeeRate > 10000) revert Types.InvalidFeeRate(); // Max 100%
        
        protocolParams = params;
        configVersion++;
        
        emit ProtocolParamsUpdated(params, configVersion);
    }

    /**
     * @notice Set chain configuration
     * @param chainId Chain ID to configure
     * @param config Chain configuration
     */
    function setChainConfig(
        uint256 chainId,
        Types.ChainConfig calldata config
    ) external onlyRole(CONFIG_ADMIN_ROLE) {
        if (chainId == 0) revert Types.InvalidChainId();
        if (config.messengerAdapter == address(0)) revert Types.ZeroAddress();
        
        chainConfigs[chainId] = config;
        supportedChains[chainId] = config.enabled;
        chainConfigVersions[chainId]++;
        
        emit ChainConfigUpdated(chainId, config, chainConfigVersions[chainId]);
    }

    /**
     * @notice Set venue configuration
     * @param chainId Chain ID for the venue
     * @param config Venue configuration
     */
    function setVenueConfig(
        uint256 chainId,
        Types.VenueConfig calldata config
    ) external onlyRole(CONFIG_ADMIN_ROLE) {
        if (chainId == 0) revert Types.InvalidChainId();
        if (config.traderSafe == address(0)) revert Types.ZeroAddress();
        
        venueConfigs[chainId] = config;
        enabledVenues[chainId] = config.enabled;
        
        emit VenueConfigUpdated(chainId, config);
    }

    /**
     * @notice Configure supported token
     * @param token Token address
     * @param minAmount Minimum bet amount for this token
     * @param supported Whether token is supported
     */
    function setTokenConfig(
        address token,
        uint256 minAmount,
        bool supported
    ) external onlyRole(CONFIG_ADMIN_ROLE) {
        if (token == address(0)) revert Types.ZeroAddress();
        
        tokenMinAmounts[token] = minAmount;
        supportedTokens[token] = supported;
        
        emit TokenConfigUpdated(token, minAmount, supported);
    }

    /**
     * @notice Toggle emergency pause for specific chain
     * @param chainId Chain ID to pause/unpause
     * @param paused Pause state
     */
    function setChainEmergencyPause(
        uint256 chainId,
        bool paused
    ) external onlyRole(PAUSE_ROLE) {
        chainEmergencyPause[chainId] = paused;
        emit EmergencyPauseToggled(chainId, paused);
    }

    /**
     * @notice Toggle global emergency pause
     * @param paused Global pause state
     */
    function setGlobalEmergencyPause(bool paused) external onlyRole(PAUSE_ROLE) {
        globalEmergencyPause = paused;
        emit GlobalEmergencyPauseToggled(paused);
    }

    /**
     * @notice Enable/disable chain support
     * @param chainId Chain ID
     * @param enabled Whether chain is enabled
     */
    function setChainEnabled(uint256 chainId, bool enabled) external onlyRole(CONFIG_ADMIN_ROLE) {
        supportedChains[chainId] = enabled;
        if (chainConfigs[chainId].messengerAdapter != address(0)) {
            chainConfigs[chainId].enabled = enabled;
            chainConfigVersions[chainId]++;
            emit ChainConfigUpdated(chainId, chainConfigs[chainId], chainConfigVersions[chainId]);
        }
    }

    /**
     * @notice Enable/disable venue
     * @param chainId Chain ID for the venue
     * @param enabled Whether venue is enabled
     */
    function setVenueEnabled(uint256 chainId, bool enabled) external onlyRole(CONFIG_ADMIN_ROLE) {
        enabledVenues[chainId] = enabled;
        if (venueConfigs[chainId].traderSafe != address(0)) {
            venueConfigs[chainId].enabled = enabled;
            emit VenueConfigUpdated(chainId, venueConfigs[chainId]);
        }
    }

    // View functions
    function getProtocolParams() external view returns (Types.ProtocolParams memory) {
        return protocolParams;
    }

    function getChainConfig(uint256 chainId) external view returns (Types.ChainConfig memory) {
        return chainConfigs[chainId];
    }

    function getVenueConfig(uint256 chainId) external view returns (Types.VenueConfig memory) {
        return venueConfigs[chainId];
    }

    function isChainSupported(uint256 chainId) external view returns (bool) {
        return supportedChains[chainId] && !chainEmergencyPause[chainId] && !globalEmergencyPause;
    }

    function isVenueEnabled(uint256 chainId) external view returns (bool) {
        return enabledVenues[chainId] && !chainEmergencyPause[chainId] && !globalEmergencyPause;
    }

    function isTokenSupported(address token) external view returns (bool) {
        return supportedTokens[token];
    }

    function getTokenMinAmount(address token) external view returns (uint256) {
        return tokenMinAmounts[token];
    }

    function isOperational(uint256 chainId) external view returns (bool) {
        return supportedChains[chainId] && 
               !chainEmergencyPause[chainId] && 
               !globalEmergencyPause &&
               !paused();
    }

    /**
     * @notice Get configuration hash for verification
     * @param chainId Chain ID
     * @return Hash of current configuration
     */
    function getConfigHash(uint256 chainId) external view returns (bytes32) {
        return keccak256(abi.encode(
            protocolParams,
            chainConfigs[chainId],
            venueConfigs[chainId],
            configVersion,
            chainConfigVersions[chainId]
        ));
    }

    /**
     * @notice Batch get chain configurations
     * @param chainIds Array of chain IDs
     * @return configs Array of chain configurations
     */
    function getChainConfigs(
        uint256[] calldata chainIds
    ) external view returns (Types.ChainConfig[] memory configs) {
        configs = new Types.ChainConfig[](chainIds.length);
        for (uint256 i = 0; i < chainIds.length; i++) {
            configs[i] = chainConfigs[chainIds[i]];
        }
    }

    /**
     * @notice Batch get venue configurations
     * @param chainIds Array of chain IDs
     * @return configs Array of venue configurations
     */
    function getVenueConfigs(
        uint256[] calldata chainIds
    ) external view returns (Types.VenueConfig[] memory configs) {
        configs = new Types.VenueConfig[](chainIds.length);
        for (uint256 i = 0; i < chainIds.length; i++) {
            configs[i] = venueConfigs[chainIds[i]];
        }
    }

    // Pausable functions
    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSE_ROLE) {
        _unpause();
    }

    // Internal functions
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // Gap for future storage variables
    uint256[50] private __gap;
}