# Predifi Smart Contracts - Deployment Addresses

**Last Updated:** November 4, 2025  
**Deployer Address:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB

## Table of Contents

1. [Native CLOB Model (Predifi's Prediction Market)](#native-clob-model-predifis-prediction-market)
2. [Aggregator Model (Cross-Chain Bet Aggregation)](#aggregator-model-cross-chain-bet-aggregation)
3. [Shared Support Contracts](#shared-support-contracts)
4. [Network Information](#network-information)
5. [Deployment Scripts](#deployment-scripts)

---

## Native CLOB Model (Predifi's Prediction Market)

### Optimism Sepolia (Chain ID: 11155420)

**Deployment Date:** November 4, 2025  
**Deployer:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Admin:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Fee Recipient:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Settler:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB

**Collateral Token:** 0x5fd84259d66Cd46123540766Be93DFE6D43130D7 (Bridged USDC on OP Sepolia)  
**Oracle (Stork):** 0xacC0a0cF13571d30B4b8637996F5D6D774d4fd62

| Contract | Proxy Address | Implementation Address | Verification |
|----------|---------------|------------------------|--------------|
| **YesNoToken** | `0x7A3689E6EE08702f9d4Ca96eC342C7c4cc3DFbDe` | `0x58E45b6dEd2169d34E776E714231CCbb36D9e272` | [Proxy: Verified](https://sepolia-optimism.etherscan.io/address/0x7A3689E6EE08702f9d4Ca96eC342C7c4cc3DFbDe#code) · [Impl: Verified](https://sepolia-optimism.etherscan.io/address/0x58E45b6dEd2169d34E776E714231CCbb36D9e272#code) |
| **OracleAdapter** | `0x7c4AF1Ec357eD16ffa70ED191bfB54b4512E6202` | `0x663E869b03823bdBf00d737d113e29bd8b4f8BeA` | [Proxy: Verified](https://sepolia-optimism.etherscan.io/address/0x7c4AF1Ec357eD16ffa70ED191bfB54b4512E6202#code) · [Impl: Verified](https://sepolia-optimism.etherscan.io/address/0x663E869b03823bdBf00d737d113e29bd8b4f8BeA#code) |
| **FeeCollector** | `0x655D9386C87e52443159bD17c412002C4F80f220` | `0xE172dAa3d4Db3c45e621eCc19a8658d1d0AA6617` | [Proxy: Verified](https://sepolia-optimism.etherscan.io/address/0x655D9386C87e52443159bD17c412002C4F80f220#code) · [Impl: Verified](https://sepolia-optimism.etherscan.io/address/0xE172dAa3d4Db3c45e621eCc19a8658d1d0AA6617#code) |
| **MarketFactory** | `0x62BC2708d4338F4955f7202791cDCef46dD97280` | `0xf80918Ff6CCd825aD214Fc71a4F1cb8F4080B919` | [Proxy: Verified](https://sepolia-optimism.etherscan.io/address/0x62BC2708d4338F4955f7202791cDCef46dD97280#code) · [Impl: Verified](https://sepolia-optimism.etherscan.io/address/0xf80918Ff6CCd825aD214Fc71a4F1cb8F4080B919#code) |
| **OrderBook** | `0x4E9f239A5BfDA2fd565f93A4a6505a8Bd5972986` | `0x6BD30c2158c9E38EaEF2A8faDa8375D87f1236e8` | [Proxy: Verified](https://sepolia-optimism.etherscan.io/address/0x4E9f239A5BfDA2fd565f93A4a6505a8Bd5972986#code) · [Impl: Verified](https://sepolia-optimism.etherscan.io/address/0x6BD30c2158c9E38EaEF2A8faDa8375D87f1236e8#code) |
| **Settlement** | `0xB42EE1571E2a4C151aA09ea8C001059D867aD96C` | `0xE9734eF9ba6115F773F7a4a46D71148Ad4718386` | [Proxy: Verified](https://sepolia-optimism.etherscan.io/address/0xB42EE1571E2a4C151aA09ea8C001059D867aD96C#code) · [Impl: Verified](https://sepolia-optimism.etherscan.io/address/0xE9734eF9ba6115F773F7a4a46D71148Ad4718386#code) |

**Deployment Transactions:**
- Deployment sequence: 17 transactions
- Total gas paid: 0.00001235961013025 ETH
- Average gas price: 0.00100025 gwei
- Block range: 35205160 - 35205179

**Roles Granted:**
- YesNoToken MINTER_ROLE → Settlement contract
- FeeCollector SETTLEMENT_ROLE → Settlement contract
- OrderBook OPERATOR_ROLE → Settlement contract & Settler address
- Settlement SETTLER_ROLE → Settler address

---

## Aggregator Model (Cross-Chain Bet Aggregation)

### Optimism Sepolia (Chain ID: 11155420) - Hub/Accounting Chain

**Deployment Date:** November 4, 2025  
**Deployer:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Admin:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Relayer:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Treasury:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Collateral Token (USDC):** 0x5fd84259d66Cd46123540766Be93DFE6D43130D7

| Contract | Proxy Address | Implementation Address | Verification |
|----------|---------------|------------------------|--------------|
| **ProtocolConfig** | `0xdb6845A2b4db952F8B087f1ADab2C1491431F4Fc` | `0x4455c50771DAA432f80b7458c8b9FEC836d23700` | [Proxy: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0xdb6845A2b4db952F8B087f1ADab2C1491431F4Fc#code) · [Impl: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0x4455c50771DAA432f80b7458c8b9FEC836d23700#code) |
| **PauseGuardian** | `0xd487C71eDDcb6618a08751c7497B76c377016311` | `0xA572D8Bd5348909C85f6bb78CE7745bd8DD06875` | [Proxy: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0xd487C71eDDcb6618a08751c7497B76c377016311#code) · [Impl: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0xA572D8Bd5348909C85f6bb78CE7745bd8DD06875#code) |
| **TreasurySplitter** | `0x7cEBBF17153a7f838BE6Fab7edA80947C7f2c3B1` | `0xb00E55a3D99200dabDD3680313eE06BDC73299D7` | [Proxy: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0x7cEBBF17153a7f838BE6Fab7edA80947C7f2c3B1#code) · [Impl: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0xb00E55a3D99200dabDD3680313eE06BDC73299D7#code) |
| **MessengerAdapter (hub)** | `0x7a66F5a4b1B9f6DE3D5F52BD32783C307675284D` | `0xC7057d3656b56F559cDBd9c7D031c75A20011635` | [Proxy: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0x7a66F5a4b1B9f6DE3D5F52BD32783C307675284D#code) · [Impl: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0xC7057d3656b56F559cDBd9c7D031c75A20011635#code) |
| **LPVault** | `0x6DED84570a93A03209aD31f16B935DA03884C9C2` | `0x144cD96A85226894893162882A98c23E8DacEb3B` | [Proxy: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0x6DED84570a93A03209aD31f16B935DA03884C9C2#code) · [Impl: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0x144cD96A85226894893162882A98c23E8DacEb3B#code) |
| **StagingEscrowVault** | `0x941FC906280197860348CD1839BE8C91A75dB6F9` | `0xf3eF0E0A699c819f3564483b499e1e6e0912af84` | [Proxy: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0x941FC906280197860348CD1839BE8C91A75dB6F9#code) · [Impl: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0xf3eF0E0A699c819f3564483b499e1e6e0912af84#code) |
| **SettlementAuthority** | `0x6A093bABE3f27829dc955cf489A1a73D93e3cF44` | `0xa84471d0c86ceC208161cB4E19a2f1761AB8c4Dd` | [Proxy: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0x6A093bABE3f27829dc955cf489A1a73D93e3cF44#code) · [Impl: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0xa84471d0c86ceC208161cB4E19a2f1761AB8c4Dd#code) |
| **SettlementAttestationAdapter** | `0x5B3bA3C32786Ef156e69901Df24cB446A502C179` | `0x2B5B0519DDd2AbeFa62a7AbDc661395Ac5A8e71C` | [Proxy: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0x5B3bA3C32786Ef156e69901Df24cB446A502C179#code) · [Impl: ✅ Verified](https://sepolia-optimism.etherscan.io/address/0x2B5B0519DDd2AbeFa62a7AbDc661395Ac5A8e71C#code) |

**Roles Configured:**
- Hub MessengerAdapter RELAYER_ROLE → 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB
- SettlementAuthority MESSENGER_ROLE → Hub MessengerAdapter + SettlementAttestationAdapter
- TreasurySplitter DISTRIBUTOR_ROLE → LPVault

---

### Base Sepolia (Chain ID: 84532) - Venue Chain (Superchain)

**Deployment Date:** November 4, 2025  
**Deployer:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Admin:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Relayer:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Trader Safe:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Collateral Token (USDC):** 0x036CbD53842c5426634e7929541eC2318f3dCF7e

| Contract | Proxy Address | Implementation Address | Verification |
|----------|---------------|------------------------|--------------|
| **ProtocolConfig** | `0x62bc2708d4338f4955f7202791cdcef46dd97280` | `0xf80918ff6ccd825ad214fc71a4f1cb8f4080b919` | [Proxy: ✅ Verified](https://sepolia.basescan.org/address/0x62bc2708d4338f4955f7202791cdcef46dd97280#code) · [Impl: ✅ Verified](https://sepolia.basescan.org/address/0xf80918ff6ccd825ad214fc71a4f1cb8f4080b919#code) |
| **PauseGuardian** | `0x4e9f239a5bfda2fd565f93a4a6505a8bd5972986` | `0x6bd30c2158c9e38eaef2a8fada8375d87f1236e8` | [Proxy: ✅ Verified](https://sepolia.basescan.org/address/0x4e9f239a5bfda2fd565f93a4a6505a8bd5972986#code) · [Impl: ✅ Verified](https://sepolia.basescan.org/address/0x6bd30c2158c9e38eaef2a8fada8375d87f1236e8#code) |
| **MessengerAdapter (venue)** | `0xb42ee1571e2a4c151aa09ea8c001059d867ad96c` | `0xe9734ef9ba6115f773f7a4a46d71148ad4718386` | [Proxy: ✅ Verified](https://sepolia.basescan.org/address/0xb42ee1571e2a4c151aa09ea8c001059d867ad96c#code) · [Impl: ✅ Verified](https://sepolia.basescan.org/address/0xe9734ef9ba6115f773f7a4a46d71148ad4718386#code) |
| **BufferVault** | `0x10815B8E550ABA011Eb1e1dceF44234184f8Ed0F` | `0x8DF7cCc3F52b75bD7bE49F988e2b0A4071930d11` | [Proxy: ✅ Verified](https://sepolia.basescan.org/address/0x10815B8E550ABA011Eb1e1dceF44234184f8Ed0F#code) · [Impl: ✅ Verified](https://sepolia.basescan.org/address/0x8DF7cCc3F52b75bD7bE49F988e2b0A4071930d11#code) |
| **BetManager** | `0x34d172dba91d15495feb4000ada3e919f2848cbc` | `0x4551958ec3f5f1a09372af0c91b72220ba8737e1` | [Proxy: ✅ Verified](https://sepolia.basescan.org/address/0x34d172dba91d15495feb4000ada3e919f2848cbc#code) · [Impl: ✅ Verified](https://sepolia.basescan.org/address/0x4551958ec3f5f1a09372af0c91b72220ba8737e1#code) |
| **ReceiptRouter** | `0x42ce5d3e86b181543eda91ffc48dd6d3e2496aa0` | `0xe7cc9eaf59d9c738254ed79d07532b883811d55b` | [Proxy: ✅ Verified](https://sepolia.basescan.org/address/0x42ce5d3e86b181543eda91ffc48dd6d3e2496aa0#code) · [Impl: ✅ Verified](https://sepolia.basescan.org/address/0xe7cc9eaf59d9c738254ed79d07532b883811d55b#code) |

**Roles Configured:**
- Venue MessengerAdapter RELAYER_ROLE → 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB
- Venue MessengerAdapter BET_MANAGER_ROLE → BetManager
- BufferVault MANAGER_ROLE → BetManager
- Cross-chain wiring: Pending (to be configured after hub wiring complete)

---

### Polygon Amoy (Chain ID: 80002) - Venue Chain (Non-Superchain)

**Deployment Date:** November 4, 2025  
**Deployer:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Admin:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Relayer:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Trader Safe:** 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB  
**Collateral Token (USDC):** 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582

| Contract | Proxy Address | Implementation Address | Verification |
|----------|---------------|------------------------|--------------|
| **ProtocolConfig** | `0x18d9c48c2cec535e713f63c01ebfc810b7ce6d5e` | `0x7b568ae4cbe30d70d4ba299f0fb0615666690c2f` | [Proxy: ✅ Verified](https://amoy.polygonscan.com/address/0x18d9c48c2cec535e713f63c01ebfc810b7ce6d5e#code) · [Impl: ✅ Verified](https://amoy.polygonscan.com/address/0x7b568ae4cbe30d70d4ba299f0fb0615666690c2f#code) |
| **PauseGuardian** | `0x7a3689e6ee08702f9d4ca96ec342c7c4cc3dfbde` | `0x58e45b6ded2169d34e776e714231ccbb36d9e272` | [Proxy: ✅ Verified](https://amoy.polygonscan.com/address/0x7a3689e6ee08702f9d4ca96ec342c7c4cc3dfbde#code) · [Impl: ✅ Verified](https://amoy.polygonscan.com/address/0x58e45b6ded2169d34e776e714231ccbb36d9e272#code) |
| **MessengerAdapter (venue)** | `0x7c4af1ec357ed16ffa70ed191bfb54b4512e6202` | `0x663e869b03823bdbf00d737d113e29bd8b4f8bea` | [Proxy: ✅ Verified](https://amoy.polygonscan.com/address/0x7c4af1ec357ed16ffa70ed191bfb54b4512e6202#code) · [Impl: ✅ Verified](https://amoy.polygonscan.com/address/0x663e869b03823bdbf00d737d113e29bd8b4f8bea#code) |
| **BufferVault** | `0x2B63c2Cb2A050D58f51EAE6Da05Dea67283219A8` | `0x32FeaA5638aF1f0CDf13dD8e75f66efC93516D54` | [Proxy: ✅ Verified](https://amoy.polygonscan.com/address/0x2B63c2Cb2A050D58f51EAE6Da05Dea67283219A8#code) · [Impl: ✅ Verified](https://amoy.polygonscan.com/address/0x32FeaA5638aF1f0CDf13dD8e75f66efC93516D54#code) |
| **BetManager** | `0x62bc2708d4338f4955f7202791cdcef46dd97280` | `0xf80918ff6ccd825ad214fc71a4f1cb8f4080b919` | [Proxy: ✅ Verified](https://amoy.polygonscan.com/address/0x62bc2708d4338f4955f7202791cdcef46dd97280#code) · [Impl: ✅ Verified](https://amoy.polygonscan.com/address/0xf80918ff6ccd825ad214fc71a4f1cb8f4080b919#code) |
| **ReceiptRouter** | `0x4e9f239a5bfda2fd565f93a4a6505a8bd5972986` | `0x6bd30c2158c9e38eaef2a8fada8375d87f1236e8` | [Proxy: ✅ Verified](https://amoy.polygonscan.com/address/0x4e9f239a5bfda2fd565f93a4a6505a8bd5972986#code) · [Impl: ✅ Verified](https://amoy.polygonscan.com/address/0x6bd30c2158c9e38eaef2a8fada8375d87f1236e8#code) |

**Roles Configured:**
- Venue MessengerAdapter RELAYER_ROLE → 0xC956f740AfFa2c42c9ce59F55000e5659502EEdB
- Venue MessengerAdapter BET_MANAGER_ROLE → BetManager
- BufferVault MANAGER_ROLE → BetManager
- Cross-chain wiring: Pending (to be configured after hub wiring complete)
- **Note:** Uses ViaLabs bridge for non-Superchain messaging (fallback path)

---

## Shared Support Contracts

Support contracts (ProtocolConfig, PauseGuardian, TreasurySplitter) serve both product models and are deployed on the hub chain (Optimism Sepolia or mainnet Optimism) as shared infrastructure.

---

## Network Information

### Optimism Sepolia (Testnet)
- **Chain ID:** 11155420
- **RPC URL:** https://sepolia.optimism.io
- **Explorer:** https://sepolia-optimism.etherscan.io
- **Currency:** ETH
- **Faucet:** https://app.optimism.io/faucet

### Base Sepolia (Testnet)
- **Chain ID:** 84532
- **RPC URL:** https://sepolia.base.org
- **Explorer:** https://sepolia.basescan.org
- **Currency:** ETH
- **Faucet:** https://www.coinbase.com/faucets/base-ethereum-goerli-faucet

### Polygon Amoy (Testnet)
- **Chain ID:** 80002
- **RPC URL:** https://rpc-amoy.polygon.technology
- **Explorer:** https://amoy.polygonscan.com
- **Currency:** MATIC
- **Faucet:** https://faucet.polygon.technology

---

## Deployment Scripts

### CLOB Deployment

```bash
# Navigate to contracts directory
cd contracts

# Ensure environment variables are set in .env:
# - PRIVATE_KEY (deployer wallet)
# - OP_SEPOLIA_RPC_URL
# - STORK_ORACLE (oracle contract address)
# - COLLATERAL_TOKEN (USDC address on target chain)

# Deploy CLOB to Optimism Sepolia
forge script script/DeployCLOB.s.sol:DeployCLOB \
  --rpc-url optimism_sepolia \
  --broadcast \
  --legacy \
  --slow
```

### Aggregator Deployment

Environment variables used by `script/DeployAggregator.s.sol`:

- Common
  - PRIVATE_KEY or MNEMONIC
  - ADMIN_ADDRESS (optional; defaults to broadcaster)
  - RELAYER_ADDRESS (granted RELAYER_ROLE on MessengerAdapter)
  - COLLATERAL_TOKEN (USDC/stablecoin for LPVault on hub; optional on venue)
- HUB mode
  - MODE=HUB
  - TREASURY_ADDRESS (final fee destination; TreasurySplitter is deployed and can be set as treasury)
  - HUB_CHAIN_ID (optional; defaults to block.chainid)
  - L2_TO_L2_MESSENGER (optional; OP/Base predeploy 0x4200000000000000000000000000000000000023)
  - Optional wiring to venue: VENUE_CHAIN_ID, VENUE_ADAPTER, VENUE_BET_MANAGER, VENUE_IS_SUPERCHAIN=true|false
- VENUE mode
  - MODE=VENUE
  - TRADER_SAFE (venue trader safe EOA/Safe)
  - VENUE_CHAIN_ID (optional; defaults to block.chainid)
  - L2_TO_L2_MESSENGER (optional)
  - Optional wiring to hub: HUB_CHAIN_ID, HUB_ADAPTER, HUB_IS_SUPERCHAIN=true|false

Artifacts deployed by mode:

- HUB: ProtocolConfig, PauseGuardian, TreasurySplitter, MessengerAdapter, LPVault, StagingEscrowVault, SettlementAuthority, SettlementAttestationAdapter
- VENUE: ProtocolConfig, PauseGuardian, MessengerAdapter, BufferVault, BetManager, ReceiptRouter

Wiring notes:

- On HUB, `setSettlementAuthority(hubChainId, SettlementAuthority)` is configured on the hub adapter.
- Cross-chain wiring (remote adapter and target BetManager) is applied automatically if counterpart addresses are provided.
- On VENUE, local BetManager is registered on the adapter for `receiveBetIntent` routing.

Example flows:

- Deploy HUB (e.g., Base Sepolia as accounting chain). Provide USDC and treasury addresses.
- Deploy VENUE (e.g., Polygon Amoy). Provide TRADER_SAFE; after both sides are deployed, rerun wiring or call the setters to connect adapters in both directions.

Verification: Use `forge verify-contract` as with CLOB, pointing to the correct source file paths under `contracts/*`.

---

## Contract Verification

### Automated Verification Script

For Aggregator contracts, use the automated verification script:

```bash
# Navigate to contracts directory
cd contracts

# Run the verification script (wait 1-2 hours after deployment for testnet indexing)
./scripts/verify-aggregator.sh
```

This script will verify all deployed Aggregator contracts across:
- Optimism Sepolia (Hub)
- Base Sepolia (Venue)
- Polygon Amoy (Venue)

**Note:** Testnet block explorers may take 1-2 hours to index new deployments. If verification fails with "Could not detect the deployment", wait and try again later.

### Manual Verification

To manually verify individual contracts:

```bash
# Example for YesNoToken on OP Sepolia
forge verify-contract \
  0x7A3689E6EE08702f9d4Ca96eC342C7c4cc3DFbDe \
  contracts/clob/tokens/YesNoToken.sol:YesNoToken \
  --chain optimism-sepolia \
  --watch

# Or use the broadcast artifacts
forge verify-contract \
  --chain optimism-sepolia \
  --watch \
  --constructor-args $(cast abi-encode "constructor()" ) \
  0x7A3689E6EE08702f9d4Ca96eC342C7c4cc3DFbDe \
  contracts/clob/tokens/YesNoToken.sol:YesNoToken
```

---

## Upgrade Process

All contracts use UUPS (Universal Upgradeable Proxy Standard). To upgrade:

1. Deploy new implementation contract
2. Call `upgradeTo(address newImplementation)` on proxy via admin
3. Multi-sig approval required for production deployments

**Example:**

```solidity
// From admin wallet
IUUPSUpgradeable(proxyAddress).upgradeToAndCall(
    newImplementationAddress,
    ""  // optional initialization data
);
```

---

## Security Notes

1. **Admin Keys:** Currently held by deployer EOA (0xC956f740AfFa2c42c9ce59F55000e5659502EEdB). For production, transfer to multi-sig.
2. **Oracle Trust:** Stork oracle address (0xacC0a0cF13571d30B4b8637996F5D6D774d4fd62) is trusted for market resolution.
3. **Pause Controls:** PauseGuardian (when deployed) can emergency-pause protocol operations.
4. **Role Management:** Use OpenZeppelin AccessControl for fine-grained permissions.

---

## Mainnet Deployment Checklist

- [ ] Deploy to testnets first (CLOB on OP Sepolia ✅, Aggregator pending)
- [ ] Audit all contracts (see AUDIT_SCOPE.md)
- [ ] Set up multi-sig for admin role
- [ ] Configure pause guardian with appropriate signers
- [ ] Test cross-chain messaging on testnets
- [ ] Verify all contracts on explorers
- [ ] Update frontend with deployment addresses
- [ ] Document emergency procedures
- [ ] Set up monitoring and alerts
- [ ] Transfer admin to multi-sig
- [ ] Lock deployment scripts in version control

---

**For Questions:** Contact Predifi Protocol Team  
**Repository:** https://github.com/Predifi-com/smart-contracts  
**Documentation:** See ARCHITECTURE.md and AUDIT_SCOPE.md
