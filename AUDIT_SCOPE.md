# Predifi Smart Contracts – Audit Scope (Minimal Set)

Generated: November 12, 2025

This minimal audit scope lists only the deployable contracts requested. SLOC figures are non-comment, non-blank lines and exclude imports/pragmas.

## CLOB (Core Orderbook & Settlement)

Total SLOC: 787

- OrderBook.sol — 167
- Settlement.sol — 188
- SettlementAuthority.sol — 272
- SettlementAuthorityV2.sol — 16
- ReceiptRouter.sol — 144

## Aggregator (Cross-Chain Bet Aggregation)

Total SLOC: 1288

- StagingEscrowVault.sol — 268
- StagingEscrowVaultV2.sol — 8
- BufferVault.sol — 193
- BufferVaultV2.sol — 155
- LPVault.sol — 276
- CCTPAdapter.sol — 100
- MessengerAdapter.sol — 288

## Plus (Treasury & Fees)

Total SLOC: 326

- TreasurySplitter.sol — 214
- FeeCollector.sol — 112

---

Out of Scope: Interfaces, libraries, scripts, test contracts, and any external/vendor code not in the list above.

Purpose: Provide auditors with a narrowed code surface for sizing, scheduling, and focused review.

## Coverage (Lines)

Source: Latest unified coverage run (lcov) at generation time.

| Contract | Covered/Total | Line Coverage |
|----------|---------------|---------------|
| OrderBook.sol | 63/68 | 92.65% |
| Settlement.sol | 88/96 | 91.67% |
| SettlementAuthority.sol | 76/101 | 75.25% |
| SettlementAuthorityV2.sol | 7/10 | 70.00% |
| ReceiptRouter.sol | 57/65 | 87.69% |
| StagingEscrowVault.sol | 134/140 | 95.71% |
| StagingEscrowVaultV2.sol | 2/2 | 100.00% |
| BufferVault.sol | 99/106 | 93.40% |
| BufferVaultV2.sol | 69/73 | 94.52% |
| LPVault.sol | 141/151 | 93.38% |
| CCTPAdapter.sol | 24/25 | 96.00% |
| MessengerAdapter.sol | 90/97 | 92.78% |
| TreasurySplitter.sol | 100/112 | 89.29% |
| FeeCollector.sol | 46/50 | 92.00% |

Group Totals:
- CLOB: 291/340 = 85.59%
- Aggregator: 559/594 = 94.11%
- Plus: 146/162 = 90.12%
- Overall: 996/1096 = 90.88%

Note: Coverage percentages may drift slightly as tests evolve; auditors should regenerate with `forge coverage --ir-minimum --report lcov` for final verification.
**License:** MIT (Open Source)

**Related Documentation:**
- `README.md` - Setup and overview
- `ARCHITECTURE.md` - System design and architecture overview
- `THREAT_MODEL.md` - Security analysis and threat modeling
- `foundry.toml` - Forge configuration with optimizer settings
