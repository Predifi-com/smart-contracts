// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

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

    event MarketManuallyCategoricalInvalidResolved(
        bytes32 indexed marketId,
        address indexed resolvedBy,
        string reasonURI
    );

    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin, address _registry) public initializer {
        __AccessControl_init();

        if (admin == address(0)) revert ZeroAddress();
        if (_registry == address(0)) revert ZeroAddress();
        registry = MarketRegistry(_registry);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RESOLVER_ROLE, admin);
    }

    function resolve(
        bytes32 marketId,
        MarketRegistry.Outcome outcome,
        string calldata reasonURI
    ) external onlyRole(RESOLVER_ROLE) {
        registry.resolveMarket(marketId, outcome, reasonURI);
        emit MarketManuallyResolved(marketId, outcome, msg.sender, reasonURI);
    }

    function resolveCategorical(
        bytes32 marketId,
        bytes32 winningOutcomeId,
        string calldata reasonURI
    ) external onlyRole(RESOLVER_ROLE) {
        registry.resolveMarketCategorical(marketId, winningOutcomeId, reasonURI);
        emit MarketManuallyCategoricalResolved(marketId, winningOutcomeId, msg.sender, reasonURI);
    }

    function resolveCategoricalInvalid(
        bytes32 marketId,
        string calldata reasonURI
    ) external onlyRole(RESOLVER_ROLE) {
        registry.resolveMarketCategoricalInvalid(marketId, reasonURI);
        emit MarketManuallyCategoricalInvalidResolved(marketId, msg.sender, reasonURI);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[50] private _gap;
}
