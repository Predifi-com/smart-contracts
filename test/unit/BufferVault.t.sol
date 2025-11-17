// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../contracts/vault/BufferVault.sol";
import "../../contracts/interfaces/IBufferVault.sol";
import "../../contracts/libs/Types.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../mocks/MockBridgeAdapter.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BufferVaultTest is Test {
    BufferVault public bufferVault;
    BufferVault public implementation;
    MockERC20 public token;
    
    address public admin;
    address public manager;
    address public funder;
    address public user;
    address public protocolConfig;
    
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE");
    
    event Funded(address indexed token, uint256 amount, address indexed funder);
    event Spent(address indexed token, address indexed to, uint256 amount);
    event ProceedsReceived(address indexed token, uint256 amount);
    event Drained(address indexed token, address indexed to, uint256 amount);
    event CapUpdated(address indexed token, uint256 oldCap, uint256 newCap);

    function setUp() public {
        admin = makeAddr("admin");
        manager = makeAddr("manager");
        funder = makeAddr("funder");
        user = makeAddr("user");
        protocolConfig = makeAddr("protocolConfig");
        
        token = new MockERC20("USDC", "USDC");
        
        // Deploy implementation
        implementation = new BufferVault();
        
        // Deploy proxy with admin as deployer
        vm.startPrank(admin);
        bytes memory initData = abi.encodeWithSelector(
            BufferVault.initialize.selector,
            protocolConfig,
            manager
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        bufferVault = BufferVault(address(proxy));
        
        // Setup additional roles
        bufferVault.grantRole(FUNDER_ROLE, funder);
        
        // Set cap for token
        bufferVault.setCap(address(token), 200_000e18);
        
        vm.stopPrank();
        
        // Fund buffer vault
        token.mint(funder, 100_000e18);
        vm.startPrank(funder);
        token.approve(address(bufferVault), 100_000e18);
        bufferVault.fund(address(token), 100_000e18);
        vm.stopPrank();
    }

    function testInitialization() public {
        assertEq(bufferVault.protocolConfig(), protocolConfig);
        assertTrue(bufferVault.hasRole(bufferVault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(bufferVault.hasRole(MANAGER_ROLE, manager));
        assertTrue(bufferVault.hasRole(FUNDER_ROLE, funder));
        assertTrue(bufferVault.isManager(manager));
    }

    function testGetCap() public {
        // Cap was set in setUp to 200_000e18
        assertEq(bufferVault.getCap(address(token)), 200_000e18);
        
        // Set a new cap
        uint256 cap = 10_000e18;
        vm.prank(admin);
        bufferVault.setCap(address(token), cap);
        
        assertEq(bufferVault.getCap(address(token)), cap);
    }

    function testSpendTo() public {
        // Buffer vault already has 100,000e18 from setUp
        uint256 initialBalance = 100_000e18;
        
        // Now spend to recipient
        uint256 spendAmount = 500e18;
        address recipient = makeAddr("recipient");
        
        vm.prank(manager);
        vm.expectEmit(true, true, false, true);
        emit Spent(address(token), recipient, spendAmount);
        
        bufferVault.spendTo(address(token), recipient, spendAmount);
        
        // Check balances
        assertEq(token.balanceOf(recipient), spendAmount);
        assertEq(token.balanceOf(address(bufferVault)), initialBalance - spendAmount);
    }

    function testReceiveProceeds() public {
        uint256 initialBalance = 100_000e18; // From setUp
        uint256 proceedsAmount = 2000e18;
        token.mint(address(this), proceedsAmount);
        
        // Transfer proceeds to vault
        token.transfer(address(bufferVault), proceedsAmount);
        
        vm.prank(manager);
        vm.expectEmit(true, false, false, true);
        emit ProceedsReceived(address(token), proceedsAmount);
        
        bufferVault.receiveProceeds(address(token), proceedsAmount);
        
        assertEq(token.balanceOf(address(bufferVault)), initialBalance + proceedsAmount);
    }

    function testDrain() public {
        // Buffer vault already has 100,000e18 from setUp
        uint256 initialBalance = 100_000e18;
        
        // Drain the vault (admin only)
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit Drained(address(token), admin, initialBalance);
        
        bufferVault.drain(address(token), admin, initialBalance);
        
        // Check balance is drained
        assertEq(token.balanceOf(address(bufferVault)), 0);
        assertEq(token.balanceOf(admin), initialBalance);
    }

    function testSetCap() public {
        uint256 oldCap = 200_000e18; // Set in setUp
        uint256 newCap = 300_000e18;
        
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit CapUpdated(address(token), oldCap, newCap);
        
        bufferVault.setCap(address(token), newCap);
        
        assertEq(bufferVault.getCap(address(token)), newCap);
    }

    function testGetBalance() public {
        // Buffer vault has 100,000e18 from setUp
        uint256 initialBalance = 100_000e18;
        assertEq(bufferVault.getBalance(address(token)), initialBalance);
        
        // After funding
        uint256 fundAmount = 1000e18;
        token.mint(funder, fundAmount);
        
        vm.startPrank(funder);
        token.approve(address(bufferVault), fundAmount);
        bufferVault.fund(address(token), fundAmount);
        vm.stopPrank();
        
        assertEq(bufferVault.getBalance(address(token)), initialBalance + fundAmount);
    }

    function testFundExceedsCap() public {
        uint256 cap = 1000e18;
        uint256 excessAmount = cap + 1e18;
        
        // Set cap first
        vm.prank(admin);
        bufferVault.setCap(address(token), cap);
        
        token.mint(funder, excessAmount);
        
        vm.startPrank(funder);
        token.approve(address(bufferVault), excessAmount);
        vm.expectRevert(); // Should revert when exceeding cap
        bufferVault.fund(address(token), excessAmount);
        vm.stopPrank();
    }

    function testFundWithoutRole() public {
        uint256 amount = 100e18;
        token.mint(user, amount);
        
        // Fund function is open to anyone, no role required
        vm.startPrank(user);
        token.approve(address(bufferVault), amount);
        bufferVault.fund(address(token), amount); // Should work for anyone
        vm.stopPrank();
        
        assertEq(bufferVault.getBalance(address(token)), 100_000e18 + amount);
    }

    function testAccessControlSpendTo() public {
        vm.prank(user);
        vm.expectRevert(); // Should revert for non-manager
        bufferVault.spendTo(address(token), user, 100e18);
    }

    function testAccessControlReceiveProceeds() public {
        vm.prank(user);
        vm.expectRevert(); // Should revert for non-manager
        bufferVault.receiveProceeds(address(token), 100e18);
    }

    function testAccessControlDrain() public {
        vm.prank(user);
        vm.expectRevert(); // Should revert for non-admin
        bufferVault.drain(address(token), user, 100e18);
    }

    function testAccessControlSetCap() public {
        vm.prank(user);
        vm.expectRevert(); // Should revert for non-admin
        bufferVault.setCap(address(token), 200_000e18);
    }

    function testIsManager() public {
        assertTrue(bufferVault.isManager(manager));
        assertFalse(bufferVault.isManager(user));
        assertFalse(bufferVault.isManager(funder));
    }

    function testIsManagerAfterRoleUpdate() public {
        address newManager = makeAddr("newManager");
        
        vm.prank(admin);
        bufferVault.grantRole(MANAGER_ROLE, newManager);
        
        assertTrue(bufferVault.isManager(newManager));
    }

    function testProtocolConfigIntegration() public {
        assertEq(bufferVault.protocolConfig(), protocolConfig);
        
        // Protocol config should be immutable after initialization
        assertNotEq(bufferVault.protocolConfig(), address(0));
    }

    function testMultipleTokenSupport() public {
        // BufferVault supports multiple tokens, not just one
        MockERC20 token2 = new MockERC20("DAI", "DAI");
        
        // Set cap for token2
        vm.prank(admin);
        bufferVault.setCap(address(token2), 50_000e18);
        
        assertEq(bufferVault.getCap(address(token2)), 50_000e18);
        assertEq(bufferVault.getBalance(address(token2)), 0);
    }

    function testFundAndSpendWorkflow() public {
        uint256 initialBalance = 100_000e18; // From setUp
        uint256 fundAmount = 1000e18;
        uint256 spendAmount = 600e18;
        address recipient = makeAddr("recipient");
        
        // Fund the vault
        token.mint(funder, fundAmount);
        vm.startPrank(funder);
        token.approve(address(bufferVault), fundAmount);
        bufferVault.fund(address(token), fundAmount);
        vm.stopPrank();
        
        // Spend from the vault
        vm.prank(manager);
        bufferVault.spendTo(address(token), recipient, spendAmount);
        
        // Check final balances
        assertEq(token.balanceOf(recipient), spendAmount);
        assertEq(bufferVault.getBalance(address(token)), initialBalance + fundAmount - spendAmount);
    }

    // ============================================
    // ADDITIONAL COVERAGE TESTS
    // ============================================

    function testReceiveProceedsMultipleTimes() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        
        token.mint(manager, amount1 + amount2);
        
        vm.startPrank(manager);
        token.approve(address(bufferVault), amount1 + amount2);
        // Transfer proceeds into the vault before accounting, as required by contract semantics
        token.transfer(address(bufferVault), amount1);
        uint256 balanceBefore = bufferVault.getBalance(address(token));
        bufferVault.receiveProceeds(address(token), amount1);
        // Transfer the second tranche and call again
        token.transfer(address(bufferVault), amount2);
        bufferVault.receiveProceeds(address(token), amount2);
        
        assertEq(bufferVault.getBalance(address(token)), balanceBefore + amount1 + amount2);
        vm.stopPrank();
    }

    function testSpendToMultipleRecipients() public {
        uint256 spendAmount = 500e18;
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        address recipient3 = makeAddr("recipient3");
        
        vm.startPrank(manager);
        bufferVault.spendTo(address(token), recipient1, spendAmount);
        bufferVault.spendTo(address(token), recipient2, spendAmount);
        bufferVault.spendTo(address(token), recipient3, spendAmount);
        vm.stopPrank();
        
        assertEq(token.balanceOf(recipient1), spendAmount);
        assertEq(token.balanceOf(recipient2), spendAmount);
        assertEq(token.balanceOf(recipient3), spendAmount);
    }

    function testDrainMultipleTokens() public {
        MockERC20 token2 = new MockERC20("DAI", "DAI");
        MockERC20 token3 = new MockERC20("WETH", "WETH");
        
        // Fund with multiple tokens
        token2.mint(address(bufferVault), 5000e18);
        token3.mint(address(bufferVault), 3000e18);
        
        address drainRecipient = makeAddr("drainRecipient");
        
        vm.startPrank(admin);
        bufferVault.drain(address(token), drainRecipient, bufferVault.getBalance(address(token)));
        // For unaccounted balances minted directly to the vault, use emergencyDrain
        bufferVault.emergencyDrain(address(token2), drainRecipient);
        bufferVault.emergencyDrain(address(token3), drainRecipient);
        vm.stopPrank();
        
        assertGt(token.balanceOf(drainRecipient), 0);
        assertEq(token2.balanceOf(drainRecipient), 5000e18);
        assertEq(token3.balanceOf(drainRecipient), 3000e18);
    }

    function testSetCapForMultipleTokens() public {
        MockERC20 token2 = new MockERC20("DAI", "DAI");
        MockERC20 token3 = new MockERC20("WETH", "WETH");
        
        vm.startPrank(admin);
        bufferVault.setCap(address(token2), 10_000e18);
        bufferVault.setCap(address(token3), 5_000e18);
        vm.stopPrank();
        
        assertEq(bufferVault.getCap(address(token2)), 10_000e18);
        assertEq(bufferVault.getCap(address(token3)), 5_000e18);
    }

    function testGetBalanceWithNoFunds() public {
        MockERC20 token2 = new MockERC20("DAI", "DAI");
        assertEq(bufferVault.getBalance(address(token2)), 0);
    }

    function testFundExactlyAtCap() public {
        uint256 currentCap = bufferVault.getCap(address(token));
        uint256 currentBalance = bufferVault.getBalance(address(token));
        uint256 fundToCapAmount = currentCap - currentBalance;
        
        token.mint(funder, fundToCapAmount);
        vm.startPrank(funder);
        token.approve(address(bufferVault), fundToCapAmount);
        bufferVault.fund(address(token), fundToCapAmount);
        vm.stopPrank();
        
        assertEq(bufferVault.getBalance(address(token)), currentCap);
    }

    function testSpendExactBalance() public {
        uint256 balance = bufferVault.getBalance(address(token));
        address recipient = makeAddr("recipient");
        
        vm.prank(manager);
        bufferVault.spendTo(address(token), recipient, balance);
        
        assertEq(bufferVault.getBalance(address(token)), 0);
        assertEq(token.balanceOf(recipient), balance);
    }

    function testSpendZeroAmount() public {
        address recipient = makeAddr("recipient");
        
        vm.prank(manager);
        vm.expectRevert();
        bufferVault.spendTo(address(token), recipient, 0);
    }

    function testFundZeroAmount() public {
        vm.startPrank(funder);
        token.approve(address(bufferVault), 0);
        
        vm.expectRevert();
        bufferVault.fund(address(token), 0);
        vm.stopPrank();
    }

    function testReceiveProceedsZeroAmount() public {
        vm.startPrank(manager);
        token.approve(address(bufferVault), 0);
        
        vm.expectRevert();
        bufferVault.receiveProceeds(address(token), 0);
        vm.stopPrank();
    }

    function testDrainWithZeroBalance() public {
        MockERC20 emptyToken = new MockERC20("EMPTY", "EMPTY");
        address recipient = makeAddr("recipient");
        
        vm.prank(admin);
        vm.expectRevert(Types.ZeroAmount.selector);
        bufferVault.drain(address(emptyToken), recipient, 0);
    }

    function testSetCapToZero() public {
        vm.prank(admin);
        bufferVault.setCap(address(token), 0);
        
        assertEq(bufferVault.getCap(address(token)), 0);
    }

    function testSetCapToMaxUint() public {
        vm.prank(admin);
        bufferVault.setCap(address(token), type(uint256).max);
        
        assertEq(bufferVault.getCap(address(token)), type(uint256).max);
    }

    function testIsManagerAfterRoleGrant() public {
        address newManager2 = makeAddr("newManager2");
        
        assertFalse(bufferVault.isManager(newManager2));
        
        vm.startPrank(admin);
        bufferVault.grantRole(bufferVault.MANAGER_ROLE(), newManager2);
        vm.stopPrank();
        
        assertTrue(bufferVault.isManager(newManager2));
    }

    function testIsManagerAfterRoleRevoke() public {
        assertTrue(bufferVault.isManager(manager));
        
    vm.startPrank(admin);
    bufferVault.revokeRole(bufferVault.MANAGER_ROLE(), manager);
    vm.stopPrank();
        
        assertFalse(bufferVault.isManager(manager));
    }

    function testMultipleManagersCanSpend() public {
        address manager2 = makeAddr("manager2");
        
    vm.startPrank(admin);
    bufferVault.grantRole(bufferVault.MANAGER_ROLE(), manager2);
    vm.stopPrank();
        
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        
        vm.prank(manager);
        bufferVault.spendTo(address(token), recipient1, 100e18);
        
        vm.prank(manager2);
        bufferVault.spendTo(address(token), recipient2, 100e18);
        
        assertEq(token.balanceOf(recipient1), 100e18);
        assertEq(token.balanceOf(recipient2), 100e18);
    }

    function testMultipleFundersCanFund() public {
        address funder2 = makeAddr("funder2");
        
    vm.startPrank(admin);
    bufferVault.grantRole(bufferVault.FUNDER_ROLE(), funder2);
    vm.stopPrank();
        
        token.mint(funder2, 5000e18);
        
        vm.startPrank(funder2);
        token.approve(address(bufferVault), 5000e18);
        bufferVault.fund(address(token), 5000e18);
        vm.stopPrank();
        
        assertGt(bufferVault.getBalance(address(token)), 100_000e18);
    }

    function testFundAndDrainCycle() public {
        address recipient = makeAddr("recipient");
        uint256 fundAmount = 10_000e18;
        
        // Fund
        token.mint(funder, fundAmount);
        vm.startPrank(funder);
        token.approve(address(bufferVault), fundAmount);
        bufferVault.fund(address(token), fundAmount);
        vm.stopPrank();
        
        uint256 balanceAfterFund = bufferVault.getBalance(address(token));
        
        // Drain
        vm.prank(admin);
        bufferVault.drain(address(token), recipient, balanceAfterFund);
        
        assertEq(bufferVault.getBalance(address(token)), 0);
        assertEq(token.balanceOf(recipient), balanceAfterFund);
    }

    function testReceiveProceedsAndSpendCycle() public {
        address recipient = makeAddr("recipient");
        uint256 proceedsAmount = 5_000e18;
        
        token.mint(manager, proceedsAmount);
        vm.startPrank(manager);
        token.approve(address(bufferVault), proceedsAmount);
        bufferVault.receiveProceeds(address(token), proceedsAmount);
        
        uint256 balanceAfterReceive = bufferVault.getBalance(address(token));
        
        bufferVault.spendTo(address(token), recipient, 3_000e18);
        vm.stopPrank();
        
        assertEq(bufferVault.getBalance(address(token)), balanceAfterReceive - 3_000e18);
        assertEq(token.balanceOf(recipient), 3_000e18);
    }

    function testGetCapForUnconfiguredToken() public {
        MockERC20 unconfiguredToken = new MockERC20("UNCONFIGURED", "UNC");
        assertEq(bufferVault.getCap(address(unconfiguredToken)), 0);
    }

    function testSpendMoreThanBalance() public {
        uint256 balance = bufferVault.getBalance(address(token));
        address recipient = makeAddr("recipient");
        
        vm.prank(manager);
        vm.expectRevert();
        bufferVault.spendTo(address(token), recipient, balance + 1e18);
    }

    function testFundWithInsufficientAllowance() public {
        uint256 fundAmount = 1000e18;
        
        token.mint(funder, fundAmount);
        vm.startPrank(funder);
        token.approve(address(bufferVault), fundAmount - 1); // Approve less
        
        vm.expectRevert();
        bufferVault.fund(address(token), fundAmount);
        vm.stopPrank();
    }

    function testReceiveProceedsWithInsufficientBalance() public {
        uint256 proceedsAmount = 1000e18;
        
        vm.startPrank(manager);
        token.approve(address(bufferVault), proceedsAmount);
        // Without transferring tokens to the vault first, this should be a no-op and not revert
        uint256 beforeBal = bufferVault.getBalance(address(token));
        bufferVault.receiveProceeds(address(token), proceedsAmount);
        uint256 afterBal = bufferVault.getBalance(address(token));
        assertEq(afterBal, beforeBal);
        vm.stopPrank();
    }

    function testGetAvailableCapacityPositiveAndZero() public {
        // With current cap 200_000 and balance 100_000, available should be 100_000
        uint256 available = bufferVault.getAvailableCapacity(address(token));
        assertEq(available, 100_000e18);

        // Reduce cap below current balance to trigger zero branch
        vm.prank(admin);
        bufferVault.setCap(address(token), 50_000e18);
        assertEq(bufferVault.getAvailableCapacity(address(token)), 0);
    }

    function testEmergencyDrainZeroBalanceNoop() public {
        MockERC20 emptyToken = new MockERC20("EMPTY", "EMPTY");
        address recipient = makeAddr("recipient");

        // No tokens minted to vault; call should not revert and not change accounting
        vm.prank(admin);
        bufferVault.emergencyDrain(address(emptyToken), recipient);
        assertEq(bufferVault.getBalance(address(emptyToken)), 0);
        assertEq(emptyToken.balanceOf(recipient), 0);
    }

    // ============ Bridge Tests ============

    function testReceiveBridge() public {
        address usdc = address(token);
        uint256 bridgeAmount = 25e18;
        
        // Simulate CCTP mint - transfer USDC to vault
        token.mint(address(bufferVault), bridgeAmount);
        
        // Track balance before
        uint256 balanceBefore = bufferVault.getBalance(usdc);
        
        // Call receiveBridge
        vm.prank(funder);
        bufferVault.receiveBridge(usdc);
        
        // Check balance increased
        uint256 balanceAfter = bufferVault.getBalance(usdc);
        assertEq(balanceAfter, balanceBefore + bridgeAmount);
    }

    function testReceiveBridgeMultipleTimes() public {
        address usdc = address(token);
        
        // First bridge
        token.mint(address(bufferVault), 25e18);
        vm.prank(funder);
        bufferVault.receiveBridge(usdc);
        
        uint256 balanceAfterFirst = bufferVault.getBalance(usdc);
        assertEq(balanceAfterFirst, 100_025e18); // 100k initial + 25
        
        // Second bridge
        token.mint(address(bufferVault), 30e18);
        vm.prank(funder);
        bufferVault.receiveBridge(usdc);
        
        uint256 balanceAfterSecond = bufferVault.getBalance(usdc);
        assertEq(balanceAfterSecond, 100_055e18); // Previous + 30
    }

    function testReceiveBridgeExceedsCap() public {
        address usdc = address(token);
        
        // Set cap lower than current balance + bridge amount
        vm.prank(admin);
        bufferVault.setCap(usdc, 100_010e18); // Only 10 USDC room
        
        // Try to receive 25 USDC - should revert
        token.mint(address(bufferVault), 25e18);
        
        vm.prank(funder);
        vm.expectRevert();
        bufferVault.receiveBridge(usdc);
    }

    function testReceiveBridgeUnauthorized() public {
        address usdc = address(token);
        token.mint(address(bufferVault), 25e18);
        
        vm.prank(user); // Not funder
        vm.expectRevert();
        bufferVault.receiveBridge(usdc);
    }

    function testReceiveBridgeWhenPaused() public {
        address usdc = address(token);
        token.mint(address(bufferVault), 25e18);
        
        vm.prank(admin);
        bufferVault.pause();
        
        vm.prank(funder);
        vm.expectRevert();
        bufferVault.receiveBridge(usdc);
    }

    function testBridgeToHub() public {
        // Setup bridge config
        MockBridgeAdapter adapter = new MockBridgeAdapter();
        uint32 hubDomain = 2;
        address hubVault = makeAddr("hubVault");
        
        vm.prank(admin);
        bufferVault.setBridgeConfig(address(adapter), hubDomain, hubVault);
        
        // Grant BRIDGE_MANAGER_ROLE
        bytes32 bridgeRole = keccak256("BRIDGE_MANAGER_ROLE");
        vm.prank(admin);
        bufferVault.grantRole(bridgeRole, manager);
        
        // Fund buffer vault with excess
        token.mint(address(bufferVault), 50e18);
        vm.prank(funder);
        bufferVault.receiveBridge(address(token));
        
        // Bridge excess to hub
        uint256 bridgeAmount = 25e18;
        uint256 balanceBefore = bufferVault.getBalance(address(token));
        
        vm.prank(manager);
        bytes32 messageId = bufferVault.bridgeToHub(address(token), bridgeAmount, "");
        
        // Check balance decreased
        uint256 balanceAfter = bufferVault.getBalance(address(token));
        assertEq(balanceAfter, balanceBefore - bridgeAmount);
        
        // Check message was sent
        assertTrue(adapter.wasMessageSent(messageId));
        assertEq(bufferVault.totalBridgedToHub(), bridgeAmount);
    }

    function testBridgeToHubInsufficientBalance() public {
        MockBridgeAdapter adapter = new MockBridgeAdapter();
        uint32 hubDomain = 2;
        address hubVault = makeAddr("hubVault");
        
        vm.prank(admin);
        bufferVault.setBridgeConfig(address(adapter), hubDomain, hubVault);
        
        bytes32 bridgeRole = keccak256("BRIDGE_MANAGER_ROLE");
        vm.prank(admin);
        bufferVault.grantRole(bridgeRole, manager);
        
        // Try to bridge more than available
        vm.prank(manager);
        vm.expectRevert();
        bufferVault.bridgeToHub(address(token), 200_000e18, "");
    }

    function testBridgeToHubNoBridgeAdapter() public {
        bytes32 bridgeRole = keccak256("BRIDGE_MANAGER_ROLE");
        vm.prank(admin);
        bufferVault.grantRole(bridgeRole, manager);
        
        // Try to bridge without setting adapter
        vm.prank(manager);
        vm.expectRevert();
        bufferVault.bridgeToHub(address(token), 1e18, "");
    }

    function testBridgeToHubNoHubVault() public {
        MockBridgeAdapter adapter = new MockBridgeAdapter();
        
        vm.prank(admin);
        bufferVault.setBridgeConfig(address(adapter), 2, address(0)); // No hub vault
        
        bytes32 bridgeRole = keccak256("BRIDGE_MANAGER_ROLE");
        vm.prank(admin);
        bufferVault.grantRole(bridgeRole, manager);
        
        vm.prank(manager);
        vm.expectRevert();
        bufferVault.bridgeToHub(address(token), 1e18, "");
    }

    function testBridgeToHubUnauthorized() public {
        MockBridgeAdapter adapter = new MockBridgeAdapter();
        
        vm.prank(admin);
        bufferVault.setBridgeConfig(address(adapter), 2, makeAddr("hubVault"));
        
        vm.prank(user); // Not bridge manager
        vm.expectRevert();
        bufferVault.bridgeToHub(address(token), 1e18, "");
    }

    function testBridgeToHubWhenPaused() public {
        MockBridgeAdapter adapter = new MockBridgeAdapter();
        
        vm.prank(admin);
        bufferVault.setBridgeConfig(address(adapter), 2, makeAddr("hubVault"));
        
        bytes32 bridgeRole = keccak256("BRIDGE_MANAGER_ROLE");
        vm.prank(admin);
        bufferVault.grantRole(bridgeRole, manager);
        
        vm.prank(admin);
        bufferVault.pause();
        
        vm.prank(manager);
        vm.expectRevert();
        bufferVault.bridgeToHub(address(token), 1e18, "");
    }

    function testSetBridgeConfig() public {
        address mockAdapter = address(0x123);
        uint32 hubDomain = 2;
        address hubVault = makeAddr("hubVault");
        
        vm.prank(admin);
        bufferVault.setBridgeConfig(mockAdapter, hubDomain, hubVault);
        
        assertEq(bufferVault.bridgeAdapter(), mockAdapter);
        assertEq(bufferVault.hubDomain(), hubDomain);
        assertEq(bufferVault.hubVault(), hubVault);
    }

    function testSetBridgeConfigUnauthorized() public {
        vm.prank(user); // Not admin
        vm.expectRevert();
        bufferVault.setBridgeConfig(address(0x123), 2, makeAddr("hubVault"));
    }

    function testBridgeToHubAccumulation() public {
        MockBridgeAdapter adapter = new MockBridgeAdapter();
        
        vm.prank(admin);
        bufferVault.setBridgeConfig(address(adapter), 2, makeAddr("hubVault"));
        
        bytes32 bridgeRole = keccak256("BRIDGE_MANAGER_ROLE");
        vm.prank(admin);
        bufferVault.grantRole(bridgeRole, manager);
        
        // Fund with extra
        token.mint(address(bufferVault), 100e18);
        vm.prank(funder);
        bufferVault.receiveBridge(address(token));
        
        // Bridge multiple times
        vm.startPrank(manager);
        bufferVault.bridgeToHub(address(token), 20e18, "");
        assertEq(bufferVault.totalBridgedToHub(), 20e18);
        
        bufferVault.bridgeToHub(address(token), 30e18, "");
        assertEq(bufferVault.totalBridgedToHub(), 50e18);
        vm.stopPrank();
    }

    // ============ Manager Management Tests ============

    function testAddManager() public {
        address newManager = makeAddr("newManager");
        
        vm.prank(admin);
        bufferVault.addManager(newManager);
        
        // Verify manager role was granted
        bytes32 managerRole = keccak256("MANAGER_ROLE");
        assertTrue(bufferVault.hasRole(managerRole, newManager));
        assertTrue(bufferVault.isManager(newManager));
    }

    function testAddManagerZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        bufferVault.addManager(address(0));
    }

    function testAddManagerUnauthorized() public {
        address newManager = makeAddr("newManager");
        
        vm.prank(user); // Not admin
        vm.expectRevert();
        bufferVault.addManager(newManager);
    }

    function testRemoveManager() public {
        address managerToRemove = makeAddr("managerToRemove");
        
        // First add the manager
        vm.startPrank(admin);
        bufferVault.addManager(managerToRemove);
        assertTrue(bufferVault.isManager(managerToRemove));
        
        // Now remove
        bufferVault.removeManager(managerToRemove);
        assertFalse(bufferVault.isManager(managerToRemove));
        vm.stopPrank();
    }

    function testRemoveManagerUnauthorized() public {
        vm.prank(user); // Not admin
        vm.expectRevert();
        bufferVault.removeManager(manager);
    }

    function testAddMultipleManagers() public {
        address manager2 = makeAddr("manager2");
        address manager3 = makeAddr("manager3");
        
        vm.startPrank(admin);
        bufferVault.addManager(manager2);
        bufferVault.addManager(manager3);
        vm.stopPrank();
        
        assertTrue(bufferVault.isManager(manager));  // Original
        assertTrue(bufferVault.isManager(manager2));
        assertTrue(bufferVault.isManager(manager3));
    }

    function testManagerCanSpendAfterAdded() public {
        address newManager = makeAddr("newManager");
        address recipient = makeAddr("recipient");
        
        // Add manager
        vm.prank(admin);
        bufferVault.addManager(newManager);
        
        // New manager should be able to spend
        vm.prank(newManager);
        bufferVault.spendTo(address(token), recipient, 100e18);
        
        assertEq(token.balanceOf(recipient), 100e18);
    }

    function testManagerCannotSpendAfterRemoved() public {
        address recipient = makeAddr("recipient");
        
        // Remove existing manager
        vm.prank(admin);
        bufferVault.removeManager(manager);
        
        // Should not be able to spend
        vm.prank(manager);
        vm.expectRevert();
        bufferVault.spendTo(address(token), recipient, 100e18);
    }

    // ============ Initialization Edge Cases ============

    function testInitializeWithMultipleTokens() public {
        // Test that vault can handle multiple token types after init
        MockERC20 token2 = new MockERC20("TOKEN2", "TK2");
        
        // Set cap for new token
        vm.prank(admin);
        bufferVault.setCap(address(token2), 50_000e18);
        
        // Fund with new token
        token2.mint(funder, 10_000e18);
        vm.startPrank(funder);
        token2.approve(address(bufferVault), 10_000e18);
        bufferVault.fund(address(token2), 10_000e18);
        vm.stopPrank();
        
        assertEq(bufferVault.getBalance(address(token2)), 10_000e18);
    }

    function testReceiveBridgeWithZeroBalance() public {
        // Test receiveBridge when no tokens were actually minted - should revert
        address usdc = address(token);
        
        // Call receiveBridge without actually minting tokens - should revert with ZeroAmount
        vm.prank(funder);
        vm.expectRevert();
        bufferVault.receiveBridge(usdc);
    }

    function testBridgeToHubWithZeroAmount() public {
        MockBridgeAdapter adapter = new MockBridgeAdapter();
        
        vm.prank(admin);
        bufferVault.setBridgeConfig(address(adapter), 2, makeAddr("hubVault"));
        
        bytes32 bridgeRole = keccak256("BRIDGE_MANAGER_ROLE");
        vm.prank(admin);
        bufferVault.grantRole(bridgeRole, manager);
        
        uint256 balanceBefore = bufferVault.getBalance(address(token));
        
        // Try to bridge zero amount
        vm.prank(manager);
        vm.expectRevert();
        bufferVault.bridgeToHub(address(token), 0, "");
    }

    function testSetBridgeConfigMultipleTimes() public {
        MockBridgeAdapter adapter1 = new MockBridgeAdapter();
        MockBridgeAdapter adapter2 = new MockBridgeAdapter();
        
        vm.startPrank(admin);
        
        // Set initial config
        bufferVault.setBridgeConfig(address(adapter1), 2, makeAddr("hub1"));
        assertEq(bufferVault.bridgeAdapter(), address(adapter1));
        
        // Update config
        bufferVault.setBridgeConfig(address(adapter2), 3, makeAddr("hub2"));
        assertEq(bufferVault.bridgeAdapter(), address(adapter2));
        assertEq(bufferVault.hubDomain(), 3);
        
        vm.stopPrank();
    }

    function testReceiveBridgeAccountingAccuracy() public {
        // Test that receiveBridge accurately calculates received amount
        address usdc = address(token);
        
        uint256 initialBalance = bufferVault.getBalance(usdc);
        
        // Mint exact amounts and verify accounting
        token.mint(address(bufferVault), 100e18);
        vm.prank(funder);
        bufferVault.receiveBridge(usdc);
        assertEq(bufferVault.getBalance(usdc), initialBalance + 100e18);
        
        token.mint(address(bufferVault), 50e18);
        vm.prank(funder);
        bufferVault.receiveBridge(usdc);
        assertEq(bufferVault.getBalance(usdc), initialBalance + 150e18);
    }

    function testBridgeToHubWithDifferentTokens() public {
        MockBridgeAdapter adapter = new MockBridgeAdapter();
        MockERC20 token2 = new MockERC20("TOKEN2", "TK2");
        
        vm.prank(admin);
        bufferVault.setBridgeConfig(address(adapter), 2, makeAddr("hubVault"));
        
        bytes32 bridgeRole = keccak256("BRIDGE_MANAGER_ROLE");
        vm.prank(admin);
        bufferVault.grantRole(bridgeRole, manager);
        
        // Fund with second token
        vm.prank(admin);
        bufferVault.setCap(address(token2), 100_000e18);
        
        token2.mint(funder, 50_000e18);
        vm.startPrank(funder);
        token2.approve(address(bufferVault), 50_000e18);
        bufferVault.fund(address(token2), 50_000e18);
        vm.stopPrank();
        
        // Bridge with second token
        vm.prank(manager);
        bufferVault.bridgeToHub(address(token2), 10_000e18, "");
        
        assertEq(bufferVault.getBalance(address(token2)), 40_000e18);
    }
}