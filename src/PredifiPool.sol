// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";

contract PredifiPool is 
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant LEDGER_ROLE = keccak256("LEDGER_ROLE");
    bytes32 public constant YIELD_MANAGER_ROLE = keccak256("YIELD_MANAGER_ROLE");

    IERC20 public asset;

    address[] public yieldAdapters;

    mapping(address => bool) public isYieldAdapter;

    uint256 public constant MAX_YIELD_ADAPTERS = 5;

    uint256 public lastTVLSnapshot;

    uint256 public lastSnapshotBlock;

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount, address indexed authorizedBy);
    event LedgerRoleGranted(address indexed account);
    event LedgerRoleRevoked(address indexed account);
    event YieldManagerRoleGranted(address indexed account);
    event YieldManagerRoleRevoked(address indexed account);
    event YieldAdapterRegistered(address indexed adapter, string adapterName);
    event YieldAdapterRemoved(address indexed adapter);
    event DeployedToYield(address indexed adapter, uint256 amount, uint256 totalInYield);
    event WithdrawnFromYield(address indexed adapter, uint256 amount, uint256 totalInYield);
    event TVLSnapshotTaken(uint256 tvl, uint256 blockNumber);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error AdapterAlreadyRegistered(address adapter);
    error AdapterNotRegistered(address adapter);
    error AdapterHasBalance(address adapter, uint256 balance);
    error TooManyAdapters();
    error AdapterAssetMismatch(address adapter, address adapterAsset, address poolAsset);
    error HTSAssociationFailed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address asset_, address admin_) public initializer {

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        if (asset_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();

        asset = IERC20(asset_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
        _grantRole(LEDGER_ROLE, admin_);
        _grantRole(YIELD_MANAGER_ROLE, admin_);

        // Best-effort HTS association. The Hedera EVM HTS precompile cannot process
        // associateToken during contract construction (the contract's Hedera account
        // is not yet finalized on-ledger). EVM contracts can receive HTS tokens
        // without explicit association, so we attempt but never revert on failure.
        if ((block.chainid == 295 || block.chainid == 296) && uint160(asset_) < type(uint32).max) {
            address(0x167).call(
                abi.encodeWithSignature("associateToken(address,address)", address(this), asset_)
            );
        }
    }

    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        asset.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, amount);
    }

    function withdraw(
        address to,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyRole(LEDGER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > asset.balanceOf(address(this))) revert InsufficientBalance();

        asset.safeTransfer(to, amount);

        emit Withdrawn(to, amount, msg.sender);
    }

    function registerYieldAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0))                revert ZeroAddress();
        if (isYieldAdapter[adapter])              revert AdapterAlreadyRegistered(adapter);
        if (yieldAdapters.length >= MAX_YIELD_ADAPTERS) revert TooManyAdapters();

        address adapterAsset = IYieldAdapter(adapter).asset();
        if (adapterAsset != address(asset)) {
            revert AdapterAssetMismatch(adapter, adapterAsset, address(asset));
        }

        isYieldAdapter[adapter] = true;
        yieldAdapters.push(adapter);

        emit YieldAdapterRegistered(adapter, IYieldAdapter(adapter).name());
    }

    function removeYieldAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isYieldAdapter[adapter]) revert AdapterNotRegistered(adapter);

        uint256 balance = IYieldAdapter(adapter).deposited();
        if (balance != 0) revert AdapterHasBalance(adapter, balance);

        isYieldAdapter[adapter] = false;

        uint256 len = yieldAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            if (yieldAdapters[i] == adapter) {
                yieldAdapters[i] = yieldAdapters[len - 1];
                yieldAdapters.pop();
                break;
            }
        }

        emit YieldAdapterRemoved(adapter);
    }

    function deployToYield(
        address adapter,
        uint256 amount
    ) external nonReentrant onlyRole(YIELD_MANAGER_ROLE) {
        if (!isYieldAdapter[adapter]) revert AdapterNotRegistered(adapter);
        if (amount == 0) revert ZeroAmount();
        if (amount > asset.balanceOf(address(this))) revert InsufficientBalance();

        asset.forceApprove(adapter, amount);
        IYieldAdapter(adapter).deposit(amount);

        emit DeployedToYield(adapter, amount, yieldBalance());
    }

    function withdrawFromYield(
        address adapter,
        uint256 amount
    ) external nonReentrant onlyRole(YIELD_MANAGER_ROLE) {
        if (!isYieldAdapter[adapter]) revert AdapterNotRegistered(adapter);
        if (amount == 0) revert ZeroAmount();

        IYieldAdapter(adapter).withdraw(amount);

        emit WithdrawnFromYield(adapter, amount, yieldBalance());
    }

    function totalBalance() external view returns (uint256) {
        return _totalBalance();
    }

    function _totalBalance() internal view returns (uint256) {
        uint256 total = asset.balanceOf(address(this));
        uint256 len = yieldAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            total += IYieldAdapter(yieldAdapters[i]).deposited();
        }
        return total;
    }

    function yieldBalance() public view returns (uint256) {
        uint256 total;
        uint256 len = yieldAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            total += IYieldAdapter(yieldAdapters[i]).deposited();
        }
        return total;
    }

    function takeYieldSnapshot() external onlyRole(LEDGER_ROLE) {
        uint256 tvl = _totalBalance();
        lastTVLSnapshot  = tvl;
        lastSnapshotBlock = block.number;
        emit TVLSnapshotTaken(tvl, block.number);
    }

    function pendingYield() external view returns (uint256) {
        uint256 current = _totalBalance();
        if (current <= lastTVLSnapshot) return 0;
        return current - lastTVLSnapshot;
    }

    function yieldAdapterCount() external view returns (uint256) {
        return yieldAdapters.length;
    }

    function grantLedgerRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(LEDGER_ROLE, account);
        emit LedgerRoleGranted(account);
    }

    function revokeLedgerRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(LEDGER_ROLE, account);
        emit LedgerRoleRevoked(account);
    }

    function grantYieldManagerRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(YIELD_MANAGER_ROLE, account);
        emit YieldManagerRoleGranted(account);
    }

    function revokeYieldManagerRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(YIELD_MANAGER_ROLE, account);
        emit YieldManagerRoleRevoked(account);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[46] private _gap;
}
