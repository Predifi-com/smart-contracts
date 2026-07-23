// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {LPVault} from "../src/vault/LPVault.sol";

contract AssignVaultRoles is Script {
    function _grantIfConfigured(LPVault vault, bytes32 role, string memory envName) internal {
        address account = vm.envOr(envName, address(0));
        if (account == address(0)) return;
        if (!vault.hasRole(role, account)) {
            vault.grantRole(role, account);
        }
        console.log(envName, account);
    }

    function run() external {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        LPVault vault = LPVault(payable(vm.envAddress("VAULT_ADDRESS")));

        vm.startBroadcast(adminKey);

        _grantIfConfigured(vault, vault.PAUSER_ROLE(), "VAULT_PAUSER");
        _grantIfConfigured(vault, vault.BRIDGE_MANAGER_ROLE(), "VAULT_BRIDGE_MANAGER");
        _grantIfConfigured(vault, vault.YIELD_MANAGER_ROLE(), "VAULT_YIELD_MANAGER");

        address adminSafe = vm.envOr("VAULT_DEFAULT_ADMIN_SAFE", address(0));
        if (adminSafe != address(0) && !vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), adminSafe)) {
            vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), adminSafe);
            console.log("VAULT_DEFAULT_ADMIN_SAFE", adminSafe);
        }

        vm.stopBroadcast();

        console.log("Vault roles assigned for:", address(vault));
    }
}
