// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {PredifiPool} from "../src/PredifiPool.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {LPVault} from "../src/vault/LPVault.sol";

contract DeployYieldAdapter is Script {
    error UnsupportedProtocol(string protocol);
    error UnsupportedOwnerKind(string ownerKind);

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _register(address owner, address adapter, string memory ownerKind) internal {
        if (_eq(ownerKind, "lp_vault")) {
            LPVault(payable(owner)).addYieldAdapter(adapter);
            return;
        }
        if (_eq(ownerKind, "predifi_pool")) {
            PredifiPool(payable(owner)).registerYieldAdapter(adapter);
            return;
        }
        revert UnsupportedOwnerKind(ownerKind);
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("YIELD_OWNER");
        string memory protocol = vm.envString("YIELD_ADAPTER_PROTOCOL");
        string memory name = vm.envOr("YIELD_ADAPTER_NAME", string("Predifi Yield Adapter"));
        bool registerWithOwner = vm.envOr("REGISTER_YIELD_ADAPTER", false);
        string memory ownerKind = vm.envOr("YIELD_OWNER_KIND", string("lp_vault"));

        vm.startBroadcast(deployerKey);

        address adapter;
        if (_eq(protocol, "aave_v3")) {
            adapter = address(new AaveV3Adapter(
                owner,
                vm.envAddress("YIELD_ASSET"),
                vm.envAddress("AAVE_V3_POOL"),
                vm.envAddress("AAVE_V3_ATOKEN"),
                name
            ));
        } else if (_eq(protocol, "erc4626") || _eq(protocol, "morpho_vault")) {
            adapter = address(new ERC4626Adapter(
                owner,
                vm.envAddress("ERC4626_VAULT"),
                name
            ));
        } else {
            revert UnsupportedProtocol(protocol);
        }

        if (registerWithOwner) {
            _register(owner, adapter, ownerKind);
        }

        vm.stopBroadcast();

        console.log("Yield adapter protocol: ", protocol);
        console.log("Yield adapter:          ", adapter);
        console.log("Yield owner:            ", owner);
        console.log("Yield owner kind:       ", ownerKind);
        console.log("Registered with owner:  ", registerWithOwner);
    }
}
