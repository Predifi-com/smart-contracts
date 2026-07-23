// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {LPVault} from "../src/vault/LPVault.sol";

contract ObserveVault is Script {
    function run() external view {
        LPVault vault = LPVault(payable(vm.envAddress("VAULT_ADDRESS")));
        address asset = vault.asset();

        console.log("Vault:                ", address(vault));
        console.log("Asset:                ", asset);
        console.log("Asset symbol:         ", IERC20Metadata(asset).symbol());
        console.log("Asset decimals:       ", IERC20Metadata(asset).decimals());
        console.log("Paused:               ", vault.paused());
        console.log("Total assets:         ", vault.totalAssets());
        console.log("Total supply:         ", vault.totalSupply());
        console.log("Idle asset balance:   ", IERC20Metadata(asset).balanceOf(address(vault)));
        console.log("Bridge deployed:      ", vault.totalDeployedToBridge());
        console.log("Yield deployed:       ", vault.totalDeployedToYield());
        console.log("Last yield sync:      ", vault.lastYieldSync());
        console.log("Valuation max age:    ", vault.valuationMaxAge());
    }
}
