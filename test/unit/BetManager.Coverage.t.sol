// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../../contracts/manager/BetManager.sol";
import "../../contracts/libs/Types.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("USDC", "USDC") {
        _mint(msg.sender, 1_000_000e18);
    }
}

contract BetManagerCoverageTest is Test {
    BetManager public betManager;
    BetManager public implementation;
    MockERC20 public token;
    
    address public admin;
    address public operator = address(0x2);
    address public messenger = address(0x3);
    address public protocolConfig = address(0x4);
    address public traderSafe = address(0x5);
    address public bufferVault = address(0x6);
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant MESSENGER_ROLE = keccak256("MESSENGER_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");

    function setUp() public {
        admin = address(this); // Test contract is the admin
        token = new MockERC20();
        implementation = new BetManager();
    }

    /// @dev Test initialize with zero config address (line 67)
    function test_initialize_zero_config() public {
        Types.VenueConfig memory venueConfig = Types.VenueConfig({
            traderSafe: traderSafe,
            bufferVault: address(0),
            useBufferVault: false,
            enabled: true
        });
        
        bytes memory initData = abi.encodeCall(
            BetManager.initialize,
            (address(0), messenger, venueConfig)
        );
        
        vm.expectRevert(Types.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test initialize with zero messenger address (line 67)
    function test_initialize_zero_messenger() public {
        Types.VenueConfig memory venueConfig = Types.VenueConfig({
            traderSafe: traderSafe,
            bufferVault: address(0),
            useBufferVault: false,
            enabled: true
        });
        
        bytes memory initData = abi.encodeCall(
            BetManager.initialize,
            (protocolConfig, address(0), venueConfig)
        );
        
        vm.expectRevert(Types.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test initialize with zero traderSafe in venueConfig (lines 68, 70-73)
    function test_initialize_zero_traderSafe() public {
        Types.VenueConfig memory venueConfig = Types.VenueConfig({
            traderSafe: address(0),
            bufferVault: address(0),
            useBufferVault: false,
            enabled: true
        });
        
        bytes memory initData = abi.encodeCall(
            BetManager.initialize,
            (protocolConfig, messenger, venueConfig)
        );
        
        vm.expectRevert(Types.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test recordFill with useBufferVault=false (line 158)
    function test_recordFill_without_buffer_vault() public {
        // Setup proper initialization
        Types.VenueConfig memory venueConfig = Types.VenueConfig({
            traderSafe: traderSafe,
            bufferVault: address(0),
            useBufferVault: false,
            enabled: true
        });
        
        bytes memory initData = abi.encodeCall(
            BetManager.initialize,
            (protocolConfig, messenger, venueConfig)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        betManager = BetManager(address(proxy));
        
        betManager.grantRole(OPERATOR_ROLE, operator);
        
        // Create a bet intent first
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: keccak256("intent1"),
            user: address(0x123),
            token: address(token),
            amount: 100e6,
            marketId: bytes32(uint256(1)),
            outcomeId: 1,
            targetChainId: 1,
            expiry: uint64(block.timestamp + 1 hours),
            state: Types.IntentState.Deposited
        });
        
        vm.prank(messenger);
        bytes32 releaseId = betManager.handleBetIntent(intent);
        
        // Now record fill without buffer vault
        bytes32 venueOrderId = keccak256("order1");
        
        vm.prank(operator);
        betManager.recordFill(releaseId, address(token), 110e6, venueOrderId);
    }

    /// @dev Test pause functionality (line 258)
    function test_pause() public {
        Types.VenueConfig memory venueConfig = Types.VenueConfig({
            traderSafe: traderSafe,
            bufferVault: address(0),
            useBufferVault: false,
            enabled: true
        });
        
        bytes memory initData = abi.encodeCall(
            BetManager.initialize,
            (protocolConfig, messenger, venueConfig)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        betManager = BetManager(address(proxy));
        
        betManager.grantRole(PAUSE_ROLE, operator);
        
        vm.prank(operator);
        betManager.pause();
        
        assertTrue(betManager.paused());
    }

    /// @dev Test unpause functionality (line 262)
    function test_unpause() public {
        Types.VenueConfig memory venueConfig = Types.VenueConfig({
            traderSafe: traderSafe,
            bufferVault: address(0),
            useBufferVault: false,
            enabled: true
        });
        
        bytes memory initData = abi.encodeCall(
            BetManager.initialize,
            (protocolConfig, messenger, venueConfig)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        betManager = BetManager(address(proxy));
        
        betManager.grantRole(PAUSE_ROLE, operator);
        
        vm.prank(operator);
        betManager.pause();
        
        vm.prank(operator);
        betManager.unpause();
        
        assertFalse(betManager.paused());
    }

    /// @dev Test emergencyReclaim for reclaimed release (line 272)
    function test_emergencyReclaim_already_reclaimed() public {
        Types.VenueConfig memory venueConfig = Types.VenueConfig({
            traderSafe: traderSafe,
            bufferVault: address(0),
            useBufferVault: false,
            enabled: true
        });
        
        bytes memory initData = abi.encodeCall(
            BetManager.initialize,
            (protocolConfig, messenger, venueConfig)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        betManager = BetManager(address(proxy));
        
        betManager.grantRole(OPERATOR_ROLE, operator);
        
        // Create a bet intent
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: keccak256("intent1"),
            user: address(0x123),
            token: address(token),
            amount: 100e6,
            marketId: bytes32(uint256(1)),
            outcomeId: 1,
            targetChainId: 1,
            expiry: uint64(block.timestamp + 1 hours),
            state: Types.IntentState.Deposited
        });
        
        vm.prank(messenger);
        bytes32 releaseId = betManager.handleBetIntent(intent);
        
        // First emergency reclaim
        betManager.emergencyReclaim(releaseId);
        
        // Second emergency reclaim should revert
        vm.expectRevert(Types.AlreadyProcessed.selector);
        betManager.emergencyReclaim(releaseId);
    }

    /// @dev Test _authorizeUpgrade (line 281)
    function test_authorizeUpgrade() public {
        Types.VenueConfig memory venueConfig = Types.VenueConfig({
            traderSafe: traderSafe,
            bufferVault: address(0),
            useBufferVault: false,
            enabled: true
        });
        
        bytes memory initData = abi.encodeCall(
            BetManager.initialize,
            (protocolConfig, messenger, venueConfig)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        betManager = BetManager(address(proxy));
        
        BetManager newImplementation = new BetManager();
        
        betManager.upgradeToAndCall(address(newImplementation), "");
        
        // Verify upgrade worked
        assertEq(betManager.protocolConfig(), protocolConfig);
    }
}
