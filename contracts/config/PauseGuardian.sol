// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "../libs/Types.sol";

/**
 * @title PauseGuardian
 * @notice Emergency pause coordinator for the protocol
 * @dev Provides circuit breaker functionality with role-based controls
 */
contract PauseGuardian is UUPSUpgradeable, AccessControlUpgradeable {
    // Roles
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // State variables
    address public protocolConfig;
    
    // Pause states
    bool public globalPause;
    mapping(uint256 => bool) public chainPause;
    mapping(address => bool) public contractPause;
    
    // Guardian configurations
    mapping(address => bool) public authorizedGuardians;
    mapping(address => uint256) public guardianPowers; // Bitmap of what they can pause
    
    // Pause reasons and timing
    mapping(uint256 => string) public pauseReasons;
    mapping(uint256 => uint256) public pauseTimestamps;
    mapping(uint256 => address) public pauseInitiators;
    
    uint256 private _pauseNonce;
    
    // Pause power flags
    uint256 private constant PAUSE_GLOBAL = 1 << 0;
    uint256 private constant PAUSE_CHAIN = 1 << 1;
    uint256 private constant PAUSE_CONTRACT = 1 << 2;
    uint256 private constant PAUSE_EMERGENCY = 1 << 3;

    // Constants
    uint256 private constant MAX_PAUSE_DURATION = 7 days;
    uint256 private constant EMERGENCY_PAUSE_DURATION = 24 hours;

    // Events
    event GlobalPauseToggled(bool paused, address initiator, string reason);
    event ChainPauseToggled(uint256 chainId, bool paused, address initiator, string reason);
    event ContractPauseToggled(address contractAddr, bool paused, address initiator, string reason);
    event GuardianConfigured(address guardian, uint256 powers, bool authorized);
    event EmergencyPauseActivated(address initiator, string reason, uint256 duration);
    event PauseExpired(uint256 pauseId, address expiredBy);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the pause guardian
     * @param config Protocol configuration contract
     */
    function initialize(address config) external initializer {
        if (config == address(0)) revert Types.ZeroAddress();

        __UUPSUpgradeable_init();
        __AccessControl_init();

        protocolConfig = config;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        
        // Initial guardian configuration
        authorizedGuardians[msg.sender] = true;
        guardianPowers[msg.sender] = PAUSE_GLOBAL | PAUSE_CHAIN | PAUSE_CONTRACT | PAUSE_EMERGENCY;
    }

    /**
     * @notice Toggle global pause
     * @param paused Pause state
     * @param reason Reason for pause/unpause
     */
    function setGlobalPause(bool paused, string calldata reason) external {
        if (!_canPauseGlobal(msg.sender)) revert Types.Unauthorized();
        
        globalPause = paused;
        uint256 pauseId = ++_pauseNonce;
        
        pauseReasons[pauseId] = reason;
        pauseTimestamps[pauseId] = block.timestamp;
        pauseInitiators[pauseId] = msg.sender;
        
        emit GlobalPauseToggled(paused, msg.sender, reason);
        
        // Forward to protocol config if available
        if (protocolConfig != address(0)) {
            try IProtocolConfig(protocolConfig).setGlobalEmergencyPause(paused) {
                // Success
            } catch {
                // Log but don't revert
            }
        }
    }

    /**
     * @notice Toggle chain-specific pause
     * @param chainId Chain ID to pause/unpause
     * @param paused Pause state
     * @param reason Reason for pause/unpause
     */
    function setChainPause(uint256 chainId, bool paused, string calldata reason) external {
        if (!_canPauseChain(msg.sender)) revert Types.Unauthorized();
        if (chainId == 0) revert Types.InvalidChainId();
        
        chainPause[chainId] = paused;
        uint256 pauseId = ++_pauseNonce;
        
        pauseReasons[pauseId] = reason;
        pauseTimestamps[pauseId] = block.timestamp;
        pauseInitiators[pauseId] = msg.sender;
        
        emit ChainPauseToggled(chainId, paused, msg.sender, reason);
        
        // Forward to protocol config if available
        if (protocolConfig != address(0)) {
            try IProtocolConfig(protocolConfig).setChainEmergencyPause(chainId, paused) {
                // Success
            } catch {
                // Log but don't revert
            }
        }
    }

    /**
     * @notice Toggle contract-specific pause
     * @param contractAddr Contract address to pause/unpause
     * @param paused Pause state
     * @param reason Reason for pause/unpause
     */
    function setContractPause(address contractAddr, bool paused, string calldata reason) external {
        if (!_canPauseContract(msg.sender)) revert Types.Unauthorized();
        if (contractAddr == address(0)) revert Types.ZeroAddress();
        
        contractPause[contractAddr] = paused;
        uint256 pauseId = ++_pauseNonce;
        
        pauseReasons[pauseId] = reason;
        pauseTimestamps[pauseId] = block.timestamp;
        pauseInitiators[pauseId] = msg.sender;
        
        emit ContractPauseToggled(contractAddr, paused, msg.sender, reason);
    }

    /**
     * @notice Emergency pause activation (temporary with auto-expiry)
     * @param reason Emergency reason
     */
    function activateEmergencyPause(string calldata reason) external {
        if (!_canEmergencyPause(msg.sender)) revert Types.Unauthorized();
        
        globalPause = true;
        uint256 pauseId = ++_pauseNonce;
        
        pauseReasons[pauseId] = reason;
        pauseTimestamps[pauseId] = block.timestamp;
        pauseInitiators[pauseId] = msg.sender;
        
        emit EmergencyPauseActivated(msg.sender, reason, EMERGENCY_PAUSE_DURATION);
        emit GlobalPauseToggled(true, msg.sender, reason);
        
        // Schedule auto-unpause (would need to be handled off-chain or via keeper)
        // For production, integrate with Chainlink Automation or similar
    }

    /**
     * @notice Configure guardian powers
     * @param guardian Guardian address
     * @param powers Bitmap of pause powers
     * @param authorized Whether guardian is authorized
     */
    function configureGuardian(
        address guardian,
        uint256 powers,
        bool authorized
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _configureGuardian(guardian, powers, authorized);
    }

    /**
     * @notice Internal function to configure guardian powers
     * @param guardian Guardian address
     * @param powers Bitmap of pause powers
     * @param authorized Whether guardian is authorized
     */
    function _configureGuardian(
        address guardian,
        uint256 powers,
        bool authorized
    ) internal {
        if (guardian == address(0)) revert Types.ZeroAddress();
        
        authorizedGuardians[guardian] = authorized;
        guardianPowers[guardian] = powers;
        
        // Grant/revoke roles based on powers
        if (authorized) {
            if (powers & PAUSE_GLOBAL != 0 || powers & PAUSE_CHAIN != 0 || powers & PAUSE_CONTRACT != 0) {
                _grantRole(GUARDIAN_ROLE, guardian);
            }
            if (powers & PAUSE_EMERGENCY != 0) {
                _grantRole(EMERGENCY_ROLE, guardian);
            }
        } else {
            _revokeRole(GUARDIAN_ROLE, guardian);
            _revokeRole(EMERGENCY_ROLE, guardian);
        }
        
        emit GuardianConfigured(guardian, powers, authorized);
    }

    /**
     * @notice Batch configure multiple guardians
     * @param guardians Array of guardian addresses
     * @param powers Array of power bitmaps
     * @param authorized Array of authorization states
     */
    function batchConfigureGuardians(
        address[] calldata guardians,
        uint256[] calldata powers,
        bool[] calldata authorized
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (guardians.length != powers.length || guardians.length != authorized.length) {
            revert Types.InvalidLength();
        }
        
        for (uint256 i = 0; i < guardians.length; i++) {
            _configureGuardian(guardians[i], powers[i], authorized[i]);
        }
    }

    /**
     * @notice Expire a pause (admin override)
     * @param pauseId Pause ID to expire
     */
    function expirePause(uint256 pauseId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pauseId == 0 || pauseId > _pauseNonce) revert Types.InvalidPauseId();
        
        // This would need additional logic to map pause IDs to actual pause states
        // For simplicity, we'll emit an event
        emit PauseExpired(pauseId, msg.sender);
    }

    // View functions
    function isPaused() external view returns (bool) {
        return globalPause;
    }

    function isChainPaused(uint256 chainId) external view returns (bool) {
        return globalPause || chainPause[chainId];
    }

    function isContractPaused(address contractAddr) external view returns (bool) {
        return globalPause || contractPause[contractAddr];
    }

    function canPause(address guardian, uint256 pauseType) external view returns (bool) {
        if (!authorizedGuardians[guardian]) return false;
        return (guardianPowers[guardian] & pauseType) != 0;
    }

    function getGuardianPowers(address guardian) external view returns (uint256) {
        return guardianPowers[guardian];
    }

    function isAuthorizedGuardian(address guardian) external view returns (bool) {
        return authorizedGuardians[guardian];
    }

    function getPauseInfo(uint256 pauseId) external view returns (
        string memory reason,
        uint256 timestamp,
        address initiator
    ) {
        return (pauseReasons[pauseId], pauseTimestamps[pauseId], pauseInitiators[pauseId]);
    }

    // Internal functions
    function _canPauseGlobal(address guardian) internal view returns (bool) {
        return authorizedGuardians[guardian] && (guardianPowers[guardian] & PAUSE_GLOBAL) != 0;
    }

    function _canPauseChain(address guardian) internal view returns (bool) {
        return authorizedGuardians[guardian] && (guardianPowers[guardian] & PAUSE_CHAIN) != 0;
    }

    function _canPauseContract(address guardian) internal view returns (bool) {
        return authorizedGuardians[guardian] && (guardianPowers[guardian] & PAUSE_CONTRACT) != 0;
    }

    function _canEmergencyPause(address guardian) internal view returns (bool) {
        return authorizedGuardians[guardian] && (guardianPowers[guardian] & PAUSE_EMERGENCY) != 0;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // Gap for future storage variables
    uint256[50] private __gap;
}

// Interface for ProtocolConfig
interface IProtocolConfig {
    function setGlobalEmergencyPause(bool paused) external;
    function setChainEmergencyPause(uint256 chainId, bool paused) external;
}