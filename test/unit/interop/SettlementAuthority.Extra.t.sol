// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../../../contracts/interop/SettlementAuthority.sol";
import "../../../contracts/escrow/StagingEscrowVault.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SettlementAuthorityExtraTest is Test {
    SettlementAuthority public authority;
    StagingEscrowVault public vault;
    
    address public admin;

    function setUp() public {
        admin = address(this);
        
        // Deploy vault first
        StagingEscrowVault vaultImpl = new StagingEscrowVault();
        bytes memory vaultInitData = abi.encodeCall(
            StagingEscrowVault.initialize,
            (admin)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = StagingEscrowVault(address(vaultProxy));
    }

    /// @dev Test successful initialization to cover lines 31-36
    function test_full_successful_initialization() public {
        SettlementAuthority implementation = new SettlementAuthority();
        
        bytes memory initData = abi.encodeCall(
            SettlementAuthority.initialize,
            (admin, address(vault))
        );
        
        // This should cover lines 30-36: require, __UUPSUpgradeable_init, __AccessControl_init, __Pausable_init, _grantRole, vault =, emit
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        authority = SettlementAuthority(address(proxy));
        
        // Verify all initialization completed successfully
        assertTrue(authority.hasRole(authority.ADMIN_ROLE(), admin));
        assertEq(address(authority.vault()), address(vault));
        assertFalse(authority.paused());
        
        // Test that we can use it
        authority.pause();
        assertTrue(authority.paused());
    }

    /// @dev Another initialization test with different addresses
    function test_initialization_with_different_addresses() public {
        address otherAdmin = address(0x999);
        
        SettlementAuthority implementation = new SettlementAuthority();
        
        bytes memory initData = abi.encodeCall(
            SettlementAuthority.initialize,
            (otherAdmin, address(vault))
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        authority = SettlementAuthority(address(proxy));
        
        // Verify
        assertTrue(authority.hasRole(authority.ADMIN_ROLE(), otherAdmin));
        assertFalse(authority.hasRole(authority.ADMIN_ROLE(), admin));
    }

    /// @dev Multiple sequential deployments to ensure constructor+init coverage
    function test_multiple_deployments() public {
        for (uint i = 0; i < 3; i++) {
            SettlementAuthority impl = new SettlementAuthority();
            bytes memory data = abi.encodeCall(SettlementAuthority.initialize, (admin, address(vault)));
            new ERC1967Proxy(address(impl), data);
        }
    }

    /// @dev Test pause then use after unpause
    function test_pause_unpause_full_workflow() public {
        SettlementAuthority implementation = new SettlementAuthority();
        bytes memory initData = abi.encodeCall(
            SettlementAuthority.initialize,
            (admin, address(vault))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        authority = SettlementAuthority(address(proxy));
        
        // Pause
        authority.pause();
        assertTrue(authority.paused());
        
        // Unpause
        authority.unpause();
        assertFalse(authority.paused());
        
        // Should be usable again
        authority.setVault(address(vault));
    }
}
