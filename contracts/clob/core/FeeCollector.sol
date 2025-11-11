// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../libs/CLOBTypes.sol";
import "../libs/CLOBErrors.sol";
import "../interfaces/ICLOBCore.sol";

/**
 * @title FeeCollector
 * @notice Collects and manages trading fees (fee-on-resolve model)
 * @dev Winners pay 2-5% fee (configurable by admin) on market resolution
 * @custom:security-contact security@predifi.com
 */
contract FeeCollector is 
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IFeeCollector
{
    using SafeERC20 for IERC20;

    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");

    /// @notice Fee configuration
    CLOBTypes.FeeConfig public feeConfig;

    /// @notice Collateral token (e.g., USDC)
    IERC20 public collateralToken;

    /// @notice Total fees collected per market
    mapping(uint256 => uint256) public marketFees;

    /// @notice Total fees available for withdrawal
    uint256 public totalFeesCollected;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param admin Address to receive admin roles
     * @param collateralToken_ Collateral token address (e.g., USDC)
     * @param feeRecipient_ Initial fee recipient
     */
    function initialize(
        address admin,
        address collateralToken_,
        address feeRecipient_
    ) public initializer {
        if (admin == address(0) || collateralToken_ == address(0)) {
            revert CLOBErrors.ZeroAddress();
        }
        if (feeRecipient_ == address(0)) {
            revert CLOBErrors.InvalidFeeRecipient(feeRecipient_);
        }

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(FEE_MANAGER_ROLE, admin);

        collateralToken = IERC20(collateralToken_);
        feeConfig = CLOBTypes.FeeConfig({
            defaultFeeBps: CLOBTypes.DEFAULT_FEE_BPS,
            maxFeeBps: CLOBTypes.MAX_FEE_BPS,
            feeRecipient: feeRecipient_
        });
    }

    /**
     * @notice Collect fee from a user (called by Settlement contract)
     * @param marketId Market identifier
     * @param from User to collect fee from
     * @param amount Winning amount (before fee)
     * @return fee Amount of fee collected
     */
    function collectFee(
        uint256 marketId,
        address from,
        uint256 amount
    ) external onlyRole(SETTLEMENT_ROLE) nonReentrant returns (uint256 fee) {
        if (from == address(0)) revert CLOBErrors.ZeroAddress();
        if (amount == 0) return 0;

        // Calculate fee based on market's fee config
        // For now, use default fee (can be extended to per-market fees)
        fee = (amount * feeConfig.defaultFeeBps) / CLOBTypes.BPS_DIVISOR;

        if (fee > 0) {
            // Transfer fee from user
            collateralToken.safeTransferFrom(from, address(this), fee);

            // Track fees
            marketFees[marketId] += fee;
            totalFeesCollected += fee;

            emit FeeCollected(marketId, from, fee, feeConfig.defaultFeeBps);
        }

        return fee;
    }

    /**
     * @notice Withdraw collected fees
     * @param recipient Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawFees(
        address recipient,
        uint256 amount
    ) external onlyRole(FEE_MANAGER_ROLE) nonReentrant {
        if (recipient == address(0)) revert CLOBErrors.ZeroAddress();
        if (amount == 0) revert CLOBErrors.ZeroAmount();
        if (amount > totalFeesCollected) {
            revert CLOBErrors.InsufficientBalance(amount, totalFeesCollected);
        }

        totalFeesCollected -= amount;
        collateralToken.safeTransfer(recipient, amount);

        emit FeeWithdrawn(recipient, amount);
    }

    /**
     * @notice Update fee configuration
     * @param defaultFeeBps New default fee in basis points
     * @param maxFeeBps New maximum fee cap in basis points
     */
    function updateFeeConfig(
        uint16 defaultFeeBps,
        uint16 maxFeeBps
    ) external onlyRole(FEE_MANAGER_ROLE) {
        if (defaultFeeBps > maxFeeBps) {
            revert CLOBErrors.FeeTooHigh(defaultFeeBps, maxFeeBps);
        }
        if (maxFeeBps > CLOBTypes.MAX_FEE_BPS) {
            revert CLOBErrors.FeeTooHigh(maxFeeBps, CLOBTypes.MAX_FEE_BPS);
        }

        feeConfig.defaultFeeBps = defaultFeeBps;
        feeConfig.maxFeeBps = maxFeeBps;

        emit FeeConfigUpdated(defaultFeeBps, maxFeeBps);
    }

    /**
     * @notice Update fee recipient
     * @param newRecipient New fee recipient address
     */
    function updateFeeRecipient(address newRecipient) external onlyRole(FEE_MANAGER_ROLE) {
        if (newRecipient == address(0)) {
            revert CLOBErrors.InvalidFeeRecipient(newRecipient);
        }
        feeConfig.feeRecipient = newRecipient;
    }

    /**
     * @notice Get current fee configuration
     * @return Fee configuration struct
     */
    function getFeeConfig() external view returns (CLOBTypes.FeeConfig memory) {
        return feeConfig;
    }

    /**
     * @notice Calculate fee for a given amount
     * @param amount Amount to calculate fee for
     * @return fee Calculated fee
     */
    function calculateFee(uint256 amount) external view returns (uint256 fee) {
        return (amount * feeConfig.defaultFeeBps) / CLOBTypes.BPS_DIVISOR;
    }

    /**
     * @notice Authorize upgrades (UUPS pattern)
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(UPGRADER_ROLE) 
    {
        // Authorization check via modifier
    }
}
