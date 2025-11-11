// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal EIP-2612 permit interface
interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/**
 * @title StagingEscrowVault
 * @notice Delivery-vs-Payment staging escrow for aggregator flow. Holds user funds on Celo
 *         and releases to LP and fee recipients only after cross-chain attestation that
 *         venue-side YES/NO tokens were received for the order.
 */
/**
 * @title ReserveVault (evolved from StagingEscrowVault)
 * @notice Delivery-vs-Payment staging escrow upgraded into a generalized Reserve Vault.
 *         Maintains per-user available vs reserved ERC20 balances keyed by orderId.
 *         Legacy reservation struct/functions retained for backward compatibility.
 * @dev UUPS upgradeable: STORAGE LAYOUT APPEND-ONLY. Existing variables MUST NOT be reordered or removed.
 */
contract StagingEscrowVault is UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant SETTLEMENT_AUTHORITY_ROLE = keccak256("SETTLEMENT_AUTHORITY_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;

    struct Reservation {
        address user;            // User who reserved
        address asset;           // ERC20 stable token
        address lpRecipient;     // LP/treasury recipient for released amount
        address feeRecipient;    // Recipient for relayer fees
        uint256 reservedAmount;  // Total reserved principal
        uint256 reservedFeeCap;  // Max fee user agrees to pay
        uint256 releasedAmount;  // Cumulative released to LP
        uint256 releasedFee;     // Cumulative fee paid to feeRecipient
        uint64 expiry;           // Expiry timestamp
        bool active;             // Active reservation
    }

    // orderId => reservation
    mapping(bytes32 => Reservation) private _res;

    // Legacy Events (retained for backward compatibility)
    event Reserved(bytes32 indexed orderId, address indexed user, address indexed asset, uint256 amount, uint256 feeCap, address lpRecipient, address feeRecipient, uint64 expiry);
    event Released(bytes32 indexed orderId, uint256 amountDelta, uint256 feeDelta, uint256 cumulativeAmount, uint256 cumulativeFee);
    event Canceled(bytes32 indexed orderId, address indexed user, uint256 refundAmount, uint256 refundFee);

    // New Canonical ReserveVault Events (for indexing) - names intentionally mirror legacy but with distinct signatures
    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount, address indexed to);
    event Reserved(address indexed user, address indexed token, bytes32 indexed orderId, uint256 amount); // reservation of available -> reserved
    event Released(address indexed user, address indexed token, bytes32 indexed orderId, uint256 remaining); // release reserved -> available
    event Settled(address indexed user, address indexed token, bytes32 indexed orderId, uint256 amount, address to); // debit reserved -> external recipient (max 3 indexed)

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        require(admin != address(0), "ZeroAdmin");
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(ADMIN_ROLE, admin);
        _grantRole(PAUSE_ROLE, admin);
    }

    /**
     * @notice Canonical deposit of tokens into user's available balance.
     * @param token ERC20 token address
     * @param amount Amount to deposit (must be approved beforehand)
     */
    function deposit(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(token != address(0), "ZeroAddr");
        require(amount > 0, "ZeroAmount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _available[msg.sender][token] += amount;
        emit Deposited(msg.sender, token, amount);
    }

    /**
     * @notice Withdraw available (non-reserved) funds.
     * @param token ERC20 token address
     * @param amount Amount to withdraw from available balance
     * @param to Recipient of withdrawal (may be different from msg.sender)
     * @dev Allowed while paused? For safety withdrawals are blocked when paused (can adjust policy later).
     */
    // Note: withdrawals are allowed even while paused to enable exit during incidents
    function withdraw(address token, uint256 amount, address to) external nonReentrant {
        require(token != address(0) && to != address(0), "ZeroAddr");
        require(amount > 0, "ZeroAmount");
        uint256 avail = _available[msg.sender][token];
        require(avail >= amount, "InsufficientAvail");
        _available[msg.sender][token] = avail - amount;
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(msg.sender, token, amount, to);
    }

    /**
     * @notice Deposit with EIP-2612 permit to avoid separate approve transaction
     */
    function depositWithPermit(
        address token,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        require(token != address(0), "ZeroAddr");
        require(amount > 0, "ZeroAmount");
        IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, v, r, s);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _available[msg.sender][token] += amount;
        emit Deposited(msg.sender, token, amount);
    }

    /**
     * @notice Reserve funds for an order (moves from available to reserved).
     * @dev Backward-compatible signature extended with explicit user parameter; now requires SETTLEMENT_AUTHORITY_ROLE.
     * @param user The user whose available balance will be reserved
     * @param orderId Unique order identifier
     * @param asset Token being reserved
     * @param amount Principal amount to reserve (feeCap treated legacy; still recorded)
     * @param feeCap Maximum fee user agrees to (legacy path retained but NOT auto-reserved into new accounting)
     * @param lpRecipient Legacy field (kept for struct compatibility)
     * @param feeRecipient Legacy field (kept for struct compatibility)
     * @param expiry Expiry timestamp (legacy cancellation guard)
     */
    function reserve(
        address user,
        bytes32 orderId,
        address asset,
        uint256 amount,
        uint256 feeCap,
        address lpRecipient,
        address feeRecipient,
        uint64 expiry
    ) external nonReentrant whenNotPaused onlyRole(SETTLEMENT_AUTHORITY_ROLE) {
        require(user != address(0), "ZeroUser");
        require(orderId != bytes32(0), "BadOrderId");
        require(!_res[orderId].active, "Exists");
        require(!_orderFinalized[user][orderId], "Finalized");
        require(asset != address(0) && lpRecipient != address(0) && feeRecipient != address(0), "ZeroAddr");
        require(amount > 0, "ZeroAmount");
        require(expiry > block.timestamp, "Expired");
        require(_available[user][asset] >= amount, "InsufficientAvail");

        // Move funds: available -> reserved
        _available[user][asset] -= amount;
        _reserved[user][asset] += amount;
        _orderReserved[user][orderId] += amount;

        // Legacy reservation record (fee accounting retained)
        _res[orderId] = Reservation({
            user: user,
            asset: asset,
            lpRecipient: lpRecipient,
            feeRecipient: feeRecipient,
            reservedAmount: amount,
            reservedFeeCap: feeCap,
            releasedAmount: 0,
            releasedFee: 0,
            expiry: expiry,
            active: true
        });

        // Emit both legacy and new canonical event variants
        emit Reserved(orderId, user, asset, amount, feeCap, lpRecipient, feeRecipient, expiry); // legacy signature
        emit Reserved(user, asset, orderId, amount); // canonical indexing event
    }

    // SettlementAuthority legacy release: transfers principal/fee out; kept for backward compatibility.
    function releaseForOrder(bytes32 orderId, uint256 amountDelta, uint256 feeDelta) external nonReentrant whenNotPaused onlyRole(SETTLEMENT_AUTHORITY_ROLE) {
        _releaseForOrder(orderId, amountDelta, feeDelta);
    }

    function _releaseForOrder(bytes32 orderId, uint256 amountDelta, uint256 feeDelta) internal {
        Reservation storage r = _res[orderId];
        require(r.active, "NotActive");
        require(!_orderFinalized[r.user][orderId], "Finalized");
    require(block.timestamp < r.expiry, "OrderExpired");
        require(amountDelta > 0 || feeDelta > 0, "ZeroDelta");
        
        // Update legacy cumulative values within caps
        uint256 newAmount = r.releasedAmount + amountDelta; require(newAmount <= r.reservedAmount, "AmountCap");
        uint256 newFee = r.releasedFee + feeDelta; require(newFee <= r.reservedFeeCap, "FeeCap");
        r.releasedAmount = newAmount; r.releasedFee = newFee;

        // Only principal was reserved in new accounting; fee comes from vault balance (legacy behavior)
        require(_orderReserved[r.user][orderId] >= amountDelta, "InsufficientReserved");
        _orderReserved[r.user][orderId] -= amountDelta;
        _reserved[r.user][r.asset] -= amountDelta;

        // Transfer out (fee from vault balance, principal from reserved)
        if (amountDelta > 0) IERC20(r.asset).safeTransfer(r.lpRecipient, amountDelta);
        if (feeDelta > 0) IERC20(r.asset).safeTransfer(r.feeRecipient, feeDelta);

        // Finalize if all principal released
        if (_orderReserved[r.user][orderId] == 0) {
            _orderFinalized[r.user][orderId] = true;
            r.active = false;
        }

        emit Released(orderId, amountDelta, feeDelta, newAmount, newFee); // legacy event
        // For legacy path, 'to' is not singular; emit canonical with sentinel
        emit Settled(r.user, r.asset, orderId, amountDelta + feeDelta, address(0));
    }

    /**
     * @notice Release previously reserved funds back to user's available balance (no external transfer).
     * @param user Original user whose funds are reserved
     * @param asset Token address
     * @param orderId Order identifier
     * @param amount Amount to release back
     */
    function release(
        address user,
        address asset,
        bytes32 orderId,
        uint256 amount
    ) external onlyRole(SETTLEMENT_AUTHORITY_ROLE) whenNotPaused nonReentrant {
        require(user != address(0) && asset != address(0) && orderId != bytes32(0), "ZeroAddr");
        require(!_orderFinalized[user][orderId], "Finalized");
        require(amount > 0, "ZeroAmount");
        require(_orderReserved[user][orderId] >= amount, "InsufficientReserved");

        _orderReserved[user][orderId] -= amount;
        _reserved[user][asset] -= amount;
        _available[user][asset] += amount;

        if (_orderReserved[user][orderId] == 0) {
            _orderFinalized[user][orderId] = true;
        }

        emit Released(user, asset, orderId, _orderReserved[user][orderId]);
    }

    /**
     * @notice Settle (debit) reserved funds and transfer out to recipient.
     * @param user User whose reservation is being settled
     * @param asset Token address
     * @param orderId Order identifier
     * @param amount Amount to debit
     * @param to Recipient address (must be non-zero)
     */
    function settleDebit(
        address user,
        address asset,
        bytes32 orderId,
        uint256 amount,
        address to
    ) external onlyRole(SETTLEMENT_AUTHORITY_ROLE) whenNotPaused nonReentrant {
        _settleDebit(user, asset, orderId, amount, to);
    }

    function _settleDebit(
        address user,
        address asset,
        bytes32 orderId,
        uint256 amount,
        address to
    ) internal {
        require(user != address(0) && asset != address(0) && to != address(0), "ZeroAddr");
        require(orderId != bytes32(0), "BadOrderId");
        require(!_orderFinalized[user][orderId], "Finalized");
        require(amount > 0, "ZeroAmount");
        require(_orderReserved[user][orderId] >= amount, "InsufficientReserved");

        _orderReserved[user][orderId] -= amount;
        _reserved[user][asset] -= amount;
        IERC20(asset).safeTransfer(to, amount);

        if (_orderReserved[user][orderId] == 0) {
            _orderFinalized[user][orderId] = true;
        }

        emit Settled(user, asset, orderId, amount, to);
    }

    /**
     * @notice Settle fee only to a dynamic recipient for a given order.
     */
    function settleFeeTo(bytes32 orderId, uint256 feeDelta, address to) external onlyRole(SETTLEMENT_AUTHORITY_ROLE) whenNotPaused nonReentrant {
        require(to != address(0), "ZeroAddr");
        Reservation storage r = _res[orderId];
        require(r.active, "NotActive");
        require(!_orderFinalized[r.user][orderId], "Finalized");
    require(block.timestamp < r.expiry, "OrderExpired");
        require(feeDelta > 0, "ZeroDelta");

        uint256 newFee = r.releasedFee + feeDelta; require(newFee <= r.reservedFeeCap, "FeeCap");
        r.releasedFee = newFee;

        IERC20(r.asset).safeTransfer(to, feeDelta);
        emit Released(orderId, 0, feeDelta, r.releasedAmount, newFee); // update legacy counters
        emit Settled(r.user, r.asset, orderId, feeDelta, to); // canonical fee settlement
    }

    /**
     * @notice Batch principal settlements to multiple recipients (atomic).
     */
    function batchSettleDebit(
        address[] calldata users,
        address[] calldata assets,
        bytes32[] calldata orderIds,
        uint256[] calldata amounts,
        address[] calldata tos
    ) external onlyRole(SETTLEMENT_AUTHORITY_ROLE) whenNotPaused nonReentrant {
        uint256 len = users.length;
        require(len == assets.length && len == orderIds.length && len == amounts.length && len == tos.length, "LenMismatch");
        for (uint256 i = 0; i < len; i++) {
            _settleDebit(users[i], assets[i], orderIds[i], amounts[i], tos[i]);
        }
    }

    /**
     * @notice Batch legacy release for multiple orders (atomic). Useful for fee/principal combined releases.
     */
    function batchReleaseForOrder(
        bytes32[] calldata orderIds,
        uint256[] calldata amountDeltas,
        uint256[] calldata feeDeltas
    ) external onlyRole(SETTLEMENT_AUTHORITY_ROLE) whenNotPaused nonReentrant {
        uint256 len = orderIds.length;
        require(len == amountDeltas.length && len == feeDeltas.length, "LenMismatch");
        for (uint256 i = 0; i < len; i++) {
            _releaseForOrder(orderIds[i], amountDeltas[i], feeDeltas[i]);
        }
    }

    // Cancel after expiry; move remaining reserved back to available & finalize. Only authority.
    function cancel(bytes32 orderId) external nonReentrant onlyRole(SETTLEMENT_AUTHORITY_ROLE) {
        Reservation storage r = _res[orderId];
        require(r.active, "NotActive");
        require(!_orderFinalized[r.user][orderId], "Finalized");
        require(block.timestamp >= r.expiry, "NotExpired");

        uint256 remainingPrincipal = r.reservedAmount - r.releasedAmount;
        uint256 remainingFee = r.reservedFeeCap - r.releasedFee;

        // Re-credit principal portion to available
        if (remainingPrincipal > 0) {
            // Ensure canonical accounting reflects release back
            if (_orderReserved[r.user][orderId] >= remainingPrincipal) {
                _orderReserved[r.user][orderId] -= remainingPrincipal;
                _reserved[r.user][r.asset] -= remainingPrincipal;
                _available[r.user][r.asset] += remainingPrincipal;
            }
        }
        // Fee portion: already in user's available balance (was deposited but not reserved); no action needed

        // Finalize
        _orderFinalized[r.user][orderId] = true;
        r.active = false;

        emit Canceled(orderId, r.user, remainingPrincipal, remainingFee);
        emit Released(r.user, r.asset, orderId, _orderReserved[r.user][orderId]);
    }

    function getReservation(bytes32 orderId) external view returns (Reservation memory) {
        return _res[orderId];
    }

    /**
     * @notice Return user's available & reserved balances for a token.
     */
    function balances(address user, address token) external view returns (uint256 avail, uint256 resv) {
        avail = _available[user][token];
        resv  = _reserved[user][token];
    }

    /**
     * @notice Return amount reserved for a specific order.
     */
    function getOrderReserved(address user, bytes32 orderId) external view returns (uint256) {
        return _orderReserved[user][orderId];
    }

    function pause() external onlyRole(PAUSE_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSE_ROLE) { _unpause(); }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // ===================== APPENDED STORAGE (DO NOT MODIFY ORDER) =====================
    // Per-user available balances: user => token => amount
    mapping(address => mapping(address => uint256)) private _available;
    // Per-user reserved balances: user => token => amount
    mapping(address => mapping(address => uint256)) private _reserved;
    // Per-user per-order reserved principal: user => orderId => amount
    mapping(address => mapping(bytes32 => uint256)) private _orderReserved;
    // Per-user per-order finalization flag: user => orderId => closed
    mapping(address => mapping(bytes32 => bool)) private _orderFinalized;
}
