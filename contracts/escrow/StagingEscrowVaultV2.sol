// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./StagingEscrowVault.sol";

// Dummy V2 to test storage layout upgrade safety (append-only)
contract StagingEscrowVaultV2 is StagingEscrowVault {
    uint256 public added;

    function setAdded(uint256 v) external onlyRole(ADMIN_ROLE) {
        added = v;
    }
}
