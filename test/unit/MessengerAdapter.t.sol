// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../../contracts/manager/MessengerAdapter.sol";
import "../../contracts/libs/Types.sol";
import "../../contracts/interfaces/IL2ToL2CrossDomainMessenger.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockBetManager {
    mapping(bytes32 => bool) public executedIntents;
    bool public shouldRevert;
    string public revertMessage;
    
    function handleBetIntent(Types.BetIntent calldata intent) external returns (bytes32 releaseId) {
        if (shouldRevert) {
            revert(revertMessage);
        }
        executedIntents[intent.intentId] = true;
        return keccak256(abi.encodePacked(intent.intentId, "release"));
    }
    
    function setRevert(bool _shouldRevert, string memory _message) external {
        shouldRevert = _shouldRevert;
        revertMessage = _message;
    }
}

contract MockSettlementAuthority {
    mapping(bytes32 => bool) public settledIntents;
    bool public shouldRevert;
    string public revertMessage;
    
    function settleFromMessenger(bytes32 intentId, uint256, uint256) external {
        if (shouldRevert) {
            revert(revertMessage);
        }
        settledIntents[intentId] = true; 
    }
    
    function setRevert(bool _shouldRevert, string memory _message) external {
        shouldRevert = _shouldRevert;
        revertMessage = _message;
    }
}

contract MockL2ToL2Messenger is IL2ToL2CrossDomainMessenger {
    struct SentMessage {
        uint256 targetChain;
        address target;
        bytes message;
    }
    
    SentMessage[] public sentMessages;
    
    function sendMessage(uint256 _destination, address _target, bytes calldata _message) external payable override returns (bytes32) {
        sentMessages.push(SentMessage({targetChain: _destination, target: _target, message: _message}));
        return keccak256(abi.encodePacked(_destination, _target, _message));
    }
    
    function crossDomainMessageSender() external pure override returns (address) { return address(0); }
    function crossDomainMessageSource() external pure override returns (uint256) { return 0; }
    function crossDomainMessageContext() external pure override returns (address, uint256) { return (address(0), 0); }
    
    function getSentMessagesCount() external view returns (uint256) { return sentMessages.length; }
}

contract MessengerAdapterTest is Test {
    MessengerAdapter public messenger;
    MockBetManager public betManager;
    MockSettlementAuthority public settlementAuthority;
    MockL2ToL2Messenger public l2Messenger;
    
    address public admin;
    address public operator;
    address public escrowRole;
    address public betManagerRole;
    address public pauseRole;
    address public protocolConfig;
    address public user;
    
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant ESCROW_ROLE = keccak256("ESCROW_ROLE");
    bytes32 public constant BET_MANAGER_ROLE = keccak256("BET_MANAGER_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    
    uint256 constant OPTIMISM = 10;
    uint256 constant ETHEREUM = 1;
    uint256 constant POLYGON = 137;
    
    function setUp() public {
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        escrowRole = makeAddr("escrowRole");
        betManagerRole = makeAddr("betManagerRole");
        pauseRole = makeAddr("pauseRole");
        protocolConfig = makeAddr("protocolConfig");
        user = makeAddr("user");
        
        betManager = new MockBetManager();
        settlementAuthority = new MockSettlementAuthority();
        l2Messenger = new MockL2ToL2Messenger();
        
        MessengerAdapter implementation = new MessengerAdapter();
        
        vm.startPrank(admin);
        bytes memory initData = abi.encodeWithSelector(MessengerAdapter.initialize.selector, protocolConfig);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        messenger = MessengerAdapter(address(proxy));
        
        messenger.grantRole(RELAYER_ROLE, operator);
        messenger.grantRole(ESCROW_ROLE, escrowRole);
        messenger.grantRole(BET_MANAGER_ROLE, betManagerRole);
        messenger.grantRole(PAUSE_ROLE, pauseRole);
        
        // Set bet managers for all chains
        messenger.setBetManager(OPTIMISM, address(betManager));
        messenger.setBetManager(ETHEREUM, address(betManager));
        messenger.setBetManager(block.chainid, address(betManager));
        
        // Set settlement authorities for all chains
        messenger.setSettlementAuthority(OPTIMISM, address(settlementAuthority));
        messenger.setSettlementAuthority(ETHEREUM, address(settlementAuthority));
        messenger.setSettlementAuthority(block.chainid, address(settlementAuthority));
        
        // Set remote adapters
        messenger.setRemoteAdapter(OPTIMISM, address(0x1234));
        messenger.setRemoteAdapter(ETHEREUM, address(0x5678));
        
        // Configure Superchain messenger and chain types
        messenger.setL2ToL2Messenger(address(l2Messenger));
        messenger.setChainType(OPTIMISM, true);
        
        vm.stopPrank();
    }
    
    // Initialization Tests
    function testInitialization() public {
        assertEq(messenger.protocolConfig(), protocolConfig);
        assertTrue(messenger.hasRole(messenger.DEFAULT_ADMIN_ROLE(), admin));
    }
    
    function testCannotInitializeWithZeroAddress() public {
        MessengerAdapter impl = new MessengerAdapter();
        bytes memory initData = abi.encodeWithSelector(MessengerAdapter.initialize.selector, address(0));
        vm.expectRevert(Types.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }
    
    // Configuration Tests
    function testSetRemoteAdapter() public {
        address newAdapter = makeAddr("newAdapter");
        vm.prank(admin);
        messenger.setRemoteAdapter(POLYGON, newAdapter);
        assertEq(messenger.remoteAdapters(POLYGON), newAdapter);
    }
    
    function testCannotSetRemoteAdapterZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Types.ZeroAddress.selector);
        messenger.setRemoteAdapter(POLYGON, address(0));
    }
    
    function testSetBetManager() public {
        address newBetManager = makeAddr("newBetManager");
        vm.prank(admin);
        messenger.setBetManager(ETHEREUM, newBetManager);
        assertEq(messenger.chainBetManagers(ETHEREUM), newBetManager);
    }
    
    function testSetSettlementAuthority() public {
        address newAuthority = makeAddr("newAuthority");
        vm.prank(admin);
        messenger.setSettlementAuthority(POLYGON, newAuthority);
        assertEq(messenger.chainSettlementAuthorities(POLYGON), newAuthority);
    }
    
    function testSetL2ToL2Messenger() public {
        address newMessenger = makeAddr("newMessenger");
        vm.prank(admin);
        messenger.setL2ToL2Messenger(newMessenger);
        assertEq(messenger.l2ToL2Messenger(), newMessenger);
    }
    
    function testSetChainType() public {
        vm.prank(admin);
        messenger.setChainType(POLYGON, true);
        assertTrue(messenger.isSuperchainId(POLYGON));
    }
    
    // Send Bet Intent Tests
    function testSendBetIntentToSuperchain() public {
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: bytes32(uint256(1)), user: user, token: address(0xdead), amount: 1000e6,
            marketId: bytes32(uint256(123)), outcomeId: 1, targetChainId: OPTIMISM,
            expiry: uint64(block.timestamp + 1 hours), state: Types.IntentState.Deposited
        });
        
        vm.prank(escrowRole);
        bytes32 messageId = messenger.sendBetIntent(intent, OPTIMISM);
        assertEq(l2Messenger.getSentMessagesCount(), 1);
        assertTrue(messageId != bytes32(0));
    }
    
    function testSendBetIntentToNonSuperchain() public {
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: bytes32(uint256(1)), user: user, token: address(0xdead), amount: 1000e6,
            marketId: bytes32(uint256(123)), outcomeId: 1, targetChainId: ETHEREUM,
            expiry: uint64(block.timestamp + 1 hours), state: Types.IntentState.Deposited
        });
        
        vm.prank(escrowRole);
        messenger.sendBetIntent(intent, ETHEREUM);
        assertEq(l2Messenger.getSentMessagesCount(), 0);
    }
    
    function testCannotSendBetIntentWithoutRole() public {
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: bytes32(uint256(1)), user: user, token: address(0xdead), amount: 1000e6,
            marketId: bytes32(uint256(123)), outcomeId: 1, targetChainId: OPTIMISM,
            expiry: uint64(block.timestamp + 1 hours), state: Types.IntentState.Deposited
        });
        
        vm.prank(user);
        vm.expectRevert();
        messenger.sendBetIntent(intent, OPTIMISM);
    }
    
    function testCannotSendBetIntentToUnsupportedChain() public {
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: bytes32(uint256(1)), user: user, token: address(0xdead), amount: 1000e6,
            marketId: bytes32(uint256(123)), outcomeId: 1, targetChainId: 999,
            expiry: uint64(block.timestamp + 1 hours), state: Types.IntentState.Deposited
        });
        
        vm.prank(escrowRole);
        vm.expectRevert(Types.ChainNotSupported.selector);
        messenger.sendBetIntent(intent, 999);
    }
    
    function testCannotSendBetIntentWhenPaused() public {
        vm.prank(pauseRole);
        messenger.pause();
        
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: bytes32(uint256(1)), user: user, token: address(0xdead), amount: 1000e6,
            marketId: bytes32(uint256(123)), outcomeId: 1, targetChainId: OPTIMISM,
            expiry: uint64(block.timestamp + 1 hours), state: Types.IntentState.Deposited
        });
        
        vm.prank(escrowRole);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        messenger.sendBetIntent(intent, OPTIMISM);
    }
    
    // Receive Bet Intent Tests
    function testReceiveBetIntent() public {
        bytes32 messageId = bytes32(uint256(12345));
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: bytes32(uint256(1)), user: user, token: address(0xdead), amount: 1000e6,
            marketId: bytes32(uint256(123)), outcomeId: 1, targetChainId: block.chainid,
            expiry: uint64(block.timestamp + 1 hours), state: Types.IntentState.Placed
        });
        
        vm.prank(admin);
        messenger.setBetManager(block.chainid, address(betManager));
        
        vm.prank(operator);
        bytes32 releaseId = messenger.receiveBetIntent(messageId, OPTIMISM, intent);
        
        assertTrue(betManager.executedIntents(intent.intentId));
        assertTrue(messenger.processedMessages(messageId));
        assertTrue(releaseId != bytes32(0));
    }
    
    function testCannotReceiveBetIntentTwice() public {
        bytes32 messageId = bytes32(uint256(12345));
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: bytes32(uint256(1)), user: user, token: address(0xdead), amount: 1000e6,
            marketId: bytes32(uint256(123)), outcomeId: 1, targetChainId: block.chainid,
            expiry: uint64(block.timestamp + 1 hours), state: Types.IntentState.Placed
        });
        
        vm.prank(admin);
        messenger.setBetManager(block.chainid, address(betManager));
        
        vm.prank(operator);
        messenger.receiveBetIntent(messageId, OPTIMISM, intent);
        
        vm.prank(operator);
        vm.expectRevert(Types.AlreadyProcessed.selector);
        messenger.receiveBetIntent(messageId, OPTIMISM, intent);
    }
    
    function testReceiveBetIntentWithFailure() public {
        bytes32 messageId = bytes32(uint256(12345));
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: bytes32(uint256(1)), user: user, token: address(0xdead), amount: 1000e6,
            marketId: bytes32(uint256(123)), outcomeId: 1, targetChainId: block.chainid,
            expiry: uint64(block.timestamp + 1 hours), state: Types.IntentState.Placed
        });
        
        vm.prank(admin);
        messenger.setBetManager(block.chainid, address(betManager));
        
        betManager.setRevert(true, "Failed");
        
        vm.prank(operator);
        vm.expectRevert(Types.MessageProcessingFailed.selector);
        messenger.receiveBetIntent(messageId, OPTIMISM, intent);
    }
    
    // Send Settlement Tests
    function testSendSettlementToSuperchain() public {
        Types.SettlementData memory settlement = Types.SettlementData({outcome: true, payout: 2000e6});
        
        vm.prank(betManagerRole);
        bytes32 messageId = messenger.sendSettlement(bytes32(uint256(1)), settlement, OPTIMISM);
        
        assertEq(l2Messenger.getSentMessagesCount(), 1);
        assertTrue(messageId != bytes32(0));
    }
    
    function testSendSettlementToNonSuperchain() public {
        Types.SettlementData memory settlement = Types.SettlementData({outcome: false, payout: 0});
        
        vm.prank(betManagerRole);
        messenger.sendSettlement(bytes32(uint256(1)), settlement, ETHEREUM);
        
        assertEq(l2Messenger.getSentMessagesCount(), 0);
    }
    
    function testCannotSendSettlementWithoutRole() public {
        Types.SettlementData memory settlement = Types.SettlementData({outcome: true, payout: 2000e6});
        
        vm.prank(user);
        vm.expectRevert();
        messenger.sendSettlement(bytes32(uint256(1)), settlement, OPTIMISM);
    }
    
    // Receive Settlement Tests
    function testReceiveSettlement() public {
        bytes32 messageId = bytes32(uint256(12345));
        Types.SettlementData memory settlement = Types.SettlementData({outcome: true, payout: 2000e6});
        
        vm.prank(operator);
        messenger.receiveSettlement(messageId, OPTIMISM, bytes32(uint256(1)), settlement);
        
        assertTrue(settlementAuthority.settledIntents(bytes32(uint256(1))));
        assertTrue(messenger.processedMessages(messageId));
    }
    
    function testCannotReceiveSettlementTwice() public {
        bytes32 messageId = bytes32(uint256(12345));
        Types.SettlementData memory settlement = Types.SettlementData({outcome: true, payout: 2000e6});
        
        vm.prank(operator);
        messenger.receiveSettlement(messageId, OPTIMISM, bytes32(uint256(1)), settlement);
        
        vm.prank(operator);
        vm.expectRevert(Types.AlreadyProcessed.selector);
        messenger.receiveSettlement(messageId, OPTIMISM, bytes32(uint256(1)), settlement);
    }
    
    // Status Update Tests
    function testSendStatusUpdate() public {
        vm.prank(betManagerRole);
        bytes32 messageId = messenger.sendStatusUpdate(bytes32(uint256(1)), Types.IntentState.Settled, ETHEREUM);
        assertTrue(messageId != bytes32(0));
    }
    
    // Pause Tests
    function testPause() public {
        vm.prank(pauseRole);
        messenger.pause();
        assertTrue(messenger.paused());
    }
    
    function testUnpause() public {
        vm.prank(pauseRole);
        messenger.pause();
        vm.prank(pauseRole);
        messenger.unpause();
        assertFalse(messenger.paused());
    }
    
    // Emergency Tests
    function testEmergencyMarkProcessed() public {
        bytes32 messageId = bytes32(uint256(12345));
        vm.prank(admin);
        messenger.emergencyMarkProcessed(messageId);
        assertTrue(messenger.processedMessages(messageId));
    }
    
    // View Function Tests
    function testGetRemoteAdapter() public {
        assertEq(messenger.getRemoteAdapter(OPTIMISM), address(0x1234));
    }
    
    function testIsChainSupported() public {
        assertTrue(messenger.isChainSupported(OPTIMISM));
        assertFalse(messenger.isChainSupported(999));
    }
    
    function testGetMessageStatus() public {
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: bytes32(uint256(1)), user: user, token: address(0xdead), amount: 1000e6,
            marketId: bytes32(uint256(123)), outcomeId: 1, targetChainId: OPTIMISM,
            expiry: uint64(block.timestamp + 1 hours), state: Types.IntentState.Deposited
        });
        
        vm.prank(escrowRole);
        bytes32 messageId = messenger.sendBetIntent(intent, OPTIMISM);
        
        Types.MessageStatus memory status = messenger.getMessageStatus(messageId);
        assertEq(status.targetChain, OPTIMISM);
    }
    
    // Upgrade Tests
    function testUpgrade() public {
        MessengerAdapter newImpl = new MessengerAdapter();
        vm.prank(admin);
        messenger.upgradeToAndCall(address(newImpl), "");
        assertEq(messenger.protocolConfig(), protocolConfig);
    }
    
    // Fuzz Tests
    function testFuzzSendBetIntent(uint256 amount, uint256 outcomeId) public {
        vm.assume(amount > 0 && amount < type(uint128).max);
        vm.assume(outcomeId < 10);
        
        Types.BetIntent memory intent = Types.BetIntent({
            intentId: keccak256(abi.encodePacked(amount, outcomeId)), user: user, token: address(0xdead),
            amount: amount, marketId: bytes32(uint256(123)), outcomeId: outcomeId, targetChainId: OPTIMISM,
            expiry: uint64(block.timestamp + 1 hours), state: Types.IntentState.Deposited
        });
        
        vm.prank(escrowRole);
        bytes32 messageId = messenger.sendBetIntent(intent, OPTIMISM);
        assertTrue(messageId != bytes32(0));
    }
}
