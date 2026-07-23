// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PredifiAdmin}    from "../src/PredifiAdmin.sol";
import {PredifiPool}     from "../src/PredifiPool.sol";
import {MarketRegistry}  from "../src/predifi/MarketRegistry.sol";
import {MatchSettlement} from "../src/predifi/MatchSettlement.sol";
import {OracleModule}    from "../src/predifi/OracleModule.sol";
import {AdminOracle}     from "../src/predifi/AdminOracle.sol";
import {RouterFactory}   from "../src/predifi/RouterFactory.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 10_000_000 * 10 ** 6);
    }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * Deploy order:
 *   0. PredifiAdmin proxy
 *   1. MockUSDC  (skipped if USDC_ADDRESS is set)
 *   2. PredifiPool proxy
 *   3. MarketRegistry proxy  (deployer as settler/oracle placeholders)
 *   4. OracleModule proxy
 *   5. AdminOracle proxy
 *   6. MatchSettlement proxy
 *   7. RouterFactory (stateless)
 *   8. Wire roles via PredifiAdmin.execute()
 *   9. Optional: hand DEFAULT_ADMIN_ROLE to MULTISIG_ADDRESS
 *
 * Env vars:
 *   PRIVATE_KEY        deployer key (required)
 *   BACKEND_WALLET     backend hot-wallet — gets operational roles (defaults to deployer)
 *   USDC_ADDRESS       real USDC address; if unset → deploys MockUSDC
 *   STORK_ADDRESS      Stork aggregator; if unset → deployer used as placeholder
 *   MULTISIG_ADDRESS   Safe address; if set → DEFAULT_ADMIN_ROLE on PredifiAdmin transferred here
 */
contract DeployPredifi is Script {
    function run() external {
        uint256 deployerKey     = vm.envUint("PRIVATE_KEY");
        address deployer        = vm.addr(deployerKey);
        address backendWallet   = vm.envOr("BACKEND_WALLET",   deployer);
        address storkAddress    = vm.envOr("STORK_ADDRESS",    deployer);
        address multisigAddress = vm.envOr("MULTISIG_ADDRESS", address(0));
        address usdcAddress     = vm.envOr("USDC_ADDRESS",     address(0));

        vm.startBroadcast(deployerKey);

        // ── 0. PredifiAdmin ───────────────────────────────────────────────────
        PredifiAdmin adminImpl  = new PredifiAdmin();
        PredifiAdmin predifiAdmin = PredifiAdmin(address(new ERC1967Proxy(
            address(adminImpl),
            abi.encodeCall(PredifiAdmin.initialize, (deployer, backendWallet))
        )));
        console.log("PredifiAdmin impl: ", address(adminImpl));
        console.log("PredifiAdmin proxy:", address(predifiAdmin));

        // ── 1. USDC ───────────────────────────────────────────────────────────
        if (usdcAddress == address(0)) {
            usdcAddress = address(new MockUSDC());
            console.log("MockUSDC deployed: ", usdcAddress);
        } else {
            console.log("Using USDC:        ", usdcAddress);
        }

        // ── 2. PredifiPool ────────────────────────────────────────────────────
        PredifiPool poolImpl = new PredifiPool();
        PredifiPool pool = PredifiPool(address(new ERC1967Proxy(
            address(poolImpl),
            abi.encodeCall(PredifiPool.initialize, (usdcAddress, address(predifiAdmin)))
        )));
        console.log("PredifiPool impl:  ", address(poolImpl));
        console.log("PredifiPool proxy: ", address(pool));

        // ── 3. MarketRegistry (deployer as settler/oracle placeholders) ───────
        MarketRegistry registryImpl = new MarketRegistry();
        MarketRegistry registry = MarketRegistry(address(new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(MarketRegistry.initialize, (
                address(predifiAdmin),
                deployer,   // settler placeholder — replaced in step 8
                deployer,   // oracleModule placeholder — replaced in step 8
                deployer    // adminOracle placeholder — replaced in step 8
            ))
        )));
        console.log("MarketRegistry impl: ", address(registryImpl));
        console.log("MarketRegistry proxy:", address(registry));

        // ── 4. OracleModule ───────────────────────────────────────────────────
        OracleModule oracleImpl = new OracleModule();
        OracleModule oracle = OracleModule(address(new ERC1967Proxy(
            address(oracleImpl),
            abi.encodeCall(OracleModule.initialize, (
                address(predifiAdmin),
                storkAddress,
                address(registry)
            ))
        )));
        console.log("OracleModule impl: ", address(oracleImpl));
        console.log("OracleModule proxy:", address(oracle));

        // ── 5. AdminOracle ────────────────────────────────────────────────────
        AdminOracle adminOracleImpl = new AdminOracle();
        AdminOracle adminOracle = AdminOracle(address(new ERC1967Proxy(
            address(adminOracleImpl),
            abi.encodeCall(AdminOracle.initialize, (address(predifiAdmin), address(registry)))
        )));
        console.log("AdminOracle impl: ", address(adminOracleImpl));
        console.log("AdminOracle proxy:", address(adminOracle));

        // ── 6. MatchSettlement ────────────────────────────────────────────────
        MatchSettlement settlementImpl = new MatchSettlement();
        MatchSettlement settlement = MatchSettlement(address(new ERC1967Proxy(
            address(settlementImpl),
            abi.encodeCall(MatchSettlement.initialize, (address(predifiAdmin), address(registry)))
        )));
        console.log("MatchSettlement impl: ", address(settlementImpl));
        console.log("MatchSettlement proxy:", address(settlement));

        // ── 7. RouterFactory (stateless) ─────────────────────────────────────
        RouterFactory routerFactory = new RouterFactory(address(pool), usdcAddress);
        console.log("RouterFactory:     ", address(routerFactory));

        // ── 8. Register contracts with PredifiAdmin ───────────────────────────
        predifiAdmin.registerContract(address(pool),        "PredifiPool");
        predifiAdmin.registerContract(address(registry),    "MarketRegistry");
        predifiAdmin.registerContract(address(oracle),      "OracleModule");
        predifiAdmin.registerContract(address(adminOracle), "AdminOracle");
        predifiAdmin.registerContract(address(settlement),  "MatchSettlement");

        // ── 9. Wire roles ─────────────────────────────────────────────────────
        // MarketRegistry: give real addresses their roles, revoke deployer placeholders
        predifiAdmin.execute(address(registry),
            abi.encodeCall(IAccessControl.grantRole,  (registry.SETTLER_ROLE(), address(settlement))));
        predifiAdmin.execute(address(registry),
            abi.encodeCall(IAccessControl.revokeRole, (registry.SETTLER_ROLE(), deployer)));

        predifiAdmin.execute(address(registry),
            abi.encodeCall(IAccessControl.grantRole,  (registry.RESOLVER_ROLE(), address(oracle))));
        predifiAdmin.execute(address(registry),
            abi.encodeCall(IAccessControl.grantRole,  (registry.RESOLVER_ROLE(), address(adminOracle))));
        predifiAdmin.execute(address(registry),
            abi.encodeCall(IAccessControl.revokeRole, (registry.RESOLVER_ROLE(), deployer)));

        predifiAdmin.execute(address(registry),
            abi.encodeCall(IAccessControl.grantRole,  (registry.MARKET_REGISTRAR_ROLE(), backendWallet)));

        // PredifiPool: backendWallet needs LEDGER_ROLE to call withdraw
        predifiAdmin.execute(address(pool),
            abi.encodeCall(IAccessControl.grantRole,  (pool.LEDGER_ROLE(), backendWallet)));

        // MatchSettlement: backendWallet needs BATCH_SIGNER_ROLE to sign batches
        predifiAdmin.execute(address(settlement),
            abi.encodeCall(IAccessControl.grantRole,  (settlement.BATCH_SIGNER_ROLE(), backendWallet)));

        // ── 10. Optional: transfer governance to multisig ─────────────────────
        if (multisigAddress != address(0)) {
            predifiAdmin.grantRole(predifiAdmin.DEFAULT_ADMIN_ROLE(), multisigAddress);
            predifiAdmin.revokeRole(predifiAdmin.DEFAULT_ADMIN_ROLE(), deployer);
            console.log("Governance transferred to:", multisigAddress);
        } else {
            console.log("WARNING: deployer still holds DEFAULT_ADMIN_ROLE on PredifiAdmin");
        }

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────────────
        console.log("");
        console.log("=== Add to deployment/addresses.json ===");
        console.log(string.concat("USDC:             ", vm.toString(usdcAddress)));
        console.log(string.concat("PREDIFI_ADMIN:    ", vm.toString(address(predifiAdmin))));
        console.log(string.concat("VAULT_ADDRESS:    ", vm.toString(address(pool))));
        console.log(string.concat("MARKET_REGISTRY:  ", vm.toString(address(registry))));
        console.log(string.concat("MATCH_SETTLEMENT: ", vm.toString(address(settlement))));
        console.log(string.concat("ORACLE_MODULE:    ", vm.toString(address(oracle))));
        console.log(string.concat("ADMIN_ORACLE:     ", vm.toString(address(adminOracle))));
        console.log(string.concat("ROUTER_FACTORY:   ", vm.toString(address(routerFactory))));
    }
}
