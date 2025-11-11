// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./BufferVault.sol";

/**
 * @title BufferVaultV2
 * @notice Enhanced BufferVault with automatic balance synchronization and reconciliation
 * @dev Adds automatic sync on token receipt and comprehensive balance tracking
 * 
 * Key improvements:
 * - Automatic balance sync on direct token transfers (no manual receiveBridge needed)
 * - Balance reconciliation views to detect discrepancies
 * - Event emission for automatic indexing
 * - Better error messages with custom errors
 */
contract BufferVaultV2 is BufferVault {
    using SafeERC20 for IERC20;

    // ========================================
    // CUSTOM ERRORS
    // ========================================
    
    error BalanceMismatch(address token, uint256 actual, uint256 tracked);
    error UnexpectedTokenReceipt(address token, uint256 amount);
    error BalanceAlreadySynced(address token);
    error InvalidSyncAmount(uint256 expected, uint256 actual);
    
    // ========================================
    // NEW EVENTS
    // ========================================
    
    /// @notice Emitted when balance is automatically synchronized
    event BalanceSynced(address indexed token, uint256 oldBalance, uint256 newBalance, uint256 delta);
    
    /// @notice Emitted when a balance discrepancy is detected
    event BalanceDiscrepancyDetected(address indexed token, uint256 actual, uint256 tracked, int256 difference);
    
    /// @notice Emitted when automatic sync is triggered by token receipt
    event AutoSyncTriggered(address indexed token, uint256 amount, string reason);
    
    // ========================================
    // AUTOMATIC BALANCE SYNCHRONIZATION
    // ========================================
    
    /**
     * @notice Automatically sync balance for a token
     * @dev Compares actual ERC20 balance vs tracked balance and updates if needed
     * @param token Token address to sync
     * @return synced Whether a sync was performed
     * @return delta Amount synchronized (0 if already in sync)
     */
    function autoSyncBalance(address token) public returns (bool synced, uint256 delta) {
        if (token == address(0)) revert Types.ZeroAddress();
        
        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        uint256 trackedBalance = _tokenBalances[token];
        
        // If already synced, nothing to do
        if (actualBalance == trackedBalance) {
            return (false, 0);
        }
        
        // If actual < tracked, this indicates a critical error (funds missing)
        if (actualBalance < trackedBalance) {
            emit BalanceDiscrepancyDetected(token, actualBalance, trackedBalance, int256(actualBalance) - int256(trackedBalance));
            revert BalanceMismatch(token, actualBalance, trackedBalance);
        }
        
        // actualBalance > trackedBalance: we received funds
        delta = actualBalance - trackedBalance;
        
        // Check against cap
        uint256 cap = _tokenCaps[token];
        if (cap > 0 && actualBalance > cap) {
            revert Types.CapExceeded();
        }
        
        // Update tracked balance
        uint256 oldBalance = trackedBalance;
        _tokenBalances[token] = actualBalance;
        totalFunded += delta;
        
        emit BalanceSynced(token, oldBalance, actualBalance, delta);
        emit AutoSyncTriggered(token, delta, "autoSyncBalance");
        
        return (true, delta);
    }
    
    /**
     * @notice Sync balances for multiple tokens at once
     * @dev Useful for batch reconciliation
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
    }
    
    // ========================================
    // ENHANCED receiveBridge WITH AUTO-SYNC
    // ========================================
    
    /**
     * @notice Receive bridged funds with automatic synchronization
     * @dev Overrides V1 to automatically sync on any token receipt
     * @param token Token received (should be USDC)
     */
    function receiveBridge(address token) external override onlyRole(FUNDER_ROLE) nonReentrant whenNotPaused {
        if (token == address(0)) revert Types.ZeroAddress();
        
        // Automatically sync balance
        (bool synced, uint256 delta) = autoSyncBalance(token);
        
        if (!synced || delta == 0) {
            revert BalanceAlreadySynced(token);
        }
        
        emit BridgeReceived(token, delta);
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
    ) external onlyRole(FUNDER_ROLE) nonReentrant whenNotPaused {
        if (token == address(0)) revert Types.ZeroAddress();
        if (expectedAmount == 0) revert Types.ZeroAmount();
        
        (bool synced, uint256 actualDelta) = autoSyncBalance(token);
        
        if (!synced) {
            revert BalanceAlreadySynced(token);
        }
        
        // Allow some tolerance (1 unit) for rounding
        if (actualDelta < expectedAmount - 1 || actualDelta > expectedAmount + 1) {
            revert InvalidSyncAmount(expectedAmount, actualDelta);
        }
        
        emit BridgeReceived(token, actualDelta);
        emit AutoSyncTriggered(token, actualDelta, "receiveBridgeWithValidation");
    }
    
    // ========================================
    // BALANCE RECONCILIATION VIEWS
    // ========================================
    
    /**
     * @notice Get comprehensive balance status for a token
     * @dev Returns both actual and tracked balances with difference
     * @param token Token address to check
     * @return actual Current ERC20 balance of the contract
     * @return tracked Internally tracked balance
     * @return difference Difference between actual and tracked (positive if actual > tracked)
     * @return needsSync Whether the balances need synchronization
     */
    function getBalanceStatus(address token) external view returns (
        uint256 actual,
        uint256 tracked,
        int256 difference,
        bool needsSync
    ) {
        actual = IERC20(token).balanceOf(address(this));
        tracked = _tokenBalances[token];
        difference = int256(actual) - int256(tracked);
        needsSync = actual != tracked;
    }
    
    /**
     * @notice Get reconciliation report for multiple tokens
     * @dev Batch version of getBalanceStatus
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
            uint256 tracked = _tokenBalances[token];
            
            report[i] = BalanceStatus({
                token: token,
                actualBalance: actual,
                trackedBalance: tracked,
                difference: int256(actual) - int256(tracked),
                needsSync: actual != tracked,
                cap: _tokenCaps[token],
                availableCapacity: _calculateAvailableCapacity(token, actual)
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
            uint256 tracked = _tokenBalances[tokens[i]];
            
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
            totalFunded: totalFunded,
            totalSpent: totalSpent,
            totalDrained: totalDrained,
            totalBridgedToHub: totalBridgedToHub,
            netBalance: totalFunded - totalSpent - totalDrained - totalBridgedToHub,
            bridgeAdapter: bridgeAdapter,
            hubDomain: hubDomain,
            hubVault: hubVault
        });
    }
    
    // ========================================
    // HELPER FUNCTIONS
    // ========================================
    
    function _calculateAvailableCapacity(address token, uint256 currentBalance) private view returns (uint256) {
        uint256 cap = _tokenCaps[token];
        if (cap == 0) return type(uint256).max; // No cap = unlimited capacity
        return cap > currentBalance ? cap - currentBalance : 0;
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
        uint256 cap;
        uint256 availableCapacity;
    }
    
    struct VaultStatistics {
        uint256 totalFunded;
        uint256 totalSpent;
        uint256 totalDrained;
        uint256 totalBridgedToHub;
        uint256 netBalance;
        address bridgeAdapter;
        uint32 hubDomain;
        address hubVault;
    }
}
