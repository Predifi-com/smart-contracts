// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract PredifiAdmin is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    uint256 public constant DEFAULT_UPGRADE_DELAY = 1 days;

    // Roles
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Governed contract registry
    struct GovernedContract {
        string  name;
        bool    active;
    }

    mapping(address => GovernedContract) public governedContracts;
    address[] private _contractList;
    uint256 public upgradeDelay;
    mapping(bytes32 => uint256) public scheduledUpgradeTime;

    // Events
    event ContractRegistered(address indexed proxy, string name);
    event ContractUnregistered(address indexed proxy);
    event Executed(address indexed target, bytes4 selector);
    event BatchExecuted(uint256 callCount);
    event UpgradeQueued(bytes32 indexed upgradeId, address indexed proxy, address indexed newImpl, uint256 executeAfter);
    event UpgradeDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event ContractUpgraded(address indexed proxy, address indexed newImpl);
    event ProtocolPaused(address indexed by);
    event ProtocolUnpaused(address indexed by);

    // Errors
    error NotGoverned(address target);
    error AlreadyRegistered(address target);
    error NotRegistered(address target);
    error CallFailed(address target, bytes reason);
    error ArrayLengthMismatch();
    error ZeroAddress();
    error DefaultAdminRoleProtected();
    error InvalidUpgradeDelay();
    error UpgradeNotQueued(bytes32 upgradeId);
    error UpgradeTooEarly(bytes32 upgradeId, uint256 executeAfter);

    // init

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    /**
     * @param admin           Becomes DEFAULT_ADMIN_ROLE — use Safe multisig on mainnet.
     * @param operatorWallet  Backend hot wallet — gets OPERATOR_ROLE.
     */
    function initialize(address admin, address operatorWallet) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (admin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE,      admin);
        upgradeDelay = DEFAULT_UPGRADE_DELAY;

        if (operatorWallet != address(0)) {
            _grantRole(OPERATOR_ROLE, operatorWallet);
        }
    }

    // Governed contract management

    /**
     * @notice Register a governed contract so it can be called via execute().
     * @dev Only DEFAULT_ADMIN_ROLE. Called once per contract at deploy time.
     */
    function registerContract(address proxy, string calldata name)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (proxy == address(0)) revert ZeroAddress();
        if (governedContracts[proxy].active) revert AlreadyRegistered(proxy);
        governedContracts[proxy] = GovernedContract({name: name, active: true});
        _contractList.push(proxy);
        emit ContractRegistered(proxy, name);
    }

    function unregisterContract(address proxy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!governedContracts[proxy].active) revert NotRegistered(proxy);
        governedContracts[proxy].active = false;
        emit ContractUnregistered(proxy);
    }

    function getContractList() external view returns (address[] memory) {
        return _contractList;
    }

    // Execute

    /**
     * @notice Execute an arbitrary call on a governed contract.
     * @dev DEFAULT_ADMIN_ROLE only. Intended for the Safe multisig.
     *      Covers any operation not explicitly exposed as a helper below.
     * @param target  Must be a registered governed contract.
     * @param data    ABI-encoded calldata.
     * @return result Raw return bytes.
     */
    function execute(address target, bytes calldata data)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bytes memory result)
    {
        if (!governedContracts[target].active) revert NotGoverned(target);
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) revert CallFailed(target, result);
        emit Executed(target, _selector(data));
    }

    /**
     * @notice Execute multiple calls on governed contracts in one transaction.
     * @dev DEFAULT_ADMIN_ROLE only. targets[i] and data[i] must correspond.
     */
    function batchExecute(
        address[] calldata targets,
        bytes[]   calldata data
    )
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bytes[] memory results)
    {
        if (targets.length != data.length) revert ArrayLengthMismatch();
        results = new bytes[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            if (!governedContracts[targets[i]].active) revert NotGoverned(targets[i]);
            bool ok;
            (ok, results[i]) = targets[i].call(data[i]);
            if (!ok) revert CallFailed(targets[i], results[i]);
        }
        emit BatchExecuted(targets.length);
    }

    // Upgrade helpers

    function setUpgradeDelay(uint256 newDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDelay == 0) revert InvalidUpgradeDelay();
        emit UpgradeDelayUpdated(upgradeDelay, newDelay);
        upgradeDelay = newDelay;
    }

    function getUpgradeId(
        address proxy,
        address newImpl,
        bytes calldata callData
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(proxy, newImpl, keccak256(callData)));
    }

    function queueUpgrade(
        address proxy,
        address newImpl,
        bytes calldata callData
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!governedContracts[proxy].active) revert NotGoverned(proxy);
        if (newImpl == address(0)) revert ZeroAddress();

        bytes32 upgradeId = getUpgradeId(proxy, newImpl, callData);
        uint256 executeAfter = block.timestamp + upgradeDelay;
        scheduledUpgradeTime[upgradeId] = executeAfter;

        emit UpgradeQueued(upgradeId, proxy, newImpl, executeAfter);
    }

    /**
     * @notice Upgrade a governed UUPS contract to a new implementation.
     * @dev UPGRADER_ROLE. All governed contracts expose upgradeToAndCall().
     * @param proxy    The proxy address (must be registered).
     * @param newImpl  New implementation address.
     * @param callData Optional init data to call on the new implementation.
     */
    function upgradeContract(
        address proxy,
        address newImpl,
        bytes calldata callData
    )
        external
        nonReentrant
        onlyRole(UPGRADER_ROLE)
    {
        if (!governedContracts[proxy].active) revert NotGoverned(proxy);
        if (newImpl == address(0)) revert ZeroAddress();

        bytes32 upgradeId = getUpgradeId(proxy, newImpl, callData);
        uint256 executeAfter = scheduledUpgradeTime[upgradeId];
        if (executeAfter == 0) revert UpgradeNotQueued(upgradeId);
        if (block.timestamp < executeAfter) revert UpgradeTooEarly(upgradeId, executeAfter);

        delete scheduledUpgradeTime[upgradeId];

        bytes memory data = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            newImpl,
            callData
        );

        (bool ok, bytes memory result) = proxy.call(data);
        if (!ok) revert CallFailed(proxy, result);
        emit ContractUpgraded(proxy, newImpl);
    }

    // Operational helpers (OPERATOR_ROLE)

    /**
     * @notice Grant a role on a governed contract.
     * @dev OPERATOR_ROLE. Used for key rotation (new backend wallet, etc.).
     *      Cannot grant DEFAULT_ADMIN_ROLE — that requires multisig via execute().
     */
    function grantContractRole(
        address target,
        bytes32 role,
        address account
    )
        external
        onlyRole(OPERATOR_ROLE)
    {
        if (!governedContracts[target].active) revert NotGoverned(target);
        if (role == DEFAULT_ADMIN_ROLE) revert DefaultAdminRoleProtected();
        (bool ok, bytes memory result) = target.call(
            abi.encodeWithSignature("grantRole(bytes32,address)", role, account)
        );
        if (!ok) revert CallFailed(target, result);
    }

    /**
     * @notice Revoke a role on a governed contract.
     * @dev OPERATOR_ROLE.
     */
    function revokeContractRole(
        address target,
        bytes32 role,
        address account
    )
        external
        onlyRole(OPERATOR_ROLE)
    {
        if (!governedContracts[target].active) revert NotGoverned(target);
        if (role == DEFAULT_ADMIN_ROLE) revert DefaultAdminRoleProtected();
        (bool ok, bytes memory result) = target.call(
            abi.encodeWithSignature("revokeRole(bytes32,address)", role, account)
        );
        if (!ok) revert CallFailed(target, result);
    }

    function pauseSettlement(address settlement) external onlyRole(OPERATOR_ROLE) {
        if (!governedContracts[settlement].active) revert NotGoverned(settlement);
        (bool ok, bytes memory result) = settlement.call(abi.encodeWithSignature("pause()"));
        if (!ok) revert CallFailed(settlement, result);
    }

    function unpauseSettlement(address settlement) external onlyRole(OPERATOR_ROLE) {
        if (!governedContracts[settlement].active) revert NotGoverned(settlement);
        (bool ok, bytes memory result) = settlement.call(abi.encodeWithSignature("unpause()"));
        if (!ok) revert CallFailed(settlement, result);
    }

    /**
     * @notice Pause PredifiPool (emergency halt on all deposits + withdrawals).
     * @dev DEFAULT_ADMIN_ROLE only — pausing the vault is a severe action.
     * @param pool  Address of the PredifiPool proxy.
     */
    function pausePool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!governedContracts[pool].active) revert NotGoverned(pool);
        (bool ok, bytes memory result) = pool.call(abi.encodeWithSignature("pause()"));
        if (!ok) revert CallFailed(pool, result);
        emit ProtocolPaused(msg.sender);
    }

    /**
     * @notice Unpause PredifiPool.
     * @dev DEFAULT_ADMIN_ROLE only.
     */
    function unpausePool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!governedContracts[pool].active) revert NotGoverned(pool);
        (bool ok, bytes memory result) = pool.call(abi.encodeWithSignature("unpause()"));
        if (!ok) revert CallFailed(pool, result);
        emit ProtocolUnpaused(msg.sender);
    }

    function _selector(bytes calldata data) internal pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly {
            selector := calldataload(data.offset)
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[50] private _gap;
}
