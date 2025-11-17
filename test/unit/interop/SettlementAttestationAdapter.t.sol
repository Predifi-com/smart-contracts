// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SettlementAttestationAdapter} from "contracts/interop/SettlementAttestationAdapter.sol";

contract MockSettlementAuthority {
    bytes32 public lastOrderId;
    uint256 public lastAmountDelta;
    uint256 public lastFeeDelta;
    uint256 public callCount;
    
    event SettleCalled(bytes32 orderId, uint256 amountDelta, uint256 feeDelta);
    
    function settleFromMessenger(bytes32 orderId, uint256 amountDelta, uint256 feeDelta) external {
        lastOrderId = orderId;
        lastAmountDelta = amountDelta;
        lastFeeDelta = feeDelta;
        callCount++;
        emit SettleCalled(orderId, amountDelta, feeDelta);
    }
}

contract SettlementAttestationAdapterTest is Test {
    SettlementAttestationAdapter impl;
    SettlementAttestationAdapter adapter;
    MockSettlementAuthority authority;
    
    address admin = address(0xA11CE);
    address caller = address(0xCA11);
    address rando = address(0xDEAD);
    
    function setUp() public {
        authority = new MockSettlementAuthority();
        
        impl = new SettlementAttestationAdapter();
        bytes memory initData = abi.encodeWithSelector(
            SettlementAttestationAdapter.initialize.selector,
            admin,
            address(authority),
            caller
        );
        adapter = SettlementAttestationAdapter(address(new ERC1967Proxy(address(impl), initData)));
    }
    
    function test_initialize_success() public {
        assertTrue(adapter.hasRole(adapter.ADMIN_ROLE(), admin));
        assertTrue(adapter.hasRole(adapter.CALLER_ROLE(), caller));
        assertEq(address(adapter.settlementAuthority()), address(authority));
    }
    
    function test_initialize_zero_admin_reverts() public {
        SettlementAttestationAdapter localImpl = new SettlementAttestationAdapter();
        vm.expectRevert(bytes("ZeroAddr"));
        new ERC1967Proxy(address(localImpl), abi.encodeWithSelector(
            SettlementAttestationAdapter.initialize.selector,
            address(0),
            address(authority),
            caller
        ));
    }
    
    function test_initialize_zero_authority_reverts() public {
        SettlementAttestationAdapter localImpl = new SettlementAttestationAdapter();
        vm.expectRevert(bytes("ZeroAddr"));
        new ERC1967Proxy(address(localImpl), abi.encodeWithSelector(
            SettlementAttestationAdapter.initialize.selector,
            admin,
            address(0),
            caller
        ));
    }
    
    function test_initialize_zero_caller_reverts() public {
        SettlementAttestationAdapter localImpl = new SettlementAttestationAdapter();
        vm.expectRevert(bytes("ZeroAddr"));
        new ERC1967Proxy(address(localImpl), abi.encodeWithSelector(
            SettlementAttestationAdapter.initialize.selector,
            admin,
            address(authority),
            address(0)
        ));
    }
    
    function test_receiveAttestation_success() public {
        bytes32 orderId = keccak256("order1");
        uint256 amountDelta = 100 ether;
        uint256 feeDelta = 5 ether;
        
        vm.expectEmit(true, true, true, true);
        emit SettlementAttestationAdapter.AttestationConsumed(orderId, amountDelta, feeDelta, caller);
        
        vm.prank(caller);
        adapter.receiveAttestation(orderId, amountDelta, feeDelta);
        
        assertEq(authority.lastOrderId(), orderId);
        assertEq(authority.lastAmountDelta(), amountDelta);
        assertEq(authority.lastFeeDelta(), feeDelta);
        assertEq(authority.callCount(), 1);
    }
    
    function test_receiveAttestation_unauthorized_reverts() public {
        vm.expectRevert();
        vm.prank(rando);
        adapter.receiveAttestation(keccak256("order1"), 100 ether, 5 ether);
    }
    
    function test_receiveAttestation_when_paused_reverts() public {
        vm.prank(admin);
        adapter.pause();
        
        vm.expectRevert();
        vm.prank(caller);
        adapter.receiveAttestation(keccak256("order1"), 100 ether, 5 ether);
    }
    
    function test_setAuthority_success() public {
        MockSettlementAuthority newAuthority = new MockSettlementAuthority();
        
        vm.expectEmit(true, false, false, false);
        emit SettlementAttestationAdapter.AuthorityUpdated(address(newAuthority));
        
        vm.prank(admin);
        adapter.setAuthority(address(newAuthority));
        
        assertEq(address(adapter.settlementAuthority()), address(newAuthority));
    }
    
    function test_setAuthority_zero_address_reverts() public {
        vm.expectRevert(bytes("ZeroAddr"));
        vm.prank(admin);
        adapter.setAuthority(address(0));
    }
    
    function test_setAuthority_unauthorized_reverts() public {
        MockSettlementAuthority newAuthority = new MockSettlementAuthority();
        
        vm.expectRevert();
        vm.prank(rando);
        adapter.setAuthority(address(newAuthority));
    }
    
    function test_setAllowedCaller_grant() public {
        address newCaller = address(0x123);
        
        vm.prank(admin);
        adapter.setAllowedCaller(newCaller, true);
        
        assertTrue(adapter.hasRole(adapter.CALLER_ROLE(), newCaller));
        
        // Verify new caller can call
        vm.prank(newCaller);
        adapter.receiveAttestation(keccak256("order1"), 100 ether, 5 ether);
    }
    
    function test_setAllowedCaller_revoke() public {
        vm.prank(admin);
        adapter.setAllowedCaller(caller, false);
        
        assertFalse(adapter.hasRole(adapter.CALLER_ROLE(), caller));
        
        // Verify caller can no longer call
        vm.expectRevert();
        vm.prank(caller);
        adapter.receiveAttestation(keccak256("order1"), 100 ether, 5 ether);
    }
    
    function test_setAllowedCaller_zero_address_reverts() public {
        vm.expectRevert(bytes("ZeroAddr"));
        vm.prank(admin);
        adapter.setAllowedCaller(address(0), true);
    }
    
    function test_setAllowedCaller_unauthorized_reverts() public {
        vm.expectRevert();
        vm.prank(rando);
        adapter.setAllowedCaller(address(0x123), true);
    }
    
    function test_pause_unpause() public {
        vm.prank(admin);
        adapter.pause();
        assertTrue(adapter.paused());
        
        vm.prank(admin);
        adapter.unpause();
        assertFalse(adapter.paused());
    }
    
    function test_pause_unauthorized_reverts() public {
        vm.expectRevert();
        vm.prank(rando);
        adapter.pause();
    }
    
    function test_unpause_unauthorized_reverts() public {
        vm.prank(admin);
        adapter.pause();
        
        vm.expectRevert();
        vm.prank(rando);
        adapter.unpause();
    }
    
    function test_upgrade_success() public {
        SettlementAttestationAdapter newImpl = new SettlementAttestationAdapter();
        
        vm.prank(admin);
        adapter.upgradeToAndCall(address(newImpl), "");
    }
    
    function test_upgrade_unauthorized_reverts() public {
        SettlementAttestationAdapter newImpl = new SettlementAttestationAdapter();
        
        vm.expectRevert();
        vm.prank(rando);
        adapter.upgradeToAndCall(address(newImpl), "");
    }
    
    function test_multiple_attestations() public {
        bytes32[] memory orderIds = new bytes32[](3);
        orderIds[0] = keccak256("order1");
        orderIds[1] = keccak256("order2");
        orderIds[2] = keccak256("order3");
        
        vm.startPrank(caller);
        for (uint i = 0; i < 3; i++) {
            adapter.receiveAttestation(orderIds[i], (i + 1) * 100 ether, (i + 1) * 5 ether);
        }
        vm.stopPrank();
        
        assertEq(authority.callCount(), 3);
    }
    
    function test_full_flow_with_authority_change() public {
        // Receive attestation with first authority
        vm.prank(caller);
        adapter.receiveAttestation(keccak256("order1"), 100 ether, 5 ether);
        assertEq(authority.callCount(), 1);
        
        // Change authority
        MockSettlementAuthority newAuthority = new MockSettlementAuthority();
        vm.prank(admin);
        adapter.setAuthority(address(newAuthority));
        
        // Receive attestation with new authority
        vm.prank(caller);
        adapter.receiveAttestation(keccak256("order2"), 200 ether, 10 ether);
        
        // Old authority should have 1 call, new should have 1
        assertEq(authority.callCount(), 1);
        assertEq(newAuthority.callCount(), 1);
    }
}
