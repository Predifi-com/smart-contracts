// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../contracts/manager/BetManager.sol";
import "../../contracts/interfaces/IBetManager.sol";
import "../../contracts/libs/Types.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockBufferVault {
    mapping(address => uint256) public balances;
    
    function spendTo(
        address token,
        address recipient,
        uint256 amount
    ) external {
        balances[token] += amount;
    }
    
    function receiveProceeds(
        address token,
        uint256 amount
    ) external {
        balances[token] += amount;
    }
    
    function getBalance(address token) external view returns (uint256) {
        return balances[token];
    }
}

contract BetManagerTest is Test {
    BetManager public betManager;
    BetManager public implementation;
    MockERC20 public token;
    MockBufferVault public bufferVault;
    
    address public admin;
    address public operator;
    address public messengerAdapter;
    address public user;
    address public protocolConfig;
    address public traderSafe;
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant MESSENGER_ROLE = keccak256("MESSENGER_ROLE");
    
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
    
    event ReleaseReclaimed(bytes32 indexed releaseId, uint256 amount);

    function setUp() public {
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        messengerAdapter = makeAddr("messengerAdapter");
        user = makeAddr("user");
        protocolConfig = makeAddr("protocolConfig");
        traderSafe = makeAddr("traderSafe");
        
        token = new MockERC20("USDC", "USDC");
        bufferVault = new MockBufferVault();
        
        // Deploy implementation
        implementation = new BetManager();
        
        // Create initial venue config
        Types.VenueConfig memory venueConfig = Types.VenueConfig({
            traderSafe: traderSafe,
            bufferVault: address(bufferVault),
            useBufferVault: true,
            enabled: true
        });
        
        // Deploy proxy with admin as deployer
        vm.startPrank(admin);
        bytes memory initData = abi.encodeWithSelector(
            BetManager.initialize.selector,
            protocolConfig,
            messengerAdapter,
            venueConfig
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        betManager = BetManager(address(proxy));
        
        // Setup additional roles
        betManager.grantRole(OPERATOR_ROLE, operator);
        
        vm.stopPrank();
        
        // Mint tokens to buffer vault for settlements
        token.mint(address(bufferVault), 1_000_000e18);
    }

    function testInitialization() public {
        assertEq(betManager.protocolConfig(), protocolConfig);
        assertTrue(betManager.hasRole(betManager.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(betManager.hasRole(OPERATOR_ROLE, operator));
        assertTrue(betManager.hasRole(MESSENGER_ROLE, messengerAdapter));
        
        Types.VenueConfig memory config = betManager.getVenueConfig();
        assertEq(config.traderSafe, traderSafe);
        assertEq(config.bufferVault, address(bufferVault));
        assertTrue(config.useBufferVault);
        assertTrue(config.enabled);
    }

    function testHandleBetIntent() public {
        bytes32 intentId = keccak256("intent1");
        bytes32 marketId = keccak256("test_market");
        uint256 amount = 100e18;
        uint256 outcomeId = 1;
        uint64 expiry = uint64(block.timestamp + 1 hours);
        
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: intentId,
            user: user,
            token: address(token),
            amount: amount,
            marketId: marketId,
            outcomeId: outcomeId,
            targetChainId: block.chainid,
            expiry: expiry,
            state: Types.IntentState.Deposited
        });
        
        vm.prank(messengerAdapter);
        vm.expectEmit(true, false, true, false);
        emit BetPlaced(intentId, bytes32(0), user, amount, marketId, outcomeId);
        
        bytes32 releaseId = betManager.handleBetIntent(intent);
        
        assertNotEq(releaseId, bytes32(0));
        
        // Check release was created
        Types.Release memory release = betManager.getRelease(releaseId);
        assertEq(release.intentId, intentId);
        assertEq(release.token, address(token));
        assertEq(release.amount, amount);
        assertEq(release.recipient, traderSafe);
        assertFalse(release.reclaimed);
    }

    function testRecordFill() public {
        // First handle a bet intent
        bytes32 intentId = keccak256("intent1");
        bytes32 marketId = keccak256("test_market");
        uint256 amount = 100e18;
        
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: intentId,
            user: user,
            token: address(token),
            amount: amount,
            marketId: marketId,
            outcomeId: 1,
            targetChainId: block.chainid,
            expiry: uint64(block.timestamp + 1 hours),
            state: Types.IntentState.Deposited
        });
        
        vm.prank(messengerAdapter);
        bytes32 releaseId = betManager.handleBetIntent(intent);
        
        // Now record fill
        uint256 proceedsAmount = 150e18;
        bytes32 venueOrderId = keccak256("order1");
        
        vm.prank(operator);
        vm.expectEmit(true, true, false, false);
        emit FillRecorded(releaseId, address(token), proceedsAmount, venueOrderId);
        
        betManager.recordFill(releaseId, address(token), proceedsAmount, venueOrderId);
        
        // Check release was updated
        Types.Release memory release = betManager.getRelease(releaseId);
        assertEq(release.venueOrderId, venueOrderId);
    }

    function testReclaimUnused() public {
        bytes32 intentId = keccak256("intent1");
        
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: intentId,
            user: user,
            token: address(token),
            amount: 100e18,
            marketId: keccak256("test_market"),
            outcomeId: 1,
            targetChainId: block.chainid,
            expiry: uint64(block.timestamp + 1 hours),
            state: Types.IntentState.Deposited
        });
        
        vm.prank(messengerAdapter);
        bytes32 releaseId = betManager.handleBetIntent(intent);
        
        // Advance time to allow reclaim
        vm.warp(block.timestamp + 25 hours);
        
        vm.prank(user); // Anyone can reclaim after timeout
        vm.expectEmit(true, false, false, true);
        emit ReleaseReclaimed(releaseId, 100e18);
        
        uint256 reclaimed = betManager.reclaimUnused(releaseId);
        assertEq(reclaimed, 100e18);
        
        Types.Release memory release = betManager.getRelease(releaseId);
        assertTrue(release.reclaimed);
    }

    function testRevertUnauthorizedHandleBetIntent() public {
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: keccak256("intent1"),
            user: user,
            token: address(token),
            amount: 100e18,
            marketId: keccak256("test_market"),
            outcomeId: 1,
            targetChainId: block.chainid,
            expiry: uint64(block.timestamp + 1 hours),
            state: Types.IntentState.Deposited
        });
        
        vm.prank(user);
        vm.expectRevert();
        betManager.handleBetIntent(intent);
    }

    function testRevertExpiredIntent() public {
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: keccak256("intent1"),
            user: user,
            token: address(token),
            amount: 100e18,
            marketId: keccak256("test_market"),
            outcomeId: 1,
            targetChainId: block.chainid,
            expiry: uint64(block.timestamp - 1), // Expired
            state: Types.IntentState.Deposited
        });
        
        vm.prank(messengerAdapter);
        vm.expectRevert(Types.Expired.selector);
        betManager.handleBetIntent(intent);
    }

    function testRevertAlreadyProcessed() public {
        bytes32 intentId = keccak256("intent1");
        
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: intentId,
            user: user,
            token: address(token),
            amount: 100e18,
            marketId: keccak256("test_market"),
            outcomeId: 1,
            targetChainId: block.chainid,
            expiry: uint64(block.timestamp + 1 hours),
            state: Types.IntentState.Deposited
        });
        
        vm.startPrank(messengerAdapter);
        
        // Handle intent first time
        betManager.handleBetIntent(intent);
        
        // Try to handle same intent again
        vm.expectRevert(Types.AlreadyProcessed.selector);
        betManager.handleBetIntent(intent);
        
        vm.stopPrank();
    }

    function testRevertRecordFillInvalidRelease() public {
        bytes32 invalidReleaseId = keccak256("invalid");
        
        vm.prank(operator);
        vm.expectRevert(Types.NotReleased.selector);
        betManager.recordFill(invalidReleaseId, address(token), 100e18, keccak256("order1"));
    }

    function testRevertReclaimAlreadyReclaimed() public {
        bytes32 intentId = keccak256("intent1");
        
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: intentId,
            user: user,
            token: address(token),
            amount: 100e18,
            marketId: keccak256("test_market"),
            outcomeId: 1,
            targetChainId: block.chainid,
            expiry: uint64(block.timestamp + 1 hours),
            state: Types.IntentState.Deposited
        });
        
        vm.prank(messengerAdapter);
        bytes32 releaseId = betManager.handleBetIntent(intent);
        
        // Reclaim first time
        vm.prank(operator);
        betManager.reclaimUnused(releaseId);
        
        // Try to reclaim again
        vm.prank(operator);
        vm.expectRevert(Types.AlreadyProcessed.selector);
        betManager.reclaimUnused(releaseId);
    }

    function testPauseUnpause() public {
        vm.prank(admin);
        betManager.pause();
        assertTrue(betManager.paused());
        
        // Should revert when paused
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: keccak256("intent1"),
            user: user,
            token: address(token),
            amount: 100e18,
            marketId: keccak256("test_market"),
            outcomeId: 1,
            targetChainId: block.chainid,
            expiry: uint64(block.timestamp + 1 hours),
            state: Types.IntentState.Deposited
        });
        
    vm.prank(messengerAdapter);
    vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
    betManager.handleBetIntent(intent);
        
        vm.prank(admin);
        betManager.unpause();
        assertFalse(betManager.paused());
    }

    function testSetBufferVault() public {
        address newBufferVault = address(new MockBufferVault());
        
        vm.prank(admin);
        betManager.setBufferVault(newBufferVault);
        
        Types.VenueConfig memory config = betManager.getVenueConfig();
        assertEq(config.bufferVault, newBufferVault);
        assertTrue(config.useBufferVault);
    }

    function testSetTraderSafe() public {
        address newTraderSafe = makeAddr("newTraderSafe");
        
        vm.prank(admin);
        betManager.setTraderSafe(newTraderSafe);
        
        Types.VenueConfig memory config = betManager.getVenueConfig();
        assertEq(config.traderSafe, newTraderSafe);
    }

    function testRevertSetZeroAddressTraderSafe() public {
        vm.prank(admin);
        vm.expectRevert(Types.ZeroAddress.selector);
        betManager.setTraderSafe(address(0));
    }

    function testSetVenueConfig() public {
        Types.VenueConfig memory newConfig = Types.VenueConfig({
            traderSafe: makeAddr("newTraderSafe"),
            bufferVault: makeAddr("newBufferVault"),
            useBufferVault: false,
            enabled: true
        });
        
        vm.prank(admin);
        betManager.setVenueConfig(newConfig);
        
        Types.VenueConfig memory retrievedConfig = betManager.getVenueConfig();
        assertEq(retrievedConfig.traderSafe, newConfig.traderSafe);
        assertEq(retrievedConfig.bufferVault, newConfig.bufferVault);
        assertEq(retrievedConfig.useBufferVault, newConfig.useBufferVault);
        assertEq(retrievedConfig.enabled, newConfig.enabled);
    }

    function testSweep() public {
        // Send some tokens to the contract
        token.transfer(address(betManager), 100e18);
        
        vm.prank(operator);
        uint256 swept = betManager.sweep(address(token));
        
        assertEq(swept, 100e18);
        assertEq(token.balanceOf(traderSafe), 100e18);
    }

    function testIsReleaseActive() public {
        bytes32 intentId = keccak256("intent1");
        
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: intentId,
            user: user,
            token: address(token),
            amount: 100e18,
            marketId: keccak256("test_market"),
            outcomeId: 1,
            targetChainId: block.chainid,
            expiry: uint64(block.timestamp + 1 hours),
            state: Types.IntentState.Deposited
        });
        
        vm.prank(messengerAdapter);
        bytes32 releaseId = betManager.handleBetIntent(intent);
        
        assertTrue(betManager.isReleaseActive(releaseId));
        
        // After reclaim, should not be active
        vm.prank(operator);
        betManager.reclaimUnused(releaseId);
        
        assertFalse(betManager.isReleaseActive(releaseId));
    }

    function testEmergencyReclaim() public {
        bytes32 intentId = keccak256("intent1");
        
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: intentId,
            user: user,
            token: address(token),
            amount: 100e18,
            marketId: keccak256("test_market"),
            outcomeId: 1,
            targetChainId: block.chainid,
            expiry: uint64(block.timestamp + 1 hours),
            state: Types.IntentState.Deposited
        });
        
        vm.prank(messengerAdapter);
        bytes32 releaseId = betManager.handleBetIntent(intent);
        
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ReleaseReclaimed(releaseId, 100e18);
        
        betManager.emergencyReclaim(releaseId);
        
        Types.Release memory release = betManager.getRelease(releaseId);
        assertTrue(release.reclaimed);
    }
}