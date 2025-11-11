// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../libs/Types.sol";

/**
 * @title IBetManager
 * @notice Interface for bet managers on venue chains
 */
interface IBetManager {
    // Events
    event BetPlaced(
        bytes32 indexed intentId,
        bytes32 indexed releaseId,
        address indexed user,
        uint256 amount,
        bytes32 marketId,
        uint256 outcomeId
    );
    
    event FillRecorded(
        bytes32 indexed releaseId,
        address indexed proceedsToken,
        uint256 proceedsAmount,
        bytes32 venueOrderId
    );
    
    event ReleaseReclaimed(bytes32 indexed releaseId, uint256 reclaimedAmount);
    event Swept(address indexed token, address indexed to, uint256 amount);

    // Core functions
    function handleBetIntent(Types.BetIntent calldata intent) external returns (bytes32 releaseId);
    
    function recordFill(
        bytes32 releaseId,
        address proceedsToken,
        uint256 proceedsAmount,
        bytes32 venueOrderId
    ) external;
    
    function reclaimUnused(bytes32 releaseId) external returns (uint256 reclaimedAmount);
    
    function sweep(address token) external returns (uint256 sweptAmount);

    // View functions
    function getRelease(bytes32 releaseId) external view returns (Types.Release memory);
    function isReleaseActive(bytes32 releaseId) external view returns (bool);
    function getVenueConfig() external view returns (Types.VenueConfig memory);
    
    // Configuration
    function setVenueConfig(Types.VenueConfig calldata config) external;
    function setBufferVault(address bufferVault) external;
    function setTraderSafe(address traderSafe) external;
    
    // Emergency functions
    function pause() external;
    function unpause() external;
    function emergencyReclaim(bytes32 releaseId) external;
}