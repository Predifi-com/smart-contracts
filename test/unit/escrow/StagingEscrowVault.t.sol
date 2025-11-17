// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockERC20Permit} from "../../mocks/MockERC20Permit.sol";

import {StagingEscrowVault} from "contracts/escrow/StagingEscrowVault.sol";
import {SettlementAuthority} from "contracts/interop/SettlementAuthority.sol";
import {SettlementAuthorityV2} from "contracts/interop/SettlementAuthorityV2.sol";
import {StagingEscrowVaultV2} from "contracts/escrow/StagingEscrowVaultV2.sol";
import {MockERC20Decimals} from "../../mocks/MockERC20Decimals.sol";

interface IUUPS {
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract StagingEscrowVaultTest is Test {
    // Mirror event for expectEmit comparisons
    event IntentFailed(address indexed user, bytes32 indexed orderId, bytes32 indexed intentHash, bytes reason);
    ERC20Mock stable;
    StagingEscrowVault vaultImpl;
    StagingEscrowVault vault;
    SettlementAuthority authImpl;
    SettlementAuthority auth;

    address admin = address(0xA11CE);
    address user = address(0xBEEF);
    address lp = address(0x1111);
    address feeRec = address(0xFEE5);
    address messenger = address(0xBABA);

    function setUp() public {
        // Deploy mock token
        stable = new ERC20Mock();
        stable.mint(user, 1_000_000e18);

        // Deploy vault via UUPS proxy
        vaultImpl = new StagingEscrowVault();
        bytes memory initData = abi.encodeWithSelector(StagingEscrowVault.initialize.selector, admin);
        vault = StagingEscrowVault(address(new ERC1967Proxy(address(vaultImpl), initData)));

        // Deploy authority via UUPS proxy
        authImpl = new SettlementAuthority();
        bytes memory authInit = abi.encodeWithSelector(SettlementAuthority.initialize.selector, admin, address(vault));
        auth = SettlementAuthority(address(new ERC1967Proxy(address(authImpl), authInit)));

        // Wire roles: messenger -> auth, auth -> vault
        vm.startPrank(admin);
        auth.grantRole(auth.MESSENGER_ROLE(), messenger);
    auth.grantRole(auth.MATCHER_ROLE(), admin);
        vault.grantRole(vault.SETTLEMENT_AUTHORITY_ROLE(), address(auth));
        // Grant authority role to admin (for direct reserve calls in tests)
        vault.grantRole(vault.SETTLEMENT_AUTHORITY_ROLE(), admin);
        vm.stopPrank();
    }

    function _deposit(address depositor, uint256 amount) internal {
        vm.startPrank(depositor);
        stable.approve(address(vault), amount);
        vault.deposit(address(stable), amount);
        vm.stopPrank();
    }

    function _reserve(address onBehalfOf, bytes32 orderId, uint256 amount, uint256 feeCap, uint64 expiry) internal {
        // User deposits principal + feeCap (vault needs balance for fee payment, but only principal is reserved)
        _deposit(onBehalfOf, amount + feeCap);
        // Authority (admin) calls reserve on behalf of user (reserves only amount)
        vm.prank(admin);
        vault.reserve(onBehalfOf, orderId, address(stable), amount, feeCap, lp, feeRec, expiry);
    }

    function test_reserve_release_and_cancel_partial() public {
        bytes32 orderId = keccak256("ORDER-1");
        uint256 amount = 1000e18;
        uint256 feeCap = 50e18;
        uint64 expiry = uint64(block.timestamp + 1 days);

        _reserve(user, orderId, amount, feeCap, expiry);

        // Initial balances and accounting: amount reserved, feeCap sits in vault available balance (not reserved)
        assertEq(stable.balanceOf(address(vault)), amount + feeCap);
        (uint256 avail, uint256 resv) = vault.balances(user, address(stable));
        assertEq(avail, feeCap); // feeCap deposited but not reserved
        assertEq(resv, amount);
        assertEq(stable.balanceOf(lp), 0);
        assertEq(stable.balanceOf(feeRec), 0);

        // Simulate messenger attestation (partial fill): release 400 + 10 fee
        vm.prank(messenger);
        auth.settleFromMessenger(orderId, 400e18, 10e18);

        assertEq(stable.balanceOf(lp), 400e18);
        assertEq(stable.balanceOf(feeRec), 10e18);

        // Second partial fill: 600 + 20 fee (completes amount, keeps fee under cap)
        vm.prank(messenger);
        auth.settleFromMessenger(orderId, 600e18, 20e18);

        assertEq(stable.balanceOf(lp), 1000e18);
        assertEq(stable.balanceOf(feeRec), 30e18);

        // After expiry, authority can cancel (no refund in new architecture; already finalized)
        // NOTE: Order is finalized after full release; cancel will revert NotActive
        vm.warp(block.timestamp + 2 days);
        vm.prank(admin);
        vm.expectRevert(bytes("NotActive"));
        vault.cancel(orderId);
    }

    function test_cannot_release_beyond_caps() public {
        bytes32 orderId = keccak256("ORDER-2");
        _reserve(user, orderId, 100e18, 10e18, uint64(block.timestamp + 1 days));

        vm.prank(messenger);
        auth.settleFromMessenger(orderId, 90e18, 10e18);

        // exceeding amount
        vm.expectRevert("AmountCap");
        vm.prank(messenger);
        auth.settleFromMessenger(orderId, 11e18, 0);

        // exceeding fee
        vm.expectRevert("FeeCap");
        vm.prank(messenger);
        auth.settleFromMessenger(orderId, 0, 1e18);
    }

    function test_cancel_refunds_all_when_unfilled() public {
        bytes32 orderId = keccak256("ORDER-3");
        _reserve(user, orderId, 200e18, 5e18, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        vm.prank(admin);
        vault.cancel(orderId);
        // In new architecture: principal returned to available; feeCap transferred back to user wallet
        (uint256 avail,) = vault.balances(user, address(stable));
        assertEq(avail, 200e18 + 5e18); // principal returned to available + feeCap still in available (not transferred)
    }

    function test_reserve_validation_reverts() public {
        // Reserve is authority-only; user calling directly should revert with AccessControl
        bytes32 orderId = keccak256("OID-USER-DIRECT");
        _deposit(user, 100e18);
        // Sanity: user should NOT have settlement authority role
        assertFalse(vault.hasRole(vault.SETTLEMENT_AUTHORITY_ROLE(), user));
    vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, vault.SETTLEMENT_AUTHORITY_ROLE()));
    vm.prank(user);
    vault.reserve(user, orderId, address(stable), 50e18, 50e18, lp, feeRec, uint64(block.timestamp + 1 days));

        // Authority calling with zero user
        vm.prank(admin);
        vm.expectRevert(bytes("ZeroUser"));
        vault.reserve(address(0), keccak256("OID-ZERO-USER"), address(stable), 50e18, 50e18, lp, feeRec, uint64(block.timestamp + 1 days));

        // Authority calling with zero order id
        orderId = bytes32(0);
        vm.prank(admin);
        vm.expectRevert(bytes("BadOrderId"));
        vault.reserve(user, orderId, address(stable), 50e18, 50e18, lp, feeRec, uint64(block.timestamp + 1 days));

        // duplicate order id
        orderId = keccak256("OID-DUP");
        _reserve(user, orderId, 50e18, 50e18, uint64(block.timestamp + 1 days));
        _deposit(user, 50e18);
        vm.prank(admin);
        vm.expectRevert(bytes("Exists"));
        vault.reserve(user, orderId, address(stable), 50e18, 50e18, lp, feeRec, uint64(block.timestamp + 1 days));

        // zero addresses
        bytes32 oid = keccak256("OID-ZEROADDR");
        _deposit(user, 10e18);
        vm.prank(admin);
        vm.expectRevert(bytes("ZeroAddr"));
        vault.reserve(user, oid, address(0), 10e18, 0, lp, feeRec, uint64(block.timestamp + 1 days));
        vm.prank(admin);
        vm.expectRevert(bytes("ZeroAddr"));
        vault.reserve(user, keccak256("OID-ZERO-LP"), address(stable), 10e18, 0, address(0), feeRec, uint64(block.timestamp + 1 days));
        vm.prank(admin);
        vm.expectRevert(bytes("ZeroAddr"));
        vault.reserve(user, keccak256("OID-ZERO-FEE"), address(stable), 10e18, 0, lp, address(0), uint64(block.timestamp + 1 days));

        // zero amount
        vm.prank(admin);
        vm.expectRevert(bytes("ZeroAmount"));
        vault.reserve(user, keccak256("OID-ZERO-AMT"), address(stable), 0, 0, lp, feeRec, uint64(block.timestamp + 1 days));

        // expired
        _deposit(user, 10e18);
        vm.prank(admin);
        vm.expectRevert(bytes("Expired"));
        vault.reserve(user, keccak256("OID-EXPIRED"), address(stable), 10e18, 0, lp, feeRec, uint64(block.timestamp));

    // insufficient available (use fresh user with low balance to avoid prior deposits affecting this case)
    address userLow = address(0xBEEF2);
    stable.mint(userLow, 10e18); // mint enough to deposit small amount
    vm.startPrank(userLow);
    stable.approve(address(vault), type(uint256).max);
    vault.deposit(address(stable), 5e18);
    vm.stopPrank();
    vm.prank(admin);
    vm.expectRevert(bytes("InsufficientAvail"));
    vault.reserve(userLow, keccak256("OID-INSUFF"), address(stable), 10e18, 0, lp, feeRec, uint64(block.timestamp + 1 days));
    }

    // --- New Tests for Extended Functionality ---

    function test_deposit_with_permit() public {
        uint256 ownerPk = 0xA11CE;
        address owner = vm.addr(ownerPk);
        MockERC20Permit permitToken = new MockERC20Permit();
        permitToken.mint(owner, 1000e18);
        // Deploy a fresh vault proxy for this isolated permit test
        StagingEscrowVault impl = new StagingEscrowVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(StagingEscrowVault.initialize, admin));
        StagingEscrowVault localVault = StagingEscrowVault(address(proxy));
        // Grant authority role to admin for consistency
        vm.startPrank(admin);
        localVault.grantRole(localVault.SETTLEMENT_AUTHORITY_ROLE(), admin);
        vm.stopPrank();
        uint256 value = 250e18; uint256 nonce = permitToken.nonces(owner); uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                permitToken.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(
                    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                    owner,
                    address(localVault),
                    value,
                    nonce,
                    deadline
                ))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        vm.prank(owner);
        localVault.depositWithPermit(address(permitToken), value, deadline, v, r, s);
        (uint256 avail,) = localVault.balances(owner, address(permitToken));
        assertEq(avail, value, "Permit deposit failed");
    }

    function test_withdraw_allowed_while_paused() public {
        // deposit
        _deposit(user, 50e18);
        vm.prank(admin); vault.pause();
        assertTrue(vault.paused());
        // withdraw should STILL succeed while paused
        vm.prank(user);
        vault.withdraw(address(stable), 20e18, user);
        (uint256 avail,) = vault.balances(user, address(stable));
        assertEq(avail, 30e18);
        // deposit blocked
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(address(stable), 10e18);
        vm.prank(admin); vault.unpause();
    }

    function test_batch_settle_debit() public {
        // create two orders
        bytes32 oid1 = keccak256("OID-BATCH-1");
        bytes32 oid2 = keccak256("OID-BATCH-2");
        _reserve(user, oid1, 100e18, 10e18, uint64(block.timestamp + 1 days));
        _reserve(user, oid2, 80e18, 5e18, uint64(block.timestamp + 1 days));
        // Batch settle principal 40 + 30 to lp
        address[] memory usersArr = new address[](2); usersArr[0]=user; usersArr[1]=user;
        address[] memory assetsArr = new address[](2); assetsArr[0]=address(stable); assetsArr[1]=address(stable);
        bytes32[] memory oids = new bytes32[](2); oids[0]=oid1; oids[1]=oid2;
        uint256[] memory amts = new uint256[](2); amts[0]=40e18; amts[1]=30e18;
        address[] memory tos = new address[](2); tos[0]=lp; tos[1]=lp;
        vm.prank(admin);
        vault.batchSettleDebit(usersArr, assetsArr, oids, amts, tos);
        assertEq(stable.balanceOf(lp), 70e18);
        uint256 remaining1 = vault.getOrderReserved(user, oid1); // should be 60
        uint256 remaining2 = vault.getOrderReserved(user, oid2); // should be 50
        assertEq(remaining1, 60e18);
        assertEq(remaining2, 50e18);
    }

    function test_batch_release_for_order() public {
        bytes32 oid1 = keccak256("OID-REL-1");
        bytes32 oid2 = keccak256("OID-REL-2");
        _reserve(user, oid1, 50e18, 5e18, uint64(block.timestamp + 1 days));
        _reserve(user, oid2, 40e18, 4e18, uint64(block.timestamp + 1 days));
        bytes32[] memory oids = new bytes32[](2); oids[0]=oid1; oids[1]=oid2;
        uint256[] memory amountDeltas = new uint256[](2); amountDeltas[0]=20e18; amountDeltas[1]=10e18;
        uint256[] memory feeDeltas = new uint256[](2); feeDeltas[0]=2e18; feeDeltas[1]=1e18;
    // Call batch legacy release as admin with authority role
    vm.prank(admin);
    vault.batchReleaseForOrder(oids, amountDeltas, feeDeltas);
        assertEq(stable.balanceOf(lp), 30e18); // 20 + 10
        assertEq(stable.balanceOf(feeRec), 3e18); // 2 + 1
        assertEq(vault.getOrderReserved(user, oid1), 30e18);
        assertEq(vault.getOrderReserved(user, oid2), 30e18); // 40 - 10
    }

    function test_settle_fee_to_dynamic_recipient() public {
        bytes32 oid = keccak256("OID-FEE-DYN");
        _reserve(user, oid, 60e18, 6e18, uint64(block.timestamp + 1 days));
        address altFee = address(0xFEE123);
        vm.prank(admin);
        vault.settleFeeTo(oid, 3e18, altFee);
        assertEq(stable.balanceOf(altFee), 3e18);
        // cannot exceed cap
        vm.prank(admin);
        vm.expectRevert(bytes("FeeCap"));
        vault.settleFeeTo(oid, 4e18, altFee);
    }

    function test_intent_lifecycle_end_to_end() public {
        // User intent: reserve 120 principal with fee cap 8, then partial fills, dynamic fee settlement, finalization
        bytes32 oid = keccak256("OID-LIFECYCLE");
        _reserve(user, oid, 120e18, 8e18, uint64(block.timestamp + 1 days));
        // First fill: 50 principal + 2 fee via legacy release
        vm.prank(admin);
        vault.releaseForOrder(oid, 50e18, 2e18);
        assertEq(stable.balanceOf(lp), 50e18);
        assertEq(stable.balanceOf(feeRec), 2e18);
    // Second fill principal only via settleDebit to alternative recipient
    address altLp = address(0x1111111111111111111111111111111111111111);
        vm.prank(admin);
        vault.settleDebit(user, address(stable), oid, 40e18, altLp);
        assertEq(stable.balanceOf(altLp), 40e18);
        // Dynamic fee settlement to new fee address
        address altFee = address(0xFEEDAD); vm.prank(admin); vault.settleFeeTo(oid, 3e18, altFee);
        assertEq(stable.balanceOf(altFee), 3e18);
        // Remaining principal = 30; release remaining + final 3 fee (cap total 8) in batch
        bytes32[] memory oids = new bytes32[](1); oids[0]=oid;
        uint256[] memory amountDeltas = new uint256[](1); amountDeltas[0]=30e18;
        uint256[] memory feeDeltas = new uint256[](1); feeDeltas[0]=3e18; // total fee now 2 + 3 + 3 = 8 cap reached
        vm.prank(admin); vault.batchReleaseForOrder(oids, amountDeltas, feeDeltas);
        // Finalization: order reserved should be zero
        assertEq(vault.getOrderReserved(user, oid), 0);
        // Further settlement should revert Finalized
        vm.prank(admin); vm.expectRevert(bytes("Finalized")); vault.settleDebit(user, address(stable), oid, 1e18, altLp);
    }

    function test_release_reverts_and_pause_guards() public {
        bytes32 orderId = keccak256("ORDER-PAUSE");
        uint64 expiry = uint64(block.timestamp + 1 days);
        _reserve(user, orderId, 100e18, 10e18, expiry);

        // Zero delta
        vm.prank(messenger);
        vm.expectRevert(bytes("ZeroDelta"));
        auth.settleFromMessenger(orderId, 0, 0);

        // After expiry -> OrderExpired
        vm.warp(block.timestamp + 2 days);
        vm.prank(messenger);
        vm.expectRevert(bytes("OrderExpired"));
        auth.settleFromMessenger(orderId, 1, 0);

        // NotActive
        bytes32 unknownId = keccak256("UNKNOWN");
        vm.prank(messenger);
        vm.expectRevert(bytes("NotActive"));
        auth.settleFromMessenger(unknownId, 1, 0);

    // Pause guards: create fresh non-expired order for pause testing (compute expiry via temp to avoid stale value)
    // After warp, user still has 10e18 in available from first order's feeCap
    bytes32 orderId2 = keccak256("ORDER-PAUSE-2");
    _deposit(user, 45e18); // Need 55e18 total for 50e18 + 5e18
    uint256 futureTs = block.timestamp + 2 days; // give ample buffer
    uint64 newExpiry = uint64(futureTs);
    vm.prank(admin);
    vault.reserve(user, orderId2, address(stable), 50e18, 5e18, lp, feeRec, newExpiry);

    vm.prank(admin);
    vault.pause();
        assertTrue(vault.paused());

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.reserve(user, keccak256("OID-PAUSED"), address(stable), 50e18, 50e18, lp, feeRec, uint64(block.timestamp + 3 days));

        vm.prank(messenger);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        auth.settleFromMessenger(orderId2, 1, 0);

        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_expiry_edge_cases() public {
        // Reserve with short expiry
        bytes32 oid = keccak256("OID-EXP-EDGE");
        uint64 expiry = uint64(block.timestamp + 10); // 10 seconds ahead
        _reserve(user, oid, 50e18, 5e18, expiry);
        // Warp to exactly expiry -> release should revert OrderExpired
        vm.warp(expiry);
        vm.prank(messenger);
        vm.expectRevert(bytes("OrderExpired"));
        auth.settleFromMessenger(oid, 1e18, 0);
        // Cancel allowed after expiry
        vm.prank(admin);
        vault.cancel(oid);
    }

    function test_pause_function_matrix() public {
        // Setup user deposit
        _deposit(user, 100e18);
        bytes32 oid = keccak256("OID-PAUSE-MATRIX");
        vm.prank(admin);
        vault.reserve(user, oid, address(stable), 60e18, 10e18, lp, feeRec, uint64(block.timestamp + 1 days));
        vm.prank(admin); vault.pause();
        assertTrue(vault.paused());
        // deposit blocked
        vm.prank(user); vm.expectRevert(abi.encodeWithSignature("EnforcedPause()")); vault.deposit(address(stable), 1e18);
        // withdraw allowed
        vm.prank(user); vault.withdraw(address(stable), 5e18, user);
        // reserve blocked
        vm.prank(admin); vm.expectRevert(abi.encodeWithSignature("EnforcedPause()")); vault.reserve(user, keccak256("OID-PAUSE-MATRIX-2"), address(stable), 10e18, 0, lp, feeRec, uint64(block.timestamp + 1 days));
        // settleDebit blocked
        vm.prank(admin); vm.expectRevert(abi.encodeWithSignature("EnforcedPause()")); vault.settleDebit(user, address(stable), oid, 1e18, lp);
        // release (canonical) blocked
        vm.prank(admin); vm.expectRevert(abi.encodeWithSignature("EnforcedPause()")); vault.release(user, address(stable), oid, 1e18);
        // legacy releaseForOrder via authority blocked
        vm.prank(admin); vm.expectRevert(abi.encodeWithSignature("EnforcedPause()")); vault.releaseForOrder(oid, 1e18, 0);
        vm.prank(admin); vault.unpause();
    }

    function test_cancel_reverts_when_not_expired_and_inactive() public {
        bytes32 orderId = keccak256("ORDER-CANCEL");
        _reserve(user, orderId, 100e18, 10e18, uint64(block.timestamp + 1 days));
        // not expired
        vm.prank(admin);
        vm.expectRevert(bytes("NotExpired"));
        vault.cancel(orderId);

        // expire and cancel once
        vm.warp(block.timestamp + 2 days);
        vm.prank(admin);
        vault.cancel(orderId);
        // cancel again -> NotActive or Finalized
        vm.prank(admin);
        vm.expectRevert(); // Will be either NotActive or Finalized
        vault.cancel(orderId);
    }

    // --- Edge Case Tests Added ---

    function test_batch_settle_debit_len_mismatch_reverts() public {
        bytes32 oid = keccak256("OID-LEN-MISMATCH");
        _reserve(user, oid, 10e18, 1e18, uint64(block.timestamp + 1 days));
        address[] memory usersArr = new address[](1); usersArr[0] = user;
        address[] memory assetsArr = new address[](1); assetsArr[0] = address(stable);
        bytes32[] memory orderIds = new bytes32[](1); orderIds[0] = oid;
        uint256[] memory amounts = new uint256[](2); amounts[0] = 5e18; amounts[1] = 5e18; // deliberately longer
        address[] memory tos = new address[](1); tos[0] = lp;
        vm.prank(admin);
        vm.expectRevert(bytes("LenMismatch"));
        vault.batchSettleDebit(usersArr, assetsArr, orderIds, amounts, tos);
    }

    function test_batch_release_for_order_len_mismatch_reverts() public {
        bytes32 oid = keccak256("OID-LEN-MISMATCH-REL");
        _reserve(user, oid, 10e18, 2e18, uint64(block.timestamp + 1 days));
        bytes32[] memory orderIds = new bytes32[](1); orderIds[0] = oid;
        uint256[] memory amountDeltas = new uint256[](1); amountDeltas[0] = 5e18;
        uint256[] memory feeDeltas = new uint256[](2); feeDeltas[0] = 1e18; feeDeltas[1] = 1e18; // mismatch
        vm.prank(admin);
        vm.expectRevert(bytes("LenMismatch"));
        vault.batchReleaseForOrder(orderIds, amountDeltas, feeDeltas);
    }

    function test_settle_fee_to_zero_recipient_reverts() public {
        bytes32 oid = keccak256("OID-FEE-ZERO");
        _reserve(user, oid, 20e18, 3e18, uint64(block.timestamp + 1 days));
        vm.prank(admin);
        vm.expectRevert(bytes("ZeroAddr"));
        vault.settleFeeTo(oid, 1e18, address(0));
    }

    function test_deposit_with_permit_expired_deadline_reverts() public {
        uint256 ownerPk = 0xA11CE1; // distinct pk from other test
        address owner = vm.addr(ownerPk);
        MockERC20Permit permitToken = new MockERC20Permit();
        permitToken.mint(owner, 100e18);
        StagingEscrowVault impl = new StagingEscrowVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(StagingEscrowVault.initialize, admin));
        StagingEscrowVault localVault = StagingEscrowVault(address(proxy));
        vm.startPrank(admin);
        localVault.grantRole(localVault.SETTLEMENT_AUTHORITY_ROLE(), admin);
        vm.stopPrank();
        uint256 value = 10e18; uint256 nonce = permitToken.nonces(owner); uint256 deadline = block.timestamp - 1; // expired
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                permitToken.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(
                    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                    owner,
                    address(localVault),
                    value,
                    nonce,
                    deadline
                ))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        vm.prank(owner);
        // OpenZeppelin ERC20Permit now uses custom error ERC2612ExpiredSignature(uint256)
        vm.expectRevert(abi.encodeWithSignature("ERC2612ExpiredSignature(uint256)", 0));
        localVault.depositWithPermit(address(permitToken), value, deadline, v, r, s);
    }

    // --- EIP-712 Intent tests (SettlementAuthority.reserveFromIntent) ---

    function _intentDigest(
        address authAddr,
        address user_,
        bytes32 orderId,
        address asset,
        uint256 amount,
        uint256 feeCap_,
        address lp_,
        address fee_,
        uint64 expiry_,
        uint256 nonce_
    ) internal view returns (bytes32) {
        bytes32 DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("PredifiIntent")),
                keccak256(bytes("1")),
                block.chainid,
                authAddr
            )
        );
        bytes32 TYPEHASH = keccak256(
            "Intent(address user,bytes32 orderId,address asset,uint256 amount,uint256 feeCap,address lpRecipient,address feeRecipient,uint64 expiry,uint256 nonce)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                TYPEHASH,
                user_,
                orderId,
                asset,
                amount,
                feeCap_,
                lp_,
                fee_,
                expiry_,
                nonce_
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function test_reserve_from_intent_happy_path() public {
        // create a signer-backed user distinct from default 'user'
        uint256 userPk = 0xBEEF1;
        address u = vm.addr(userPk);
        stable.mint(u, 1_000e18);
        vm.startPrank(u);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(address(stable), 500e18);
        vm.stopPrank();

        bytes32 oid = keccak256("OID-INTENT-OK");
        uint256 amount = 120e18;
        uint256 feeCap_ = 8e18;
        uint64 expiry_ = uint64(block.timestamp + 1 days);

        // nonce should be 0 initially
        uint256 nonce_ = auth.getUserNonce(u);
        assertEq(nonce_, 0);

        bytes32 digest = _intentDigest(address(auth), u, oid, address(stable), amount, feeCap_, lp, feeRec, expiry_, nonce_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        // Call reserveFromIntent
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: u,
            orderId: oid,
            asset: address(stable),
            amount: amount,
            feeCap: feeCap_,
            lpRecipient: lp,
            feeRecipient: feeRec,
            expiry: expiry_,
            nonce: nonce_
        });

    vm.prank(admin);
    auth.reserveFromIntent(intent, abi.encodePacked(r, s, v));

        // Assert reservation took place: reserved == amount, available decreased by amount, feeCap untouched in available
        (uint256 avail, uint256 resv) = vault.balances(u, address(stable));
        assertEq(resv, amount);
        assertEq(avail, 500e18 - amount); // feeCap not auto-reserved
        assertEq(vault.getOrderReserved(u, oid), amount);
        // nonce advanced
        assertEq(auth.getUserNonce(u), 1);
    }

    function test_reserve_from_intent_bad_sig_reverts() public {
        uint256 userPk = 0xCAFE01;
        address u = vm.addr(userPk);
        stable.mint(u, 200e18);
        vm.startPrank(u);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(address(stable), 150e18);
        vm.stopPrank();

        bytes32 oid = keccak256("OID-INTENT-BADSIG");
        uint64 expiry_ = uint64(block.timestamp + 1 days);
        uint256 nonce_ = auth.getUserNonce(u);
        // Sign with wrong key
        bytes32 digest = _intentDigest(address(auth), u, oid, address(stable), 100e18, 5e18, lp, feeRec, expiry_, nonce_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);

        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: u,
            orderId: oid,
            asset: address(stable),
            amount: 100e18,
            feeCap: 5e18,
            lpRecipient: lp,
            feeRecipient: feeRec,
            expiry: expiry_,
            nonce: nonce_
        });

    vm.prank(admin);
    vm.expectRevert(bytes("BadSig"));
    auth.reserveFromIntent(intent, abi.encodePacked(r, s, v));
    }

    function test_reserve_from_intent_expired_reverts() public {
        uint256 userPk = 0xC0FFEE;
        address u = vm.addr(userPk);
        stable.mint(u, 200e18);
        vm.startPrank(u);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(address(stable), 150e18);
        vm.stopPrank();

        bytes32 oid = keccak256("OID-INTENT-EXP");
        uint64 expiry_ = uint64(block.timestamp - 1); // already expired
        uint256 nonce_ = auth.getUserNonce(u);

        bytes32 digest = _intentDigest(address(auth), u, oid, address(stable), 50e18, 5e18, lp, feeRec, expiry_, nonce_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: u,
            orderId: oid,
            asset: address(stable),
            amount: 50e18,
            feeCap: 5e18,
            lpRecipient: lp,
            feeRecipient: feeRec,
            expiry: expiry_,
            nonce: nonce_
        });

    vm.prank(admin);
    vm.expectRevert(bytes("Expired"));
    auth.reserveFromIntent(intent, abi.encodePacked(r, s, v));
    }

    function test_reserve_from_intent_bad_nonce_reverts() public {
        uint256 userPk = 0xBADBEEF;
        address u = vm.addr(userPk);
        stable.mint(u, 200e18);
        vm.startPrank(u);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(address(stable), 150e18);
        vm.stopPrank();

        bytes32 oid = keccak256("OID-INTENT-NONCE");
        uint64 expiry_ = uint64(block.timestamp + 1 days);
        // use wrong nonce (1 instead of 0)
        uint256 wrongNonce = 1;
        bytes32 digest = _intentDigest(address(auth), u, oid, address(stable), 50e18, 5e18, lp, feeRec, expiry_, wrongNonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: u,
            orderId: oid,
            asset: address(stable),
            amount: 50e18,
            feeCap: 5e18,
            lpRecipient: lp,
            feeRecipient: feeRec,
            expiry: expiry_,
            nonce: wrongNonce
        });

        vm.prank(admin);
        vm.expectRevert(bytes("BadNonce"));
        auth.reserveFromIntent(intent, abi.encodePacked(r, s, v));

    }

    function test_reserve_from_intent_nonce_not_burned_on_revert() public {
        uint256 userPk = 0xF00D;
        address u = vm.addr(userPk);
        // Deposit less than amount+feeCap to trigger authority pre-check
        stable.mint(u, 50e18);
        vm.startPrank(u);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(address(stable), 10e18);
        vm.stopPrank();

        bytes32 oid = keccak256("OID-INTENT-NONCE-BURN");
        uint64 expiry_ = uint64(block.timestamp + 1 days);
        uint256 nonce_ = auth.getUserNonce(u); // 0
        bytes32 digest = _intentDigest(address(auth), u, oid, address(stable), 20e18, 5e18, lp, feeRec, expiry_, nonce_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: u,
            orderId: oid,
            asset: address(stable),
            amount: 20e18,
            feeCap: 5e18,
            lpRecipient: lp,
            feeRecipient: feeRec,
            expiry: expiry_,
            nonce: nonce_
        });
        // Expect revert due to InsufficientAvailFeeCap and nonce unchanged
        vm.prank(admin);
        vm.expectRevert(bytes("InsufficientAvailFeeCap"));
        auth.reserveFromIntent(intent, abi.encodePacked(r, s, v));
        assertEq(auth.getUserNonce(u), 0, "nonce should not increment on revert");
    // Fund and succeed with same signature (digest same, unordered path would mark used; ordered path allows since nonce unchanged and prev call failed)
    stable.mint(u, 100e18);
    _deposit(u, 100e18);
        vm.prank(admin);
        auth.reserveFromIntent(intent, abi.encodePacked(r, s, v));
        assertEq(auth.getUserNonce(u), 1);
    }

    function test_reserve_from_intent_paused_reverts() public {
        uint256 userPk = 0xABCDEF;
        address u = vm.addr(userPk);
        stable.mint(u, 200e18);
        vm.startPrank(u);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(address(stable), 100e18);
        vm.stopPrank();
        bytes32 oid = keccak256("OID-INTENT-PAUSE");
        uint64 expiry_ = uint64(block.timestamp + 1 days);
        uint256 nonce_ = auth.getUserNonce(u);
        bytes32 digest = _intentDigest(address(auth), u, oid, address(stable), 50e18, 10e18, lp, feeRec, expiry_, nonce_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent({
            user: u,
            orderId: oid,
            asset: address(stable),
            amount: 50e18,
            feeCap: 10e18,
            lpRecipient: lp,
            feeRecipient: feeRec,
            expiry: expiry_,
            nonce: nonce_
        });
        vm.prank(admin); auth.pause();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        auth.reserveFromIntent(intent, abi.encodePacked(r, s, v));
        vm.prank(admin); auth.unpause();
    }

    function test_reserve_from_intent_unordered_and_replay_guard() public {
        uint256 userPk = 0x123456;
        address u = vm.addr(userPk);
        stable.mint(u, 1000e18);
        vm.startPrank(u);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(address(stable), 600e18);
        vm.stopPrank();

        bytes32 oidA = keccak256("OID-U-100");
        bytes32 oidB = keccak256("OID-U-5");
        uint64 expiry_ = uint64(block.timestamp + 1 days);
        bytes32 digA = _intentDigest(address(auth), u, oidA, address(stable), 200e18, 20e18, lp, feeRec, expiry_, 100);
        bytes32 digB = _intentDigest(address(auth), u, oidB, address(stable), 100e18, 10e18, lp, feeRec, expiry_, 5);
        (uint8 vA, bytes32 rA, bytes32 sA) = vm.sign(userPk, digA);
        (uint8 vB, bytes32 rB, bytes32 sB) = vm.sign(userPk, digB);

        SettlementAuthority.Intent memory intentA = SettlementAuthority.Intent(u, oidA, address(stable), 200e18, 20e18, lp, feeRec, expiry_, 100);
        SettlementAuthority.Intent memory intentB = SettlementAuthority.Intent(u, oidB, address(stable), 100e18, 10e18, lp, feeRec, expiry_, 5);

        vm.prank(admin);
        auth.reserveFromIntentUnordered(intentA, abi.encodePacked(rA, sA, vA));
        vm.prank(admin);
        auth.reserveFromIntentUnordered(intentB, abi.encodePacked(rB, sB, vB));
        // Replay should fail Used
        vm.prank(admin);
        vm.expectRevert(bytes("Used"));
        auth.reserveFromIntentUnordered(intentA, abi.encodePacked(rA, sA, vA));
    }

    function test_isDigestConsumed_getter_after_success_unordered() public {
        uint256 userPk = 0xAAA111;
        address u = vm.addr(userPk);
        stable.mint(u, 500e18);
        vm.startPrank(u);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(address(stable), 300e18);
        vm.stopPrank();

        bytes32 oid = keccak256("OID-U-CONSUME");
        uint64 expiry_ = uint64(block.timestamp + 1 days);
        bytes32 dig = _intentDigest(address(auth), u, oid, address(stable), 100e18, 20e18, lp, feeRec, expiry_, 7);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, dig);
        SettlementAuthority.Intent memory it = SettlementAuthority.Intent(u, oid, address(stable), 100e18, 20e18, lp, feeRec, expiry_, 7);
        vm.prank(admin);
        auth.reserveFromIntentUnordered(it, abi.encodePacked(r, s, v));
        assertTrue(auth.isDigestConsumed(u, dig));
    }

    function test_settle_debit_unordered_replay_guard_and_getter() public {
        // Prepare reservation for user u
        uint256 userPk = 0xFACE77;
        address u = vm.addr(userPk);
        stable.mint(u, 400e18);
        vm.startPrank(u); stable.approve(address(vault), type(uint256).max); vault.deposit(address(stable), 200e18); vm.stopPrank();
        bytes32 oid = keccak256("OID-SETTLE-U");
        vm.prank(admin); vault.reserve(u, oid, address(stable), 120e18, 10e18, lp, feeRec, uint64(block.timestamp + 1 days));
        // Build settle digest
        SettlementAuthority.SettleIntent memory sIntent = SettlementAuthority.SettleIntent({
            user: u,
            orderId: oid,
            asset: address(stable),
            amount: 30e18,
            to: lp,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 42
        });
        bytes32 sDigest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                auth.domainSeparator(),
                keccak256(
                    abi.encode(
                        keccak256("SettleIntent(address user,bytes32 orderId,address asset,uint256 amount,address to,uint64 expiry,uint256 nonce)"),
                        sIntent.user,
                        sIntent.orderId,
                        sIntent.asset,
                        sIntent.amount,
                        sIntent.to,
                        sIntent.expiry,
                        sIntent.nonce
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, sDigest);
        vm.prank(admin); auth.settleDebitFromIntent(sIntent, abi.encodePacked(r, s, v));
        assertTrue(auth.isDigestConsumed(u, sDigest));
        // Replay should revert with Used
        vm.prank(admin); vm.expectRevert(bytes("Used")); auth.settleDebitFromIntent(sIntent, abi.encodePacked(r, s, v));
    }

    function test_intentFailed_emits_when_vault_reserve_reverts_and_state_unchanged() public {
        // User with sufficient funds reserves an order, then tries reserving duplicate order via intent (vault reverts Exists)
        uint256 userPk = 0xB0B0B0;
        address u = vm.addr(userPk);
        stable.mint(u, 500e18);
        vm.startPrank(u); stable.approve(address(vault), type(uint256).max); vault.deposit(address(stable), 300e18); vm.stopPrank();
        bytes32 oid = keccak256("OID-DUP-INTENT");
        vm.prank(admin); vault.reserve(u, oid, address(stable), 100e18, 20e18, lp, feeRec, uint64(block.timestamp + 2 days));
        // Build second intent with same orderId and next nonce
        uint256 nonce_ = auth.getUserNonce(u); // 0 initially (we didn't reserve via intent yet)
        // We need to advance nonce by making a first intent succeed so that we can show unaffected nonce on failure? Instead, we check unchanged (still 0) after failure.
        uint64 expiry_ = uint64(block.timestamp + 2 days);
        bytes32 digest = _intentDigest(address(auth), u, oid, address(stable), 50e18, 5e18, lp, feeRec, expiry_, nonce_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent(u, oid, address(stable), 50e18, 5e18, lp, feeRec, expiry_, nonce_);
        // Expect IntentFailed topics with user/orderId/digest; don't check data
        vm.expectEmit(true, true, true, false);
        emit IntentFailed(u, oid, digest, bytes(""));
        vm.prank(admin);
        vm.expectRevert();
        auth.reserveFromIntent(intent, abi.encodePacked(r, s, v));
        // Nonce should remain unchanged and digest not consumed
        assertEq(auth.getUserNonce(u), nonce_);
        assertFalse(auth.isDigestConsumed(u, digest));
    }

    function test_feeCap_boundary_equality_and_then_exceeds_after_first_reserve() public {
        uint256 userPk = 0xC0FFEA;
        address u = vm.addr(userPk);
        stable.mint(u, 500e18);
        vm.startPrank(u); stable.approve(address(vault), type(uint256).max); vault.deposit(address(stable), 100e18); vm.stopPrank();
        // Case A: available == amount + feeCap -> succeed
        uint64 expiry_ = uint64(block.timestamp + 1 days);
        bytes32 oid1 = keccak256("OID-FEE-EQ");
        bytes32 dig1 = _intentDigest(address(auth), u, oid1, address(stable), 60e18, 40e18, lp, feeRec, expiry_, 0);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userPk, dig1);
        SettlementAuthority.Intent memory it1 = SettlementAuthority.Intent(u, oid1, address(stable), 60e18, 40e18, lp, feeRec, expiry_, 0);
        vm.prank(admin); auth.reserveFromIntent(it1, abi.encodePacked(r1, s1, v1));
        // available now 40; try second reserve where amount+feeCap > 40 -> revert InsufficientAvailFeeCap
        bytes32 oid2 = keccak256("OID-FEE-EXCEED");
        bytes32 dig2 = _intentDigest(address(auth), u, oid2, address(stable), 30e18, 20e18, lp, feeRec, expiry_, 1);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(userPk, dig2);
        SettlementAuthority.Intent memory it2 = SettlementAuthority.Intent(u, oid2, address(stable), 30e18, 20e18, lp, feeRec, expiry_, 1);
        vm.prank(admin); vm.expectRevert(bytes("InsufficientAvailFeeCap")); auth.reserveFromIntent(it2, abi.encodePacked(r2, s2, v2));
    }

    function test_intent_expiry_equality_reverts_and_cancel_after_expiry_succeeds() public {
        uint256 userPk = 0xE1E1E1;
        address u = vm.addr(userPk);
        stable.mint(u, 200e18);
        vm.startPrank(u); stable.approve(address(vault), type(uint256).max); vault.deposit(address(stable), 100e18); vm.stopPrank();
        bytes32 oid = keccak256("OID-EXP-INTENT");
        uint64 expiry_ = uint64(block.timestamp + 1);
        uint256 nonce_ = auth.getUserNonce(u);
        bytes32 dig = _intentDigest(address(auth), u, oid, address(stable), 10e18, 5e18, lp, feeRec, expiry_, nonce_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, dig);
        SettlementAuthority.Intent memory it = SettlementAuthority.Intent(u, oid, address(stable), 10e18, 5e18, lp, feeRec, expiry_, nonce_);
        // Warp to exactly expiry -> should revert Expired for intent-based reserve
        vm.warp(expiry_);
        vm.prank(admin); vm.expectRevert(bytes("Expired")); auth.reserveFromIntent(it, abi.encodePacked(r, s, v));
        // After > expiry, cancel intent should succeed (using a fresh cancel digest)
        // First, set up a new order and reserve directly so we can cancel after expiry
        bytes32 oid2 = keccak256("OID-EXP-INTENT-CANCEL");
        vm.warp(block.timestamp - 1); // move back 1 second to allow reserve
        vm.prank(admin); vault.reserve(u, oid2, address(stable), 20e18, 5e18, lp, feeRec, uint64(block.timestamp + 1));
        // Move past expiry
        vm.warp(block.timestamp + 2);
        SettlementAuthority.CancelIntent memory cIt = SettlementAuthority.CancelIntent(u, oid2, address(stable), uint64(block.timestamp + 100), 0);
        bytes32 cDig = keccak256(abi.encodePacked("\x19\x01", auth.domainSeparator(), keccak256(abi.encode(keccak256("CancelIntent(address user,bytes32 orderId,address asset,uint64 expiry,uint256 nonce)"), cIt.user, cIt.orderId, cIt.asset, cIt.expiry, cIt.nonce))));
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(userPk, cDig);
        vm.prank(admin); auth.cancelFromIntent(cIt, abi.encodePacked(cr, cs, cv));
        assertEq(vault.getOrderReserved(u, oid2), 0);
    }

    function test_cancel_from_intent_idempotency_and_after_finalize() public {
        uint256 userPk = 0xDEAD55;
        address u = vm.addr(userPk);
        stable.mint(u, 400e18);
        vm.startPrank(u); stable.approve(address(vault), type(uint256).max); vault.deposit(address(stable), 200e18); vm.stopPrank();
        bytes32 oid = keccak256("OID-CANCEL-ONCE");
        vm.prank(admin); vault.reserve(u, oid, address(stable), 100e18, 10e18, lp, feeRec, uint64(block.timestamp + 1 days));
        SettlementAuthority.CancelIntent memory c1 = SettlementAuthority.CancelIntent(u, oid, address(stable), uint64(block.timestamp + 1 days), 0);
        bytes32 d1 = keccak256(abi.encodePacked("\x19\x01", auth.domainSeparator(), keccak256(abi.encode(keccak256("CancelIntent(address user,bytes32 orderId,address asset,uint64 expiry,uint256 nonce)"), c1.user, c1.orderId, c1.asset, c1.expiry, c1.nonce))));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userPk, d1);
        vm.prank(admin); auth.cancelFromIntent(c1, abi.encodePacked(r1, s1, v1));
        // Second cancel with different nonce/digest should revert Finalized
        SettlementAuthority.CancelIntent memory c2 = SettlementAuthority.CancelIntent(u, oid, address(stable), uint64(block.timestamp + 1 days), 1);
        bytes32 d2 = keccak256(abi.encodePacked("\x19\x01", auth.domainSeparator(), keccak256(abi.encode(keccak256("CancelIntent(address user,bytes32 orderId,address asset,uint64 expiry,uint256 nonce)"), c2.user, c2.orderId, c2.asset, c2.expiry, c2.nonce))));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(userPk, d2);
        vm.prank(admin); vm.expectRevert(abi.encodeWithSignature("Finalized()")); auth.cancelFromIntent(c2, abi.encodePacked(r2, s2, v2));

        // Also verify cancel after full settle is rejected
        bytes32 oid2 = keccak256("OID-CANCEL-AFTER-SETTLE");
        vm.prank(admin); vault.reserve(u, oid2, address(stable), 60e18, 5e18, lp, feeRec, uint64(block.timestamp + 1 days));
        // settle all via authority-less direct call (simplify)
        vm.prank(admin); vault.settleDebit(u, address(stable), oid2, 60e18, lp);
        SettlementAuthority.CancelIntent memory c3 = SettlementAuthority.CancelIntent(u, oid2, address(stable), uint64(block.timestamp + 1 days), 0);
        bytes32 d3 = keccak256(abi.encodePacked("\x19\x01", auth.domainSeparator(), keccak256(abi.encode(keccak256("CancelIntent(address user,bytes32 orderId,address asset,uint64 expiry,uint256 nonce)"), c3.user, c3.orderId, c3.asset, c3.expiry, c3.nonce))));
        (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(userPk, d3);
        vm.prank(admin); vm.expectRevert(abi.encodeWithSignature("Finalized()")); auth.cancelFromIntent(c3, abi.encodePacked(r3, s3, v3));
    }

    function test_pause_coverage_on_unordered_and_settle() public {
        uint256 userPk = 0x111222;
        address u = vm.addr(userPk);
        stable.mint(u, 300e18);
        vm.startPrank(u); stable.approve(address(vault), type(uint256).max); vault.deposit(address(stable), 150e18); vm.stopPrank();
        bytes32 oid = keccak256("OID-PAUSE-COVER");
        uint64 expiry_ = uint64(block.timestamp + 1 days);
        // unordered reserve intent
        bytes32 dig = _intentDigest(address(auth), u, oid, address(stable), 50e18, 10e18, lp, feeRec, expiry_, 9);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, dig);
        SettlementAuthority.Intent memory it = SettlementAuthority.Intent(u, oid, address(stable), 50e18, 10e18, lp, feeRec, expiry_, 9);
        vm.prank(admin); auth.pause();
        vm.prank(admin); vm.expectRevert(abi.encodeWithSignature("EnforcedPause()")); auth.reserveFromIntentUnordered(it, abi.encodePacked(r, s, v));
        // settle path also reverts while paused
        // unpause and reserve first to create order, then pause and try settle
        vm.prank(admin); auth.unpause(); vm.prank(admin); auth.reserveFromIntentUnordered(it, abi.encodePacked(r, s, v));
        SettlementAuthority.SettleIntent memory sIt = SettlementAuthority.SettleIntent(u, oid, address(stable), 10e18, lp, uint64(block.timestamp + 1 days), 77);
        bytes32 sDig = keccak256(abi.encodePacked("\x19\x01", auth.domainSeparator(), keccak256(abi.encode(keccak256("SettleIntent(address user,bytes32 orderId,address asset,uint256 amount,address to,uint64 expiry,uint256 nonce)"), sIt.user, sIt.orderId, sIt.asset, sIt.amount, sIt.to, sIt.expiry, sIt.nonce)))) ;
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(userPk, sDig);
        vm.prank(admin); auth.pause(); vm.prank(admin); vm.expectRevert(abi.encodeWithSignature("EnforcedPause()")); auth.settleDebitFromIntent(sIt, abi.encodePacked(sr, ss, sv));
        vm.prank(admin); auth.unpause();
    }

    function test_accounting_invariant_available_plus_reserved_equals_vault_token_balance() public {
        // Single-user scenario suffices to assert global equality in this test
        _deposit(user, 200e18);
        bytes32 oid = keccak256("OID-INV-1");
        vm.prank(admin); vault.reserve(user, oid, address(stable), 150e18, 10e18, lp, feeRec, uint64(block.timestamp + 1 days));
        // Sequence: settle 40, release back 20, then cancel after expiry
        vm.prank(admin); vault.settleDebit(user, address(stable), oid, 40e18, lp);
        vm.prank(admin); vault.release(user, address(stable), oid, 20e18);
        vm.warp(block.timestamp + 2 days); vm.prank(admin); vault.cancel(oid);
        (uint256 avail, uint256 resv) = vault.balances(user, address(stable));
        uint256 vaultBal = auth.vaultTokenBalance(address(stable));
        assertEq(avail + resv, vaultBal, "Accounting invariant broken");
    }

    function test_settle_debit_from_intent_happy_and_badsig() public {
        // reserve first
        bytes32 oid = keccak256("OID-SETTLE-INTENT");
        _reserve(user, oid, 90e18, 5e18, uint64(block.timestamp + 1 days));
        // user signs settle intent to alternate LP
        uint256 userPk = 0xBEEFCAFE;
        address u = vm.addr(userPk);
    // Set up separate order for u (mint and deposit)
    stable.mint(u, 200e18);
        bytes32 oid2 = keccak256("OID-SETTLE-INTENT-2");
        _reserve(u, oid2, 60e18, 3e18, uint64(block.timestamp + 1 days));
        address altLp = address(0x2222222222222222222222222222222222222222);
        SettlementAuthority.SettleIntent memory sIntent = SettlementAuthority.SettleIntent({
            user: u,
            orderId: oid2,
            asset: address(stable),
            amount: 20e18,
            to: altLp,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 1
        });
        bytes32 sDigest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                auth.domainSeparator(),
                keccak256(
                    abi.encode(
                        keccak256("SettleIntent(address user,bytes32 orderId,address asset,uint256 amount,address to,uint64 expiry,uint256 nonce)"),
                        sIntent.user,
                        sIntent.orderId,
                        sIntent.asset,
                        sIntent.amount,
                        sIntent.to,
                        sIntent.expiry,
                        sIntent.nonce
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, sDigest);
    // bad sig first
    vm.prank(admin);
    // invalid signature should revert with ECDSAInvalidSignature
    vm.expectRevert(); // accept any revert (could be BadSig or ECDSAInvalidSignature depending on lib)
    auth.settleDebitFromIntent(sIntent, abi.encodePacked(r, s, uint8(v ^ 0x01)));
    // then happy path
    vm.prank(admin);
    auth.settleDebitFromIntent(sIntent, abi.encodePacked(r, s, v));
    assertEq(stable.balanceOf(altLp), 20e18);
    }

    function test_cancel_from_intent_finalizes() public {
        uint256 userPk = 0xABCD01;
        address u = vm.addr(userPk);
        stable.mint(u, 500e18);
        vm.startPrank(u);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(address(stable), 200e18);
        vm.stopPrank();
        bytes32 oid = keccak256("OID-CANCEL-INTENT");
        // reserve 150, feeCap 10
        vm.prank(admin);
        vault.reserve(u, oid, address(stable), 150e18, 10e18, lp, feeRec, uint64(block.timestamp + 1 days));
        SettlementAuthority.CancelIntent memory cIntent = SettlementAuthority.CancelIntent({
            user: u,
            orderId: oid,
            asset: address(stable),
            expiry: uint64(block.timestamp + 1 days),
            nonce: 0
        });
        bytes32 cDigest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                auth.domainSeparator(),
                keccak256(
                    abi.encode(
                        keccak256("CancelIntent(address user,bytes32 orderId,address asset,uint64 expiry,uint256 nonce)"),
                        cIntent.user,
                        cIntent.orderId,
                        cIntent.asset,
                        cIntent.expiry,
                        cIntent.nonce
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, cDigest);
        vm.prank(admin);
        auth.cancelFromIntent(cIntent, abi.encodePacked(r, s, v));
        // finalized: reserved is zero
        assertEq(vault.getOrderReserved(u, oid), 0);
        // further settlement should revert Finalized
        vm.prank(admin);
        vm.expectRevert(bytes("Finalized"));
        vault.settleDebit(u, address(stable), oid, 1e18, lp);
    }

    function test_fee_cap_funding_policy_enforced() public {
        uint256 userPk = 0xD00D00;
        address u = vm.addr(userPk);
        stable.mint(u, 100e18);
        vm.startPrank(u);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(address(stable), 50e18);
        vm.stopPrank();
        bytes32 oid = keccak256("OID-FEE-POLICY");
        uint64 expiry_ = uint64(block.timestamp + 1 days);
        uint256 nonce_ = auth.getUserNonce(u);
        bytes32 digest = _intentDigest(address(auth), u, oid, address(stable), 40e18, 20e18, lp, feeRec, expiry_, nonce_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        SettlementAuthority.Intent memory intent = SettlementAuthority.Intent(u, oid, address(stable), 40e18, 20e18, lp, feeRec, expiry_, nonce_);
        vm.prank(admin);
        vm.expectRevert(bytes("InsufficientAvailFeeCap"));
        auth.reserveFromIntent(intent, abi.encodePacked(r, s, v));
    }

    function test_release_partial_and_finalization_guard() public {
        bytes32 oid = keccak256("OID-PARTIAL-RELEASE");
        _reserve(user, oid, 70e18, 5e18, uint64(block.timestamp + 1 days));
        // Partial release back to available
        vm.prank(admin);
        vault.release(user, address(stable), oid, 20e18);
        (uint256 avail, uint256 resv) = vault.balances(user, address(stable));
        // User initially deposited amount+feeCap in _reserve; release returns 20 to available
        // available should increase by 20, reserved should decrease by 20
        assertEq(resv, 50e18);
        // Finalize after releasing remaining
        vm.prank(admin);
        vault.release(user, address(stable), oid, 50e18);
        assertEq(vault.getOrderReserved(user, oid), 0);
        // Further release should revert Finalized
        vm.prank(admin);
        vm.expectRevert(bytes("Finalized"));
        vault.release(user, address(stable), oid, 1);
    }

    function test_upgrade_keeps_storage_layout() public {
        // New isolated setup for upgrade test
        StagingEscrowVault impl = new StagingEscrowVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(StagingEscrowVault.initialize, admin));
        StagingEscrowVault proxied = StagingEscrowVault(address(proxy));
        // Grant roles
        vm.startPrank(admin);
        proxied.grantRole(proxied.SETTLEMENT_AUTHORITY_ROLE(), admin);
        vm.stopPrank();
        // Seed balances and reserve
        ERC20Mock tkn = new ERC20Mock();
        tkn.mint(user, 1000e18);
        vm.startPrank(user); tkn.approve(address(proxied), type(uint256).max); proxied.deposit(address(tkn), 300e18); vm.stopPrank();
        vm.prank(admin); proxied.reserve(user, keccak256("OID-UPG"), address(tkn), 200e18, 10e18, lp, feeRec, uint64(block.timestamp + 1 days));
        (uint256 availBefore, uint256 resvBefore) = proxied.balances(user, address(tkn));
        uint256 ordBefore = proxied.getOrderReserved(user, keccak256("OID-UPG"));

        // Upgrade to V2
    StagingEscrowVaultV2 v2 = new StagingEscrowVaultV2();
    // sanity: admin has role
    assertTrue(proxied.hasRole(proxied.ADMIN_ROLE(), admin));
    vm.prank(admin);
    IUUPS(address(proxied)).upgradeToAndCall(address(v2), "");

        // Validate storage invariant
        (uint256 availAfter, uint256 resvAfter) = proxied.balances(user, address(tkn));
        uint256 ordAfter = proxied.getOrderReserved(user, keccak256("OID-UPG"));
        assertEq(availBefore, availAfter, "available changed across upgrade");
        assertEq(resvBefore, resvAfter, "reserved changed across upgrade");
        assertEq(ordBefore, ordAfter, "order reserved changed across upgrade");

        // Use new var
        vm.prank(admin);
        StagingEscrowVaultV2(address(proxied)).setAdded(42);
        assertEq(StagingEscrowVaultV2(address(proxied)).added(), 42);
    }

    function test_settlement_authority_upgrade_and_non_admin_guard() public {
        // Arrange: increment a user's nonce via ordered intent
        uint256 userPk = 0xAA55AA;
        address u = vm.addr(userPk);
        stable.mint(u, 300e18);
        vm.startPrank(u); stable.approve(address(vault), type(uint256).max); vault.deposit(address(stable), 150e18); vm.stopPrank();
        bytes32 oid = keccak256("OID-SA-UPG");
        uint64 expiry_ = uint64(block.timestamp + 1 days);
        uint256 nonce_ = auth.getUserNonce(u);
        bytes32 dig = _intentDigest(address(auth), u, oid, address(stable), 50e18, 10e18, lp, feeRec, expiry_, nonce_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, dig);
        SettlementAuthority.Intent memory it = SettlementAuthority.Intent(u, oid, address(stable), 50e18, 10e18, lp, feeRec, expiry_, nonce_);
        vm.prank(admin); auth.reserveFromIntent(it, abi.encodePacked(r, s, v));
        assertEq(auth.getUserNonce(u), nonce_ + 1);

        // Upgrade auth to V2 (append storage) and verify invariants
        SettlementAuthorityV2 saV2Impl = new SettlementAuthorityV2();
        // non-admin cannot upgrade
    vm.prank(u);
    vm.expectRevert(); // generic revert acceptance (AccessControlUnauthorizedAccount)
    IUUPS(address(auth)).upgradeToAndCall(address(saV2Impl), "");

        // admin upgrades
        vm.prank(admin); IUUPS(address(auth)).upgradeToAndCall(address(saV2Impl), "");
        // nonce preserved
        assertEq(auth.getUserNonce(u), nonce_ + 1);
        // can use new variable
        vm.prank(admin); SettlementAuthorityV2(address(auth)).setAdded(99);
        assertEq(SettlementAuthorityV2(address(auth)).added(), 99);
    }

    function test_domain_version_drift_v1_vs_v2() public {
        // Deploy fresh SA v1 and v2 pointing to the same vault via their own proxies
        // v1 already deployed as 'auth'. Deploy v2 with DOMAIN_VERSION == "2"
    SettlementAuthorityV2 impl = new SettlementAuthorityV2();
    ERC1967Proxy p = new ERC1967Proxy(address(impl), abi.encodeCall(SettlementAuthorityV2.initializeV2, (admin, address(vault))));
        SettlementAuthorityV2 authV2 = SettlementAuthorityV2(address(p));
        vm.startPrank(admin);
        authV2.grantRole(authV2.MATCHER_ROLE(), admin);
        vault.grantRole(vault.SETTLEMENT_AUTHORITY_ROLE(), address(authV2));
        vm.stopPrank();

        // User and deposit
        uint256 userPk = 0xD15EA5; address u = vm.addr(userPk);
        stable.mint(u, 400e18); vm.startPrank(u); stable.approve(address(vault), type(uint256).max); vault.deposit(address(stable), 200e18); vm.stopPrank();
        bytes32 oid = keccak256("OID-DRIFT"); uint64 expiry_ = uint64(block.timestamp + 1 days);

        // Sign V1 digest
        uint256 nonceV1 = auth.getUserNonce(u);
        bytes32 digV1 = _intentDigest(address(auth), u, oid, address(stable), 60e18, 10e18, lp, feeRec, expiry_, nonceV1);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userPk, digV1);
        SettlementAuthority.Intent memory itV1 = SettlementAuthority.Intent(u, oid, address(stable), 60e18, 10e18, lp, feeRec, expiry_, nonceV1);
        // Works on v1
        vm.prank(admin); auth.reserveFromIntent(itV1, abi.encodePacked(r1, s1, v1));

        // Try same signature on v2 -> different verifyingContract/domain, should revert BadSig
    vm.prank(admin); vm.expectRevert(); authV2.reserveFromIntent(itV1, abi.encodePacked(r1, s1, v1));

        // Build V2 digest using its domain separator
        bytes32 DOMAIN_V2 = authV2.domainSeparator();
        bytes32 TYPEHASH = keccak256("Intent(address user,bytes32 orderId,address asset,uint256 amount,uint256 feeCap,address lpRecipient,address feeRecipient,uint64 expiry,uint256 nonce)");
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, u, keccak256("OID-DRIFT-2"), address(stable), uint256(40e18), uint256(5e18), lp, feeRec, expiry_, uint256(0)));
        bytes32 digV2 = keccak256(abi.encodePacked("\x19\x01", DOMAIN_V2, structHash));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(userPk, digV2);
        SettlementAuthority.Intent memory itV2 = SettlementAuthority.Intent(u, keccak256("OID-DRIFT-2"), address(stable), 40e18, 5e18, lp, feeRec, expiry_, 0);
        vm.prank(admin); authV2.reserveFromIntent(itV2, abi.encodePacked(r2, s2, v2));
    }

    function test_digest_uniqueness_no_collision() public {
        // Two different messages must produce distinct digests under same domain separator
        uint256 userPk = 0x123abc; address u = vm.addr(userPk);
        stable.mint(u, 100e18); vm.startPrank(u); stable.approve(address(vault), type(uint256).max); vault.deposit(address(stable), 80e18); vm.stopPrank();
        uint64 expiry_ = uint64(block.timestamp + 1 days);
        bytes32 d1 = _intentDigest(address(auth), u, keccak256("OID-A"), address(stable), 10e18, 1e18, lp, feeRec, expiry_, 0);
        bytes32 d2 = _intentDigest(address(auth), u, keccak256("OID-B"), address(stable), 10e18, 1e18, lp, feeRec, expiry_, 0);
        assertTrue(d1 != d2, "Digests should differ");
    }

    function test_six_decimal_token_rounding_finalize() public {
        // Deploy 6-dec token and run a tiny settle sequence
        MockERC20Decimals usdc6 = new MockERC20Decimals("USDC6", "USDC6", 6);
        address u = address(0x444444);
        usdc6.mint(u, 10_000_000); // 10 tokens (6 decimals)
        // New vault for isolation
        StagingEscrowVault impl = new StagingEscrowVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(StagingEscrowVault.initialize, admin));
        StagingEscrowVault v = StagingEscrowVault(address(proxy));
        // authority setup
        SettlementAuthority aImpl = new SettlementAuthority();
        ERC1967Proxy ap = new ERC1967Proxy(address(aImpl), abi.encodeCall(SettlementAuthority.initialize, (admin, address(v))));
        SettlementAuthority a = SettlementAuthority(address(ap));
    vm.startPrank(admin); a.grantRole(a.MATCHER_ROLE(), admin); v.grantRole(v.SETTLEMENT_AUTHORITY_ROLE(), address(a)); v.grantRole(v.SETTLEMENT_AUTHORITY_ROLE(), admin); vm.stopPrank();
        // deposit 10 tokens
        vm.startPrank(u); usdc6.approve(address(v), type(uint256).max); v.deposit(address(usdc6), 10_000_000); vm.stopPrank();
        // reserve 1.000005 tokens (1_000_005 units), feeCap 0
        bytes32 oid = keccak256("OID-USDC6");
    vm.prank(admin); v.reserve(u, oid, address(usdc6), 1_000_005, 0, lp, feeRec, uint64(block.timestamp + 1 days));
        // settle 1_000_004 -> leave 1 unit
    vm.prank(admin); v.settleDebit(u, address(usdc6), oid, 1_000_004, lp);
        assertEq(v.getOrderReserved(u, oid), 1);
        // settle final 1 unit -> finalized
        vm.prank(admin); v.settleDebit(u, address(usdc6), oid, 1, lp);
        assertEq(v.getOrderReserved(u, oid), 0);
    vm.prank(admin); vm.expectRevert(bytes("Finalized")); v.settleDebit(u, address(usdc6), oid, 1, lp);
    }
}
