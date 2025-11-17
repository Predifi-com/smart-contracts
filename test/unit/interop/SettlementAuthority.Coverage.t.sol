// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SettlementAuthority} from "contracts/interop/SettlementAuthority.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 ether);
    }
}

// Comprehensive mock that supports all vault operations
contract ComprehensiveMockVault {
    mapping(address => mapping(address => uint256)) public availBalances;
    mapping(address => mapping(address => uint256)) public resvBalances;
    mapping(address => mapping(bytes32 => uint256)) public orderReserved;
    
    bool public shouldRevert;
    bytes public revertReason;
    
    event Reserve(address user, bytes32 orderId, address asset, uint256 amount, uint256 feeCap);
    event Release(address user, address asset, bytes32 orderId, uint256 amount);
    event SettleDebit(address user, address asset, bytes32 orderId, uint256 amount, address to);
    event ReleaseForOrder(bytes32 orderId, uint256 amountDelta, uint256 feeDelta);
    
    function setAvailBalance(address user, address token, uint256 amount) external {
        availBalances[user][token] = amount;
    }
    
    function setReservedBalance(address user, bytes32 orderId, uint256 amount) external {
        orderReserved[user][orderId] = amount;
    }
    
    function setShouldRevert(bool _revert, bytes memory _reason) external {
        shouldRevert = _revert;
        revertReason = _reason;
    }
    
    function balances(address user, address token) external view returns (uint256 avail, uint256 resv) {
        return (availBalances[user][token], resvBalances[user][token]);
    }
    
    function getOrderReserved(address user, bytes32 orderId) external view returns (uint256) {
        return orderReserved[user][orderId];
    }
    
    function reserve(
        address user,
        bytes32 orderId,
        address asset,
        uint256 amount,
        uint256 feeCap,
        address /* lpRecipient */,
        address /* feeRecipient */,
        uint64 /* expiry */
    ) external {
        if (shouldRevert) {
            bytes memory reason = revertReason;
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        emit Reserve(user, orderId, asset, amount, feeCap);
        availBalances[user][asset] -= (amount + feeCap);
        resvBalances[user][asset] += (amount + feeCap);
        orderReserved[user][orderId] += (amount + feeCap);
    }
    
    function release(address user, address asset, bytes32 orderId, uint256 amount) external {
        if (shouldRevert) {
            bytes memory reason = revertReason;
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        emit Release(user, asset, orderId, amount);
        if (orderReserved[user][orderId] >= amount) {
            orderReserved[user][orderId] -= amount;
        }
        if (resvBalances[user][asset] >= amount) {
            resvBalances[user][asset] -= amount;
        }
        availBalances[user][asset] += amount;
    }
    
    function settleDebit(address user, address asset, bytes32 orderId, uint256 amount, address to) external {
        if (shouldRevert) {
            bytes memory reason = revertReason;
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        emit SettleDebit(user, asset, orderId, amount, to);
        if (orderReserved[user][orderId] >= amount) {
            orderReserved[user][orderId] -= amount;
        }
        if (resvBalances[user][asset] >= amount) {
            resvBalances[user][asset] -= amount;
        }
    }
    
    function releaseForOrder(bytes32 orderId, uint256 amountDelta, uint256 feeDelta) external {
        emit ReleaseForOrder(orderId, amountDelta, feeDelta);
    }
}

contract SettlementAuthorityCoverageTest is Test {
    SettlementAuthority impl;
    SettlementAuthority auth;
    ComprehensiveMockVault vault;
    MockERC20 token;
    
    address admin = address(0xA11CE);
    address matcher = address(0xBA7C4);
    address messenger = address(0xBABA);
    address user = address(0xBEEF);
    uint256 userPk = 0x1234;
    address lpRecipient = address(0x111);
    address feeRecipient = address(0x222);
    address settleTo = address(0x333);
    
    function setUp() public {
        token = new MockERC20("Test", "TEST", 18);
        vault = new ComprehensiveMockVault();
        
        impl = new SettlementAuthority();
        bytes memory initData = abi.encodeWithSelector(SettlementAuthority.initialize.selector, admin, address(vault));
        auth = SettlementAuthority(address(new ERC1967Proxy(address(impl), initData)));
        
        vm.startPrank(admin);
        auth.grantRole(auth.MESSENGER_ROLE(), messenger);
        auth.grantRole(auth.MATCHER_ROLE(), matcher);
        vm.stopPrank();
        
        // Setup user with proper key
        (user, userPk) = makeAddrAndKey("testUser");
        
        // Fund vault for user
        vault.setAvailBalance(user, address(token), 10000 ether);
    }
    
    // Test reserveFromIntent ordered happy path
    function test_reserveFromIntent_success() public {
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            amount: 100 ether,
            feeCap: 5 ether,
            lpRecipient: lpRecipient,
            feeRecipient: feeRecipient,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 0
        });
        
        bytes memory signature = _signIntent(userPk, intent);
        
        vm.expectEmit(true, true, true, true);
        emit SettlementAuthority.IntentConsumed(
            _getIntentDigest(intent),
            user,
            intent.orderId,
            0,
            100 ether,
            5 ether
        );
        
        vm.prank(matcher);
        auth.reserveFromIntent(intent, signature);
        
        assertEq(auth.getUserNonce(user), 1);
    }
    
    // Test expired intent reverts
    function test_reserveFromIntent_expired_reverts() public {
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            amount: 100 ether,
            feeCap: 5 ether,
            lpRecipient: lpRecipient,
            feeRecipient: feeRecipient,
            expiry: uint64(block.timestamp - 1), // Expired
            nonce: 0
        });
        
        bytes memory signature = _signIntent(userPk, intent);
        
        vm.expectRevert("Expired");
        vm.prank(matcher);
        auth.reserveFromIntent(intent, signature);
    }
    
    // Test bad nonce reverts
    function test_reserveFromIntent_bad_nonce_reverts() public {
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            amount: 100 ether,
            feeCap: 5 ether,
            lpRecipient: lpRecipient,
            feeRecipient: feeRecipient,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 5 // Wrong nonce, should be 0
        });
        
        bytes memory signature = _signIntent(userPk, intent);
        
        vm.expectRevert("BadNonce");
        vm.prank(matcher);
        auth.reserveFromIntent(intent, signature);
    }
    
    // Test bad signature reverts
    function test_reserveFromIntent_bad_signature_reverts() public {
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            amount: 100 ether,
            feeCap: 5 ether,
            lpRecipient: lpRecipient,
            feeRecipient: feeRecipient,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 0
        });
        
        // Sign with wrong key
        (, uint256 wrongPk) = makeAddrAndKey("wrongUser");
        bytes memory signature = _signIntent(wrongPk, intent);
        
        vm.expectRevert("BadSig");
        vm.prank(matcher);
        auth.reserveFromIntent(intent, signature);
    }
    
    // Test insufficient available balance reverts
    function test_reserveFromIntent_insufficient_avail_reverts() public {
        vault.setAvailBalance(user, address(token), 50 ether); // Not enough
        
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            amount: 100 ether,
            feeCap: 5 ether,
            lpRecipient: lpRecipient,
            feeRecipient: feeRecipient,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 0
        });
        
        bytes memory signature = _signIntent(userPk, intent);
        
        vm.expectRevert("InsufficientAvailFeeCap");
        vm.prank(matcher);
        auth.reserveFromIntent(intent, signature);
    }
    
    // Test vault reserve failure emits IntentFailed
    function test_reserveFromIntent_vault_failure_emits_failed() public {
        vault.setShouldRevert(true, abi.encodeWithSignature("Error(string)", "VaultError"));
        
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            amount: 100 ether,
            feeCap: 5 ether,
            lpRecipient: lpRecipient,
            feeRecipient: feeRecipient,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 0
        });
        
        bytes memory signature = _signIntent(userPk, intent);
        
        bytes32 digest = _getIntentDigest(intent);
        
        vm.expectEmit(true, true, true, false);
        emit SettlementAuthority.IntentFailedSummary(user, intent.orderId, digest, bytes4(0), bytes32(0));
        
        vm.expectRevert();
        vm.prank(matcher);
        auth.reserveFromIntent(intent, signature);
        
        // Nonce should NOT be incremented
        assertEq(auth.getUserNonce(user), 0);
    }
    
    // Test reserveFromIntentUnordered success
    function test_reserveFromIntentUnordered_success() public {
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            amount: 100 ether,
            feeCap: 5 ether,
            lpRecipient: lpRecipient,
            feeRecipient: feeRecipient,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 999 // Unordered, can be any nonce
        });
        
        bytes memory signature = _signIntent(userPk, intent);
        bytes32 digest = _getIntentDigest(intent);
        
        vm.prank(matcher);
        auth.reserveFromIntentUnordered(intent, signature);
        
        assertTrue(auth.isDigestConsumed(user, digest));
    }
    
    // Test unordered replay protection
    function test_reserveFromIntentUnordered_replay_reverts() public {
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            amount: 100 ether,
            feeCap: 5 ether,
            lpRecipient: lpRecipient,
            feeRecipient: feeRecipient,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 999
        });
        
        bytes memory signature = _signIntent(userPk, intent);
        
        vm.prank(matcher);
        auth.reserveFromIntentUnordered(intent, signature);
        
        vm.expectRevert(bytes("Used"));
        vm.prank(matcher);
        auth.reserveFromIntentUnordered(intent, signature);
    }
    
    // Test cancelFromIntent success
    function test_cancelFromIntent_success() public {
        // First reserve
        vault.setReservedBalance(user, keccak256("order1"), 100 ether);
        
        SettlementAuthority.CancelIntent memory cancelIntent = SettlementAuthority.CancelIntent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 1
        });
        
        bytes memory signature = _signCancelIntent(userPk, cancelIntent);
        
        vm.prank(matcher);
        auth.cancelFromIntent(cancelIntent, signature);
    }
    
    // Test cancel with no remaining reservation reverts
    function test_cancelFromIntent_finalized_reverts() public {
        vault.setReservedBalance(user, keccak256("order1"), 0); // Nothing reserved
        
        SettlementAuthority.CancelIntent memory cancelIntent = SettlementAuthority.CancelIntent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 1
        });
        
        bytes memory signature = _signCancelIntent(userPk, cancelIntent);
        
        vm.expectRevert(abi.encodeWithSelector(SettlementAuthority.Finalized.selector));
        vm.prank(matcher);
        auth.cancelFromIntent(cancelIntent, signature);
    }
    
    // Test settleDebitFromIntent success
    function test_settleDebitFromIntent_success() public {
        vault.setReservedBalance(user, keccak256("order1"), 100 ether);
        
        SettlementAuthority.SettleIntent memory settleIntent = SettlementAuthority.SettleIntent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            amount: 50 ether,
            to: settleTo,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 2
        });
        
        bytes memory signature = _signSettleIntent(userPk, settleIntent);
        
        vm.prank(matcher);
        auth.settleDebitFromIntent(settleIntent, signature);
    }
    
    // Test domain separator
    function test_domainSeparator() public {
        bytes32 separator = auth.domainSeparator();
        assertTrue(separator != bytes32(0));
    }
    
    // Test getUserNonce
    function test_getUserNonce() public {
        assertEq(auth.getUserNonce(user), 0);
        
        // Reserve once
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            amount: 100 ether,
            feeCap: 5 ether,
            lpRecipient: lpRecipient,
            feeRecipient: feeRecipient,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 0
        });
        
        bytes memory signature = _signIntent(userPk, intent);
        
        vm.prank(matcher);
        auth.reserveFromIntent(intent, signature);
        
        assertEq(auth.getUserNonce(user), 1);
    }
    
    // Test isDigestConsumed
    function test_isDigestConsumed() public {
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: user,
            orderId: keccak256("order1"),
            asset: address(token),
            amount: 100 ether,
            feeCap: 5 ether,
            lpRecipient: lpRecipient,
            feeRecipient: feeRecipient,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 999
        });
        
        bytes memory signature = _signIntent(userPk, intent);
        bytes32 digest = _getIntentDigest(intent);
        
        assertFalse(auth.isDigestConsumed(user, digest));
        
        vm.prank(matcher);
        auth.reserveFromIntentUnordered(intent, signature);
        
        assertTrue(auth.isDigestConsumed(user, digest));
    }
    
    // Helper functions
    function _signIntent(uint256 pk, SettlementAuthority.Intent memory intent) internal view returns (bytes memory) {
        bytes32 digest = _getIntentDigest(intent);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
    
    function _signCancelIntent(uint256 pk, SettlementAuthority.CancelIntent memory intent) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("CancelIntent(address user,bytes32 orderId,address asset,uint64 expiry,uint256 nonce)"),
                intent.user,
                intent.orderId,
                intent.asset,
                intent.expiry,
                intent.nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", auth.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
    
    function _signSettleIntent(uint256 pk, SettlementAuthority.SettleIntent memory intent) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SettleIntent(address user,bytes32 orderId,address asset,uint256 amount,address to,uint64 expiry,uint256 nonce)"),
                intent.user,
                intent.orderId,
                intent.asset,
                intent.amount,
                intent.to,
                intent.expiry,
                intent.nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", auth.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
    
    function _getIntentDigest(SettlementAuthority.Intent memory intent) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Intent(address user,bytes32 orderId,address asset,uint256 amount,uint256 feeCap,address lpRecipient,address feeRecipient,uint64 expiry,uint256 nonce)"),
                intent.user,
                intent.orderId,
                intent.asset,
                intent.amount,
                intent.feeCap,
                intent.lpRecipient,
                intent.feeRecipient,
                intent.expiry,
                intent.nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", auth.domainSeparator(), structHash));
    }
}
