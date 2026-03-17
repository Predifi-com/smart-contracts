// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MarketRegistry} from "./MarketRegistry.sol";

contract AdminOracle is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

    MarketRegistry public registry;

    event MarketManuallyResolved(
        bytes32 indexed marketId,
        MarketRegistry.Outcome outcome,
        address indexed resolvedBy,
        string reasonURI
    );

    event MarketManuallyCategoricalResolved(
        bytes32 indexed marketId,
        bytes32 indexed winningOutcomeId,
        address indexed resolvedBy,
        string reasonURI
    );

    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin, address _registry) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        if (admin == address(0)) revert ZeroAddress();
        if (_registry == address(0)) revert ZeroAddress();
        registry = MarketRegistry(_registry);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RESOLVER_ROLE, admin);
    }

    /**
     * @notice Manually resolve a market outcome.
     * @dev Requires RESOLVER_ROLE. Calls registry.resolveMarket() which enforces
     *      all resolution guards (market must exist, must be PENDING, caller must
     *      hold RESOLVER_ROLE on the registry).
     *      This contract must be granted RESOLVER_ROLE on MarketRegistry at deploy time.
     * @param marketId  The bytes32 market ID registered in MarketRegistry
     * @param outcome   YES, NO, or INVALID
     * @param reasonURI URI pointing to resolution evidence (IPFS, HTTPS, or HCS topic message)
     */
    function resolve(
        bytes32 marketId,
        MarketRegistry.Outcome outcome,
        string calldata reasonURI
    ) external onlyRole(RESOLVER_ROLE) {
        registry.resolveMarket(marketId, outcome, reasonURI);
        emit MarketManuallyResolved(marketId, outcome, msg.sender, reasonURI);
    }

    /**
     * @notice Manually resolve a CATEGORICAL market by specifying the winning outcome.
     * @dev Requires RESOLVER_ROLE. Calls registry.resolveMarketCategorical().
     *      The winningOutcomeId must match one of the OutcomeDef IDs registered
     *      for this market. Use for event markets ("Will X win?") where no price
     *      feed exists — AdminOracle is the only resolution path.
     * @param marketId         The bytes32 market ID registered in MarketRegistry
     * @param winningOutcomeId The bytes32 ID of the winning outcome definition
     * @param reasonURI        URI pointing to resolution evidence
     */
    function resolveCategorical(
        bytes32 marketId,
        bytes32 winningOutcomeId,
        string calldata reasonURI
    ) external onlyRole(RESOLVER_ROLE) {
        registry.resolveMarketCategorical(marketId, winningOutcomeId, reasonURI);
        emit MarketManuallyCategoricalResolved(marketId, winningOutcomeId, msg.sender, reasonURI);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[50] private _gap;
}
