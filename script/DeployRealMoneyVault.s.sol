// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LPVault} from "../src/vault/LPVault.sol";

contract DeployRealMoneyVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address asset = vm.envAddress("VAULT_ASSET");
        address admin = vm.envAddress("VAULT_ADMIN");
        string memory name = vm.envOr("VAULT_NAME", string("Predifi Stable Vault"));
        string memory symbol = vm.envOr("VAULT_SYMBOL", string("pSTABLE"));

        vm.startBroadcast(deployerKey);

        LPVault implementation = new LPVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(LPVault.initialize, (IERC20(asset), name, symbol, admin))
        );

        vm.stopBroadcast();

        console.log("LPVault implementation:", address(implementation));
        console.log("LPVault proxy:         ", address(proxy));
        console.log("Vault asset:           ", asset);
        console.log("Vault admin:           ", admin);
        console.log("Vault name:            ", name);
        console.log("Vault symbol:          ", symbol);
    }
}
