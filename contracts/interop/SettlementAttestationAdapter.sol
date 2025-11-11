// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

interface ISettlementAuthorityMinimal {
    function settleFromMessenger(bytes32 orderId, uint256 amountDelta, uint256 feeDelta) external;
}

/**
 * @title SettlementAttestationAdapter
 * @notice Minimal on-chain consumer that accepts validated attestations and
 *         forwards them to SettlementAuthority on the accounting chain.
 *         This contract is permissioned: only an allowed caller (bridge/relayer)
 *         may submit attestations. It holds no funds.
 */
contract SettlementAttestationAdapter is UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant CALLER_ROLE = keccak256("CALLER_ROLE");

    ISettlementAuthorityMinimal public settlementAuthority;

    event AttestationConsumed(bytes32 indexed orderId, uint256 amountDelta, uint256 feeDelta, address indexed caller);
    event AuthorityUpdated(address indexed authority);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address authority, address allowedCaller) external initializer {
        require(admin != address(0) && authority != address(0) && allowedCaller != address(0), "ZeroAddr");
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(ADMIN_ROLE, admin);
        _grantRole(CALLER_ROLE, allowedCaller);
        settlementAuthority = ISettlementAuthorityMinimal(authority);
        emit AuthorityUpdated(authority);
    }

    function setAuthority(address authority) external onlyRole(ADMIN_ROLE) {
        require(authority != address(0), "ZeroAddr");
        settlementAuthority = ISettlementAuthorityMinimal(authority);
        emit AuthorityUpdated(authority);
    }

    function setAllowedCaller(address caller, bool allowed) external onlyRole(ADMIN_ROLE) {
        require(caller != address(0), "ZeroAddr");
        if (allowed) {
            _grantRole(CALLER_ROLE, caller);
        } else {
            _revokeRole(CALLER_ROLE, caller);
        }
    }

    function receiveAttestation(bytes32 orderId, uint256 amountDelta, uint256 feeDelta) external whenNotPaused onlyRole(CALLER_ROLE) {
        // Trust boundary: upstream bridge/relayer must ensure message authenticity
        // SettlementAuthority enforces messenger role; adapter must be granted that role
        settlementAuthority.settleFromMessenger(orderId, amountDelta, feeDelta);
        emit AttestationConsumed(orderId, amountDelta, feeDelta, msg.sender);
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
