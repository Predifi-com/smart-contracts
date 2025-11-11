# Predifi Smart Contract Suite

Production-grade smart contracts for the Predifi protocol - **Built for Optimism Superchain** with native L2-to-L2 messaging.

[![Test Coverage](https://img.shields.io/badge/coverage-92%25-brightgreen)](./lcov-all.info)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Foundry](https://img.shields.io/badge/built%20with-Foundry-orange.svg)](https://getfoundry.sh/)
[![Solidity](https://img.shields.io/badge/solidity-^0.8.25-363636.svg)](https://soliditylang.org/)

## 📖 Table of Contents

- [Architecture Overview](#architecture-overview)
- [Quick Start](#quick-start)
- [Building & Testing](#building--testing)
- [Deployment](#deployment)
- [Test Coverage](#test-coverage)
- [Contract Documentation](#contract-documentation)
- [Security](#security)
- [Optimism Superchain Integration](#optimism-superchain-integration)
- [Documentation](#documentation)

## Architecture Overview

The Predifi protocol offers **two distinct product models** built on shared infrastructure, with **Optimism (Chain ID 10) as the hub chain**:

### Shared Infrastructure (Optimism - Chain ID 10)
**Core Platform (Used by Both Models):**
- **ProtocolConfig**: Central configuration and parameter management (95.40% coverage)
- **LPVault**: ERC-4626 vault for LP deposits with yield distribution (**93.38% coverage** - Updated Nov 5, 2025)
- **PauseGuardian**: Emergency pause controls and circuit breakers (94.85% coverage)
- **TreasurySplitter**: Fee distribution among protocol stakeholders (95.54% coverage)

### Product Model 1: Aggregator (Cross-Chain Bet Aggregation)
**Purpose**: Enables users to bet on external prediction markets (Polymarket, Limitless, etc.) with unified cross-chain liquidity.

**Hub Components (Optimism):**
- **SettlementAuthority**: Settlement attestation gateway (100% coverage)
- **StagingEscrowVault**: Reserve and release funds per order (94.23% coverage)
- **SettlementAttestationAdapter**: Off-chain attestation validation (46.15% coverage)
- **MessengerAdapter**: Cross-chain message routing (100% coverage)

**Venue Components (Base, Polygon, etc.):**
- **BetManager**: Processes bet intents and manages fund releases (96.47% coverage)
- **MessengerAdapter**: Cross-chain messaging coordination (100% coverage)
- **BufferVault**: Token buffer for enhanced liquidity (**92.45% coverage** - Updated Nov 5, 2025)
- **ReceiptRouter**: Venue receipt processing and forwarding (92.31% coverage)

### Product Model 2: Native CLOB (Predifi's Own Prediction Market)
**Purpose**: Predifi's native prediction market with off-chain matching and on-chain settlement for optimal price discovery and gas efficiency.

**CLOB Components (Any Chain - typically Optimism or Base):**
- **MarketFactory**: Create and manage prediction markets (90.28% coverage)
- **OrderBook**: Order management with EIP-712 signatures (92.65% coverage)
- **Settlement**: Trade settlement and position management (91.67% coverage)
- **OracleAdapter**: Stork oracle integration for resolution (90.32% coverage)
- **FeeCollector**: Protocol fee management (92.00% coverage)
- **YesNoToken**: ERC1155 position tokens (91.18% coverage)

**📚 Detailed Architecture:** See [ARCHITECTURE.md](./ARCHITECTURE.md)  
**🔒 Security Model:** See [THREAT_MODEL.md](./THREAT_MODEL.md)  
**🔍 Audit Scope:** See [AUDIT_SCOPE.md](./AUDIT_SCOPE.md)

## Key Features

### Product Model 1: Aggregator
Enables betting on external prediction markets (Polymarket, Limitless) with cross-chain liquidity:
- **Cross-Chain Bet Aggregation**: Unified liquidity across Optimism, Base, Polygon, etc.
- **Dual Messaging**: Optimism Superchain L2-to-L2 (primary) + ViaLabs (fallback)
- **ERC-4626 LP Vault**: Standard compliant liquidity provision for liquidity providers
- **Settlement Authority**: Attestation-based settlement verification
- **External Market Integration**: Connect to multiple prediction market venues

### Product Model 2: Native CLOB
Predifi's own prediction market with superior price discovery:
- **Off-chain Matching, On-chain Settlement**: Gas-efficient order execution
- **EIP-712 Signed Orders**: Secure off-chain order matching with on-chain verification
- **ERC1155 Position Tokens**: Transferable YES/NO position tokens
- **Stork Oracle Integration**: Decentralized, tamper-proof market resolution
- **Fee-on-Resolve**: Winners pay fees only when claiming (2% default, 5% max)
- **Central Limit Order Book**: Professional trading experience with full orderbook

### Shared Infrastructure (Both Models)
- **UUPS Upgradeable**: All contracts use OpenZeppelin's UUPS proxy pattern
- **Role-Based Access Control**: Granular permission system with 8+ roles
- **Emergency Controls**: Comprehensive pause and recovery mechanisms
- **Optimism Native**: Built specifically for OP Stack chains with native L2-L2 messaging

## Quick Start

### Prerequisites

1. **Install Foundry**
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

2. **Install Dependencies**
```bash
forge install
```

3. **Set up Environment**
```bash
cp .env.example .env
# Edit .env with your configuration
```

## Building & Testing

### Build All Contracts
```bash
forge build
```

### Run Tests

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/unit/EscrowVault.t.sol

# Run specific test contract
forge test --match-contract MessengerAdapter

# Run with gas reporting
forge test --gas-report
```

### Test Coverage

```bash
# Generate coverage report
forge coverage --no-match-coverage "(test|script|mock)"

# Coverage for specific contracts
forge coverage --match-contract "BufferVault|LPVault"

# View detailed coverage
forge coverage --report lcov
genhtml lcov.info -o coverage-report
open coverage-report/index.html
```

**Current Test Coverage (24 test files, comprehensive suite):**

**CLOB Contracts:**
- MarketFactory: 90.28% ✅
- OrderBook: 92.65% ✅
- Settlement: 91.67% ✅
- FeeCollector: 92.00% ✅
- OracleAdapter: 90.32% ✅
- YesNoToken: 91.18% ✅

**Aggregator Contracts:**
- MessengerAdapter: 100% ✅
- LPVault: 98.81% ✅
- BufferVault: 92.31% ✅
- BetManager: 96.47% ✅
- StagingEscrowVault: 94.23% ✅
- SettlementAuthority: 100% ✅
- ReceiptRouter: 92.31% ✅

**Support Contracts:**
- ProtocolConfig: 95.40% ✅
- PauseGuardian: 94.85% ✅
- TreasurySplitter: 95.54% ✅

**Overall Average:** ~92% line coverage across 18 deployable contracts

**📊 Detailed Coverage Reports:** 
- `lcov-all.info` - Full protocol coverage (CLOB + Aggregator)
- `lcov-unit.info` - Unit test coverage (Aggregator + Support)
- See [AUDIT_SCOPE.md](./AUDIT_SCOPE.md) for detailed breakdown

## Deployment

### Environment Setup

Required environment variables:
```bash
# Deployer wallet
PRIVATE_KEY=your_deployer_private_key

# RPC URLs
OPTIMISM_RPC_URL=https://mainnet.optimism.io
BASE_RPC_URL=https://mainnet.base.org
POLYGON_RPC_URL=https://polygon-rpc.com

# Block explorers (for verification)
OPTIMISM_ETHERSCAN_API_KEY=your_optimism_api_key
BASE_ETHERSCAN_API_KEY=your_base_api_key
POLYGON_ETHERSCAN_API_KEY=your_polygonscan_api_key

# Protocol Configuration
HUB_CHAIN_ID=10  # Optimism
```

### Deployment Scripts

**Deploy Hub Contracts (Optimism)**
```bash
forge script script/DeployHub.s.sol \
  --rpc-url $OPTIMISM_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

This deploys:
- ProtocolConfig
- LPVault (ERC-4626)
- PauseGuardian
- TreasurySplitter

**Deploy Venue Contracts (e.g., Base)**
```bash
forge script script/DeployVenue.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

This deploys:
- BetManager
- MessengerAdapter
- BufferVault (optional)

**Deploy Origin Contracts (e.g., Polygon)**
```bash
forge script script/DeployOrigin.s.sol \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

This deploys:
- EscrowVault
- MessengerAdapter

### Post-Deployment Configuration

After deployment, configure cross-chain routing:

```bash
# Configure MessengerAdapter on each chain
forge script script/ConfigureMessenger.s.sol \
  --rpc-url $OPTIMISM_RPC_URL \
  --broadcast
```

**📋 Deployment Checklist:** See `docs/DEPLOYMENT.md` for comprehensive checklist

## Optimism Superchain Integration

Predifi is **natively built for the OP Superchain**, using the L2-to-L2 cross-domain messenger for seamless communication between OP Stack chains.

### Supported Superchain Networks
- **Base** (Chain ID: 8453)
- **Optimism** (Chain ID: 10)
- **Mode** (Chain ID: 34443)
- **Zora** (Chain ID: 7777777)
- **Other OP Stack chains**: Coming soon

### L2ToL2CrossDomainMessenger
- **Predeploy Address**: `0x4200000000000000000000000000000000000023` (same on all OP Stack chains)
- **Configured via**: `MessengerAdapter.setL2ToL2Messenger()`
- **Chain routing**: Use `MessengerAdapter.setChainType(chainId, true)` to mark chains as Superchain

### Example Configuration
```solidity
// On Base (8453)
messengerAdapter.setL2ToL2Messenger(0x4200000000000000000000000000000000000023);
messengerAdapter.setChainType(10, true);  // Mark Optimism as Superchain
messengerAdapter.setChainType(34443, true);  // Mark Mode as Superchain
messengerAdapter.setRemoteAdapter(10, optimismMessengerAddr);
messengerAdapter.setRemoteAdapter(34443, modeMessengerAddr);

// For non-Superchain (e.g., Polygon)
messengerAdapter.setChainType(137, false);  // Mark as non-Superchain (uses ViaLabs)
messengerAdapter.setRemoteAdapter(137, polygonMessengerAddr);
```

## Contract Addresses

Deployment addresses are saved to `deployments/` directory:
- `hub-deployment-{chainId}.json`: Hub chain contracts
- `venue-deployment-{chainId}.json`: Venue chain contracts  
- `origin-deployment-{chainId}.json`: Origin chain contracts

## Cross-Chain Testing

This repository includes comprehensive cross-chain testing infrastructure demonstrating OP Stack Superchain interoperability:

### CrossChainPingPong Reference Implementation
**File**: `contracts/interop/CrossChainPingPong.sol`

A reference contract demonstrating L2ToL2CrossDomainMessenger usage across:
- OP Mainnet (10), Base (8453), World Chain (480), Celo (42220)
- Future: Unichain, Ink

**Test**: `forge test --match-contract CrossChainPingPong`

### Documentation
- `CROSS_CHAIN_TESTING.md` - Comprehensive testing guide (100+ test cases documented)
- `CROSSCHAIN_SUMMARY.md` - Implementation summary and YesNoToken SuperchainERC20 analysis

## Testing

### Running Tests

```bash
# All tests
forge test

# Specific contract
forge test --match-contract CrossChainPingPong
forge test --match-contract BetManager
```

### Coverage

To generate a coverage report for unit tests (avoiding stack-too-deep issues):

```bash
cd coverage_proj
forge coverage --no-match-path "lib/**"
```

This will show line coverage for:

## ABI Generation

Generate ABIs for backend integration:
```bash
# Generate all ABIs
forge build

# Copy ABIs to backend (adjust path as needed)
cp out/*/contracts/**/*.sol/*.json ../backend/src/abi/

# Generate TypeChain typings
cd ../backend && npm run generate-types
```

## Contract Interactions

### User Flow Example

1. **Deposit** (Origin Chain):
```solidity
escrowVault.depositForBet(
    tokenAddress,
    amount,
    marketId,
    outcomeId,
    targetChainId,
    expiry
);
```

2. **Cross-Chain Intent** (Automatic):
   - MessengerAdapter sends intent to venue chain
   - BetManager processes intent and releases funds

3. **Settlement** (Venue Chain):
```solidity
betManager.recordFill(releaseId, proceedsToken, proceedsAmount, venueOrderId);
```

### LP Operations

```solidity
// Deposit to LP vault
lpVault.deposit(amount, receiver);

// Withdraw from LP vault
lpVault.withdraw(assets, receiver, owner);

// Check vault performance
uint256 totalAssets = lpVault.totalAssets();
uint256 sharePrice = lpVault.convertToAssets(1e18);
```

## Configuration

### Protocol Parameters
- `minBetAmount`: Minimum bet size
- `maxBetAmount`: Maximum bet size  
- `baseFeeRate`: Base protocol fee (basis points)
- `treasuryFeeRate`: Treasury allocation (basis points)
- `lpYieldRate`: LP yield rate (basis points)

### Chain Configuration
Each supported chain requires:
- Messenger adapter address
- Supported tokens list
- Emergency pause controls

## Security

### Access Control
- `DEFAULT_ADMIN_ROLE`: Contract administration
- `MESSENGER_ROLE`: Cross-chain message handling
- `OPERATOR_ROLE`: Operational functions
- `PAUSE_ROLE`: Emergency pause controls

### Emergency Functions
- Global protocol pause
- Chain-specific pause
- Contract-specific pause
- Emergency token withdrawal

### Upgradeability
All contracts use UUPS upgradeable pattern with admin-only upgrade authorization.

## Gas Optimization

- Packed structs for cross-chain messages
- Batch operations where possible
- Optimized storage layouts
- Events for off-chain indexing

## Monitoring

### Key Events
- `BetDeposited`: User deposits tracked
- `BetPlaced`: Cross-chain intents
- `BetSettled`: Settlement completions
- `FeesDistributed`: Treasury operations

### Metrics to Track
- Total value locked (TVL)
- Cross-chain message success rate
- Fee collection and distribution
- LP vault performance

## Development

### Pre-commit Hooks
```bash
# Install pre-commit
pip install pre-commit
pre-commit install

# Manual run
pre-commit run --all-files
```

### Code Style
- Solidity: Follow official style guide
- Comments: NatSpec format for all public functions
- Testing: Comprehensive unit and integration tests

## License

MIT License - see LICENSE file for details.