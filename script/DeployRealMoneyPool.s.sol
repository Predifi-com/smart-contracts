// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PredifiPool} from "../src/PredifiPool.sol";

contract DeployRealMoneyPool is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address asset = vm.envAddress("POOL_ASSET");
        address admin = vm.envAddress("POOL_ADMIN");

        vm.startBroadcast(deployerKey);

        PredifiPool implementation = new PredifiPool();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(PredifiPool.initialize, (asset, admin))
        );

        vm.stopBroadcast();

        console.log("PredifiPool implementation:", address(implementation));
        console.log("PredifiPool proxy:         ", address(proxy));
        console.log("Pool asset:                ", asset);
        console.log("Pool admin:                ", admin);
    }
}
