// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IBufferVault
 * @notice Interface for buffer vaults on venue chains (optional minimal float holder)
 */
interface IBufferVault {
    // Events
    event BridgeReceived(address indexed token, uint256 amount);
    event BridgedToHub(address indexed token, uint256 amount, bytes32 messageId);
    event BridgeConfigSet(address indexed adapter, uint32 hubDomain, address indexed hubVault);
    event Funded(address indexed token, uint256 amount, address indexed funder);
    event Spent(address indexed token, address indexed to, uint256 amount);
    event ProceedsReceived(address indexed token, uint256 amount);
    event Drained(address indexed token, address indexed to, uint256 amount);
    event CapUpdated(address indexed token, uint256 oldCap, uint256 newCap);

    // Core functions
    function receiveBridge(address token) external;
    
    function bridgeToHub(address token, uint256 amount, bytes calldata bridgeData) external returns (bytes32 messageId);
    
    function fund(address token, uint256 amount) external;
    
    function spendTo(
        address token,
        address to,
        uint256 amount
    ) external;
    
    function receiveProceeds(address token, uint256 amount) external;
    
    function drain(
        address token,
        address to,
        uint256 amount
    ) external;

    // View functions
    function getBalance(address token) external view returns (uint256);
    function getCap(address token) external view returns (uint256);
    function getAvailableCapacity(address token) external view returns (uint256);
    function isManager(address account) external view returns (bool);
    
    // Configuration
    function setBridgeConfig(address bridgeAdapter, uint32 hubDomain, address hubVault) external;
    function setCap(address token, uint256 cap) external;
    function addManager(address manager) external;
    function removeManager(address manager) external;
    
    // Emergency functions
    function pause() external;
    function unpause() external;
    function emergencyDrain(address token, address to) external;
}