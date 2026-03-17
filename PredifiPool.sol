// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

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

    // Yield adapter registry

    /// @notice Registered yield adapters. Each adapter handles one protocol/chain.
    address[] public yieldAdapters;

    /// @notice Quick membership check: adapter address → registered.
    mapping(address => bool) public isYieldAdapter;

    /// @notice Maximum number of adapters to bound the gas cost of totalBalance().
    uint256 public constant MAX_YIELD_ADAPTERS = 5;

    // Yield snapshot

    /**
     * @notice TVL at the time of the last yield distribution snapshot.
     * @dev The off-chain ledger polls totalBalance() and compares it against
     *      this value to compute yieldDelta = totalBalance() - lastTVLSnapshot.
     *      Updated by takeYieldSnapshot() after each distribution cycle.
     */
    uint256 public lastTVLSnapshot;

    /**
     * @notice Block number when lastTVLSnapshot was recorded.
     * @dev Provides the ledger a deterministic timestamp anchor.
     */
    uint256 public lastSnapshotBlock;

    // Events

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

    // Errors

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

    /**
     * @notice Initialize the vault.
     * @param asset_ The underlying asset (USDC).
     * @param admin_ Address granted DEFAULT_ADMIN_ROLE, PAUSER_ROLE, LEDGER_ROLE.
     *               On production this should be the PredifiAdmin proxy.
     */
    function initialize(address asset_, address admin_) public initializer {
        __UUPSUpgradeable_init();
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

        // Hedera: associate with HTS token. HTS entity IDs are always < 2^32 so the
        // uint160 < uint32.max check distinguishes them from random EVM addresses.
        // Soft-fail on testnet (296), hard-fail on mainnet (295).
        bool isHtsToken = uint160(asset_) < type(uint32).max;
        if ((block.chainid == 295 || block.chainid == 296) && isHtsToken) {
            (bool success, ) = address(0x167).call(
                abi.encodeWithSignature("associateToken(address,address)", address(this), asset_)
            );
            if (block.chainid == 295) {
                if (!success) revert HTSAssociationFailed();
            }
        }
    }

    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        asset.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw assets from the vault
     * @dev Only callable by authorized ledger service. Can send to ANY address.
     * @param to Destination address (can be different from depositor)
     * @param amount Amount to withdraw
     */
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

    // Yield adapter management

    /**
     * @notice Register a yield adapter for idle liquidity deployment.
     * @dev DEFAULT_ADMIN_ROLE only. Adapter's asset() must match pool's asset.
     *      Max MAX_YIELD_ADAPTERS adapters to cap gas cost of totalBalance().
     * @param adapter Deployed IYieldAdapter contract address.
     */
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

    /**
     * @notice Remove a yield adapter. Any deployed funds must be withdrawn first.
     * @dev DEFAULT_ADMIN_ROLE only. Call withdrawFromYield() before removing
     *      if the adapter has an active position.
     * @param adapter Adapter address to remove.
     */
    function removeYieldAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isYieldAdapter[adapter]) revert AdapterNotRegistered(adapter);

        uint256 balance = IYieldAdapter(adapter).deposited();
        if (balance != 0) revert AdapterHasBalance(adapter, balance);

        isYieldAdapter[adapter] = false;

        // Remove from array (swap-and-pop)
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

    /**
     * @notice Deploy idle USDC into a yield adapter.
     * @dev LEDGER_ROLE only. The ledger decides when/how much to deploy based on
     *      the predicted minimum float needed to service withdrawals.
     * @param adapter Registered IYieldAdapter to use.
     * @param amount  Amount of USDC to deploy. Must be <= spot balance.
     */
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

    /**
     * @notice Retrieve USDC from a yield adapter back to this pool.
     * @dev LEDGER_ROLE only. Call before withdraw() if spot balance is insufficient.
     *      Pass `type(uint256).max` to exit the full adapter position.
     * @param adapter Registered IYieldAdapter to pull from.
     * @param amount  Amount of underlying asset to withdraw from the adapter.
     */
    function withdrawFromYield(
        address adapter,
        uint256 amount
    ) external nonReentrant onlyRole(YIELD_MANAGER_ROLE) {
        if (!isYieldAdapter[adapter]) revert AdapterNotRegistered(adapter);
        if (amount == 0) revert ZeroAmount();

        IYieldAdapter(adapter).withdraw(amount);

        emit WithdrawnFromYield(adapter, amount, yieldBalance());
    }

    // View functions

    /**
     * @notice Total assets controlled by this pool: spot balance + all yield positions.
     * @dev This is the canonical TVL figure the off-chain ledger uses to compute
     *      per-user balances and yield allocations.
     * @return Spot USDC + sum of adapter.deposited() across all registered adapters.
     */
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

    /**
     * @notice Sum of assets currently deployed across all yield adapters.
     * @return Total yield-deployed balance (principal + accrued yield).
     */
    function yieldBalance() public view returns (uint256) {
        uint256 total = 0;
        uint256 len = yieldAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            total += IYieldAdapter(yieldAdapters[i]).deposited();
        }
        return total;
    }

    /**
     * @notice Snapshot the current TVL as the yield-distribution baseline.
     * @dev Called by the LEDGER_ROLE backend AFTER distributing yield to users.
     *      Sets lastTVLSnapshot = totalBalance() so the next snapshot captures only
     *      yield that accrued AFTER this point.
     *
     *      Typical ledger cycle:
     *        1. yieldDelta = totalBalance() - lastTVLSnapshot   (off-chain)
     *        2. distribute yieldDelta to users                   (off-chain DB)
     *        3. call takeYieldSnapshot()                         (on-chain anchor)
     */
    function takeYieldSnapshot() external onlyRole(LEDGER_ROLE) {
        uint256 tvl = _totalBalance();
        lastTVLSnapshot  = tvl;
        lastSnapshotBlock = block.number;
        emit TVLSnapshotTaken(tvl, block.number);
    }

    /**
     * @notice Yield that has accrued since the last snapshot.
     * @dev Returns (currentTVL - lastTVLSnapshot), clamped to 0 to avoid
     *      underflow if TVL somehow shrank (e.g. AAVE slashing scenario).
     * @return Pending undistributed yield in asset base units.
     */
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
