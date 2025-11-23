// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./StagingEscrowVault.sol";
import "../interfaces/IBridgeAdapter.sol";

/**
 * @title StagingEscrowVaultV2
 * @notice Enhanced reserve vault with bidirectional CCTP flows and LPVault integration
 * @dev Upgrade target for production-grade CCTP reconciliation and liquidity management.
 *      Storage layout is append-only for safe upgrades from V1.
 *      No re-initialization needed - new features activate immediately on upgrade.
 * 
 * Key improvements over V1:
 * - Automatic balance sync on CCTP receipts from LPVault (no manual receiveBridge needed)
 * - Push settled funds to LPVault after successful trades
 * - Pull liquidity from LPVault via CCTP when buffer needs rebalancing
 * - Balance reconciliation views to detect discrepancies
 * - Batch operations for gas efficiency
 * - Emergency recovery functions
 * - Comprehensive monitoring and statistics
 * 
 * Storage Layout:
 * - All V1 storage variables preserved (user deposits, reservations, etc.)
 * - New V2 variables appended for CCTP tracking and bridge configuration
 * - Safe to upgrade from V1 using upgradeToAndCall without data migration
 * - Existing user balances and reservations remain intact
 * 
 * Bidirectional Flow:
 *   User → deposit() → available balance
 *   SettlementAuthority → reserve() → reserved balance  
 *   Trade completes → settleDebit() → push to LPVault via CCTP
 *   Rebalancing needed → receiveBridge() ← CCTP from LPVault
 * 
 * Intent Compatibility:
 * - Works seamlessly with SettlementAuthority V1/V2 intent processing
 * - Reserve/release functions maintain same signatures for backward compatibility
 * - New CCTP features operate independently without breaking existing flows
 */
contract StagingEscrowVaultV2 is StagingEscrowVault {
    using SafeERC20 for IERC20;

    // ========================================
    // CUSTOM ERRORS
    // ========================================
    
    error BalanceMismatch(address token, uint256 actual, uint256 tracked);
    error BalanceAlreadySynced(address token);
    error InvalidSyncAmount(uint256 expected, uint256 actual);
    error NoBridgeAdapter();
    error NoLPVault();
    error InsufficientContractBalance();
    
    // ========================================
    // NEW EVENTS
    // ========================================
    
    /// @notice Emitted when balance is automatically synchronized after CCTP receipt
    event BalanceSynced(address indexed token, uint256 oldBalance, uint256 newBalance, uint256 delta);
    
    /// @notice Emitted when balance discrepancy is detected
    event BalanceDiscrepancyDetected(address indexed token, uint256 actual, uint256 tracked, int256 difference);
    
    /// @notice Emitted when automatic sync is triggered
    event AutoSyncTriggered(address indexed token, uint256 amount, string reason);
    
    /// @notice Emitted when funds are pushed to LPVault
    event PushedToLPVault(address indexed token, uint256 amount, bytes32 indexed messageId);
    
    /// @notice Emitted when funds are received from LPVault via CCTP
    event ReceivedFromLPVault(address indexed token, uint256 amount);
    
    /// @notice Emitted when bridge configuration is updated
    event BridgeConfigUpdated(address indexed bridgeAdapter, uint32 lpVaultDomain, address indexed lpVault);
    
    /// @notice Emitted when batch operations complete
    event BatchOperationCompleted(string operation, uint256 count, uint256 totalAmount);
    
    // ========================================
    // NEW STATE VARIABLES (APPEND-ONLY)
    // ========================================
    
    /// @notice Bridge adapter for CCTP transfers
    address public bridgeAdapter;
    
    /// @notice Domain ID of LPVault chain (Optimism Sepolia = 2, Optimism Mainnet = 10)
    uint32 public lpVaultDomain;
    
    /// @notice Address of LPVault on hub chain
    address public lpVault;
    
    /// @notice Total amount pushed to LPVault
    uint256 public totalPushedToLPVault;
    
    /// @notice Total amount received from LPVault via CCTP
    uint256 public totalReceivedFromLPVault;
    
    /// @notice Tracked contract balances per token (for CCTP reconciliation)
    mapping(address => uint256) private _contractBalances;
    
    // ========================================
    // AUTOMATIC BALANCE SYNCHRONIZATION
    // ========================================
    
    /**
     * @notice Automatically sync balance for a token after CCTP receipt
     * @dev Compares actual ERC20 balance vs tracked balance and updates if needed
     * @param token Token address to sync
     * @return synced Whether a sync was performed
     * @return delta Amount synchronized (0 if already in sync)
     */
    function autoSyncBalance(address token) public returns (bool synced, uint256 delta) {
        require(token != address(0), "ZeroAddr");
        
        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        uint256 trackedBalance = _contractBalances[token];
        
        // If already synced, nothing to do
        if (actualBalance == trackedBalance) {
            return (false, 0);
        }
        
        // If actual < tracked, this indicates a critical error (funds missing)
        if (actualBalance < trackedBalance) {
            emit BalanceDiscrepancyDetected(token, actualBalance, trackedBalance, int256(actualBalance) - int256(trackedBalance));
            revert BalanceMismatch(token, actualBalance, trackedBalance);
        }
        
        // actualBalance > trackedBalance: we received funds via CCTP
        delta = actualBalance - trackedBalance;
        
        // Update tracked balance
        uint256 oldBalance = trackedBalance;
        _contractBalances[token] = actualBalance;
        totalReceivedFromLPVault += delta;
        
        emit BalanceSynced(token, oldBalance, actualBalance, delta);
        emit AutoSyncTriggered(token, delta, "autoSyncBalance");
        
        return (true, delta);
    }
    
    /**
     * @notice Sync balances for multiple tokens at once
     * @dev Useful for batch reconciliation across multiple assets
     * @param tokens Array of token addresses to sync
     * @return syncedCount Number of tokens that were synced
     * @return totalDelta Total amount synchronized across all tokens
     */
    function batchAutoSync(address[] calldata tokens) external returns (uint256 syncedCount, uint256 totalDelta) {
        for (uint256 i = 0; i < tokens.length; i++) {
            (bool synced, uint256 delta) = autoSyncBalance(tokens[i]);
            if (synced) {
                syncedCount++;
                totalDelta += delta;
            }
        }
        
        if (syncedCount > 0) {
            emit BatchOperationCompleted("batchAutoSync", syncedCount, totalDelta);
        }
    }
    
    // ========================================
    // CCTP BRIDGE OPERATIONS
    // ========================================
    
    /**
     * @notice Receive bridged funds from LPVault via CCTP with automatic synchronization
     * @dev Called after CCTP mints tokens directly to this contract
     * @param token Token received (should be USDC)
     */
    function receiveBridge(address token) external onlyRole(SETTLEMENT_AUTHORITY_ROLE) nonReentrant whenNotPaused {
        require(token != address(0), "ZeroAddr");
        
        // Automatically sync balance
        (bool synced, uint256 delta) = autoSyncBalance(token);
        
        if (!synced || delta == 0) {
            revert BalanceAlreadySynced(token);
        }
        
        emit ReceivedFromLPVault(token, delta);
        emit AutoSyncTriggered(token, delta, "receiveBridge");
    }
    
    /**
     * @notice Receive bridge with expected amount validation
     * @dev Allows caller to specify expected amount for validation
     * @param token Token received
     * @param expectedAmount Expected amount to be received
     */
    function receiveBridgeWithValidation(
        address token,
        uint256 expectedAmount
    ) external onlyRole(SETTLEMENT_AUTHORITY_ROLE) nonReentrant whenNotPaused {
        require(token != address(0), "ZeroAddr");
        require(expectedAmount > 0, "ZeroAmount");
        
        (bool synced, uint256 actualDelta) = autoSyncBalance(token);
        
        if (!synced) {
            revert BalanceAlreadySynced(token);
        }
        
        // Allow some tolerance (1 unit) for rounding
        if (actualDelta < expectedAmount - 1 || actualDelta > expectedAmount + 1) {
            revert InvalidSyncAmount(expectedAmount, actualDelta);
        }
        
        emit ReceivedFromLPVault(token, actualDelta);
        emit AutoSyncTriggered(token, actualDelta, "receiveBridgeWithValidation");
    }
    
    /**
     * @notice Push settled funds to LPVault on hub chain via CCTP
     * @dev Used after successful trade settlements to return liquidity to LP pool
     * @param token Token to bridge (should be USDC)
     * @param amount Amount to push to LPVault
     * @param bridgeData Additional bridge-specific data (fees, hooks, etc.)
     * @return messageId Unique identifier for cross-chain message
     */
    function pushToLPVault(
        address token,
        uint256 amount,
        bytes calldata bridgeData
    ) external onlyRole(SETTLEMENT_AUTHORITY_ROLE) nonReentrant whenNotPaused returns (bytes32 messageId) {
        require(token != address(0), "ZeroAddr");
        require(amount > 0, "ZeroAmount");
        if (bridgeAdapter == address(0)) revert NoBridgeAdapter();
        if (lpVault == address(0)) revert NoLPVault();
        
        // Check actual contract balance
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        if (contractBalance < amount) revert InsufficientContractBalance();
        
        // Update tracked balance
        _contractBalances[token] = contractBalance - amount;
        totalPushedToLPVault += amount;
        
        // Approve bridge adapter
        IERC20(token).approve(bridgeAdapter, amount);
        
        // Execute bridge to LPVault
        messageId = IBridgeAdapter(bridgeAdapter).bridgeUSDC(
            amount,
            lpVaultDomain,
            lpVault,
            bridgeData
        );
        
        emit PushedToLPVault(token, amount, messageId);
    }
    
    // ========================================
    // BATCH OPERATIONS
    // ========================================
    
    /**
     * @notice Batch release funds back to available balance for multiple orders
     * @param users Array of user addresses
     * @param assets Array of asset addresses
     * @param orderIds Array of order IDs
     * @param amounts Array of amounts to release
     */
    function batchRelease(
        address[] calldata users,
        address[] calldata assets,
        bytes32[] calldata orderIds,
        uint256[] calldata amounts
    ) external onlyRole(SETTLEMENT_AUTHORITY_ROLE) whenNotPaused nonReentrant {
        uint256 len = users.length;
        require(len == assets.length && len == orderIds.length && len == amounts.length, "LenMismatch");
        
        uint256 totalReleased = 0;
        for (uint256 i = 0; i < len; i++) {
            // Call internal release from parent contract
            this.release(users[i], assets[i], orderIds[i], amounts[i]);
            totalReleased += amounts[i];
        }
        
        emit BatchOperationCompleted("batchRelease", len, totalReleased);
    }
    
    /**
     * @notice Batch cancel multiple expired orders
     * @param orderIds Array of order IDs to cancel
     */
    function batchCancel(bytes32[] calldata orderIds) external onlyRole(SETTLEMENT_AUTHORITY_ROLE) nonReentrant {
        uint256 len = orderIds.length;
        uint256 totalRefunded = 0;
        
        for (uint256 i = 0; i < len; i++) {
            Reservation memory r = this.getReservation(orderIds[i]);
            if (r.active && block.timestamp >= r.expiry) {
                this.cancel(orderIds[i]);
                totalRefunded += (r.reservedAmount - r.releasedAmount);
            }
        }
        
        emit BatchOperationCompleted("batchCancel", len, totalRefunded);
    }
    
    // ========================================
    // BALANCE RECONCILIATION VIEWS
    // ========================================
    
    /**
     * @notice Get comprehensive balance status for a token
     * @param token Token address to check
     * @return actual Current ERC20 balance of the contract
     * @return tracked Internally tracked balance
     * @return difference Difference between actual and tracked
     * @return needsSync Whether the balances need synchronization
     */
    function getBalanceStatus(address token) external view returns (
        uint256 actual,
        uint256 tracked,
        int256 difference,
        bool needsSync
    ) {
        actual = IERC20(token).balanceOf(address(this));
        tracked = _contractBalances[token];
        difference = int256(actual) - int256(tracked);
        needsSync = actual != tracked;
    }
    
    /**
     * @notice Get reconciliation report for multiple tokens
     * @param tokens Array of token addresses
     * @return report Array of balance statuses
     */
    function getReconciliationReport(address[] calldata tokens) external view returns (
        BalanceStatus[] memory report
    ) {
        report = new BalanceStatus[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 actual = IERC20(token).balanceOf(address(this));
            uint256 tracked = _contractBalances[token];
            
            report[i] = BalanceStatus({
                token: token,
                actualBalance: actual,
                trackedBalance: tracked,
                difference: int256(actual) - int256(tracked),
                needsSync: actual != tracked
            });
        }
    }
    
    /**
     * @notice Check if any token balances need synchronization
     * @param tokens Array of token addresses to check
     * @return anyNeedSync True if any token needs sync
     * @return tokensNeedingSync Array of tokens that need sync
     */
    function checkSyncNeeded(address[] calldata tokens) external view returns (
        bool anyNeedSync,
        address[] memory tokensNeedingSync
    ) {
        uint256 count = 0;
        address[] memory temp = new address[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 actual = IERC20(tokens[i]).balanceOf(address(this));
            uint256 tracked = _contractBalances[tokens[i]];
            
            if (actual != tracked) {
                temp[count] = tokens[i];
                count++;
            }
        }
        
        anyNeedSync = count > 0;
        tokensNeedingSync = new address[](count);
        
        for (uint256 i = 0; i < count; i++) {
            tokensNeedingSync[i] = temp[i];
        }
    }
    
    /**
     * @notice Get detailed vault statistics
     * @return stats VaultStatistics struct with all metrics
     */
    function getVaultStatistics() external view returns (VaultStatistics memory stats) {
        stats = VaultStatistics({
            totalPushedToLPVault: totalPushedToLPVault,
            totalReceivedFromLPVault: totalReceivedFromLPVault,
            netFlowToLPVault: totalPushedToLPVault - totalReceivedFromLPVault,
            bridgeAdapter: bridgeAdapter,
            lpVaultDomain: lpVaultDomain,
            lpVault: lpVault
        });
    }
    
    /**
     * @notice Get summary of user's balances and active reservations
     * @param user User address
     * @param tokens Array of token addresses
     * @return summary UserBalanceSummary struct
     */
    function getUserBalanceSummary(address user, address[] calldata tokens) external view returns (
        UserBalanceSummary memory summary
    ) {
        summary.user = user;
        summary.tokenCount = tokens.length;
        summary.tokens = tokens;
        summary.availableBalances = new uint256[](tokens.length);
        summary.reservedBalances = new uint256[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length; i++) {
            (uint256 avail, uint256 resv) = this.balances(user, tokens[i]);
            summary.availableBalances[i] = avail;
            summary.reservedBalances[i] = resv;
            summary.totalAvailable += avail;
            summary.totalReserved += resv;
        }
    }
    
    // ========================================
    // CONFIGURATION
    // ========================================
    
    /**
     * @notice Set bridge configuration for LPVault CCTP transfers
     * @param _bridgeAdapter Address of CCTP bridge adapter
     * @param _lpVaultDomain Domain ID of LPVault chain
     * @param _lpVault Address of LPVault on hub chain
     */
    function setBridgeConfig(
        address _bridgeAdapter,
        uint32 _lpVaultDomain,
        address _lpVault
    ) external onlyRole(ADMIN_ROLE) {
        require(_bridgeAdapter != address(0) && _lpVault != address(0), "ZeroAddr");
        
        bridgeAdapter = _bridgeAdapter;
        lpVaultDomain = _lpVaultDomain;
        lpVault = _lpVault;
        
        emit BridgeConfigUpdated(_bridgeAdapter, _lpVaultDomain, _lpVault);
    }
    
    // ========================================
    // EMERGENCY FUNCTIONS
    // ========================================
    
    /**
     * @notice Emergency sync for a specific token (admin override)
     * @param token Token to sync
     */
    function emergencySync(address token) external onlyRole(ADMIN_ROLE) returns (uint256 delta) {
        require(token != address(0), "ZeroAddr");
        
        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        uint256 trackedBalance = _contractBalances[token];
        
        if (actualBalance >= trackedBalance) {
            delta = actualBalance - trackedBalance;
            _contractBalances[token] = actualBalance;
            emit BalanceSynced(token, trackedBalance, actualBalance, delta);
        }
    }
    
    // ========================================
    // STRUCTS
    // ========================================
    
    struct BalanceStatus {
        address token;
        uint256 actualBalance;
        uint256 trackedBalance;
        int256 difference;
        bool needsSync;
    }
    
    struct VaultStatistics {
        uint256 totalPushedToLPVault;
        uint256 totalReceivedFromLPVault;
        uint256 netFlowToLPVault;
        address bridgeAdapter;
        uint32 lpVaultDomain;
        address lpVault;
    }
    
    struct UserBalanceSummary {
        address user;
        uint256 tokenCount;
        address[] tokens;
        uint256[] availableBalances;
        uint256[] reservedBalances;
        uint256 totalAvailable;
        uint256 totalReserved;
    }
}
