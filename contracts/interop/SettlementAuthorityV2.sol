// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./SettlementAuthority.sol";

/**
 * @title SettlementAuthorityV2
 * @notice Upgrade target for storage layout testing and domain-version drift testing.
 *         When deployed standalone, initializes EIP-712 with version "2".
 *         When upgraded from V1, domain separator remains unchanged (no re-init).
 */
contract SettlementAuthorityV2 is SettlementAuthority {
    // appended storage to validate layout append-only
    uint256 public added;

    function setAdded(uint256 v) external onlyRole(ADMIN_ROLE) { added = v; }

    /// @notice Initialize for fresh deployments with DOMAIN_VERSION bump to "2"
    /// @dev Use only on a fresh proxy/new deployment (not during upgrade)
    function initializeV2(address admin, address _vault) external initializer {
        require(admin != address(0) && _vault != address(0), "ZeroAddr");
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
    __EIP712_init(DOMAIN_NAME, "2");
        _grantRole(ADMIN_ROLE, admin);
    // Directly set vault reference for fresh deployments
    vault = IStagingEscrowVault(_vault);
    emit VaultUpdated(_vault);
    }
}
