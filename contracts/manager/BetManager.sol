// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IBetManager.sol";
import "../interfaces/IBufferVault.sol";
import "../libs/Types.sol";
import "../libs/SafeCastExt.sol";

/**
 * @title BetManager
 * @notice Manages bet placement and settlement on venue chains
 * @dev Handles bet intents from MessengerAdapter and manages fund releases
 */
contract BetManager is 
    IBetManager,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCastExt for uint256;

    // Roles
    bytes32 public constant MESSENGER_ROLE = keccak256("MESSENGER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");

    // State variables
    address public protocolConfig;
    address public messengerAdapter;
    
    Types.VenueConfig public venueConfig;
    mapping(bytes32 => Types.Release) private _releases;
    mapping(bytes32 => bool) private _processedIntents;
    
    uint256 private _releaseNonce;
    uint256 public totalReleased;
    uint256 public totalReclaimed;

    // Constants
    uint256 private constant RELEASE_TIMEOUT = 24 hours;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the bet manager
     * @param config Protocol configuration contract
     * @param messenger Messenger adapter address
     * @param initialVenueConfig Initial venue configuration
     */
    function initialize(
        address config,
        address messenger,
        Types.VenueConfig memory initialVenueConfig
    ) external initializer {
        if (config == address(0) || messenger == address(0)) revert Types.ZeroAddress();
        if (initialVenueConfig.traderSafe == address(0)) revert Types.ZeroAddress();

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        protocolConfig = config;
        messengerAdapter = messenger;
        venueConfig = initialVenueConfig;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MESSENGER_ROLE, messenger);
        _grantRole(PAUSE_ROLE, msg.sender);
    }

    /**
     * @notice Handle bet intent from messenger adapter
     * @param intent Bet intent to process
     * @return releaseId Generated release ID
     */
    function handleBetIntent(
        Types.BetIntent calldata intent
    ) external onlyRole(MESSENGER_ROLE) nonReentrant whenNotPaused returns (bytes32 releaseId) {
        if (_processedIntents[intent.intentId]) revert Types.AlreadyProcessed();
        if (block.timestamp > intent.expiry) revert Types.Expired();
        if (!venueConfig.enabled) revert Types.VenueDisabled();

        // Mark intent as processed
        _processedIntents[intent.intentId] = true;

        // Generate release ID
        releaseId = keccak256(abi.encodePacked(
            block.chainid,
            address(this),
            intent.intentId,
            ++_releaseNonce,
            block.timestamp
        ));

        // Create release record
        Types.Release memory release = Types.Release({
            intentId: intent.intentId,
            token: intent.token,
            amount: intent.amount,
            recipient: venueConfig.traderSafe,
            releaseTime: uint64(block.timestamp),
            reclaimed: false,
            venueOrderId: bytes32(0) // Will be set when fill is recorded
        });

        _releases[releaseId] = release;
        totalReleased += intent.amount;

        // Handle fund release based on configuration
        if (venueConfig.useBufferVault && venueConfig.bufferVault != address(0)) {
            // Use buffer vault
            IBufferVault(venueConfig.bufferVault).spendTo(
                intent.token,
                venueConfig.traderSafe,
                intent.amount
            );
        }
        // If not using buffer vault, funds are managed directly by the Safe (off-chain policy)

        emit BetPlaced(
            intent.intentId,
            releaseId,
            intent.user,
            intent.amount,
            intent.marketId,
            intent.outcomeId
        );
    }

    /**
     * @notice Record fill completion
     * @param releaseId Release ID
     * @param proceedsToken Token for proceeds
     * @param proceedsAmount Amount of proceeds
     * @param venueOrderId Venue-specific order ID
     */
    function recordFill(
        bytes32 releaseId,
        address proceedsToken,
        uint256 proceedsAmount,
        bytes32 venueOrderId
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        Types.Release storage release = _releases[releaseId];
        if (release.intentId == bytes32(0)) revert Types.NotReleased();
        if (release.reclaimed) revert Types.InvalidState();

        // Update release with venue order ID
        release.venueOrderId = venueOrderId;

        // Handle proceeds if using buffer vault
        if (venueConfig.useBufferVault && 
            venueConfig.bufferVault != address(0) && 
            proceedsAmount > 0) {
            IBufferVault(venueConfig.bufferVault).receiveProceeds(
                proceedsToken,
                proceedsAmount
            );
        }

        emit FillRecorded(releaseId, proceedsToken, proceedsAmount, venueOrderId);
    }

    /**
     * @notice Reclaim unused funds from a release
     * @param releaseId Release ID to reclaim from
     * @return reclaimedAmount Amount reclaimed
     */
    function reclaimUnused(bytes32 releaseId) external nonReentrant returns (uint256 reclaimedAmount) {
        Types.Release storage release = _releases[releaseId];
        if (release.intentId == bytes32(0)) revert Types.NotReleased();
        if (release.reclaimed) revert Types.AlreadyProcessed();
        
        // Check if enough time has passed or if caller has appropriate role
        bool canReclaim = hasRole(OPERATOR_ROLE, msg.sender) || 
                         (block.timestamp >= release.releaseTime + RELEASE_TIMEOUT);
        
        if (!canReclaim) revert Types.ReleaseActive();

        release.reclaimed = true;
        reclaimedAmount = release.amount;
        totalReclaimed += reclaimedAmount;

        // If using buffer vault, reclaim to buffer
        if (venueConfig.useBufferVault && venueConfig.bufferVault != address(0)) {
            // Note: This assumes the Safe will transfer back to buffer vault
            // In practice, this would involve Safe transaction execution
        }

        emit ReleaseReclaimed(releaseId, reclaimedAmount);
    }

    /**
     * @notice Sweep accumulated tokens
     * @param token Token to sweep
     * @return sweptAmount Amount swept
     */
    function sweep(address token) external onlyRole(OPERATOR_ROLE) nonReentrant returns (uint256 sweptAmount) {
        if (token == address(0)) revert Types.ZeroAddress();
        
        sweptAmount = IERC20(token).balanceOf(address(this));
        if (sweptAmount > 0) {
            address treasury = venueConfig.traderSafe; // Use traderSafe as treasury
            IERC20(token).safeTransfer(treasury, sweptAmount);
            
            emit Swept(token, treasury, sweptAmount);
        }
    }

    // View functions
    function getRelease(bytes32 releaseId) external view returns (Types.Release memory) {
        return _releases[releaseId];
    }

    function isReleaseActive(bytes32 releaseId) external view returns (bool) {
        Types.Release memory release = _releases[releaseId];
        return release.intentId != bytes32(0) && 
               !release.reclaimed && 
               block.timestamp < release.releaseTime + RELEASE_TIMEOUT;
    }

    function getVenueConfig() external view returns (Types.VenueConfig memory) {
        return venueConfig;
    }

    // Configuration functions
    function setVenueConfig(
        Types.VenueConfig calldata config
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (config.traderSafe == address(0)) revert Types.ZeroAddress();
        venueConfig = config;
    }

    function setBufferVault(address bufferVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        venueConfig.bufferVault = bufferVault;
        venueConfig.useBufferVault = bufferVault != address(0);
    }

    function setTraderSafe(address traderSafe) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (traderSafe == address(0)) revert Types.ZeroAddress();
        venueConfig.traderSafe = traderSafe;
    }

    // Pausable functions
    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSE_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency reclaim for specific release
     * @param releaseId Release ID to emergency reclaim
     */
    function emergencyReclaim(bytes32 releaseId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Types.Release storage release = _releases[releaseId];
        if (release.intentId == bytes32(0)) revert Types.NotReleased();
        if (release.reclaimed) revert Types.AlreadyProcessed();

        release.reclaimed = true;
        totalReclaimed += release.amount;

        emit ReleaseReclaimed(releaseId, release.amount);
    }

    // Internal functions
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // Gap for future storage variables
    uint256[50] private __gap;
}