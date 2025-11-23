// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../../../contracts/escrow/StagingEscrowVault.sol";
import "../../../contracts/escrow/StagingEscrowVaultV2.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("USDC", "USDC") {
        _mint(msg.sender, 1_000_000_000e18);
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockBridgeAdapter {
    function bridgeUSDC(
        uint256 amount,
        uint32 destinationDomain,
        address recipient,
        bytes calldata
    ) external returns (bytes32) {
        return keccak256(abi.encodePacked(amount, destinationDomain, recipient, block.timestamp));
    }
}

contract StagingEscrowVaultV2Test is Test {
    StagingEscrowVault public vaultV1;
    StagingEscrowVaultV2 public vault;
    MockERC20 public token;
    MockBridgeAdapter public bridgeAdapter;
    
    address public admin;
    address public settlementAuthority;
    address public lpVault;
    uint32 public constant LP_VAULT_DOMAIN = 10; // Optimism mainnet
    
    bytes32 public constant ADMIN_ROLE = 0x00;
    bytes32 public constant SETTLEMENT_AUTHORITY_ROLE = keccak256("SETTLEMENT_AUTHORITY_ROLE");
    
    function setUp() public {
        admin = address(this);
        settlementAuthority = address(0x123);
        lpVault = address(0x456);
        
        token = new MockERC20();
        bridgeAdapter = new MockBridgeAdapter();
        
        // Deploy StagingEscrowVaultV2
        StagingEscrowVaultV2 implementation = new StagingEscrowVaultV2();
        bytes memory initData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = StagingEscrowVaultV2(address(proxy));
        
        // Grant roles
        vault.grantRole(SETTLEMENT_AUTHORITY_ROLE, settlementAuthority);
        
        // Configure bridge
        vault.setBridgeConfig(address(bridgeAdapter), LP_VAULT_DOMAIN, lpVault);
    }
    
    // ========================================
    // AUTO SYNC TESTS
    // ========================================
    
    function test_autoSyncBalance_no_sync_needed() public {
        (bool synced, uint256 delta) = vault.autoSyncBalance(address(token));
        
        assertFalse(synced);
        assertEq(delta, 0);
    }
    
    function test_autoSyncBalance_syncs_new_tokens() public {
        uint256 amount = 1000e18;
        token.transfer(address(vault), amount);
        
        (bool synced, uint256 delta) = vault.autoSyncBalance(address(token));
        
        assertTrue(synced);
        assertEq(delta, amount);
        assertEq(vault.totalReceivedFromLPVault(), amount);
    }
    
    function test_autoSyncBalance_multiple_syncs() public {
        uint256 amount1 = 1000e18;
        token.transfer(address(vault), amount1);
        vault.autoSyncBalance(address(token));
        
        uint256 amount2 = 500e18;
        token.transfer(address(vault), amount2);
        (bool synced, uint256 delta) = vault.autoSyncBalance(address(token));
        
        assertTrue(synced);
        assertEq(delta, amount2);
        assertEq(vault.totalReceivedFromLPVault(), amount1 + amount2);
    }
    
    function test_autoSyncBalance_detects_missing_funds() public {
        uint256 amount = 1000e18;
        token.transfer(address(vault), amount);
        vault.autoSyncBalance(address(token));
        
        // Manually transfer out (simulating missing funds)
        vm.prank(address(vault));
        token.transfer(address(0xdead), 500e18);
        
        vm.expectRevert();
        vault.autoSyncBalance(address(token));
    }
    
    function test_batchAutoSync() public {
        MockERC20 token2 = new MockERC20();
        
        token.transfer(address(vault), 1000e18);
        token2.transfer(address(vault), 2000e18);
        
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token2);
        
        (uint256 syncedCount, uint256 totalDelta) = vault.batchAutoSync(tokens);
        
        assertEq(syncedCount, 2);
        assertEq(totalDelta, 3000e18);
    }
    
    // ========================================
    // CCTP BRIDGE TESTS
    // ========================================
    
    function test_receiveBridge() public {
        uint256 amount = 1000e18;
        token.transfer(address(vault), amount);
        
        vm.prank(settlementAuthority);
        vault.receiveBridge(address(token));
        
        assertEq(vault.totalReceivedFromLPVault(), amount);
    }
    
    function test_receiveBridge_unauthorized_reverts() public {
        uint256 amount = 1000e18;
        token.transfer(address(vault), amount);
        
        vm.prank(address(0x999));
        vm.expectRevert();
        vault.receiveBridge(address(token));
    }
    
    function test_receiveBridge_already_synced_reverts() public {
        vm.prank(settlementAuthority);
        vm.expectRevert();
        vault.receiveBridge(address(token));
    }
    
    function test_receiveBridgeWithValidation() public {
        uint256 amount = 1000e18;
        token.transfer(address(vault), amount);
        
        vm.prank(settlementAuthority);
        vault.receiveBridgeWithValidation(address(token), amount);
        
        assertEq(vault.totalReceivedFromLPVault(), amount);
    }
    
    function test_receiveBridgeWithValidation_wrong_amount_reverts() public {
        uint256 amount = 1000e18;
        token.transfer(address(vault), amount);
        
        vm.prank(settlementAuthority);
        vm.expectRevert();
        vault.receiveBridgeWithValidation(address(token), amount + 100e18);
    }
    
    function test_pushToLPVault() public {
        uint256 amount = 1000e18;
        token.transfer(address(vault), amount);
        vault.autoSyncBalance(address(token));
        
        vm.prank(settlementAuthority);
        bytes32 messageId = vault.pushToLPVault(address(token), amount, "");
        
        assertTrue(messageId != bytes32(0));
        assertEq(vault.totalPushedToLPVault(), amount);
    }
    
    function test_pushToLPVault_insufficient_balance_reverts() public {
        vm.prank(settlementAuthority);
        vm.expectRevert();
        vault.pushToLPVault(address(token), 1000e18, "");
    }
    
    function test_pushToLPVault_unauthorized_reverts() public {
        uint256 amount = 1000e18;
        token.transfer(address(vault), amount);
        
        vm.prank(address(0x999));
        vm.expectRevert();
        vault.pushToLPVault(address(token), amount, "");
    }
    
    // ========================================
    // BATCH OPERATION TESTS
    // ========================================
    
    function test_batchRelease() public {
        // Setup: create reservations for multiple users
        address user1 = address(0x111);
        address user2 = address(0x222);
        bytes32 orderId1 = keccak256("order1");
        bytes32 orderId2 = keccak256("order2");
        
        // Fund users
        token.transfer(user1, 1000e18);
        token.transfer(user2, 2000e18);
        
        vm.prank(user1);
        token.approve(address(vault), type(uint256).max);
        vm.prank(user1);
        vault.deposit(address(token), 1000e18);
        
        vm.prank(user2);
        token.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        vault.deposit(address(token), 2000e18);
        
        // Reserve funds
        vm.prank(settlementAuthority);
        vault.reserve(user1, orderId1, address(token), 500e18, 10e18, lpVault, lpVault, uint64(block.timestamp + 1 days));
        
        vm.prank(settlementAuthority);
        vault.reserve(user2, orderId2, address(token), 1000e18, 10e18, lpVault, lpVault, uint64(block.timestamp + 1 days));
        
        // Batch release
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        
        address[] memory assets = new address[](2);
        assets[0] = address(token);
        assets[1] = address(token);
        
        bytes32[] memory orderIds = new bytes32[](2);
        orderIds[0] = orderId1;
        orderIds[1] = orderId2;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500e18;
        amounts[1] = 1000e18;
        
        vm.prank(settlementAuthority);
        vault.batchRelease(users, assets, orderIds, amounts);
        
        (uint256 avail1,) = vault.balances(user1, address(token));
        (uint256 avail2,) = vault.balances(user2, address(token));
        
        assertEq(avail1, 1000e18);
        assertEq(avail2, 2000e18);
    }
    
    function test_batchCancel() public {
        // Setup expired reservations
        address user1 = address(0x111);
        bytes32 orderId1 = keccak256("order1");
        
        token.transfer(user1, 1000e18);
        vm.prank(user1);
        token.approve(address(vault), type(uint256).max);
        vm.prank(user1);
        vault.deposit(address(token), 1000e18);
        
        vm.prank(settlementAuthority);
        vault.reserve(user1, orderId1, address(token), 500e18, 10e18, lpVault, lpVault, uint64(block.timestamp + 1 hours));
        
        // Fast forward past expiry
        vm.warp(block.timestamp + 2 hours);
        
        bytes32[] memory orderIds = new bytes32[](1);
        orderIds[0] = orderId1;
        
        vm.prank(settlementAuthority);
        vault.batchCancel(orderIds);
        
        (uint256 avail,) = vault.balances(user1, address(token));
        assertEq(avail, 1000e18);
    }
    
    // ========================================
    // BALANCE RECONCILIATION TESTS
    // ========================================
    
    function test_getBalanceStatus() public {
        uint256 amount = 1000e18;
        token.transfer(address(vault), amount);
        
        (uint256 actual, uint256 tracked, int256 difference, bool needsSync) = 
            vault.getBalanceStatus(address(token));
        
        assertEq(actual, amount);
        assertEq(tracked, 0);
        assertEq(difference, int256(amount));
        assertTrue(needsSync);
        
        vault.autoSyncBalance(address(token));
        
        (actual, tracked, difference, needsSync) = vault.getBalanceStatus(address(token));
        assertEq(actual, amount);
        assertEq(tracked, amount);
        assertEq(difference, 0);
        assertFalse(needsSync);
    }
    
    function test_getReconciliationReport() public {
        MockERC20 token2 = new MockERC20();
        
        token.transfer(address(vault), 1000e18);
        token2.transfer(address(vault), 2000e18);
        
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token2);
        
        StagingEscrowVaultV2.BalanceStatus[] memory report = vault.getReconciliationReport(tokens);
        
        assertEq(report.length, 2);
        assertEq(report[0].actualBalance, 1000e18);
        assertEq(report[0].trackedBalance, 0);
        assertTrue(report[0].needsSync);
        
        assertEq(report[1].actualBalance, 2000e18);
        assertEq(report[1].trackedBalance, 0);
        assertTrue(report[1].needsSync);
    }
    
    function test_checkSyncNeeded() public {
        MockERC20 token2 = new MockERC20();
        
        token.transfer(address(vault), 1000e18);
        token2.transfer(address(vault), 2000e18);
        
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token2);
        
        (bool anyNeedSync, address[] memory tokensNeedingSync) = vault.checkSyncNeeded(tokens);
        
        assertTrue(anyNeedSync);
        assertEq(tokensNeedingSync.length, 2);
        
        vault.autoSyncBalance(address(token));
        vault.autoSyncBalance(address(token2));
        
        (anyNeedSync, tokensNeedingSync) = vault.checkSyncNeeded(tokens);
        assertFalse(anyNeedSync);
        assertEq(tokensNeedingSync.length, 0);
    }
    
    function test_getVaultStatistics() public {
        uint256 receivedAmount = 1000e18;
        token.transfer(address(vault), receivedAmount);
        vault.autoSyncBalance(address(token));
        
        uint256 pushedAmount = 500e18;
        vm.prank(settlementAuthority);
        vault.pushToLPVault(address(token), pushedAmount, "");
        
        StagingEscrowVaultV2.VaultStatistics memory stats = vault.getVaultStatistics();
        
        assertEq(stats.totalPushedToLPVault, pushedAmount);
        assertEq(stats.totalReceivedFromLPVault, receivedAmount);
        assertEq(stats.netFlowToLPVault, pushedAmount - receivedAmount);
        assertEq(stats.bridgeAdapter, address(bridgeAdapter));
        assertEq(stats.lpVaultDomain, LP_VAULT_DOMAIN);
        assertEq(stats.lpVault, lpVault);
    }
    
    function test_getUserBalanceSummary() public {
        address user = address(0x111);
        
        token.transfer(user, 2000e18);
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
        vm.prank(user);
        vault.deposit(address(token), 2000e18);
        
        bytes32 orderId = keccak256("order1");
        vm.prank(settlementAuthority);
        vault.reserve(user, orderId, address(token), 500e18, 10e18, lpVault, lpVault, uint64(block.timestamp + 1 days));
        
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        
        StagingEscrowVaultV2.UserBalanceSummary memory summary = vault.getUserBalanceSummary(user, tokens);
        
        assertEq(summary.user, user);
        assertEq(summary.tokenCount, 1);
        assertEq(summary.tokens[0], address(token));
        assertEq(summary.availableBalances[0], 1500e18);
        assertEq(summary.reservedBalances[0], 500e18);
        assertEq(summary.totalAvailable, 1500e18);
        assertEq(summary.totalReserved, 500e18);
    }
    
    // ========================================
    // CONFIGURATION TESTS
    // ========================================
    
    function test_setBridgeConfig() public {
        address newBridge = address(0x789);
        uint32 newDomain = 42;
        address newLPVault = address(0xabc);
        
        vault.setBridgeConfig(newBridge, newDomain, newLPVault);
        
        assertEq(vault.bridgeAdapter(), newBridge);
        assertEq(vault.lpVaultDomain(), newDomain);
        assertEq(vault.lpVault(), newLPVault);
    }
    
    function test_setBridgeConfig_zero_address_reverts() public {
        vm.expectRevert("ZeroAddr");
        vault.setBridgeConfig(address(0), 10, lpVault);
    }
    
    function test_setBridgeConfig_unauthorized_reverts() public {
        vm.prank(address(0x999));
        vm.expectRevert();
        vault.setBridgeConfig(address(bridgeAdapter), 10, lpVault);
    }
    
    // ========================================
    // EMERGENCY FUNCTION TESTS
    // ========================================
    
    function test_emergencySync() public {
        uint256 amount = 1000e18;
        token.transfer(address(vault), amount);
        
        uint256 delta = vault.emergencySync(address(token));
        
        assertEq(delta, amount);
        
        (uint256 actual, uint256 tracked,,) = vault.getBalanceStatus(address(token));
        assertEq(actual, tracked);
    }
    
    function test_emergencySync_unauthorized_reverts() public {
        vm.prank(address(0x999));
        vm.expectRevert();
        vault.emergencySync(address(token));
    }
    
    // ========================================
    // UPGRADE TESTS
    // ========================================
    
    function test_upgrade_v1_to_v2() public {
        StagingEscrowVault implementationV1 = new StagingEscrowVault();
        bytes memory initData = abi.encodeCall(StagingEscrowVault.initialize, (admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementationV1), initData);
        vaultV1 = StagingEscrowVault(address(proxy));
        
        // Use V1
        address user = address(0x111);
        token.transfer(user, 1000e18);
        vm.prank(user);
        token.approve(address(vaultV1), type(uint256).max);
        vm.prank(user);
        vaultV1.deposit(address(token), 1000e18);
        
        (uint256 availV1,) = vaultV1.balances(user, address(token));
        assertEq(availV1, 1000e18);
        
        // Upgrade to V2
        StagingEscrowVaultV2 implementationV2 = new StagingEscrowVaultV2();
        vaultV1.upgradeToAndCall(address(implementationV2), "");
        
        StagingEscrowVaultV2 vaultV2 = StagingEscrowVaultV2(address(proxy));
        
        // Verify V1 state preserved
        (uint256 availV2,) = vaultV2.balances(user, address(token));
        assertEq(availV2, 1000e18);
        
        // Test new V2 features
        vault = vaultV2;
        vault.grantRole(SETTLEMENT_AUTHORITY_ROLE, settlementAuthority);
        vault.setBridgeConfig(address(bridgeAdapter), LP_VAULT_DOMAIN, lpVault);
        
        uint256 cctpAmount = 500e18;
        token.transfer(address(vaultV2), cctpAmount);
        (bool synced, uint256 delta) = vaultV2.autoSyncBalance(address(token));
        
        assertTrue(synced);
        assertEq(delta, cctpAmount);
    }
    
    // ========================================
    // INTEGRATION TESTS
    // ========================================
    
    function test_full_lifecycle_with_cctp() public {
        address user = address(0x111);
        
        // 1. User deposits
        token.transfer(user, 5000e18);
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
        vm.prank(user);
        vault.deposit(address(token), 5000e18);
        
        // 2. Reserve for trade
        bytes32 orderId = keccak256("trade1");
        vm.prank(settlementAuthority);
        vault.reserve(user, orderId, address(token), 1000e18, 10e18, lpVault, lpVault, uint64(block.timestamp + 1 days));
        
        // 3. Trade settles - push to LPVault
        vm.prank(settlementAuthority);
        vault.settleDebit(user, address(token), orderId, 1000e18, lpVault);
        
        // Manually simulate pushing to LPVault (in reality done via separate call)
        // For test, just check balance tracking
        
        // 4. Receive liquidity back from LPVault via CCTP
        uint256 cctpAmount = 2000e18;
        token.transfer(address(vault), cctpAmount);
        vm.prank(settlementAuthority);
        vault.receiveBridge(address(token));
        
        // Verify stats
        assertEq(vault.totalReceivedFromLPVault(), cctpAmount);
    }
}
