// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../../../contracts/interop/SettlementAuthority.sol";
import "../../../contracts/interop/SettlementAuthorityV2.sol";
import "../../../contracts/escrow/StagingEscrowVault.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SettlementAuthorityV2Test is Test {
    SettlementAuthority public authorityV1;
    SettlementAuthorityV2 public authorityV2;
    StagingEscrowVault public vault;
    
    address public admin;
    address public messenger;

    bytes32 public constant ADMIN_ROLE = 0x00;
    bytes32 public constant MESSENGER_ROLE = keccak256("MESSENGER_ROLE");

    function setUp() public {
        admin = address(this);
        messenger = address(0x123);
        
        // Deploy vault first
        StagingEscrowVault vaultImpl = new StagingEscrowVault();
        bytes memory vaultInitData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (admin)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = StagingEscrowVault(address(vaultProxy));
    }

    function test_initializeV2_fresh_deployment() public {
        SettlementAuthorityV2 implementation = new SettlementAuthorityV2();
        bytes memory initData = abi.encodeCall(SettlementAuthorityV2.initializeV2, (admin, address(vault)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        authorityV2 = SettlementAuthorityV2(address(proxy));
        
        assertTrue(authorityV2.hasRole(ADMIN_ROLE, admin));
        assertEq(address(authorityV2.vault()), address(vault));
        assertEq(authorityV2.added(), 0);
    }

    function test_setAdded_success() public {
        SettlementAuthorityV2 implementation = new SettlementAuthorityV2();
        bytes memory initData = abi.encodeCall(SettlementAuthorityV2.initializeV2, (admin, address(vault)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        authorityV2 = SettlementAuthorityV2(address(proxy));
        
        authorityV2.setAdded(42);
        assertEq(authorityV2.added(), 42);
    }

    function test_setAdded_multiple_values() public {
        SettlementAuthorityV2 implementation = new SettlementAuthorityV2();
        bytes memory initData = abi.encodeCall(SettlementAuthorityV2.initializeV2, (admin, address(vault)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        authorityV2 = SettlementAuthorityV2(address(proxy));
        
        authorityV2.setAdded(100);
        assertEq(authorityV2.added(), 100);
        
        authorityV2.setAdded(type(uint256).max);
        assertEq(authorityV2.added(), type(uint256).max);
    }

    function test_setAdded_unauthorized_reverts() public {
        SettlementAuthorityV2 implementation = new SettlementAuthorityV2();
        bytes memory initData = abi.encodeCall(SettlementAuthorityV2.initializeV2, (admin, address(vault)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        authorityV2 = SettlementAuthorityV2(address(proxy));
        
        vm.prank(address(0x456));
        vm.expectRevert();
        authorityV2.setAdded(42);
    }

    function test_upgrade_v1_to_v2() public {
        SettlementAuthority implementationV1 = new SettlementAuthority();
        bytes memory initData = abi.encodeCall(SettlementAuthority.initialize, (admin, address(vault)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementationV1), initData);
        authorityV1 = SettlementAuthority(address(proxy));
        
        bytes32 domainV1 = authorityV1.domainSeparator();
        
        SettlementAuthorityV2 implementationV2 = new SettlementAuthorityV2();
        authorityV1.upgradeToAndCall(address(implementationV2), "");
        
        authorityV2 = SettlementAuthorityV2(address(proxy));
        
        assertTrue(authorityV2.hasRole(ADMIN_ROLE, admin));
        assertEq(address(authorityV2.vault()), address(vault));
        assertEq(authorityV2.domainSeparator(), domainV1);
        assertEq(authorityV2.added(), 0);
        
        authorityV2.setAdded(999);
        assertEq(authorityV2.added(), 999);
    }

    function test_v2_maintains_v1_functionality() public {
        SettlementAuthorityV2 implementation = new SettlementAuthorityV2();
        bytes memory initData = abi.encodeCall(SettlementAuthorityV2.initializeV2, (admin, address(vault)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        authorityV2 = SettlementAuthorityV2(address(proxy));
        
        authorityV2.grantRole(MESSENGER_ROLE, messenger);
        authorityV2.pause();
        assertTrue(authorityV2.paused());
        
        authorityV2.unpause();
        assertFalse(authorityV2.paused());
    }

    function test_initializeV2_zero_admin_reverts() public {
        SettlementAuthorityV2 implementation = new SettlementAuthorityV2();
        bytes memory initData = abi.encodeCall(SettlementAuthorityV2.initializeV2, (address(0), address(vault)));
        vm.expectRevert("ZeroAddr");
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_initializeV2_zero_vault_reverts() public {
        SettlementAuthorityV2 implementation = new SettlementAuthorityV2();
        bytes memory initData = abi.encodeCall(SettlementAuthorityV2.initializeV2, (admin, address(0)));
        vm.expectRevert("ZeroAddr");
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_storage_layout_preserved() public {
        SettlementAuthority implementationV1 = new SettlementAuthority();
        bytes memory initData = abi.encodeCall(SettlementAuthority.initialize, (admin, address(vault)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementationV1), initData);
        authorityV1 = SettlementAuthority(address(proxy));
        
        authorityV1.grantRole(MESSENGER_ROLE, messenger);
        authorityV1.pause();
        
        SettlementAuthorityV2 implementationV2 = new SettlementAuthorityV2();
        authorityV1.upgradeToAndCall(address(implementationV2), "");
        authorityV2 = SettlementAuthorityV2(address(proxy));
        
        assertTrue(authorityV2.hasRole(ADMIN_ROLE, admin));
        assertTrue(authorityV2.hasRole(MESSENGER_ROLE, messenger));
        assertTrue(authorityV2.paused());
        
        authorityV2.setAdded(777);
        assertEq(authorityV2.added(), 777);
    }

    function test_multiple_v2_deployments() public {
        for (uint i = 0; i < 3; i++) {
            SettlementAuthorityV2 impl = new SettlementAuthorityV2();
            bytes memory data = abi.encodeCall(SettlementAuthorityV2.initializeV2, (admin, address(vault)));
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
            SettlementAuthorityV2 auth = SettlementAuthorityV2(address(proxy));
            
            assertEq(auth.added(), 0);
            auth.setAdded(i);
            assertEq(auth.added(), i);
        }
    }

    function test_initializeV2_emits_event() public {
        SettlementAuthorityV2 implementation = new SettlementAuthorityV2();
        bytes memory initData = abi.encodeCall(SettlementAuthorityV2.initializeV2, (admin, address(vault)));
        
        vm.expectEmit(true, true, true, true);
        emit SettlementAuthority.VaultUpdated(address(vault));
        
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_constructor() public {
        SettlementAuthorityV2 impl = new SettlementAuthorityV2();
        assertTrue(address(impl) != address(0));
    }

    function test_multiple_admin_operations() public {
        SettlementAuthorityV2 implementation = new SettlementAuthorityV2();
        bytes memory initData = abi.encodeCall(SettlementAuthorityV2.initializeV2, (admin, address(vault)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        authorityV2 = SettlementAuthorityV2(address(proxy));
        
        authorityV2.setAdded(100);
        authorityV2.setAdded(200);
        authorityV2.pause();
        authorityV2.unpause();
        authorityV2.setAdded(300);
        
        assertEq(authorityV2.added(), 300);
    }

    function test_added_default_value() public {
        SettlementAuthorityV2 implementation = new SettlementAuthorityV2();
        bytes memory initData = abi.encodeCall(SettlementAuthorityV2.initializeV2, (admin, address(vault)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        authorityV2 = SettlementAuthorityV2(address(proxy));
        
        assertEq(authorityV2.added(), 0);
        
        authorityV2.setAdded(42);
        assertEq(authorityV2.added(), 42);
    }
}
