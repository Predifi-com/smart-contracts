// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Roles
 * @notice Centralized role definitions for the Predifi protocol
 * @dev Provides compile-time constants for all AccessControl role hashes
 *      to avoid manual keccak256 computation and reduce errors
 */
library Roles {
    // ========================================
    // UNIVERSAL ROLES
    // ========================================
    
    /**
     * @notice Default admin role for all contracts
     * @dev Has the ability to grant/revoke all other roles
     */
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    
    /**
     * @notice Pauser role - can pause/unpause contracts
     */
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    /**
     * @notice Upgrader role - can upgrade UUPS proxy implementations
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    // ========================================
    // VAULT ROLES
    // ========================================
    
    /**
     * @notice Manager role - can manage vault operations (spend, withdraw)
     * @dev Used by: BufferVault, LPVault, StagingEscrowVault
     */
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    /**
     * @notice Funder role - can deposit/bridge funds into vaults
     * @dev Used by: BufferVault (for receiveBridge), LPVault
     */
    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE");
    
    /**
     * @notice Settlement authority role - can release escrowed funds
     * @dev Used by: StagingEscrowVault
     */
    bytes32 public constant SETTLEMENT_AUTHORITY_ROLE = keccak256("SETTLEMENT_AUTHORITY_ROLE");
    
    /**
     * @notice Distributor role - can trigger treasury distributions
     * @dev Used by: TreasurySplitter
     */
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    
    // ========================================
    // MESSAGING & CROSS-CHAIN ROLES
    // ========================================
    
    /**
     * @notice Relayer role - can relay cross-chain messages
     * @dev Used by: MessengerAdapter (both hub and venue)
     */
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    
    /**
     * @notice Messenger role - can send messages via adapters
     * @dev Used by: SettlementAuthority, SettlementAttestationAdapter
     */
    bytes32 public constant MESSENGER_ROLE = keccak256("MESSENGER_ROLE");
    
    /**
     * @notice Bet manager role - authorized to receive bet intents
     * @dev Used by: MessengerAdapter (venue) to authorize BetManager
     */
    bytes32 public constant BET_MANAGER_ROLE = keccak256("BET_MANAGER_ROLE");
    
    // ========================================
    // CLOB ROLES
    // ========================================
    
    /**
     * @notice Minter role - can mint YesNoTokens
     * @dev Used by: Settlement contract
     */
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    /**
     * @notice Burner role - can burn YesNoTokens
     * @dev Used by: Settlement contract
     */
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    /**
     * @notice Settler role - can settle markets and execute settlements
     * @dev Used by: Settlement contract, authorized settler EOA
     */
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");
    
    /**
     * @notice Operator role - can execute orderbook operations
     * @dev Used by: Settlement contract
     */
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    /**
     * @notice Settlement role - can trigger fee collections
     * @dev Used by: FeeCollector, granted to Settlement contract
     */
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    
    // ========================================
    // ORACLE ROLES
    // ========================================
    
    /**
     * @notice Oracle updater role - can update oracle prices
     * @dev Used by: OracleAdapter
     */
    bytes32 public constant ORACLE_UPDATER_ROLE = keccak256("ORACLE_UPDATER_ROLE");
    
    // ========================================
    // HELPER FUNCTIONS
    // ========================================
    
    /**
     * @notice Get role hash for any custom role name
     * @dev Use for dynamic role computation when needed
     * @param roleName The name of the role (e.g., "CUSTOM_ROLE")
     * @return The keccak256 hash of the role name
     */
    function getRoleHash(string memory roleName) internal pure returns (bytes32) {
        return keccak256(bytes(roleName));
    }
    
    /**
     * @notice Check if a role hash matches a known role constant
     * @dev Useful for validation and debugging
     * @param roleHash The role hash to check
     * @return roleName Human-readable role name, or "UNKNOWN_ROLE"
     */
    function getRoleName(bytes32 roleHash) internal pure returns (string memory roleName) {
        if (roleHash == DEFAULT_ADMIN_ROLE) return "DEFAULT_ADMIN_ROLE";
        if (roleHash == PAUSER_ROLE) return "PAUSER_ROLE";
        if (roleHash == UPGRADER_ROLE) return "UPGRADER_ROLE";
        if (roleHash == MANAGER_ROLE) return "MANAGER_ROLE";
        if (roleHash == FUNDER_ROLE) return "FUNDER_ROLE";
        if (roleHash == SETTLEMENT_AUTHORITY_ROLE) return "SETTLEMENT_AUTHORITY_ROLE";
        if (roleHash == DISTRIBUTOR_ROLE) return "DISTRIBUTOR_ROLE";
        if (roleHash == RELAYER_ROLE) return "RELAYER_ROLE";
        if (roleHash == MESSENGER_ROLE) return "MESSENGER_ROLE";
        if (roleHash == BET_MANAGER_ROLE) return "BET_MANAGER_ROLE";
        if (roleHash == MINTER_ROLE) return "MINTER_ROLE";
        if (roleHash == BURNER_ROLE) return "BURNER_ROLE";
        if (roleHash == SETTLER_ROLE) return "SETTLER_ROLE";
        if (roleHash == OPERATOR_ROLE) return "OPERATOR_ROLE";
        if (roleHash == SETTLEMENT_ROLE) return "SETTLEMENT_ROLE";
        if (roleHash == ORACLE_UPDATER_ROLE) return "ORACLE_UPDATER_ROLE";
        return "UNKNOWN_ROLE";
    }
}
