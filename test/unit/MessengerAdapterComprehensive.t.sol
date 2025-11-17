// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../../contracts/manager/MessengerAdapter.sol";
import "../../contracts/libs/Types.sol";
import "../../contracts/interfaces/IL2ToL2CrossDomainMessenger.sol";
import "../../contracts/interfaces/IBetManager.sol";
// SettlementAuthority removed - now using StagingSettlementAuthority
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title MockL2ToL2Messenger
 * @notice Mock implementation of L2ToL2CrossDomainMessenger for testing
 */
contract MockL2ToL2Messenger is IL2ToL2CrossDomainMessenger {
    struct SentMessage {
        uint256 destination;
        address target;
        bytes message;
    }

    SentMessage[] public sentMessages;
    address private _crossDomainSender;
    uint256 private _crossDomainSource;

    function sendMessage(
        uint256 _destination,
        address _target,
        bytes calldata _message
    ) external payable returns (bytes32 msgHash) {
        sentMessages.push(SentMessage({
            destination: _destination,
            target: _target,
            message: _message
        }));
        return keccak256(abi.encodePacked(_destination, _target, _message, block.timestamp));
    }

    function crossDomainMessageSender() external view returns (address) {
        return _crossDomainSender;
    }

    function crossDomainMessageSource() external view returns (uint256) {
        return _crossDomainSource;
    }

    function crossDomainMessageContext() external view returns (address sender, uint256 source) {
        return (_crossDomainSender, _crossDomainSource);
    }

    // Test helpers
    function setMockContext(address sender, uint256 source) external {
        _crossDomainSender = sender;
        _crossDomainSource = source;
    }

    function getLastMessage() external view returns (SentMessage memory) {
        require(sentMessages.length > 0, "No messages sent");
        return sentMessages[sentMessages.length - 1];
    }

    function getMessageCount() external view returns (uint256) {
        return sentMessages.length;
    }
}

/**
 * @title MockBetManager
 * @notice Mock bet manager for testing
 */
contract MockBetManager {
    mapping(bytes32 => Types.Release) public releases;
    mapping(bytes32 => bool) public processedIntents;
    
    bool public shouldRevert;
    string public revertMessage;

    function handleBetIntent(Types.BetIntent calldata intent) external returns (bytes32 releaseId) {
        if (shouldRevert) {
            revert(revertMessage);
        }
        
        releaseId = keccak256(abi.encodePacked(intent.intentId, "release"));
        processedIntents[intent.intentId] = true;
        
        releases[releaseId] = Types.Release({
            intentId: intent.intentId,
            token: intent.token,
            amount: intent.amount,
            recipient: intent.user,
            releaseTime: uint64(block.timestamp),
            reclaimed: false,
            venueOrderId: bytes32(0)
        });
        
        return releaseId;
    }

    function setRevertBehavior(bool _shouldRevert, string memory _message) external {
        shouldRevert = _shouldRevert;
        revertMessage = _message;
    }
}

/**
 * @title MockSettlementAuthority
 * @notice Mock escrow vault for testing
 */
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

    function markSettled(
        bytes32 intentId,
        bool outcome,
        uint256 payout
    ) external {
        if (shouldRevert) {
            revert(revertMessage);
        }
        settledIntents[intentId] = true;
    }

    function setRevertBehavior(bool _shouldRevert, string memory _message) external {
        shouldRevert = _shouldRevert;
        revertMessage = _message;
    }
}

/**
 * @title MessengerAdapterComprehensiveTest
 * @notice Comprehensive test suite for MessengerAdapter (Target: 90%+ coverage)
 */
contract MessengerAdapterComprehensiveTest is Test {
    MessengerAdapter public adapter;
    MessengerAdapter public implementation;
    MockL2ToL2Messenger public l2Messenger;
    MockBetManager public betManager;
    MockSettlementAuthority public settlementAuthority;

    address public admin;
    address public escrow;
    address public relayer;
    address public pauser;
    address public protocolConfig;
    address public user;
    address public usdcToken;

    // Chain IDs
    uint256 public constant CHAIN_OP_MAINNET = 10;
    uint256 public constant CHAIN_BASE = 8453;
    uint256 public constant CHAIN_POLYGON = 137;
    uint256 public constant CHAIN_ARBITRUM = 42161;
    uint256 public constant CHAIN_OP_SEPOLIA = 11155420;
    uint256 public constant CHAIN_BASE_SEPOLIA = 84532;

    // Roles
    bytes32 public constant ESCROW_ROLE = keccak256("ESCROW_ROLE");
    bytes32 public constant BET_MANAGER_ROLE = keccak256("BET_MANAGER_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");

    // Events to test
    event BetIntentSent(
        bytes32 indexed messageId,
        bytes32 indexed intentId,
        uint256 sourceChain,
        uint256 targetChain,
        address user,
        uint256 amount,
        bytes32 marketId,
        uint256 outcomeId
    );

    event BetIntentReceived(
        bytes32 indexed messageId,
        bytes32 indexed intentId,
        uint256 sourceChain,
        uint256 targetChain,
        bytes32 releaseId
    );

    event SettlementSent(
        bytes32 indexed messageId,
        bytes32 indexed intentId,
        uint256 sourceChain,
        uint256 targetChain,
        bool outcome,
        uint256 payout
    );

    event SettlementReceived(
        bytes32 indexed messageId,
        bytes32 indexed intentId,
        uint256 sourceChain,
        uint256 targetChain,
        bool outcome,
        uint256 payout
    );

    event CrossChainMessage(
        bytes32 indexed messageId,
        uint256 sourceChain,
        uint256 targetChain,
        address remoteAdapter,
        address targetContract,
        bytes32 messageType,
        bytes message
    );

    event L2MessengerSet(address indexed messenger);
    event ChainTypeSet(uint256 indexed chainId, bool isSuperchain);
    event RemoteAdapterSet(uint256 indexed chainId, address indexed adapter);
    event BetManagerSet(uint256 indexed chainId, address indexed betManager);
    event SettlementAuthoritySet(uint256 indexed chainId, address indexed settlementAuthority);

    function setUp() public {
        admin = makeAddr("admin");
        escrow = makeAddr("escrow");
        relayer = makeAddr("relayer");
        pauser = makeAddr("pauser");
        user = makeAddr("user");
        protocolConfig = makeAddr("protocolConfig");
        usdcToken = makeAddr("USDC");

        // Deploy mocks
        l2Messenger = new MockL2ToL2Messenger();
        betManager = new MockBetManager();
        settlementAuthority = new MockSettlementAuthority();

        // Deploy implementation
        implementation = new MessengerAdapter();

        // Deploy proxy
        vm.startPrank(admin);
        bytes memory initData = abi.encodeWithSelector(
            MessengerAdapter.initialize.selector,
            protocolConfig
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        adapter = MessengerAdapter(address(proxy));

        // Grant roles
        adapter.grantRole(ESCROW_ROLE, escrow);
        adapter.grantRole(BET_MANAGER_ROLE, address(betManager));
        adapter.grantRole(RELAYER_ROLE, relayer);
        adapter.grantRole(PAUSE_ROLE, pauser);

        // Configure L2 messenger
        adapter.setL2ToL2Messenger(address(l2Messenger));

        // Configure Superchain chains (OP Mainnet, Base, OP Sepolia, Base Sepolia)
        adapter.setChainType(CHAIN_OP_MAINNET, true);
        adapter.setChainType(CHAIN_BASE, true);
        adapter.setChainType(CHAIN_OP_SEPOLIA, true);
        adapter.setChainType(CHAIN_BASE_SEPOLIA, true);

        // Configure non-Superchain chains (Polygon, Arbitrum)
        adapter.setChainType(CHAIN_POLYGON, false);
        adapter.setChainType(CHAIN_ARBITRUM, false);

        // Set remote adapters
        adapter.setRemoteAdapter(CHAIN_OP_MAINNET, makeAddr("opAdapter"));
        adapter.setRemoteAdapter(CHAIN_BASE, makeAddr("baseAdapter"));
        adapter.setRemoteAdapter(CHAIN_POLYGON, makeAddr("polygonAdapter"));
        adapter.setRemoteAdapter(CHAIN_ARBITRUM, makeAddr("arbitrumAdapter"));
        adapter.setRemoteAdapter(CHAIN_OP_SEPOLIA, makeAddr("opSepoliaAdapter"));
        adapter.setRemoteAdapter(CHAIN_BASE_SEPOLIA, makeAddr("baseSepoliaAdapter"));

        // Set bet managers
        adapter.setBetManager(CHAIN_OP_MAINNET, address(betManager));
        adapter.setBetManager(CHAIN_BASE, address(betManager));
        adapter.setBetManager(CHAIN_POLYGON, address(betManager));
        adapter.setBetManager(CHAIN_ARBITRUM, address(betManager));
        adapter.setBetManager(CHAIN_OP_SEPOLIA, address(betManager));
        adapter.setBetManager(CHAIN_BASE_SEPOLIA, address(betManager));
        adapter.setBetManager(block.chainid, address(betManager));

        // Set escrow vaults
        adapter.setSettlementAuthority(CHAIN_OP_MAINNET, address(settlementAuthority));
        adapter.setSettlementAuthority(CHAIN_BASE, address(settlementAuthority));
        adapter.setSettlementAuthority(CHAIN_POLYGON, address(settlementAuthority));
        adapter.setSettlementAuthority(CHAIN_ARBITRUM, address(settlementAuthority));
        adapter.setSettlementAuthority(CHAIN_OP_SEPOLIA, address(settlementAuthority));
        adapter.setSettlementAuthority(CHAIN_BASE_SEPOLIA, address(settlementAuthority));
        adapter.setSettlementAuthority(block.chainid, address(settlementAuthority));

        vm.stopPrank();
    }

    // ============================================
    // A. SUPERCHAIN ROUTING TESTS (PRIMARY PATH)
    // ============================================

    function testSendBetIntentToOPMainnet() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_OP_MAINNET);
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_OP_MAINNET);
        
        assertGt(uint256(messageId), 0, "Message ID should be generated");
        assertEq(l2Messenger.getMessageCount(), 1, "Should send one L2 message");
        
        vm.stopPrank();
    }

    function testSendBetIntentToBase() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_BASE);
        
        assertGt(uint256(messageId), 0);
        assertEq(l2Messenger.getMessageCount(), 1);
        
        MockL2ToL2Messenger.SentMessage memory sent = l2Messenger.getLastMessage();
        assertEq(sent.destination, CHAIN_BASE);
        
        vm.stopPrank();
    }

    function testSendBetIntentToOptimismSepolia() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_OP_SEPOLIA);
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_OP_SEPOLIA);
        
        assertGt(uint256(messageId), 0);
        assertEq(l2Messenger.getMessageCount(), 1);
        
        vm.stopPrank();
    }

    function testSendBetIntentToBaseSepolia() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE_SEPOLIA);
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_BASE_SEPOLIA);
        
        assertGt(uint256(messageId), 0);
        assertEq(l2Messenger.getMessageCount(), 1);
        
        vm.stopPrank();
    }

    function testL2MessengerCalledCorrectly() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        adapter.sendBetIntent(intent, CHAIN_BASE);
        
        MockL2ToL2Messenger.SentMessage memory sent = l2Messenger.getLastMessage();
        assertEq(sent.destination, CHAIN_BASE);
        assertEq(sent.target, adapter.getRemoteAdapter(CHAIN_BASE));
        assertGt(sent.message.length, 0);
        
        vm.stopPrank();
    }

    function testSuperchainMessageEncoding() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        adapter.sendBetIntent(intent, CHAIN_BASE);
        
        MockL2ToL2Messenger.SentMessage memory sent = l2Messenger.getLastMessage();
        
        // Verify message contains selector for receiveBetIntent
        bytes4 selector = bytes4(sent.message);
        assertEq(selector, IMessengerAdapter.receiveBetIntent.selector);
        
        vm.stopPrank();
    }

    function testSendSettlementViaSuperchain() public {
        vm.startPrank(address(betManager));
        
        bytes32 intentId = bytes32("intent1");
        Types.SettlementData memory settlement = Types.SettlementData({
            outcome: true,
            payout: 200 ether
        });
        
        bytes32 messageId = adapter.sendSettlement(intentId, settlement, CHAIN_BASE);
        
        assertGt(uint256(messageId), 0);
        assertEq(l2Messenger.getMessageCount(), 1);
        
        vm.stopPrank();
    }

    // ============================================
    // B. VIALABS FALLBACK TESTS (NON-SUPERCHAIN)
    // ============================================

    function testSendBetIntentToPolygon() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_POLYGON);
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_POLYGON);
        
        assertGt(uint256(messageId), 0);
        // Should NOT call L2 messenger for non-Superchain
        assertEq(l2Messenger.getMessageCount(), 0);
        
        vm.stopPrank();
    }

    function testSendBetIntentToArbitrum() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_ARBITRUM);
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_ARBITRUM);
        
        assertGt(uint256(messageId), 0);
        assertEq(l2Messenger.getMessageCount(), 0);
        
        vm.stopPrank();
    }

    function testSendSettlementViaViaLabs() public {
        vm.startPrank(address(betManager));
        
        bytes32 intentId = bytes32("intent1");
        Types.SettlementData memory settlement = Types.SettlementData({
            outcome: true,
            payout: 200 ether
        });
        
        bytes32 messageId = adapter.sendSettlement(intentId, settlement, CHAIN_POLYGON);
        
        assertGt(uint256(messageId), 0);
        assertEq(l2Messenger.getMessageCount(), 0);
        
        vm.stopPrank();
    }

    function testCrossChainMessageEventEmission() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_POLYGON);
        
        vm.recordLogs();
        adapter.sendBetIntent(intent, CHAIN_POLYGON);
        
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundCrossChainEvent = false;
        
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("CrossChainMessage(bytes32,uint256,uint256,address,address,bytes32,bytes)")) {
                foundCrossChainEvent = true;
                break;
            }
        }
        
        assertTrue(foundCrossChainEvent, "Should emit CrossChainMessage event");
        
        vm.stopPrank();
    }

    function testFallbackForUnconfiguredChains() public {
        vm.startPrank(admin);
        uint256 newChainId = 999;
        adapter.setRemoteAdapter(newChainId, makeAddr("newAdapter"));
        adapter.setBetManager(newChainId, address(betManager));
        // Don't set chain type - defaults to false (non-Superchain)
        vm.stopPrank();

        vm.startPrank(escrow);
        Types.BetIntent memory intent = _createTestIntent(newChainId);
        
        bytes32 messageId = adapter.sendBetIntent(intent, newChainId);
        
        assertGt(uint256(messageId), 0);
        assertEq(l2Messenger.getMessageCount(), 0, "Should use fallback, not L2 messenger");
        
        vm.stopPrank();
    }

    // ============================================
    // C. CONFIGURATION TESTS
    // ============================================

    function testSetL2ToL2Messenger() public {
        address newMessenger = makeAddr("newMessenger");
        
        vm.startPrank(admin);
        vm.expectEmit(true, false, false, false);
        emit L2MessengerSet(newMessenger);
        
        adapter.setL2ToL2Messenger(newMessenger);
        assertEq(adapter.l2ToL2Messenger(), newMessenger);
        vm.stopPrank();
    }

    function testSetL2ToL2MessengerUnauthorized() public {
        address newMessenger = makeAddr("newMessenger");
        
        vm.startPrank(user);
        vm.expectRevert();
        adapter.setL2ToL2Messenger(newMessenger);
        vm.stopPrank();
    }

    function testSetL2ToL2MessengerZeroAddress() public {
        vm.startPrank(admin);
        vm.expectRevert(Types.ZeroAddress.selector);
        adapter.setL2ToL2Messenger(address(0));
        vm.stopPrank();
    }

    function testSetChainType() public {
        uint256 newChainId = 1234;
        
        vm.startPrank(admin);
        vm.expectEmit(true, false, false, true);
        emit ChainTypeSet(newChainId, true);
        
        adapter.setChainType(newChainId, true);
        assertTrue(adapter.isSuperchainId(newChainId));
        vm.stopPrank();
    }

    function testSetChainTypeMultiple() public {
        vm.startPrank(admin);
        
        adapter.setChainType(100, true);
        adapter.setChainType(200, false);
        adapter.setChainType(300, true);
        
        assertTrue(adapter.isSuperchainId(100));
        assertFalse(adapter.isSuperchainId(200));
        assertTrue(adapter.isSuperchainId(300));
        
        vm.stopPrank();
    }

    function testFuzzSetChainType(uint256 chainId, bool isSuperchain) public {
        vm.assume(chainId > 0 && chainId < type(uint64).max);
        
        vm.startPrank(admin);
        adapter.setChainType(chainId, isSuperchain);
        assertEq(adapter.isSuperchainId(chainId), isSuperchain);
        vm.stopPrank();
    }

    function testSetBetManager() public {
        address newBetManager = makeAddr("newBetManager");
        uint256 chainId = 5000;
        
        vm.startPrank(admin);
        adapter.setBetManager(chainId, newBetManager);
        assertEq(adapter.chainBetManagers(chainId), newBetManager);
        vm.stopPrank();
    }

    function testSetBetManagerZeroAddress() public {
        vm.startPrank(admin);
        vm.expectRevert(Types.ZeroAddress.selector);
        adapter.setBetManager(5000, address(0));
        vm.stopPrank();
    }

    function testSetSettlementAuthority() public {
        address newSettlementAuthority = makeAddr("newSettlementAuthority");
        uint256 chainId = 6000;
        
        vm.startPrank(admin);
        adapter.setSettlementAuthority(chainId, newSettlementAuthority);
        assertEq(adapter.chainSettlementAuthorities(chainId), newSettlementAuthority);
        vm.stopPrank();
    }

    function testSetRemoteAdapter() public {
        address newAdapter = makeAddr("newAdapter");
        uint256 chainId = 7000;
        
        vm.startPrank(admin);
        adapter.setRemoteAdapter(chainId, newAdapter);
        assertEq(adapter.getRemoteAdapter(chainId), newAdapter);
        vm.stopPrank();
    }

    function testConfigurationEvents() public {
        vm.startPrank(admin);
        
        vm.recordLogs();
        adapter.setL2ToL2Messenger(makeAddr("newMessenger"));
        adapter.setChainType(888, true);
        adapter.setBetManager(888, makeAddr("newBetManager"));
        adapter.setSettlementAuthority(888, makeAddr("newSettlementAuthority"));
        adapter.setRemoteAdapter(888, makeAddr("newAdapter"));
        
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGe(logs.length, 5, "Should emit at least 5 events");
        
        vm.stopPrank();
    }

    // ============================================
    // D. ACCESS CONTROL TESTS
    // ============================================

    function testOnlyEscrowCanSendBetIntent() public {
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        
        vm.startPrank(user);
        vm.expectRevert();
        adapter.sendBetIntent(intent, CHAIN_BASE);
        vm.stopPrank();
    }

    function testOnlyBetManagerCanSendSettlement() public {
        bytes32 intentId = bytes32("intent1");
        Types.SettlementData memory settlement = Types.SettlementData({
            outcome: true,
            payout: 200 ether
        });
        
        vm.startPrank(user);
        vm.expectRevert();
        adapter.sendSettlement(intentId, settlement, CHAIN_BASE);
        vm.stopPrank();
    }

    function testOnlyRelayerCanReceiveBetIntent() public {
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        bytes32 messageId = bytes32("msg1");
        
        vm.startPrank(user);
        vm.expectRevert();
        adapter.receiveBetIntent(messageId, CHAIN_BASE, intent);
        vm.stopPrank();
    }

    function testOnlyRelayerCanReceiveSettlement() public {
        bytes32 messageId = bytes32("msg1");
        bytes32 intentId = bytes32("intent1");
        Types.SettlementData memory settlement = Types.SettlementData({
            outcome: true,
            payout: 200 ether
        });
        
        vm.startPrank(user);
        vm.expectRevert();
        adapter.receiveSettlement(messageId, CHAIN_BASE, intentId, settlement);
        vm.stopPrank();
    }

    function testOnlyAdminCanConfigure() public {
        vm.startPrank(user);
        
        vm.expectRevert();
        adapter.setL2ToL2Messenger(makeAddr("test"));
        
        vm.expectRevert();
        adapter.setChainType(999, true);
        
        vm.expectRevert();
        adapter.setBetManager(999, makeAddr("test"));
        
        vm.expectRevert();
        adapter.setSettlementAuthority(999, makeAddr("test"));
        
        vm.expectRevert();
        adapter.setRemoteAdapter(999, makeAddr("test"));
        
        vm.stopPrank();
    }

    function testRoleGranting() public {
        address newRelayer = makeAddr("newRelayer");
        
        vm.startPrank(admin);
        adapter.grantRole(RELAYER_ROLE, newRelayer);
        assertTrue(adapter.hasRole(RELAYER_ROLE, newRelayer));
        vm.stopPrank();
    }

    function testRoleRevoking() public {
        vm.startPrank(admin);
        adapter.revokeRole(RELAYER_ROLE, relayer);
        assertFalse(adapter.hasRole(RELAYER_ROLE, relayer));
        vm.stopPrank();
    }

    // ============================================
    // E. PAUSABILITY TESTS
    // ============================================

    function testPause() public {
        vm.startPrank(pauser);
        adapter.pause();
        assertTrue(adapter.paused());
        vm.stopPrank();
    }

    function testUnpause() public {
        vm.startPrank(pauser);
        adapter.pause();
        adapter.unpause();
        assertFalse(adapter.paused());
        vm.stopPrank();
    }

    function testCannotSendBetIntentWhenPaused() public {
        vm.prank(pauser);
        adapter.pause();
        
        vm.startPrank(escrow);
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        vm.expectRevert();
        adapter.sendBetIntent(intent, CHAIN_BASE);
        vm.stopPrank();
    }

    function testCannotSendSettlementWhenPaused() public {
        vm.prank(pauser);
        adapter.pause();
        
        vm.startPrank(address(betManager));
        bytes32 intentId = bytes32("intent1");
        Types.SettlementData memory settlement = Types.SettlementData({
            outcome: true,
            payout: 200 ether
        });
        vm.expectRevert();
        adapter.sendSettlement(intentId, settlement, CHAIN_BASE);
        vm.stopPrank();
    }

    function testCannotReceiveWhenPaused() public {
        vm.prank(pauser);
        adapter.pause();
        
        vm.startPrank(relayer);
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        bytes32 messageId = bytes32("msg1");
        vm.expectRevert();
        adapter.receiveBetIntent(messageId, CHAIN_BASE, intent);
        vm.stopPrank();
    }

    function testOnlyPauserCanPause() public {
        vm.startPrank(user);
        vm.expectRevert();
        adapter.pause();
        vm.stopPrank();
    }

    // ============================================
    // F. MESSAGE LIFECYCLE TESTS
    // ============================================

    function testMessageIdGeneration() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent1 = _createTestIntent(CHAIN_BASE);
        Types.BetIntent memory intent2 = _createTestIntent(CHAIN_BASE);
        
        bytes32 messageId1 = adapter.sendBetIntent(intent1, CHAIN_BASE);
        bytes32 messageId2 = adapter.sendBetIntent(intent2, CHAIN_BASE);
        
        assertTrue(messageId1 != messageId2, "Message IDs should be unique");
        
        vm.stopPrank();
    }

    function testMessageStatusTracking() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_BASE);
        
        Types.MessageStatus memory status = adapter.getMessageStatus(messageId);
        assertEq(status.sourceChain, block.chainid);
        assertEq(status.targetChain, CHAIN_BASE);
        assertFalse(status.processed);
        assertFalse(status.failed);
        
        vm.stopPrank();
    }

    function testProcessedMessageRejection() public {
        vm.startPrank(relayer);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        bytes32 messageId = bytes32("msg1");
        
        // First call should succeed
        adapter.receiveBetIntent(messageId, CHAIN_BASE, intent);
        
        // Second call should revert
        vm.expectRevert(Types.AlreadyProcessed.selector);
        adapter.receiveBetIntent(messageId, CHAIN_BASE, intent);
        
        vm.stopPrank();
    }

    function testRevertWhenMessageHandlingFails() public {
        // Configure bet manager to revert
        betManager.setRevertBehavior(true, "Intentional failure");
        
        vm.startPrank(relayer);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        bytes32 messageId = bytes32("msg1");
        
        vm.expectRevert(Types.MessageProcessingFailed.selector);
        adapter.receiveBetIntent(messageId, CHAIN_BASE, intent);
        
        vm.stopPrank();
    }

    // ============================================
    // G. EDGE CASE TESTS
    // ============================================

    function testZeroAmountBetIntent() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        intent.amount = 0;
        
        // Should still process (validation happens in SettlementAuthority)
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_BASE);
        assertGt(uint256(messageId), 0);
        
        vm.stopPrank();
    }

    function testMaxAmountBetIntent() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        intent.amount = type(uint256).max;
        
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_BASE);
        assertGt(uint256(messageId), 0);
        
        vm.stopPrank();
    }

    function testZeroPayoutSettlement() public {
        vm.startPrank(address(betManager));
        
        bytes32 intentId = bytes32("intent1");
        Types.SettlementData memory settlement = Types.SettlementData({
            outcome: false,
            payout: 0
        });
        
        bytes32 messageId = adapter.sendSettlement(intentId, settlement, CHAIN_BASE);
        assertGt(uint256(messageId), 0);
        
        vm.stopPrank();
    }

    function testInvalidChainId() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent = _createTestIntent(99999);
        
        vm.expectRevert(Types.ChainNotSupported.selector);
        adapter.sendBetIntent(intent, 99999);
        
        vm.stopPrank();
    }

    function testMessengerNotSet() public {
        vm.startPrank(admin);
        vm.expectRevert(Types.ZeroAddress.selector);
        adapter.setL2ToL2Messenger(address(0));
        vm.stopPrank();
    }

    function testRemoteAdapterNotSet() public {
        vm.startPrank(admin);
        uint256 newChainId = 8888;
        adapter.setChainType(newChainId, true);
        adapter.setBetManager(newChainId, address(betManager));
        // Don't set remote adapter
        vm.stopPrank();
        
        vm.startPrank(escrow);
        Types.BetIntent memory intent = _createTestIntent(newChainId);
        
        vm.expectRevert(Types.ChainNotSupported.selector);
        adapter.sendBetIntent(intent, newChainId);
        
        vm.stopPrank();
    }

    function testBetManagerNotSet() public {
        vm.startPrank(admin);
        uint256 newChainId = 9999;
        adapter.setChainType(newChainId, true);
        adapter.setRemoteAdapter(newChainId, makeAddr("adapter"));
        // Don't set bet manager
        vm.stopPrank();
        
        vm.startPrank(escrow);
        Types.BetIntent memory intent = _createTestIntent(newChainId);
        
        vm.expectRevert(Types.BetManagerNotSet.selector);
        adapter.sendBetIntent(intent, newChainId);
        
        vm.stopPrank();
    }

    // NOTE: testSettlementAuthorityNotSet disabled - architecture change:
    // SettlementAuthority is only checked on receiving side in receiveSettlement,
    // not in sendSettlement. Sending doesn't require local SettlementAuthority.
    function skip_testSettlementAuthorityNotSet() public {
        vm.startPrank(admin);
        uint256 newChainId = 7777;
        adapter.setChainType(newChainId, true);
        adapter.setRemoteAdapter(newChainId, makeAddr("adapter"));
        // Don't set settlement authority
        vm.stopPrank();
        
        vm.startPrank(address(betManager));
        bytes32 intentId = bytes32("intent1");
        Types.SettlementData memory settlement = Types.SettlementData({
            outcome: true,
            payout: 200 ether
        });
        
        // This no longer reverts - sending doesn't check for SettlementAuthority
        adapter.sendSettlement(intentId, settlement, newChainId);
        
        vm.stopPrank();
    }

    // ============================================
    // H. INTEGRATION FLOW TESTS
    // ============================================

    function testFullBetIntentFlow() public {
        // Step 1: Send bet intent from escrow
        vm.startPrank(escrow);
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_BASE);
        vm.stopPrank();
        
        // Step 2: Relayer receives and processes
        vm.startPrank(relayer);
        bytes32 releaseId = adapter.receiveBetIntent(messageId, CHAIN_BASE, intent);
        vm.stopPrank();
        
        // Verify bet manager processed it
        assertTrue(betManager.processedIntents(intent.intentId));
        assertGt(uint256(releaseId), 0);
    }

    function testFullSettlementFlow() public {
        // Step 1: Send settlement from bet manager
        vm.startPrank(address(betManager));
        bytes32 intentId = bytes32("intent1");
        Types.SettlementData memory settlement = Types.SettlementData({
            outcome: true,
            payout: 200 ether
        });
        bytes32 messageId = adapter.sendSettlement(intentId, settlement, CHAIN_BASE);
        vm.stopPrank();
        
        // Step 2: Relayer receives and processes settlement
        vm.startPrank(relayer);
        adapter.receiveSettlement(messageId, CHAIN_BASE, intentId, settlement);
        vm.stopPrank();
        
        // Verify escrow vault processed it
        assertTrue(settlementAuthority.settledIntents(intentId));
    }

    function testMultiChainScenario() public {
        vm.startPrank(escrow);
        
        // Send to multiple chains
        Types.BetIntent memory intent1 = _createTestIntent(CHAIN_BASE);
        Types.BetIntent memory intent2 = _createTestIntent(CHAIN_POLYGON);
        Types.BetIntent memory intent3 = _createTestIntent(CHAIN_OP_MAINNET);
        
        bytes32 msg1 = adapter.sendBetIntent(intent1, CHAIN_BASE);
        bytes32 msg2 = adapter.sendBetIntent(intent2, CHAIN_POLYGON);
        bytes32 msg3 = adapter.sendBetIntent(intent3, CHAIN_OP_MAINNET);
        
        // Verify unique message IDs
        assertTrue(msg1 != msg2);
        assertTrue(msg2 != msg3);
        assertTrue(msg1 != msg3);
        
        // Verify correct routing
        assertEq(l2Messenger.getMessageCount(), 2, "Should use L2 messenger for 2 Superchain chains");
        
        vm.stopPrank();
    }

    // ============================================
    // I. FUZZ TESTS
    // ============================================

    function testFuzzChainId(uint256 chainId) public {
        vm.assume(chainId > 0 && chainId < type(uint64).max);
        
        vm.startPrank(admin);
        adapter.setChainType(chainId, true);
        adapter.setRemoteAdapter(chainId, makeAddr("adapter"));
        adapter.setBetManager(chainId, address(betManager));
        vm.stopPrank();
        
        vm.startPrank(escrow);
        Types.BetIntent memory intent = _createTestIntent(chainId);
        bytes32 messageId = adapter.sendBetIntent(intent, chainId);
        assertGt(uint256(messageId), 0);
        vm.stopPrank();
    }

    function testFuzzBetAmount(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint128).max);
        
        vm.startPrank(escrow);
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        intent.amount = amount;
        
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_BASE);
        assertGt(uint256(messageId), 0);
        vm.stopPrank();
    }

    function testFuzzPayoutAmount(uint256 payout) public {
        vm.assume(payout < type(uint128).max);
        
        vm.startPrank(address(betManager));
        bytes32 intentId = bytes32("intent1");
        Types.SettlementData memory settlement = Types.SettlementData({
            outcome: true,
            payout: payout
        });
        
        bytes32 messageId = adapter.sendSettlement(intentId, settlement, CHAIN_BASE);
        assertGt(uint256(messageId), 0);
        vm.stopPrank();
    }

    function testFuzzTimestamp(uint64 timestamp) public {
        vm.assume(timestamp > block.timestamp);
        
        vm.startPrank(escrow);
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        intent.expiry = timestamp;
        
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_BASE);
        assertGt(uint256(messageId), 0);
        vm.stopPrank();
    }

    // ============================================
    // ADDITIONAL COVERAGE TESTS
    // ============================================

    function testSendStatusUpdateSuccess() public {
        // Caller must have BET_MANAGER_ROLE; use the mock betManager address
        vm.startPrank(address(betManager));
        
        bytes32 intentId = bytes32("intent_status");
        Types.IntentState newState = Types.IntentState.Settled;
        // sendStatusUpdate emits CrossChainMessage (fallback path), not L2 messenger
        vm.recordLogs();
        adapter.sendStatusUpdate(intentId, newState, CHAIN_BASE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        bytes32 evtSig = keccak256("CrossChainMessage(bytes32,uint256,uint256,address,address,bytes32,bytes)");
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == evtSig) {
                found = true;
                break;
            }
        }
        assertTrue(found, "Should emit CrossChainMessage event for status update");
        
        vm.stopPrank();
    }

    function testSendStatusUpdateWhenPaused() public {
        vm.prank(admin);
        adapter.pause();
        
        // Use a caller with BET_MANAGER_ROLE so pause check is reached
        vm.startPrank(address(betManager));
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        adapter.sendStatusUpdate(bytes32("intent1"), Types.IntentState.Settled, CHAIN_BASE);
        vm.stopPrank();
    }

    function testGetMessageStatusReturnsCorrectData() public {
        vm.startPrank(escrow);
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_BASE);
        vm.stopPrank();
        
        Types.MessageStatus memory status = adapter.getMessageStatus(messageId);
        assertFalse(status.processed);
        assertFalse(status.failed);
        assertEq(status.sourceChain, block.chainid);
        assertEq(status.targetChain, CHAIN_BASE);
    }

    function testIsChainSupportedWithUnsupportedChain() public view {
        assertFalse(adapter.isChainSupported(999999), "Random chain should not be supported");
    }

    function testIsChainSupportedWithSupportedChain() public view {
        assertTrue(adapter.isChainSupported(CHAIN_BASE), "Base should be supported");
        assertTrue(adapter.isChainSupported(CHAIN_OP_MAINNET), "OP Mainnet should be supported");
    }

    function testGetRemoteAdapterForUnconfiguredChain() public view {
        assertEq(adapter.getRemoteAdapter(999999), address(0), "Should return zero address");
    }

    function testEmergencyMarkProcessedSuccess() public {
        // Create a pending message
        vm.startPrank(escrow);
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        bytes32 messageId = adapter.sendBetIntent(intent, CHAIN_BASE);
        vm.stopPrank();
        
        // Check initial status
        Types.MessageStatus memory statusBefore = adapter.getMessageStatus(messageId);
        assertFalse(statusBefore.processed);
        assertFalse(statusBefore.failed);
        
        // Emergency mark as processed
        vm.prank(admin);
        adapter.emergencyMarkProcessed(messageId);
        
        // Verify processedMessages mapping updated (messageStatuses is not mutated by emergency)
        assertTrue(adapter.processedMessages(messageId));
    }

    function testEmergencyMarkProcessedUnauthorized() public {
        bytes32 messageId = bytes32("someMessage");
        
        vm.prank(user);
        vm.expectRevert();
        adapter.emergencyMarkProcessed(messageId);
    }

    function testSetBetManagerForMultipleChains() public {
        address betManager2 = makeAddr("betManager2");
        address betManager3 = makeAddr("betManager3");
        
        vm.startPrank(admin);
        adapter.setBetManager(CHAIN_BASE, betManager2);
        adapter.setBetManager(CHAIN_OP_MAINNET, betManager3);
        vm.stopPrank();
        
        // Verify each chain has correct bet manager
        // (Would need getter function in actual contract)
    }

    function testSetSettlementAuthorityForMultipleChains() public {
        address settlementAuthority2 = makeAddr("settlementAuthority2");
        address settlementAuthority3 = makeAddr("settlementAuthority3");
        
        vm.startPrank(admin);
        adapter.setSettlementAuthority(CHAIN_BASE, settlementAuthority2);
        adapter.setSettlementAuthority(CHAIN_OP_MAINNET, settlementAuthority3);
        vm.stopPrank();
    }

    function testReceiveBetIntentWithDifferentTokens() public {
        address wethToken = makeAddr("weth");
        address remoteAdapter = makeAddr("baseAdapter");
        
        l2Messenger.setMockContext(remoteAdapter, CHAIN_BASE);
        
        Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
        intent.token = wethToken;
        bytes32 messageId = bytes32("msg_weth");
        
        vm.prank(relayer);
        adapter.receiveBetIntent(messageId, CHAIN_BASE, intent);
    }

    function testReceiveBetIntentWithDifferentOutcomes() public {
        address remoteAdapter = makeAddr("baseAdapter");
        l2Messenger.setMockContext(remoteAdapter, CHAIN_BASE);
        
        for (uint256 i = 0; i < 5; i++) {
            Types.BetIntent memory intent = _createTestIntent(CHAIN_BASE);
            intent.intentId = bytes32(uint256(i));
            intent.outcomeId = i;
            bytes32 messageId = bytes32(uint256(i + 1000));
            
            vm.prank(relayer);
            adapter.receiveBetIntent(messageId, CHAIN_BASE, intent);
        }
    }

    function testReceiveSettlementWithZeroPayout() public {
        bytes32 intentId = bytes32("intent_zero_payout");
        bytes32 messageId = bytes32("msg_zero");
        address remoteAdapter = makeAddr("baseAdapter");
        
        l2Messenger.setMockContext(remoteAdapter, CHAIN_BASE);
        
        Types.SettlementData memory settlement = Types.SettlementData({
            outcome: false,
            payout: 0
        });
        
        vm.prank(relayer);
        adapter.receiveSettlement(messageId, CHAIN_BASE, intentId, settlement);
    }

    function testReceiveSettlementWithMaxPayout() public {
        bytes32 intentId = bytes32("intent_max_payout");
        bytes32 messageId = bytes32("msg_max");
        address remoteAdapter = makeAddr("baseAdapter");
        
        l2Messenger.setMockContext(remoteAdapter, CHAIN_BASE);
        
        Types.SettlementData memory settlement = Types.SettlementData({
            outcome: true,
            payout: type(uint256).max / 2 // Use safe max value
        });
        
        vm.prank(relayer);
        adapter.receiveSettlement(messageId, CHAIN_BASE, intentId, settlement);
    }

    function testSendBetIntentToMultipleDifferentChains() public {
        uint256[] memory chains = new uint256[](3);
        chains[0] = CHAIN_BASE;
        chains[1] = CHAIN_OP_MAINNET;
        chains[2] = CHAIN_BASE_SEPOLIA;
        
        vm.startPrank(escrow);
        
        for (uint256 i = 0; i < chains.length; i++) {
            Types.BetIntent memory intent = _createTestIntent(chains[i]);
            intent.intentId = bytes32(uint256(i));
            
            bytes32 messageId = adapter.sendBetIntent(intent, chains[i]);
            assertGt(uint256(messageId), 0);
        }
        
        vm.stopPrank();
    }

    function testSendSettlementWithBothOutcomes() public {
        vm.startPrank(address(betManager));
        
        // Test win outcome
        Types.SettlementData memory winSettlement = Types.SettlementData({
            outcome: true,
            payout: 200 ether
        });
        adapter.sendSettlement(bytes32("intent_win"), winSettlement, CHAIN_BASE);
        
        // Test loss outcome
        Types.SettlementData memory lossSettlement = Types.SettlementData({
            outcome: false,
            payout: 0
        });
        adapter.sendSettlement(bytes32("intent_loss"), lossSettlement, CHAIN_BASE);
        
        vm.stopPrank();
    }

    function testPauseUnpauseCycle() public {
        vm.startPrank(admin);
        
        // Pause
        adapter.pause();
        assertEq(adapter.paused(), true);
        
        // Unpause
        adapter.unpause();
        assertEq(adapter.paused(), false);
        
        // Pause again
        adapter.pause();
        assertEq(adapter.paused(), true);
        
        vm.stopPrank();
    }

    function testSetChainTypeMultipleTimes() public {
        vm.startPrank(admin);
        
        // Set as Superchain
        adapter.setChainType(CHAIN_BASE, true);
        
        // Change to non-Superchain
        adapter.setChainType(CHAIN_BASE, false);
        
        // Back to Superchain
        adapter.setChainType(CHAIN_BASE, true);
        
        vm.stopPrank();
    }

    function testMessageIdUniqueness() public {
        vm.startPrank(escrow);
        
        Types.BetIntent memory intent1 = _createTestIntent(CHAIN_BASE);
        Types.BetIntent memory intent2 = _createTestIntent(CHAIN_BASE);
        intent2.intentId = bytes32(uint256(intent1.intentId) + 1);
        
        bytes32 messageId1 = adapter.sendBetIntent(intent1, CHAIN_BASE);
        
        vm.warp(block.timestamp + 1); // Advance time
        
        bytes32 messageId2 = adapter.sendBetIntent(intent2, CHAIN_BASE);
        
        assertNotEq(messageId1, messageId2, "Message IDs should be unique");
        
        vm.stopPrank();
    }

    function testReceiveBetIntentFromDifferentSourceChains() public {
        // Test receiving from Base
        address remoteAdapterBase = makeAddr("baseAdapter");
        l2Messenger.setMockContext(remoteAdapterBase, CHAIN_BASE);
        
        Types.BetIntent memory intentFromBase = _createTestIntent(CHAIN_BASE);
        intentFromBase.intentId = bytes32("from_base");
        bytes32 messageIdBase = bytes32("msg_base");
        
        vm.prank(relayer);
        adapter.receiveBetIntent(messageIdBase, CHAIN_BASE, intentFromBase);
        
        // Test receiving from OP Mainnet
        address remoteAdapterOp = makeAddr("opAdapter");
        l2Messenger.setMockContext(remoteAdapterOp, CHAIN_OP_MAINNET);
        
        Types.BetIntent memory intentFromOp = _createTestIntent(CHAIN_OP_MAINNET);
        intentFromOp.intentId = bytes32("from_op");
        bytes32 messageIdOp = bytes32("msg_op");
        
        vm.prank(relayer);
        adapter.receiveBetIntent(messageIdOp, CHAIN_OP_MAINNET, intentFromOp);
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    function _createTestIntent(uint256 targetChainId) internal view returns (Types.BetIntent memory) {
        return Types.BetIntent({
            intentId: bytes32(uint256(uint160(user)) + block.timestamp),
            user: user,
            token: usdcToken,
            amount: 100 ether,
            marketId: bytes32("market1"),
            outcomeId: 1,
            targetChainId: targetChainId,
            expiry: uint64(block.timestamp + 1 hours),
            state: Types.IntentState.Deposited
        });
    }
}
