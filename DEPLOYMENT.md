# Predifi Smart Contract Deployments

## Hedera Mainnet (Chain ID: 295)

**Network:** Hedera Mainnet  
**RPC URL:** `https://mainnet.hashio.io/api`  
**Deployer:** `0x4900C7F3c4Bc8598DdbeD62dE9afa4C9bBC58852`  
**Hedera Operator ID:** [`0.0.10474070`](https://hashscan.io/mainnet/account/0.0.10474070)  
**Deployed At:** 2026-05-12

---

### USDC (Mock HTS Token)

| | Hedera ID | EVM Address |
|---|---|---|
| **Token** | [`0.0.10474083`](https://hashscan.io/mainnet/token/0.0.10474083) | `0x00000000000000000000000000000000009fd263` |

---

### Core Contracts

| Contract | Proxy | Implementation |
|---|---|---|
| **PredifiAdmin** | [`0x0C38Fa015B78C607E1186C7d539AEDecBd20DA2d`](https://hashscan.io/mainnet/contract/0x0C38Fa015B78C607E1186C7d539AEDecBd20DA2d) | [`0xa9F63AfE29e45DF9fa3bA3cb348367E6F4a61b6e`](https://hashscan.io/mainnet/contract/0xa9F63AfE29e45DF9fa3bA3cb348367E6F4a61b6e) |
| **PredifiPool** *(Vault)* | [`0x7d904E415Ba721972799B64F63E671C4f4E0779c`](https://hashscan.io/mainnet/contract/0x7d904E415Ba721972799B64F63E671C4f4E0779c) | [`0xbb3644d9373218e65439eFeB7E5e3050D298Efe9`](https://hashscan.io/mainnet/contract/0xbb3644d9373218e65439eFeB7E5e3050D298Efe9) |
| **MarketRegistry** | [`0x7AAc52bc92cb964Bedc3A1F636fff6381930D22B`](https://hashscan.io/mainnet/contract/0x7AAc52bc92cb964Bedc3A1F636fff6381930D22B) | [`0x583f9733c3d5b67e026CBa3073EAeDF7268eddfC`](https://hashscan.io/mainnet/contract/0x583f9733c3d5b67e026CBa3073EAeDF7268eddfC) |
| **MatchSettlement** | [`0x49C38149AD23374d7c07B2df4ceDeF0DE33f0C45`](https://hashscan.io/mainnet/contract/0x49C38149AD23374d7c07B2df4ceDeF0DE33f0C45) | [`0xE50C235A3f794610e2D6d56Cae7e80ff8F11D2c1`](https://hashscan.io/mainnet/contract/0xE50C235A3f794610e2D6d56Cae7e80ff8F11D2c1) |
| **OracleModule** | [`0x2CC534b3d3BDa6c6697849e09Ae393ea1b135686`](https://hashscan.io/mainnet/contract/0x2CC534b3d3BDa6c6697849e09Ae393ea1b135686) | [`0xf4922bc3d08eAff62Dd2Fa8Af79035CE91FD6f0b`](https://hashscan.io/mainnet/contract/0xf4922bc3d08eAff62Dd2Fa8Af79035CE91FD6f0b) |
| **AdminOracle** | [`0x198127f0d2C994B457d06F9e353Fd6A8DC20f24B`](https://hashscan.io/mainnet/contract/0x198127f0d2C994B457d06F9e353Fd6A8DC20f24B) | [`0xF2FF1Fe33b04bE898F3782F5a1d1AF8b51a28249`](https://hashscan.io/mainnet/contract/0xF2FF1Fe33b04bE898F3782F5a1d1AF8b51a28249) |
| **RouterFactory** | *(no proxy)* | [`0x339414f14D6fdf2Acc67E217E5e9519feFc89b9e`](https://hashscan.io/mainnet/contract/0x339414f14D6fdf2Acc67E217E5e9519feFc89b9e) |

---

### HCS (Hedera Consensus Service) Topics

All market activity is published as an on-chain audit trail to three HCS topics. Messages are visible publicly on HashScan in real time.

| Topic | Hedera ID | HashScan | Events Published |
|---|---|---|---|
| **market_events** | `0.0.10474131` | [View on HashScan](https://hashscan.io/mainnet/topic/0.0.10474131) | `MARKET_CREATED`, `MARKET_RESOLVED` |
| **trade_events** | `0.0.10474129` | [View on HashScan](https://hashscan.io/mainnet/topic/0.0.10474129) | `TRADE_FILLED` |
| **settlement_batches** | `0.0.10474130` | [View on HashScan](https://hashscan.io/mainnet/topic/0.0.10474130) | `BATCH_SETTLED`, `WITHDRAWAL_COMPLETED` |

---

### What Gets Published On-Chain

| User Action | On-Chain Activity | Where to See It |
|---|---|---|
| Admin creates a market | `registerMarket()` call on **MarketRegistry** + `MARKET_CREATED` message on `market_events` HCS topic | HashScan contract tx + HCS topic |
| User places a trade (bot match) | `TRADE_FILLED` message on `trade_events` HCS topic (off-chain settlement; bot has no on-chain USDC) | HCS topic |
| User↔User trade match | `batchSettle()` call on **MatchSettlement** contract + `BATCH_SETTLED` on `settlement_batches` HCS topic | HashScan contract tx + HCS topic |
| Admin resolves a market | `resolveMarket()` call on **AdminOracle/OracleModule** + `MARKET_RESOLVED` on `market_events` HCS topic | HashScan contract tx + HCS topic |
| User withdraws USDC | `withdraw()` call on **PredifiPool** vault + `WITHDRAWAL_COMPLETED` on `settlement_batches` HCS topic | HashScan contract tx + HCS topic |
| New user signs in | `deployRouter()` on **RouterFactory** — deploys a personal **UserRouter** contract | HashScan factory tx |

---

### Contract Verification

Contracts can be verified on HashScan via [Sourcify](https://sourcify.dev). Compiler settings:

| Setting | Value |
|---|---|
| Compiler | `solc 0.8.25` |
| EVM Version | `paris` |
| Optimizer | enabled, 200 runs |
| Framework | Foundry |

**Verify with Foundry:**
```bash
# Example: verify PredifiPool proxy
forge verify-contract \
  --chain-id 295 \
  --verifier sourcify \
  --verifier-url https://sourcify.hashscan.io \
  0x7d904E415Ba721972799B64F63E671C4f4E0779c \
  src/PredifiPool.sol:PredifiPool \
  --watch
```

Alternatively, paste the **standard JSON input** (from `out/<Contract>.sol/<Contract>.json`) directly into the HashScan contract page → *Verify Contract* tab.

> **Note:** Proxy contracts (ERC-1967 UUPS) should be verified as the proxy bytecode. HashScan will auto-detect the proxy pattern and display the implementation ABI once the implementation is also verified.

---

---

## Hedera Testnet (Chain ID: 296)

**Network:** Hedera Testnet  
**RPC URL:** `https://testnet.hashio.io/api`  
**Deployer:** `0xa2ae1dade3457802c1678d17ccc56687a6abd53a`  
**Hedera Operator ID:** `0.0.8220981`  
**Deployed At:** 2026-05-11

---

### USDC (Mock HTS Token)

| | Address |
|---|---|
| **Token** | [`0x00000000000000000000000000000000007d7a6E`](https://hashscan.io/testnet/token/0x00000000000000000000000000000000007d7a6E) |

---

### Core Contracts

| Contract | Proxy | Implementation |
|---|---|---|
| **PredifiAdmin** | [`0xc8Dc22D6EEb354e2F7Ac781d8e5ff1b23996221e`](https://hashscan.io/testnet/contract/0xc8Dc22D6EEb354e2F7Ac781d8e5ff1b23996221e) | [`0x09Cfd1F2D67F43adcF6C22b6dAd3fbeb74Fa66c0`](https://hashscan.io/testnet/contract/0x09Cfd1F2D67F43adcF6C22b6dAd3fbeb74Fa66c0) |
| **PredifiPool** *(Vault)* | [`0x25A4d9e112AE3d46C14B6f842dFa1da7b35302c6`](https://hashscan.io/testnet/contract/0x25A4d9e112AE3d46C14B6f842dFa1da7b35302c6) | [`0x30268e6161FFb927940Efb8e4aD2295B171ca87a`](https://hashscan.io/testnet/contract/0x30268e6161FFb927940Efb8e4aD2295B171ca87a) |
| **MarketRegistry** | [`0x8cF89FF3F5F106519dfeD86AbD0B896C5accF1cB`](https://hashscan.io/testnet/contract/0x8cF89FF3F5F106519dfeD86AbD0B896C5accF1cB) | [`0xE59b88866E6Cd9854F9B8b6e40856B10B12e113A`](https://hashscan.io/testnet/contract/0xE59b88866E6Cd9854F9B8b6e40856B10B12e113A) |
| **MatchSettlement** | [`0xfd0000D637F66621DBEbB3e83f388133B3e90EF4`](https://hashscan.io/testnet/contract/0xfd0000D637F66621DBEbB3e83f388133B3e90EF4) | [`0x7B68552D07c09Ff4D57363771D623EdB2a55d73E`](https://hashscan.io/testnet/contract/0x7B68552D07c09Ff4D57363771D623EdB2a55d73E) |
| **OracleModule** | [`0x8CAfD20BD94444006Bd426DF9dDdDaF64684FbA0`](https://hashscan.io/testnet/contract/0x8CAfD20BD94444006Bd426DF9dDdDaF64684FbA0) | [`0x6A2B7F6bBd23AD9283e3795C372dbA8991CAC456`](https://hashscan.io/testnet/contract/0x6A2B7F6bBd23AD9283e3795C372dbA8991CAC456) |
| **AdminOracle** | [`0xAFf7e01f3a2d5E5d2E5b390739d1BC86A4978b50`](https://hashscan.io/testnet/contract/0xAFf7e01f3a2d5E5d2E5b390739d1BC86A4978b50) | [`0x897d7cB489b6d61C63C5bCec538e5A30549183B4`](https://hashscan.io/testnet/contract/0x897d7cB489b6d61C63C5bCec538e5A30549183B4) |
| **RouterFactory** | *(no proxy)* | [`0xD8BcD8f35A20B46513A97D7893DACD75c7fC2A31`](https://hashscan.io/testnet/contract/0xD8BcD8f35A20B46513A97D7893DACD75c7fC2A31) |

---

### Verification

All contracts are verifiable on [HashScan Testnet Explorer](https://hashscan.io/testnet) using the same Sourcify method described in the Mainnet section above (use `--chain-id 296`).
