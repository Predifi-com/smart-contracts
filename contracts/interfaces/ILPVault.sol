// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title ILPVault
 * @notice Interface for the LP vault (ERC-4626) on hub chain
 */
interface ILPVault is IERC4626 {
    // Events
    event TreasurySet(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeeSet(uint16 oldFeeBps, uint16 newFeeBps);
    event FeesCollected(address indexed token, uint256 amount);
    event YieldDistributed(uint256 amount, uint256 timestamp);
    event LiquidityBridged(uint32 indexed destinationDomain, address indexed recipient, uint256 amount, bytes32 messageId);
    event BridgeAdapterSet(uint32 indexed destinationDomain, address oldAdapter, address newAdapter);
    event RecipientAuthorizationSet(uint32 indexed destinationDomain, address indexed recipient, bool authorized);
    event YieldDeployed(address indexed adapter, uint256 amount, uint256 shares);
    event YieldWithdrawn(address indexed adapter, uint256 amount, uint256 shares);
    event YieldAdapterAdded(address indexed adapter);
    event YieldAdapterRemoved(address indexed adapter);
    event LiquidityReceivedFromVenue(uint256 amount, uint256 timestamp);

    // Configuration functions
    function setTreasury(address treasury) external;
    function setProtocolFeeBps(uint16 feeBps) external;
    
    // Fee management
    function collectFees() external returns (uint256 feeAmount);
    function distributeYield(uint256 amount) external;
    
    // View functions
    function treasury() external view returns (address);
    function protocolFeeBps() external view returns (uint16);
    function totalFees() external view returns (uint256);
    function pendingFees() external view returns (uint256);
    
    // Vault metrics
    function totalAssets() external view override returns (uint256);
    function convertToShares(uint256 assets) external view override returns (uint256);
    function convertToAssets(uint256 shares) external view override returns (uint256);
    
    // Emergency functions
    function pause() external;
    function unpause() external;
    
    // Bridge functions
    function bridgeToVenue(uint32 destinationDomain, address recipient, uint256 amount, bytes calldata bridgeData) external returns (bytes32 messageId);
    function receiveFromVenue() external;
    function setBridgeAdapter(uint32 destinationDomain, address adapter) external;
    function setAuthorizedRecipient(uint32 destinationDomain, address recipient, bool authorized) external;
    
    // Yield functions
    function deployToYield(address adapter, uint256 amount) external returns (uint256 shares);
    function withdrawFromYield(address adapter, uint256 amount) external returns (uint256 shares);
    function addYieldAdapter(address adapter) external;
    function removeYieldAdapter(address adapter) external;
    function getYieldAdapters() external view returns (address[] memory);
}