# Predifi Protocol Architecture

**Version:** 1.1  
**Date:** November 4, 2025  
**Status:** Updated (Aggregator + CLOB aligned)

## Table of Contents

- [Overview](#overview)
- [Hub-and-Spoke Model](#hub-and-spoke-model)
- [Core Components](#core-components)
- [CLOB (Core Orderbook & Settlement)](#clob-core-orderbook--settlement)
- [Cross-Chain Communication](#cross-chain-communication)
- [User Flow](#user-flow)
- [Security Architecture](#security-architecture)
- [Upgrade Strategy](#upgrade-strategy)
- [Economic Model](#economic-model)

## Overview

Predifi is a **dual-model prediction market protocol** built natively for the **Optimism Superchain**. The protocol offers two distinct product lines:

1. **Aggregator Model**: Cross-chain bet aggregation across multiple prediction market venues (Polymarket, Limitless, etc.). Coordinates funds across chains, releases liquidity to external venues, and reconciles settlements via attestations.

2. **Native CLOB Model**: Predifi's own prediction market powered by a **Central Limit Order Book (CLOB)** with off-chain matching and on-chain settlement. Built for optimal price discovery and gas efficiency.

Both models share the same underlying infrastructure (ProtocolConfig, PauseGuardian, TreasurySplitter) but serve different use cases and can operate independently.

### Key Design Principles

1. **Security First**: Multi-signature controls, emergency pause, comprehensive access control
2. **Optimism Native**: Built for OP Stack L2-to-L2 messaging with ViaLabs fallback
3. **Upgradeable**: UUPS pattern for all contracts with admin-controlled upgrades
4. **ERC-4626 Standard**: Standard vault interface for LP deposits
5. **Gas Efficient**: Optimized for L2 deployment with minimal storage and computation

## Hub-and-Spoke Model

```
                    ┌─────────────────────────┐
                    │   Shared Infrastructure │
                    │     (Optimism - ID: 10) │
                    │                         │
                    │  ┌──────────────────┐   │
                    │  │  ProtocolConfig  │   │
                    │  └──────────────────┘   │
                    │  ┌──────────────────┐   │
                    │  │    LPVault       │   │
                    │  │   (ERC-4626)     │   │
                    │  └──────────────────┘   │
                    │  ┌──────────────────┐   │
                    │  │ PauseGuardian    │   │
                    │  └──────────────────┘   │
                    │  ┌──────────────────┐   │
                    │  │TreasurySplitter  │   │
                    │  └──────────────────┘   │
                    └─────────────────────────┘
                              │
              ┌───────────────┴─────────────────────────┐
              │                                         │
              ▼                                         ▼
    ┌──────────────────────┐               ┌───────────────────────┐
    │  AGGREGATOR MODEL    │               │   NATIVE CLOB MODEL   │
    │  (Cross-Chain Bets)  │               │  (Predifi Markets)    │
    │                      │               │                       │
    │ Hub (OP Sepolia):    │               │ Deployment Chain:     │
    │ - SettlementAuth     │               │ - MarketFactory       │
    │ - StagingEscrow      │               │ - OrderBook           │
    │ - MessengerAdapter   │               │ - Settlement          │
    │                      │               │ - OracleAdapter       │
    │ Venues (Base, etc.): │               │ - FeeCollector        │
    │ - BetManager         │               │ - YesNoToken          │
    │ - MessengerAdapter   │               │                       │
    │ - BufferVault        │               │                       │
    │ - ReceiptRouter      │               │                       │
    └──────────────────────┘               └───────────────────────┘
```

### Product Models

#### Model 1: Aggregator (Cross-Chain Bet Aggregation)
**Purpose**: Enable users to bet on external prediction markets (Polymarket, Limitless) with unified liquidity

**Chains**:
- **Hub (Optimism)**: Central coordination and settlement authority
- **Venues (Base, Polygon, etc.)**: Execute bets on external markets

**User Flow**: User deposits → Hub routes bet intent → Venue executes on external market → Settlement reconciled

#### Model 2: Native CLOB (Predifi's Own Prediction Market)
**Purpose**: Predifi's native prediction market with optimal price discovery and gas-efficient settlement

**Deployment**: Can be deployed on any chain (typically Optimism or Base)

**User Flow**: User places order (off-chain) → Order matched (off-chain) → Trade settled (on-chain) → Winner claims payout

### Chain Roles

#### Shared Infrastructure Chain (Optimism)
**Role**: Central configuration and liquidity management for both models

**Contracts**:
- `ProtocolConfig`: Global parameters, supported chains, token whitelist
- `LPVault`: ERC-4626 vault for LP deposits (used by Aggregator model)
- `PauseGuardian`: Emergency pause controls
- `TreasurySplitter`: Fee collection and distribution

**Serves**: Both Aggregator and CLOB models

#### Aggregator - Venue Chains (Base, Polygon, etc.)
**Role**: Execute bets on external prediction markets

**Contracts**:
- `BetManager`: Processes bet intents, manages fund releases, records settlements
- `MessengerAdapter`: Cross-chain message routing (Superchain or ViaLabs)
- `BufferVault`: Optional liquidity buffer for immediate bet fulfillment

**Responsibilities**:
- Receive bet intents from origin chains
- Release funds to venue markets (Polymarket, Limitless)
- Track bet fills and settlements
- Send settlement data back to origin chains
- Manage venue-specific liquidity

#### Accounting Chains (Settlement)
**Role**: Settlement attestation intake and authorization; centralized accounting where applicable

**Contracts**:
- `SettlementAttestationAdapter`: Validates off-chain attestations (signatures/proofs)
- `SettlementAuthority`: Messenger-gated entrypoint that authorizes or triggers accounting actions

**Responsibilities**:
- Accept and validate settlement attestations
- Gate settlement/authorization calls to protect trust boundaries
- Coordinate with venue-side components (e.g., confirm releases)

## Core Components

### 1. ProtocolConfig (Hub)

**Location**: `contracts/config/ProtocolConfig.sol`  
**Coverage**: 95.40% lines, 95.83% functions

**Purpose**: Central configuration registry for the entire protocol

**Key Functions**:
```solidity
// Chain management
function addSupportedChain(uint256 chainId, ChainConfig config)
function removeSupportedChain(uint256 chainId)
function updateChainConfig(uint256 chainId, ChainConfig config)

// Token management  
function whitelistToken(address token, TokenConfig config)
function blacklistToken(address token)

// Parameter management
function setMinBetAmount(uint256 amount)
function setMaxBetAmount(uint256 amount)
function setProtocolFeeRate(uint256 bps)
```

**Storage**:
- `supportedChains`: Mapping of chain ID → ChainConfig
- `whitelistedTokens`: Mapping of token address → TokenConfig
- `globalParams`: Protocol-wide parameters (fees, limits)

**Access Control**:
- `DEFAULT_ADMIN_ROLE`: Full configuration access
- `CONFIG_MANAGER_ROLE`: Parameter updates
- `PAUSE_ROLE`: Emergency pause

### 2. LPVault (Hub)

**Location**: `contracts/vault/LPVault.sol`  
**Coverage**: 98.81% lines, 94.44% functions

**Purpose**: ERC-4626 compliant vault for LP deposits with yield distribution

**Key Functions**:
```solidity
// ERC-4626 standard
function deposit(uint256 assets, address receiver) returns (uint256 shares)
function mint(uint256 shares, address receiver) returns (uint256 assets)
function withdraw(uint256 assets, address receiver, address owner) returns (uint256 shares)
function redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)

// Yield management
function distributeYield(uint256 amount) onlyRole(BET_MANAGER_ROLE)
function collectFees() onlyRole(TREASURY_ROLE)
function setProtocolFeeBps(uint256 bps) onlyRole(DEFAULT_ADMIN_ROLE)

// Emergency
function emergencyWithdraw(address token, address to) onlyRole(DEFAULT_ADMIN_ROLE)
```

**Economic Model (Aggregator)**:
- LPs deposit USDC/USDT
- Protocol distributes yield from successful bets
- Protocol fee: 0.05-0.1% (admin-configurable, much lower for aggregation)
- Share price increases as yield accumulates
- Fair share calculation prevents sandwich attacks

**Security Features**:
- Pausable deposits/withdrawals
- Allowance-based withdrawals by BetManager
- Reentrancy protection
- Maximum slippage checks

### 3. StagingEscrowVault (Venue Chains)

**Location**: `contracts/escrow/StagingEscrowVault.sol`  
**Coverage**: 94.23% lines, 77.78% functions

**Purpose**: Reserve and release funds per orderId with caps, expiry, and cancellation; supports partial fills and refunds; pause-guarded.

**Key Functions (illustrative)**:
```solidity
function reserve(bytes32 orderId, address token, uint256 amount, uint64 expiry) onlyRole(DEFAULT_ADMIN_ROLE)
function release(bytes32 orderId, address token, uint256 amount) onlyRole(DEFAULT_ADMIN_ROLE)
function cancel(bytes32 orderId) onlyRole(DEFAULT_ADMIN_ROLE)
```

**Behavior**:
- Enforces per-order caps and expiries
- Allows partial release and cancellation/refund
- Integrates with BetManager/BufferVault for liquidity

### 4. BetManager (Venue Chains)

**Location**: `contracts/manager/BetManager.sol`  
**Coverage**: 96.47% lines, 93.75% functions

**Purpose**: Process bet intents and manage venue interactions

**Key Functions**:
```solidity
// Intent processing
function handleBetIntent(BetIntent calldata intent) 
    onlyRole(MESSENGER_ROLE) 
    returns (bytes32 releaseId)

// Settlement recording
function recordFill(
    bytes32 releaseId,
    address proceedsToken,
    uint256 proceedsAmount,
    string calldata venueOrderId
) onlyRole(OPERATOR_ROLE)

// Fund management
function releaseFunds(
    bytes32 releaseId,
    address token,
    uint256 amount,
    address recipient
) returns (bool success)
```

**Release Management**:
- Each intent creates a release ID
- Funds released from BufferVault or LPVault
- Settlement data recorded and sent back to origin
- Proceeds collected and distributed

### 5. MessengerAdapter (All Chains)

**Location**: `contracts/manager/MessengerAdapter.sol`  
**Coverage**: 97.03% lines, 100% functions

**Purpose**: Cross-chain message routing with dual-path support

**Key Functions**:
```solidity
// Send messages
function sendBetIntent(BetIntent calldata intent, uint256 targetChainId) 
    returns (bytes32 messageId)
function sendSettlement(bytes32 intentId, SettlementData calldata data, uint256 targetChainId)
function sendStatusUpdate(bytes32 intentId, IntentState state, uint256 targetChainId)

// Receive messages
function receiveBetIntent(bytes32 messageId, uint256 sourceChainId, BetIntent calldata intent)
function receiveSettlement(bytes32 messageId, uint256 sourceChainId, bytes32 intentId, SettlementData calldata data)

// Configuration
function setRemoteAdapter(uint256 chainId, address adapter)
function setL2ToL2Messenger(address messenger)
function setChainType(uint256 chainId, bool isSuperchain)
```

**Routing Logic**:
```solidity
if (isSuperchainId[targetChainId]) {
    // Use Optimism L2ToL2CrossDomainMessenger
    IL2ToL2CrossDomainMessenger(l2ToL2Messenger).sendMessage{value: msg.value}(
        targetChainId,
        remoteAdapters[targetChainId],
        abi.encodeCall(this.receiveBetIntent, (messageId, block.chainid, intent))
    );
} else {
    // Use ViaLabs or other bridge
    emit FallbackMessageSent(messageId, targetChainId, data);
}
```

**Message Tracking**:
- `processedMessages`: Prevents replay attacks
- `messageStatuses`: Track message lifecycle
- `MessageStatus` struct: Type, chains, timestamp, processed flag

### 6. BufferVault (Venue Chains)
### 7. SettlementAuthority (Interop)

**Location**: `contracts/interop/SettlementAuthority.sol`  
**Coverage**: 100.00% lines, 100.00% functions

**Purpose**: Messenger-gated settlement entrypoint that authorizes settlement actions; pausable and upgradeable.

**Key Points**:
- Only trusted MessengerAdapter(s) may call settlement functions
- Emits settlement events and coordinates with venue-side components

### 8. SettlementAttestationAdapter (Interop)

**Location**: `contracts/interop/SettlementAttestationAdapter.sol`  
**Coverage**: dedicated unit tests pending; see audit scope for current figure

**Purpose**: Minimal on-chain adapter that accepts validated attestations and forwards them to SettlementAuthority on the accounting chain. Permissioned submission.

### 9. ReceiptRouter (Venue)

**Location**: `contracts/venue/ReceiptRouter.sol`  
**Coverage**: 92.31% lines, 66.67% functions

**Purpose**: Receives venue receipts, forwards to user destinations, and optionally triggers attestations; validates sender and payload.

## CLOB (Core Orderbook & Settlement)

Predifi includes a native CLOB deployed as upgradeable contracts with off-chain matching and on-chain settlement. Key properties:

- ERC1155 position tokens (YES/NO) with `YesNoToken`
- EIP-712 orders; off-chain matching; on-chain settlement
- Fee-on-resolve: default 2% with a 5% cap, configurable
- Upgradeability via UUPS (OpenZeppelin v5)

Core Contracts:
- `MarketFactory`: Market creation, lifecycle, per-market config/oracle binding
- `OrderBook`: On-chain order registry, nonce management, signature verification
- `Settlement`: Collateral accounting, position mint/burn, settlement logic
- `OracleAdapter`: Stork-like adapter for resolution attestations (EIP-712)
- `FeeCollector`: Fee calculations and withdrawals
- `YesNoToken`: ERC1155 YES/NO positions

**Location**: `contracts/vault/BufferVault.sol`  
**Coverage**: 92.31% lines, 82.35% functions

**Purpose**: Liquidity buffer for immediate bet execution

**Key Functions**:
```solidity
// Funding
function fundBuffer(address token, uint256 amount)
function receiveProceeds(address token, uint256 amount)

// Spending
function spendTo(address token, uint256 amount, address recipient) 
    onlyRole(MANAGER_ROLE)

// Caps
function setCap(address token, uint256 cap) 
    onlyRole(DEFAULT_ADMIN_ROLE)
```

**Buffer Strategy**:
- Pre-funded with stablecoins for immediate execution
- Cap per token prevents over-allocation
- Proceeds flow back from venue to buffer
- Excess can be swept to LPVault

## Cross-Chain Communication

### Optimism Superchain (Primary)

**Technology**: L2ToL2CrossDomainMessenger  
**Predeploy Address**: `0x4200000000000000000000000000000000000023`  
**Supported Chains**: Base, Optimism, Mode, Zora, World Chain, Celo

**Bet Intent Flow (Aggregator)**:
```
Hub/Accounting
    └─> MessengerAdapter.sendBetIntent()
        └─> L2ToL2CrossDomainMessenger.sendMessage()
            │
            ▼ (Optimism Interop)
            │
Venue (Base)
    └─> MessengerAdapter.receiveBetIntent()
        └─> BetManager.handleBetIntent()
            ├─> StagingEscrowVault.reserve(orderId,...)
            └─> BufferVault.spendTo(... venue )
```

**Gas Costs**:
- Superchain L2→L2: ~100-200k gas (native messaging)
- Non-Superchain: ~300-500k gas (bridge fees apply)

### ViaLabs Bridge (Fallback)

**Technology**: ViaLabs Omni-Chain Router  
**Supported Chains**: Non-OP Stack chains (Polygon, Avalanche, etc.)

**Configuration**:
```solidity
messengerAdapter.setChainType(137, false);  // Polygon = non-Superchain
messengerAdapter.setRemoteAdapter(137, polygonMessengerAddr);
```

### Settlement Attestation Flow

```
Off-chain: venue outcome finalized → attestation produced
    ↓
Accounting chain: SettlementAttestationAdapter.submit(attestation)
    └─> SettlementAuthority.settleFromMessenger(...)
         (messenger-gated authorization and events)
```

### Security Properties

**Replay Protection**:
```solidity
bytes32 messageId = keccak256(abi.encode(messageType, sourceChain, targetChain, nonce, timestamp));
require(!processedMessages[messageId], "AlreadyProcessed");
processedMessages[messageId] = true;
```

**Message Validation**:
- Sender must be registered remote adapter
- Chain ID must be supported
- Message must not be processed
- Timestamp must be recent (anti-replay)

**Failure Handling**:
- Messages can be marked processed manually (emergency)
- Failed intents can be refunded
- Status updates sent for tracking

## User Flow

### Complete Bet Lifecycle (Aggregator)

```
1) Intent received on venue via MessengerAdapter → BetManager.handleBetIntent()
2) Reserve funds in StagingEscrowVault; spend from BufferVault to venue
3) Venue executes off-chain; proceeds recorded via BetManager.recordFill()
4) Settlement attested on accounting chain via SettlementAttestationAdapter
5) SettlementAuthority authorizes finalization; receipts optionally forwarded via ReceiptRouter
```

### Error Scenarios

**Intent Expiry**:
```
if (block.timestamp > intent.expiry) {
    // Refund to user
    markSettled(intentId, false, intent.amount);
}
```

**Venue Failure**:
```
if (fillFailed) {
    // Send status update back to origin
    sendStatusUpdate(intentId, IntentState.Failed, originChainId);
    // Origin refunds user
}
```

**Insufficient Liquidity**:
```
if (bufferVault.getBalance(token) < amount) {
    // Fallback to LPVault withdrawal
    lpVault.withdrawByBetManager(amount, address(this));
}
```

## Security Architecture

### Access Control Hierarchy

```
DEFAULT_ADMIN_ROLE (Multi-sig)
├─> Can grant/revoke all roles
├─> Can upgrade contracts
├─> Can set protocol parameters
└─> Emergency functions

OPERATOR_ROLE (Backend services)
├─> Record bet fills
├─> Process settlements
└─> Update statuses

MESSENGER_ROLE (MessengerAdapter contracts)
├─> Send cross-chain messages
├─> Receive cross-chain messages
└─> Update intent states

BET_MANAGER_ROLE (BetManager contracts)
├─> Release funds from vaults
├─> Withdraw from LPVault
└─> Record settlements

PAUSE_ROLE (Guardian multi-sig)
├─> Pause/unpause protocol
├─> Emergency pause individual contracts
└─> No other permissions (separation of concerns)

TREASURY_ROLE (Treasury contract)
├─> Collect protocol fees
└─> Distribute to stakeholders
```

### Emergency Controls

**Protocol-Wide Pause**:
```solidity
pauseGuardian.pauseProtocol();
// Pauses: deposits, withdrawals, bets, settlements
// Allows: emergency withdrawals by admin
```

**Chain-Specific Pause**:
```solidity
pauseGuardian.pauseChain(chainId);
// Disables cross-chain messages to/from specific chain
```

**Contract-Specific Pause**:
```solidity
escrowVault.pause();  // Pauses only this vault
```

**Emergency Withdrawal**:
```solidity
// Admin can rescue stuck funds (7-day timelock)
escrowVault.emergencyWithdraw(intentId);
```

### Invariants

**StagingEscrowVault**:
1. Reserved ≤ cap and ≤ available balance
2. Release ≤ reserved (per-order invariant)
3. Canceled orders refund correctly and only once

**LPVault**:
1. `totalAssets() >= sum(user shares * sharePrice)`
2. `protocolFees <= totalYieldDistributed * feeBps / 10000`
3. `share price is non-decreasing (no negative yield)`

**BetManager**:
1. `releasedFunds == recordedFills`
2. `all releaseIds are unique`
3. `settled intents have corresponding release`

**MessengerAdapter**:
1. `processedMessages prevents replay`
2. `all messages have valid sender`
3. `message routing matches chain configuration`

## Upgrade Strategy

### UUPS Proxy Pattern

All contracts use UUPS (Universal Upgradeable Proxy Standard):

```solidity
contract SettlementAuthority is UUPSUpgradeable, AccessControlUpgradeable {
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}
}
```

### Upgrade Process

1. **Deploy new implementation**:
```bash
forge script script/DeployNewImplementation.s.sol
```

2. **Test upgrade on testnet**:
```bash
forge script script/UpgradeTestnet.s.sol --rpc-url $TESTNET_RPC
```

3. **Propose upgrade via multi-sig**:
```bash
# Create Gnosis Safe transaction
cast send $PROXY "upgradeTo(address)" $NEW_IMPLEMENTATION --from $MULTISIG
```

4. **Execute after timelock**:
```bash
# Multi-sig executes after 48-hour timelock
```

### Storage Layout

Contracts use **gap arrays** to prevent storage collisions:

```solidity
contract EscrowVault {
    // Storage layout v1
    mapping(bytes32 => BetIntent) public intents;
    mapping(address => bytes32[]) public userIntents;
    
    // Reserve 50 storage slots for future versions
    uint256[50] private __gap;
}
```

### Upgrade Safety

- All upgrades tested on testnet first
- Storage layout verified with `forge inspect`
- 48-hour timelock for production upgrades
- Multi-sig requirement (3 of 5)
- Rollback plan documented

## Economic Model

### Fee Structure

Predifi's two product models have distinct fee structures optimized for their respective use cases:

#### Native CLOB Model (Predifi's Prediction Market)

**Protocol Fee**: 2% default, capped at 5% (enforced on-chain)
- ✅ **Smart contract enforced**: Maximum 5% cap hardcoded in `CLOBTypes.sol` (500 basis points)
- Default fee: 2% (200 basis points)
- Collected on market resolution from winners' profits
- Fee applied when market settles and positions are claimed
- Admin-adjustable per market within the 5% cap

#### Aggregator Model (Cross-Chain Betting)

**Protocol Fee**: 0.05% - 0.1% (admin-configurable)
- Much lower fee structure for aggregation service
- Fee range: 5-10 basis points
- Set by admin based on market conditions
- Collected on settlement
- Distributed via TreasurySplitter
- Split: 60% LPs, 30% treasury, 10% insurance fund

#### LP Yield (Aggregator Model)

- LPs earn from successful bets
- Yield distributed proportionally by shares
- Share price increases over time

#### Buffer Efficiency (Aggregator Model)

- Pre-funded for 80% of typical bet flow
- Reduces LP vault withdrawals (gas savings)
- Excess swept back to LPVault

**Token Flows (Aggregator)**

```
BufferVault funds (100 USDC)
    ↓
Venue execution (off-chain)
    ↓ returns 150 USDC
BufferVault receiveProceeds(150)
    ↓
TreasurySplitter distributes protocol fee (2%-5%) to stakeholders
    ↓
LPVault yield distribution when scheduled
```

### Risk Management

**Concentration Limits**:
- Max bet size per user: 10,000 USDC
- Max exposure per market: 100,000 USDC
- Max buffer allocation: 20% of LP vault

**Liquidity Management**:
- BufferVault: 1M USDC target
- LPVault: 10M USDC capacity
- Reserve ratio: 15% minimum

**Oracle Risk**:
- Multiple oracle sources (Polymarket, UMA, Pyth)
- Dispute resolution via governance
- Settlement delays for suspicious outcomes

---

**Last Updated**: November 4, 2025  
**Version**: 1.1  
**Authors**: Predifi Protocol Team
