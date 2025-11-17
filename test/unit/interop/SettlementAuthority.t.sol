// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SettlementAuthority } from "contracts/interop/SettlementAuthority.sol";

contract MockStagingEscrowVault {
    bytes32 public lastOrderId;
    uint256 public lastAmountDelta;
    uint256 public lastFeeDelta;
    uint256 public callCount;

    event ReleaseCalled(bytes32 orderId, uint256 amountDelta, uint256 feeDelta);

    function releaseForOrder(bytes32 orderId, uint256 amountDelta, uint256 feeDelta) external {
        lastOrderId = orderId;
        lastAmountDelta = amountDelta;
        lastFeeDelta = feeDelta;
        callCount++;
        emit ReleaseCalled(orderId, amountDelta, feeDelta);
    }
}

contract SettlementAuthorityTest is Test {
    SettlementAuthority impl;
    SettlementAuthority auth;
    MockStagingEscrowVault vault;

    address admin = address(0xA11CE);
    address messenger = address(0xBABA);
    address rando = address(0xDEAD);

    function setUp() public {
        vault = new MockStagingEscrowVault();

        impl = new SettlementAuthority();
        bytes memory initData = abi.encodeWithSelector(SettlementAuthority.initialize.selector, admin, address(vault));
        auth = SettlementAuthority(address(new ERC1967Proxy(address(impl), initData)));

        bytes32 messengerRole = auth.MESSENGER_ROLE();
        vm.prank(admin);
        auth.grantRole(messengerRole, messenger);
    }

    function test_initialize_reverts_on_zero_admin() public {
        SettlementAuthority localImpl = new SettlementAuthority();
        vm.expectRevert(bytes("ZeroAddr"));
        new ERC1967Proxy(address(localImpl), abi.encodeWithSelector(SettlementAuthority.initialize.selector, address(0), address(vault)));
    }

    function test_initialize_reverts_on_zero_vault() public {
        SettlementAuthority localImpl = new SettlementAuthority();
        vm.expectRevert(bytes("ZeroAddr"));
        new ERC1967Proxy(address(localImpl), abi.encodeWithSelector(SettlementAuthority.initialize.selector, admin, address(0)));
    }

    function test_settle_calls_vault_and_emits() public {
        bytes32 orderId = keccak256("OID-1");
        uint256 amountDelta = 100;
        uint256 feeDelta = 5;

        vm.expectEmit(true, true, true, true);
        emit SettlementAuthority.Settled(orderId, amountDelta, feeDelta);

        vm.prank(messenger);
        auth.settleFromMessenger(orderId, amountDelta, feeDelta);

        assertEq(vault.lastOrderId(), orderId);
        assertEq(vault.lastAmountDelta(), amountDelta);
        assertEq(vault.lastFeeDelta(), feeDelta);
        assertEq(vault.callCount(), 1);
    }

    function test_only_messenger_can_settle() public {
        bytes32 orderId = keccak256("OID-2");
        vm.expectRevert();
        vm.prank(rando);
        auth.settleFromMessenger(orderId, 1, 0);
    }

    function test_pause_blocks_settle_and_unpause_allows() public {
        bytes32 orderId = keccak256("OID-3");
        // Pause by admin
        vm.prank(admin);
        auth.pause();

        vm.expectRevert();
        vm.prank(messenger);
        auth.settleFromMessenger(orderId, 1, 0);

        // Unpause and try again
        vm.prank(admin);
        auth.unpause();

        vm.prank(messenger);
        auth.settleFromMessenger(orderId, 2, 1);
        assertEq(vault.callCount(), 1);
    }

    function test_setVault_onlyAdmin_and_emits() public {
        MockStagingEscrowVault newVault = new MockStagingEscrowVault();

        // Non-admin cannot set
        vm.expectRevert();
        vm.prank(rando);
        auth.setVault(address(newVault));

        // Admin can set and event emitted
        vm.expectEmit(true, true, true, true);
        emit SettlementAuthority.VaultUpdated(address(newVault));
        vm.prank(admin);
        auth.setVault(address(newVault));

        // Prove it routes to new vault
        bytes32 messengerRole = auth.MESSENGER_ROLE();
        vm.prank(admin);
        auth.grantRole(messengerRole, messenger);
        vm.prank(messenger);
        auth.settleFromMessenger(keccak256("OID-4"), 7, 3);
        assertEq(newVault.callCount(), 1);
    }

    function test_upgrade_only_admin() public {
        // Deploy a new implementation
        SettlementAuthority newImpl = new SettlementAuthority();

        // Non-admin cannot upgrade
        vm.expectRevert();
        vm.prank(rando);
        auth.upgradeToAndCall(address(newImpl), "");

        // Admin can upgrade
        vm.prank(admin);
        auth.upgradeToAndCall(address(newImpl), "");
    }

    function test_setVault_zero_address_reverts() public {
        vm.expectRevert(bytes("ZeroAddr"));
        vm.prank(admin);
        auth.setVault(address(0));
    }
}
