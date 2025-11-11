// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IBufferVault.sol";
import "../interfaces/IBridgeAdapter.sol";
import "../libs/Types.sol";

/**
 * @title BufferVault
 * @notice Minimal capped float holder for venue chains (optional)
 * @dev Holds limited amounts of tokens to facilitate quick bet placements
 */
contract BufferVault is 
    IBufferVault,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE");
    bytes32 public constant BRIDGE_MANAGER_ROLE = keccak256("BRIDGE_MANAGER_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");

    // State variables
    address public protocolConfig;
    
    mapping(address => uint256) internal _tokenCaps;
    mapping(address => uint256) internal _tokenBalances;
    
    // Bridge adapter for returning liquidity to hub
    address public bridgeAdapter;
    uint32 public hubDomain; // Domain ID of hub chain (OP Sepolia = 2)
    address public hubVault; // Address of LPVault on hub chain
    
    // Events tracking
    uint256 public totalFunded;
    uint256 public totalSpent;
    uint256 public totalDrained;
    uint256 public totalBridgedToHub;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the buffer vault
     * @param config Protocol configuration contract
     * @param initialManager Initial manager address (typically BetManager)
     */
    function initialize(
        address config,
        address initialManager
    ) external initializer {
        if (config == address(0) || initialManager == address(0)) revert Types.ZeroAddress();

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        protocolConfig = config;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, initialManager);
        _grantRole(PAUSE_ROLE, msg.sender);
    }

    /**
     * @notice Receive bridged funds from LPVault via CCTP
     * @param token Token received (should be USDC)
     * @dev Called after CCTP mints USDC directly to this contract
     */
    function receiveBridge(address token) external virtual onlyRole(FUNDER_ROLE) nonReentrant whenNotPaused {
        if (token == address(0)) revert Types.ZeroAddress();

        // Calculate actual received amount
        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        uint256 trackedBalance = _tokenBalances[token];
        
        if (actualBalance <= trackedBalance) revert Types.ZeroAmount();
        
        uint256 receivedAmount = actualBalance - trackedBalance;
        
        // Check cap
        uint256 newBalance = trackedBalance + receivedAmount;
        uint256 cap = _tokenCaps[token];
        if (cap > 0 && newBalance > cap) revert Types.CapExceeded();

        _tokenBalances[token] = newBalance;
        totalFunded += receivedAmount;

        emit BridgeReceived(token, receivedAmount);
    }
    
    /**
     * @notice Bridge excess liquidity back to LPVault on hub chain
     * @param token Token to bridge (should be USDC)
     * @param amount Amount to bridge back to hub
     * @param bridgeData Additional bridge-specific data (fees, hooks, etc.)
     * @return messageId Unique identifier for cross-chain message
     */
    function bridgeToHub(
        address token,
        uint256 amount,
        bytes calldata bridgeData
    ) external onlyRole(BRIDGE_MANAGER_ROLE) nonReentrant whenNotPaused returns (bytes32 messageId) {
        if (token == address(0)) revert Types.ZeroAddress();
        if (amount == 0) revert Types.ZeroAmount();
        if (_tokenBalances[token] < amount) revert Types.InsufficientBalance();
        if (bridgeAdapter == address(0)) revert NoBridgeAdapter();
        if (hubVault == address(0)) revert NoHubVault();
        
        // Deduct from balance
        _tokenBalances[token] -= amount;
        totalBridgedToHub += amount;
        
        // Approve bridge adapter
        IERC20(token).approve(bridgeAdapter, amount);
        
        // Execute bridge to hub LPVault
        messageId = IBridgeAdapter(bridgeAdapter).bridgeUSDC(
            amount,
            hubDomain,
            hubVault,
            bridgeData
        );
        
        emit BridgedToHub(token, amount, messageId);
    }

    /**
     * @notice Fund the buffer vault with tokens (pull transfer)
     * @param token Token to fund
     * @param amount Amount to fund
     */
    function fund(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (token == address(0)) revert Types.ZeroAddress();
        if (amount == 0) revert Types.ZeroAmount();

        uint256 newBalance = _tokenBalances[token] + amount;
        uint256 cap = _tokenCaps[token];
        
        if (cap > 0 && newBalance > cap) revert Types.CapExceeded();

        _tokenBalances[token] = newBalance;
        totalFunded += amount;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Funded(token, amount, msg.sender);
    }

    /**
     * @notice Spend tokens to specified address (only managers)
     * @param token Token to spend
     * @param to Recipient address
     * @param amount Amount to spend
     */
    function spendTo(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(MANAGER_ROLE) nonReentrant whenNotPaused {
        if (token == address(0) || to == address(0)) revert Types.ZeroAddress();
        if (amount == 0) revert Types.ZeroAmount();
        if (_tokenBalances[token] < amount) revert Types.InsufficientBalance();

        _tokenBalances[token] -= amount;
        totalSpent += amount;

        IERC20(token).safeTransfer(to, amount);

        emit Spent(token, to, amount);
    }

    /**
     * @notice Receive proceeds from trading
     * @param token Token received
     * @param amount Amount received
     */
    function receiveProceeds(
        address token,
        uint256 amount
    ) external onlyRole(MANAGER_ROLE) nonReentrant {
        if (token == address(0)) revert Types.ZeroAddress();
        if (amount == 0) revert Types.ZeroAmount();

        // Note: Assumes tokens are already transferred to this contract
        // In practice, this would be called after a transfer
        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        uint256 expectedBalance = _tokenBalances[token] + amount;
        
        if (actualBalance >= expectedBalance) {
            _tokenBalances[token] = actualBalance;
            emit ProceedsReceived(token, amount);
        }
    }

    /**
     * @notice Drain tokens from buffer (admin only)
     * @param token Token to drain
     * @param to Recipient address
     * @param amount Amount to drain
     */
    function drain(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (token == address(0) || to == address(0)) revert Types.ZeroAddress();
        if (amount == 0) revert Types.ZeroAmount();
        if (_tokenBalances[token] < amount) revert Types.InsufficientBalance();

        _tokenBalances[token] -= amount;
        totalDrained += amount;

        IERC20(token).safeTransfer(to, amount);

        emit Drained(token, to, amount);
    }

    /**
     * @notice Set cap for a token
     * @param token Token to set cap for
     * @param cap New cap amount
     */
    function setCap(address token, uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert Types.ZeroAddress();
        
        uint256 oldCap = _tokenCaps[token];
        _tokenCaps[token] = cap;
        
        emit CapUpdated(token, oldCap, cap);
    }

    /**
     * @notice Set bridge configuration for returning liquidity to hub
     * @param _bridgeAdapter Address of bridge adapter contract
     * @param _hubDomain CCTP domain ID of hub chain
     * @param _hubVault Address of LPVault on hub chain
     */
    function setBridgeConfig(
        address _bridgeAdapter,
        uint32 _hubDomain,
        address _hubVault
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bridgeAdapter = _bridgeAdapter;
        hubDomain = _hubDomain;
        hubVault = _hubVault;
        
        emit BridgeConfigSet(_bridgeAdapter, _hubDomain, _hubVault);
    }

    /**
     * @notice Add a manager
     * @param manager Manager address to add
     */
    function addManager(address manager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (manager == address(0)) revert Types.ZeroAddress();
        _grantRole(MANAGER_ROLE, manager);
    }

    /**
     * @notice Remove a manager
     * @param manager Manager address to remove
     */
    function removeManager(address manager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(MANAGER_ROLE, manager);
    }

    // View functions
    function getBalance(address token) external view returns (uint256) {
        return _tokenBalances[token];
    }

    function getCap(address token) external view returns (uint256) {
        return _tokenCaps[token];
    }

    function getAvailableCapacity(address token) external view returns (uint256) {
        uint256 cap = _tokenCaps[token];
        uint256 balance = _tokenBalances[token];
        return cap > balance ? cap - balance : 0;
    }

    function isManager(address account) external view returns (bool) {
        return hasRole(MANAGER_ROLE, account);
    }

    // Pausable functions
    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSE_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency drain all tokens of a type
     * @param token Token to drain
     * @param to Recipient address
     */
    function emergencyDrain(
        address token,
        address to
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || to == address(0)) revert Types.ZeroAddress();
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            _tokenBalances[token] = 0;
            IERC20(token).safeTransfer(to, balance);
            emit Drained(token, to, balance);
        }
    }

    // Internal functions
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ============ Errors ============
    
    error NoBridgeAdapter();
    error NoHubVault();

    // Gap for future storage variables
    uint256[46] private __gap; // Reduced from 50 to account for new storage
}