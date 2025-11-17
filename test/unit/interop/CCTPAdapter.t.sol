// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../../../contracts/interop/CCTPAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock USDC token
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1000000 * 10**6); // 1M USDC
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock Circle TokenMessenger
contract MockTokenMessenger {
    uint64 public nextNonce = 1;
    
    event DepositForBurn(
        uint64 indexed nonce,
        address indexed burnToken,
        uint256 amount,
        address indexed depositor,
        bytes32 mintRecipient,
        uint32 destinationDomain,
        bytes32 destinationTokenMessenger,
        bytes32 destinationCaller
    );

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce) {
        nonce = nextNonce++;
        
        // Transfer tokens from caller
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        
        emit DepositForBurn(
            nonce,
            burnToken,
            amount,
            msg.sender,
            mintRecipient,
            destinationDomain,
            bytes32(0),
            bytes32(0)
        );
        
        return nonce;
    }
}

// Mock Circle MessageTransmitter
contract MockMessageTransmitter {
    mapping(bytes32 => bool) public processedMessages;
    
    event MessageReceived(
        address indexed caller,
        uint32 sourceDomain,
        uint64 nonce,
        bytes32 sender,
        bytes messageBody
    );

    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool) {
        bytes32 messageHash = keccak256(message);
        require(!processedMessages[messageHash], "Message already processed");
        require(attestation.length > 0, "Invalid attestation");
        
        processedMessages[messageHash] = true;
        
        emit MessageReceived(
            msg.sender,
            1, // source domain
            1, // nonce
            bytes32(0), // sender
            message
        );
        
        return true;
    }
}

contract CCTPAdapterTest is Test {
    CCTPAdapter public adapter;
    MockUSDC public usdc;
    MockTokenMessenger public tokenMessenger;
    MockMessageTransmitter public messageTransmitter;
    
    address public user = address(0x1);
    address public recipient = address(0x2);
    uint32 public constant LOCAL_DOMAIN = 0; // Ethereum
    uint32 public constant DEST_DOMAIN = 1; // Optimism
    
    event CCTPBridgeInitiated(
        bytes32 indexed messageId,
        uint64 indexed nonce,
        uint256 amount,
        uint32 destinationDomain,
        address recipient
    );
    
    event CCTPBridgeReceived(
        bytes32 indexed messageId,
        uint256 amount,
        address recipient
    );

    function setUp() public {
        usdc = new MockUSDC();
        tokenMessenger = new MockTokenMessenger();
        messageTransmitter = new MockMessageTransmitter();
        
        adapter = new CCTPAdapter(
            address(tokenMessenger),
            address(messageTransmitter),
            address(usdc),
            LOCAL_DOMAIN
        );
        
        // Setup user with USDC
        usdc.transfer(user, 100000 * 10**6);
    }

    function test_constructor() public {
        assertEq(address(adapter.tokenMessenger()), address(tokenMessenger));
        assertEq(address(adapter.messageTransmitter()), address(messageTransmitter));
        assertEq(address(adapter.usdc()), address(usdc));
        assertEq(adapter.localDomain(), LOCAL_DOMAIN);
    }

    function test_bridgeUSDC_success() public {
        uint256 amount = 1000 * 10**6; // 1000 USDC
        
        vm.startPrank(user);
        usdc.approve(address(adapter), amount);
        
        vm.expectEmit(false, true, false, false);
        emit CCTPBridgeInitiated(bytes32(0), 1, amount, DEST_DOMAIN, recipient);
        
        bytes32 messageId = adapter.bridgeUSDC(amount, DEST_DOMAIN, recipient, "");
        vm.stopPrank();
        
        assertTrue(messageId != bytes32(0));
        assertEq(usdc.balanceOf(user), 99000 * 10**6);
    }

    function test_bridgeUSDC_zero_amount_reverts() public {
        vm.startPrank(user);
        usdc.approve(address(adapter), 1000 * 10**6);
        
        vm.expectRevert(CCTPAdapter.InvalidAmount.selector);
        adapter.bridgeUSDC(0, DEST_DOMAIN, recipient, "");
        vm.stopPrank();
    }

    function test_bridgeUSDC_zero_recipient_reverts() public {
        uint256 amount = 1000 * 10**6;
        
        vm.startPrank(user);
        usdc.approve(address(adapter), amount);
        
        vm.expectRevert(CCTPAdapter.InvalidRecipient.selector);
        adapter.bridgeUSDC(amount, DEST_DOMAIN, address(0), "");
        vm.stopPrank();
    }

    function test_bridgeUSDC_same_domain_reverts() public {
        uint256 amount = 1000 * 10**6;
        
        vm.startPrank(user);
        usdc.approve(address(adapter), amount);
        
        vm.expectRevert(CCTPAdapter.InvalidDomain.selector);
        adapter.bridgeUSDC(amount, LOCAL_DOMAIN, recipient, "");
        vm.stopPrank();
    }

    function test_bridgeUSDC_insufficient_allowance_reverts() public {
        uint256 amount = 1000 * 10**6;
        
        vm.startPrank(user);
        usdc.approve(address(adapter), amount / 2); // Only approve half
        
        vm.expectRevert();
        adapter.bridgeUSDC(amount, DEST_DOMAIN, recipient, "");
        vm.stopPrank();
    }

    function test_bridgeUSDC_multiple_times() public {
        uint256 amount = 1000 * 10**6;
        
        vm.startPrank(user);
        usdc.approve(address(adapter), amount * 3);
        
        bytes32 messageId1 = adapter.bridgeUSDC(amount, DEST_DOMAIN, recipient, "");
        bytes32 messageId2 = adapter.bridgeUSDC(amount, DEST_DOMAIN, recipient, "");
        bytes32 messageId3 = adapter.bridgeUSDC(amount, DEST_DOMAIN, recipient, "");
        
        vm.stopPrank();
        
        // All message IDs should be different
        assertTrue(messageId1 != messageId2);
        assertTrue(messageId2 != messageId3);
        assertTrue(messageId1 != messageId3);
        
        assertEq(usdc.balanceOf(user), 97000 * 10**6);
    }

    function test_bridgeUSDC_large_amount() public {
        uint256 largeAmount = 50000 * 10**6; // 50k USDC
        
        vm.startPrank(user);
        usdc.approve(address(adapter), largeAmount);
        
        bytes32 messageId = adapter.bridgeUSDC(largeAmount, DEST_DOMAIN, recipient, "");
        vm.stopPrank();
        
        assertTrue(messageId != bytes32(0));
        assertEq(usdc.balanceOf(user), 50000 * 10**6);
    }

    function test_estimateBridgeFee_always_zero() public {
        uint256 fee = adapter.estimateBridgeFee(1000 * 10**6, DEST_DOMAIN, "");
        assertEq(fee, 0);
        
        // Test with different amounts
        fee = adapter.estimateBridgeFee(1, DEST_DOMAIN, "");
        assertEq(fee, 0);
        
        fee = adapter.estimateBridgeFee(type(uint256).max, DEST_DOMAIN, "");
        assertEq(fee, 0);
    }

    function test_receiveMessage_success() public {
        bytes memory message = abi.encode("test message");
        bytes memory attestation = abi.encode("test attestation");
        
        vm.expectEmit(true, false, false, false);
        emit CCTPBridgeReceived(keccak256(message), 0, address(0));
        
        adapter.receiveMessage(message, attestation);
    }

    function test_receiveMessage_anyone_can_call() public {
        bytes memory message = abi.encode("test message");
        bytes memory attestation = abi.encode("test attestation");
        
        // Call from different addresses
        vm.prank(user);
        adapter.receiveMessage(message, attestation);
        
        vm.prank(recipient);
        bytes memory message2 = abi.encode("test message 2");
        adapter.receiveMessage(message2, attestation);
    }

    function test_receiveMessage_empty_attestation_reverts() public {
        bytes memory message = abi.encode("test message");
        bytes memory emptyAttestation = "";
        
        vm.expectRevert();
        adapter.receiveMessage(message, emptyAttestation);
    }

    function test_receiveMessage_duplicate_message_reverts() public {
        bytes memory message = abi.encode("test message");
        bytes memory attestation = abi.encode("test attestation");
        
        adapter.receiveMessage(message, attestation);
        
        // Try to process same message again
        vm.expectRevert();
        adapter.receiveMessage(message, attestation);
    }

    function test_bridgeUSDC_to_different_domains() public {
        uint256 amount = 1000 * 10**6;
        
        vm.startPrank(user);
        usdc.approve(address(adapter), amount * 3);
        
        bytes32 messageId1 = adapter.bridgeUSDC(amount, 1, recipient, ""); // Optimism
        bytes32 messageId2 = adapter.bridgeUSDC(amount, 2, recipient, ""); // Arbitrum
        bytes32 messageId3 = adapter.bridgeUSDC(amount, 3, recipient, ""); // Base
        
        vm.stopPrank();
        
        assertTrue(messageId1 != bytes32(0));
        assertTrue(messageId2 != bytes32(0));
        assertTrue(messageId3 != bytes32(0));
    }

    function test_bridgeUSDC_different_recipients() public {
        uint256 amount = 1000 * 10**6;
        address recipient2 = address(0x3);
        address recipient3 = address(0x4);
        
        vm.startPrank(user);
        usdc.approve(address(adapter), amount * 3);
        
        bytes32 messageId1 = adapter.bridgeUSDC(amount, DEST_DOMAIN, recipient, "");
        bytes32 messageId2 = adapter.bridgeUSDC(amount, DEST_DOMAIN, recipient2, "");
        bytes32 messageId3 = adapter.bridgeUSDC(amount, DEST_DOMAIN, recipient3, "");
        
        vm.stopPrank();
        
        // All should succeed with different recipients
        assertTrue(messageId1 != bytes32(0));
        assertTrue(messageId2 != bytes32(0));
        assertTrue(messageId3 != bytes32(0));
    }

    function test_messageId_uniqueness() public {
        uint256 amount = 1000 * 10**6;
        
        vm.startPrank(user);
        usdc.approve(address(adapter), amount * 5);
        
        bytes32[] memory messageIds = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            messageIds[i] = adapter.bridgeUSDC(amount, DEST_DOMAIN, recipient, "");
        }
        
        vm.stopPrank();
        
        // Verify all message IDs are unique
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = i + 1; j < 5; j++) {
                assertTrue(messageIds[i] != messageIds[j], "Duplicate message ID");
            }
        }
    }

    function test_full_bridge_flow() public {
        // 1. Bridge tokens
        uint256 amount = 5000 * 10**6;
        
        vm.startPrank(user);
        usdc.approve(address(adapter), amount);
        bytes32 messageId = adapter.bridgeUSDC(amount, DEST_DOMAIN, recipient, "");
        vm.stopPrank();
        
        assertTrue(messageId != bytes32(0));
        assertEq(usdc.balanceOf(user), 95000 * 10**6);
        
        // 2. Simulate receiving on destination
        bytes memory message = abi.encodePacked(messageId);
        bytes memory attestation = abi.encode("valid attestation");
        
        adapter.receiveMessage(message, attestation);
    }
}
