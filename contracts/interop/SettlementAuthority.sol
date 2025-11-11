// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStagingEscrowVault {
    function releaseForOrder(bytes32 orderId, uint256 amountDelta, uint256 feeDelta) external;
    function reserve(
        address user,
        bytes32 orderId,
        address asset,
        uint256 amount,
        uint256 feeCap,
        address lpRecipient,
        address feeRecipient,
        uint64 expiry
    ) external;
    function balances(address user, address token) external view returns (uint256 avail, uint256 resv);
    function getOrderReserved(address user, bytes32 orderId) external view returns (uint256);
    function release(address user, address asset, bytes32 orderId, uint256 amount) external;
    function settleDebit(address user, address asset, bytes32 orderId, uint256 amount, address to) external;
}

/**
 * @title SettlementAuthority
 * @notice Trusted contract called by cross-chain messenger to authorize releases
 *         from the StagingEscrowVault after venue-side token receipt.
 */
contract SettlementAuthority is UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, EIP712Upgradeable {
    bytes32 public constant MESSENGER_ROLE = keccak256("MESSENGER_ROLE");
    bytes32 public constant MATCHER_ROLE = keccak256("MATCHER_ROLE");
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;

    IStagingEscrowVault public vault;

    event Settled(bytes32 indexed orderId, uint256 amountDelta, uint256 feeDelta);
    event VaultUpdated(address indexed vault);
    event IntentConsumed(bytes32 indexed intentHash, address indexed user, bytes32 indexed orderId, uint256 nonce, uint256 amount, uint256 feeCap);
    // Emitted only when a downstream vault call inside a try/catch reverts; nonce/digest must NOT be marked consumed
    event IntentFailed(address indexed user, bytes32 indexed orderId, bytes32 indexed intentHash, bytes reason);
    // Compact summary to help dashboards (no large bytes payload)
    event IntentFailedSummary(address indexed user, bytes32 indexed orderId, bytes32 indexed intentHash, bytes4 selector, bytes32 reasonHash);

    // -------- EIP-712 Intents --------
    using ECDSA for bytes32;

    // Note: struct not stored; order chosen for readability
    struct Intent {
        address user;
        bytes32 orderId;
        address asset;
        uint256 amount;
        uint256 feeCap;
        address lpRecipient;
        address feeRecipient;
        uint64 expiry;
        uint256 nonce; // sequential per-user
    }

    bytes32 private constant INTENT_TYPEHASH = keccak256(
        "Intent(address user,bytes32 orderId,address asset,uint256 amount,uint256 feeCap,address lpRecipient,address feeRecipient,uint64 expiry,uint256 nonce)"
    );

    // user => next expected nonce (ordered intents)
    mapping(address => uint256) private _userNonces;
    // digest => consumed
    mapping(bytes32 => bool) private _consumedDigest;

    string public constant DOMAIN_NAME = "PredifiIntent";
    string public constant DOMAIN_VERSION = "1";

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin, address _vault) external initializer {
        require(admin != address(0) && _vault != address(0), "ZeroAddr");
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __EIP712_init(DOMAIN_NAME, DOMAIN_VERSION);
        _grantRole(ADMIN_ROLE, admin);
        vault = IStagingEscrowVault(_vault);
        emit VaultUpdated(_vault);
    }

    function setVault(address _vault) external onlyRole(ADMIN_ROLE) {
        require(_vault != address(0), "ZeroAddr");
        vault = IStagingEscrowVault(_vault);
        emit VaultUpdated(_vault);
    }

    // Called by messenger after verifying venue-chain receipt/forward.
    function settleFromMessenger(bytes32 orderId, uint256 amountDelta, uint256 feeDelta) external whenNotPaused onlyRole(MESSENGER_ROLE) {
        vault.releaseForOrder(orderId, amountDelta, feeDelta);
        emit Settled(orderId, amountDelta, feeDelta);
    }

     /**
     * @notice Reserve funds in the vault using a user-signed EIP-712 intent.
     */
    /// @notice Reserve funds per a user EIP-712 intent (ordered; uses per-user nonces)
    /// @dev Reverts:
    ///  - Expired when block.timestamp >= intent.expiry
    ///  - BadNonce if intent.nonce != next expected nonce
    ///  - BadSig if signature does not recover to intent.user under this domain
    ///  - InsufficientAvailFeeCap when user's available < amount+feeCap
    ///  - Finalized can bubble from downstream operations in cancel/settle paths, not here
    ///  Emits IntentFailed and IntentFailedSummary on downstream reserve failure without burning nonce/digest
    function reserveFromIntent(Intent calldata intent, bytes calldata signature) external whenNotPaused onlyRole(MATCHER_ROLE) {
        // expiry
        require(block.timestamp < intent.expiry, "Expired");
        // nonce
        uint256 expected = _userNonces[intent.user];
        require(intent.nonce == expected, "BadNonce");
        // signer
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    INTENT_TYPEHASH,
                    intent.user,
                    intent.orderId,
                    intent.asset,
                    intent.amount,
                    intent.feeCap,
                    intent.lpRecipient,
                    intent.feeRecipient,
                    intent.expiry,
                    intent.nonce
                )
            )
        );
        require(!_consumedDigest[digest], "Used");
        address recovered = digest.recover(signature);
        require(recovered == intent.user, "BadSig");
        // optional economic guard: ensure feeCap is also funded
        (uint256 avail, ) = vault.balances(intent.user, intent.asset);
        require(avail >= intent.amount + intent.feeCap, "InsufficientAvailFeeCap");

        // call vault.reserve (requires SettlementAuthority to have role on the vault)
        try vault.reserve(
            intent.user,
            intent.orderId,
            intent.asset,
            intent.amount,
            intent.feeCap,
            intent.lpRecipient,
            intent.feeRecipient,
            intent.expiry
        ) {
            // mark success
            _userNonces[intent.user] = expected + 1;
            _consumedDigest[digest] = true;
            emit IntentConsumed(digest, intent.user, intent.orderId, intent.nonce, intent.amount, intent.feeCap);
        } catch (bytes memory reason) {
            bytes4 sel;
            if (reason.length >= 4) {
                assembly { sel := mload(add(reason, 0x20)) }
            }
            emit IntentFailedSummary(intent.user, intent.orderId, digest, sel, keccak256(reason));
            // failure: do NOT mark nonce/digest consumed
            emit IntentFailed(intent.user, intent.orderId, digest, reason);
            revert();
        }
    }

    /**
     * @notice Unordered reserve: uses digest replay guard instead of sequential nonce.
     */
    /// @notice Reserve funds per a user EIP-712 intent (unordered; uses digest replay guard)
    /// @dev Reverts Expired/BadSig/Used/InsufficientAvailFeeCap. Emits IntentFailed and summary on downstream failure.
    function reserveFromIntentUnordered(Intent calldata intent, bytes calldata signature) external whenNotPaused onlyRole(MATCHER_ROLE) {
        require(block.timestamp < intent.expiry, "Expired");
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    INTENT_TYPEHASH,
                    intent.user,
                    intent.orderId,
                    intent.asset,
                    intent.amount,
                    intent.feeCap,
                    intent.lpRecipient,
                    intent.feeRecipient,
                    intent.expiry,
                    intent.nonce
                )
            )
        );
        require(!_consumedDigest[digest], "Used");
        address recovered = digest.recover(signature);
        require(recovered == intent.user, "BadSig");
        (uint256 avail, ) = vault.balances(intent.user, intent.asset);
        require(avail >= intent.amount + intent.feeCap, "InsufficientAvailFeeCap");
        try vault.reserve(
            intent.user,
            intent.orderId,
            intent.asset,
            intent.amount,
            intent.feeCap,
            intent.lpRecipient,
            intent.feeRecipient,
            intent.expiry
        ) {
            _consumedDigest[digest] = true;
            emit IntentConsumed(digest, intent.user, intent.orderId, intent.nonce, intent.amount, intent.feeCap);
        } catch (bytes memory reason) {
            bytes4 sel;
            if (reason.length >= 4) {
                assembly { sel := mload(add(reason, 0x20)) }
            }
            emit IntentFailedSummary(intent.user, intent.orderId, digest, sel, keccak256(reason));
            emit IntentFailed(intent.user, intent.orderId, digest, reason);
            revert();
        }
    }

    // Cancel intent
    struct CancelIntent {
        address user;
        bytes32 orderId;
        address asset;
        uint64 expiry;
        uint256 nonce;
    }

    bytes32 private constant CANCEL_TYPEHASH = keccak256(
        "CancelIntent(address user,bytes32 orderId,address asset,uint64 expiry,uint256 nonce)"
    );

    event CancelIntentConsumed(bytes32 indexed intentHash, address indexed user, bytes32 indexed orderId, uint256 nonce);

    error Finalized();

    /// @notice Cancel an intent by releasing any remaining reserved amount back to available and finalizing the order.
    /// @dev Reverts:
    ///  - Expired when block.timestamp >= intent.expiry
    ///  - Used if the same digest was already consumed
    ///  - BadSig if signature invalid
    ///  - Finalized if no remaining reservation (already canceled or fully settled)
    ///  Emits IntentFailed and summary on downstream failure.
    function cancelFromIntent(CancelIntent calldata intent, bytes calldata signature) external whenNotPaused onlyRole(MATCHER_ROLE) {
        require(block.timestamp < intent.expiry, "Expired");
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    CANCEL_TYPEHASH,
                    intent.user,
                    intent.orderId,
                    intent.asset,
                    intent.expiry,
                    intent.nonce
                )
            )
        );
        require(!_consumedDigest[digest], "Used");
        address recovered = digest.recover(signature);
        require(recovered == intent.user, "BadSig");

        uint256 remaining = vault.getOrderReserved(intent.user, intent.orderId);
        if (remaining == 0) revert Finalized();

        try vault.release(intent.user, intent.asset, intent.orderId, remaining) {
            _consumedDigest[digest] = true;
            emit CancelIntentConsumed(digest, intent.user, intent.orderId, intent.nonce);
        } catch (bytes memory reason) {
            bytes4 sel;
            if (reason.length >= 4) {
                assembly { sel := mload(add(reason, 0x20)) }
            }
            emit IntentFailedSummary(intent.user, intent.orderId, digest, sel, keccak256(reason));
            emit IntentFailed(intent.user, intent.orderId, digest, reason);
            revert();
        }
    }

    // Settle principal intent
    struct SettleIntent {
        address user;
        bytes32 orderId;
        address asset;
        uint256 amount;
        address to;
        uint64 expiry;
        uint256 nonce;
    }

    bytes32 private constant SETTLE_TYPEHASH = keccak256(
        "SettleIntent(address user,bytes32 orderId,address asset,uint256 amount,address to,uint64 expiry,uint256 nonce)"
    );

    event SettleIntentConsumed(bytes32 indexed intentHash, address indexed user, bytes32 indexed orderId, uint256 nonce, uint256 amount, address to);

    /// @notice Settle/debit reserved principal to a recipient per user EIP-712 intent (unordered; digest replay guard)
    /// @dev Reverts Expired/BadSig/Used. Downstream may revert Finalized/InsufficientReserved. Emits failure events on catch.
    function settleDebitFromIntent(SettleIntent calldata intent, bytes calldata signature) external whenNotPaused onlyRole(MATCHER_ROLE) {
        require(block.timestamp < intent.expiry, "Expired");
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SETTLE_TYPEHASH,
                    intent.user,
                    intent.orderId,
                    intent.asset,
                    intent.amount,
                    intent.to,
                    intent.expiry,
                    intent.nonce
                )
            )
        );
        require(!_consumedDigest[digest], "Used");
        address recovered = digest.recover(signature);
        require(recovered == intent.user, "BadSig");
        try vault.settleDebit(intent.user, intent.asset, intent.orderId, intent.amount, intent.to) {
            _consumedDigest[digest] = true;
            emit SettleIntentConsumed(digest, intent.user, intent.orderId, intent.nonce, intent.amount, intent.to);
        } catch (bytes memory reason) {
            bytes4 sel;
            if (reason.length >= 4) {
                assembly { sel := mload(add(reason, 0x20)) }
            }
            emit IntentFailedSummary(intent.user, intent.orderId, digest, sel, keccak256(reason));
            emit IntentFailed(intent.user, intent.orderId, digest, reason);
            revert();
        }
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function getUserNonce(address user) external view returns (uint256) {
        return _userNonces[user];
    }

    /// @notice Returns whether a given digest has been consumed.
    /// @dev The user parameter is ignored and kept for indexer API symmetry across user-scoped endpoints.
    function isDigestConsumed(address /*user*/, bytes32 digest) external view returns (bool) {
        return _consumedDigest[digest];
    }

    /// @dev Testing helper: current ERC20 balance held by the vault (exposed for invariants in tests)
    function vaultTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(vault));
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // upgradeability gap for future variables
    uint256[49] private __gap;
}
