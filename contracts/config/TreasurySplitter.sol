// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../libs/Types.sol";

/**
 * @title TreasurySplitter
 * @notice Splits protocol fees among various recipients
 * @dev Handles fee distribution from LP vault and other protocol revenue
 */
contract TreasurySplitter is 
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant SPLITTER_ADMIN_ROLE = keccak256("SPLITTER_ADMIN_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    // Fee recipient structure
    struct FeeRecipient {
        address recipient;
        uint256 basisPoints; // Out of 10000 (100.00%)
        bool active;
        string description;
    }

    // State variables
    mapping(address => FeeRecipient[]) public tokenRecipients;
    mapping(address => uint256) public totalBasisPoints;
    mapping(address => mapping(address => uint256)) public recipientShares; // token => recipient => basis points
    
    // Default recipients (used when no token-specific recipients are set)
    FeeRecipient[] public defaultRecipients;
    uint256 public defaultTotalBasisPoints;
    
    // Fee collection tracking
    mapping(address => uint256) public totalFeesReceived;
    mapping(address => uint256) public totalFeesDistributed;
    mapping(address => mapping(address => uint256)) public distributedToRecipient;
    
    // Distribution settings
    uint256 public minimumDistributionAmount;
    bool public autoDistributeOnReceive;
    
    // Constants
    uint256 private constant MAX_BASIS_POINTS = 10000;
    uint256 private constant MAX_RECIPIENTS = 20;

    // Events
    event FeeReceived(address indexed token, uint256 amount, address from);
    event FeesDistributed(address indexed token, uint256 totalAmount, uint256 recipientCount);
    event RecipientConfigured(address indexed token, address indexed recipient, uint256 basisPoints, bool active);
    event DefaultRecipientConfigured(address indexed recipient, uint256 basisPoints, bool active);
    event DistributionSettingsUpdated(uint256 minimumAmount, bool autoDistribute);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the treasury splitter
     * @param admin Admin address
     * @param distributor Distributor address (typically LP vault)
     */
    function initialize(address admin, address distributor) external initializer {
        if (admin == address(0) || distributor == address(0)) revert Types.ZeroAddress();

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SPLITTER_ADMIN_ROLE, admin);
        _grantRole(DISTRIBUTOR_ROLE, distributor);

        minimumDistributionAmount = 1e6; // 1 USDC minimum by default
        autoDistributeOnReceive = true;
    }

    /**
     * @notice Receive fees from protocol components
     * @param token Token being received
     * @param amount Amount being received
     */
    function receiveFees(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert Types.InvalidAmount();
        
        // Transfer tokens from sender
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        totalFeesReceived[token] += amount;
        
        emit FeeReceived(token, amount, msg.sender);
        
        // Auto-distribute if enabled and meets minimum
        if (autoDistributeOnReceive && amount >= minimumDistributionAmount) {
            _distributeFees(token);
        }
    }

    /**
     * @notice Manually distribute fees for a token
     * @param token Token to distribute
     * @return distributedAmount Amount distributed
     */
    function distributeFees(address token) external nonReentrant returns (uint256 distributedAmount) {
        return _distributeFees(token);
    }

    /**
     * @notice Batch distribute fees for multiple tokens
     * @param tokens Array of tokens to distribute
     * @return distributedAmounts Array of distributed amounts
     */
    function batchDistributeFees(
        address[] calldata tokens
    ) external nonReentrant returns (uint256[] memory distributedAmounts) {
        distributedAmounts = new uint256[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length; i++) {
            distributedAmounts[i] = _distributeFees(tokens[i]);
        }
    }

    /**
     * @notice Configure fee recipient for specific token
     * @param token Token address
     * @param recipient Recipient address
     * @param basisPoints Basis points (out of 10000)
     * @param active Whether recipient is active
     * @param description Description of recipient
     */
    function configureTokenRecipient(
        address token,
        address recipient,
        uint256 basisPoints,
        bool active,
        string calldata description
    ) external onlyRole(SPLITTER_ADMIN_ROLE) {
        if (recipient == address(0)) revert Types.ZeroAddress();
        if (basisPoints > MAX_BASIS_POINTS) revert Types.InvalidBasisPoints();
        
        FeeRecipient[] storage recipients = tokenRecipients[token];
        
        // Find existing recipient or add new one
        bool found = false;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i].recipient == recipient) {
                // Update existing recipient
                totalBasisPoints[token] = totalBasisPoints[token] - recipients[i].basisPoints + basisPoints;
                recipients[i].basisPoints = basisPoints;
                recipients[i].active = active;
                recipients[i].description = description;
                found = true;
                break;
            }
        }
        
        if (!found && active) {
            // Add new recipient
            if (recipients.length >= MAX_RECIPIENTS) revert Types.TooManyRecipients();
            recipients.push(FeeRecipient({
                recipient: recipient,
                basisPoints: basisPoints,
                active: active,
                description: description
            }));
            totalBasisPoints[token] += basisPoints;
        }
        
        if (totalBasisPoints[token] > MAX_BASIS_POINTS) revert Types.InvalidBasisPoints();
        
        recipientShares[token][recipient] = active ? basisPoints : 0;
        
        emit RecipientConfigured(token, recipient, basisPoints, active);
    }

    /**
     * @notice Configure default fee recipient (used when no token-specific recipients)
     * @param recipient Recipient address
     * @param basisPoints Basis points (out of 10000)
     * @param active Whether recipient is active
     * @param description Description of recipient
     */
    function configureDefaultRecipient(
        address recipient,
        uint256 basisPoints,
        bool active,
        string calldata description
    ) external onlyRole(SPLITTER_ADMIN_ROLE) {
        if (recipient == address(0)) revert Types.ZeroAddress();
        if (basisPoints > MAX_BASIS_POINTS) revert Types.InvalidBasisPoints();
        
        // Find existing recipient or add new one
        bool found = false;
        for (uint256 i = 0; i < defaultRecipients.length; i++) {
            if (defaultRecipients[i].recipient == recipient) {
                // Update existing recipient
                defaultTotalBasisPoints = defaultTotalBasisPoints - defaultRecipients[i].basisPoints + basisPoints;
                defaultRecipients[i].basisPoints = basisPoints;
                defaultRecipients[i].active = active;
                defaultRecipients[i].description = description;
                found = true;
                break;
            }
        }
        
        if (!found && active) {
            // Add new recipient
            if (defaultRecipients.length >= MAX_RECIPIENTS) revert Types.TooManyRecipients();
            defaultRecipients.push(FeeRecipient({
                recipient: recipient,
                basisPoints: basisPoints,
                active: active,
                description: description
            }));
            defaultTotalBasisPoints += basisPoints;
        }
        
        if (defaultTotalBasisPoints > MAX_BASIS_POINTS) revert Types.InvalidBasisPoints();
        
        emit DefaultRecipientConfigured(recipient, basisPoints, active);
    }

    /**
     * @notice Update distribution settings
     * @param minimumAmount Minimum amount for auto-distribution
     * @param autoDistribute Whether to auto-distribute on receive
     */
    function updateDistributionSettings(
        uint256 minimumAmount,
        bool autoDistribute
    ) external onlyRole(SPLITTER_ADMIN_ROLE) {
        minimumDistributionAmount = minimumAmount;
        autoDistributeOnReceive = autoDistribute;
        
        emit DistributionSettingsUpdated(minimumAmount, autoDistribute);
    }

    /**
     * @notice Emergency withdrawal (admin only)
     * @param token Token to withdraw
     * @param to Withdrawal destination
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert Types.ZeroAddress();
        if (amount == 0) revert Types.InvalidAmount();
        
        IERC20(token).safeTransfer(to, amount);
        
        emit EmergencyWithdrawal(token, to, amount);
    }

    // View functions
    function getTokenRecipients(address token) external view returns (FeeRecipient[] memory) {
        return tokenRecipients[token];
    }

    function getDefaultRecipients() external view returns (FeeRecipient[] memory) {
        return defaultRecipients;
    }

    function getDistributableAmount(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function getRecipientShare(address token, address recipient) external view returns (uint256) {
        return recipientShares[token][recipient];
    }

    function getTotalBasisPoints(address token) external view returns (uint256) {
        return totalBasisPoints[token] > 0 ? totalBasisPoints[token] : defaultTotalBasisPoints;
    }

    function canDistribute(address token) external view returns (bool) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        return balance >= minimumDistributionAmount && 
               (totalBasisPoints[token] > 0 || defaultTotalBasisPoints > 0);
    }

    // Internal functions
    function _distributeFees(address token) internal returns (uint256 distributedAmount) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return 0;
        
        FeeRecipient[] memory recipients;
        uint256 totalBasis;
        
        // Use token-specific recipients if available, otherwise use defaults
        if (tokenRecipients[token].length > 0 && totalBasisPoints[token] > 0) {
            recipients = tokenRecipients[token];
            totalBasis = totalBasisPoints[token];
        } else if (defaultRecipients.length > 0 && defaultTotalBasisPoints > 0) {
            recipients = defaultRecipients;
            totalBasis = defaultTotalBasisPoints;
        } else {
            return 0; // No recipients configured
        }
        
        uint256 distributed = 0;
        uint256 activeRecipients = 0;
        
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i].active && recipients[i].basisPoints > 0) {
                uint256 share = (balance * recipients[i].basisPoints) / totalBasis;
                if (share > 0) {
                    IERC20(token).safeTransfer(recipients[i].recipient, share);
                    distributedToRecipient[token][recipients[i].recipient] += share;
                    distributed += share;
                    activeRecipients++;
                }
            }
        }
        
        if (distributed > 0) {
            totalFeesDistributed[token] += distributed;
            emit FeesDistributed(token, distributed, activeRecipients);
        }
        
        return distributed;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // Gap for future storage variables
    uint256[50] private __gap;
}