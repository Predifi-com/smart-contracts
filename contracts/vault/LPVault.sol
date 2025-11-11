// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/ILPVault.sol";
import "../interfaces/IBridgeAdapter.sol";
import "../interfaces/IYieldAdapter.sol";
import "../libs/Types.sol";
import "../libs/SafeCastExt.sol";

/**
 * @title LPVault
 * @notice ERC-4626 vault for LP deposits on hub chain with fee management
 * @dev UUPS upgradeable vault with proper totalAssets() and pull-on-redeem accounting
 */
contract LPVault is 
    ILPVault,
    ERC4626Upgradeable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCastExt for uint256;

    // Roles
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant BRIDGE_MANAGER_ROLE = keccak256("BRIDGE_MANAGER_ROLE");
    bytes32 public constant YIELD_MANAGER_ROLE = keccak256("YIELD_MANAGER_ROLE");

    // State variables
    address public treasury;
    uint16 public protocolFeeBps;
    uint256 public totalFees;
    uint256 public pendingFees;
    
    // Fee tracking
    mapping(address => uint256) private _userLastDeposit;
    mapping(address => uint256) private _userAccumulatedFees;
    
    // Bridge adapters: domain => adapter address
    mapping(uint32 => address) public bridgeAdapters;
    
    // Authorized recipients: domain => recipient => authorized
    mapping(uint32 => mapping(address => bool)) public authorizedRecipients;
    
    // Yield adapters: array of yield strategy adapters
    address[] public yieldAdapters;
    mapping(address => bool) public isYieldAdapter;
    
    // Yield allocation tracking
    uint256 public totalDeployedToYield;

    // Constants
    uint16 private constant MAX_FEE_BPS = 1000; // 10% max fee
    uint256 private constant FEE_PRECISION = 10_000;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the LP vault
     * @param asset Underlying asset (e.g., USDC)
     * @param name Vault token name
     * @param symbol Vault token symbol
     * @param _treasury Treasury address for fee collection
     * @param _protocolFeeBps Protocol fee in basis points
     */
    function initialize(
        IERC20 asset,
        string memory name,
        string memory symbol,
        address _treasury,
        uint16 _protocolFeeBps
    ) external initializer {
        if (_treasury == address(0)) revert Types.ZeroAddress();
        if (_protocolFeeBps > MAX_FEE_BPS) revert Types.InvalidConfiguration();

        __ERC4626_init(asset);
        __ERC20_init(name, symbol);
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        treasury = _treasury;
        protocolFeeBps = _protocolFeeBps;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TREASURY_ROLE, _treasury);
        _grantRole(PAUSE_ROLE, msg.sender);
    }

    /**
     * @notice Get total assets including deployed to yield strategies
     * @return Total assets under management
     */
    function totalAssets() public view override(ERC4626Upgradeable, ILPVault) returns (uint256) {
        uint256 idleLiquidity = IERC20(asset()).balanceOf(address(this));
        
        // Add deployed yield across all adapters
        uint256 yieldAssets = 0;
        for (uint256 i = 0; i < yieldAdapters.length; i++) {
            yieldAssets += IYieldAdapter(yieldAdapters[i]).totalAssets();
        }
        
        return idleLiquidity + yieldAssets - pendingFees;
    }

    /**
     * @notice Deposit assets and mint shares
     * @param assets Amount of assets to deposit
     * @param receiver Receiver of vault shares
     * @return shares Amount of shares minted
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public override(ERC4626Upgradeable, IERC4626) nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) revert Types.ZeroAmount();
        if (receiver == address(0)) revert Types.ZeroAddress();

        shares = super.deposit(assets, receiver);
        _userLastDeposit[receiver] = block.timestamp;

        // Calculate and track fees
        uint256 feeAmount = SafeCastExt.bpsMul(assets, protocolFeeBps);
        if (feeAmount > 0) {
            pendingFees += feeAmount;
            totalFees += feeAmount;
            _userAccumulatedFees[receiver] += feeAmount;
        }
    }

    /**
     * @notice Mint shares for exact amount
     * @param shares Amount of shares to mint
     * @param receiver Receiver of vault shares
     * @return assets Amount of assets deposited
     */
    function mint(
        uint256 shares,
        address receiver
    ) public override(ERC4626Upgradeable, IERC4626) nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert Types.ZeroAmount();
        if (receiver == address(0)) revert Types.ZeroAddress();

        assets = super.mint(shares, receiver);
        _userLastDeposit[receiver] = block.timestamp;

        // Calculate and track fees
        uint256 feeAmount = SafeCastExt.bpsMul(assets, protocolFeeBps);
        if (feeAmount > 0) {
            pendingFees += feeAmount;
            totalFees += feeAmount;
            _userAccumulatedFees[receiver] += feeAmount;
        }
    }

    /**
     * @notice Withdraw assets by burning shares
     * @param assets Amount of assets to withdraw
     * @param receiver Receiver of assets
     * @param owner Owner of shares to burn
     * @return shares Amount of shares burned
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override(ERC4626Upgradeable, IERC4626) nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) revert Types.ZeroAmount();
        if (receiver == address(0)) revert Types.ZeroAddress();

        // Collect fees before withdrawal
        _collectFeesInternal();
        
        return super.withdraw(assets, receiver, owner);
    }

    /**
     * @notice Redeem shares for assets
     * @param shares Amount of shares to redeem
     * @param receiver Receiver of assets
     * @param owner Owner of shares to burn
     * @return assets Amount of assets withdrawn
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override(ERC4626Upgradeable, IERC4626) nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert Types.ZeroAmount();
        if (receiver == address(0)) revert Types.ZeroAddress();

        // Collect fees before redemption
        _collectFeesInternal();
        
        return super.redeem(shares, receiver, owner);
    }

    /**
     * @notice Set treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert Types.ZeroAddress();
        
        address oldTreasury = treasury;
        treasury = _treasury;
        
        _revokeRole(TREASURY_ROLE, oldTreasury);
        _grantRole(TREASURY_ROLE, _treasury);
        
        emit TreasurySet(oldTreasury, _treasury);
    }

    /**
     * @notice Set protocol fee
     * @param _protocolFeeBps New protocol fee in basis points
     */
    function setProtocolFeeBps(uint16 _protocolFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_protocolFeeBps > MAX_FEE_BPS) revert Types.InvalidConfiguration();
        
        uint16 oldFeeBps = protocolFeeBps;
        protocolFeeBps = _protocolFeeBps;
        
        emit ProtocolFeeSet(oldFeeBps, _protocolFeeBps);
    }

    /**
     * @notice Collect accumulated fees
     * @return feeAmount Amount of fees collected
     */
    function collectFees() external onlyRole(TREASURY_ROLE) returns (uint256 feeAmount) {
        return _collectFeesInternal();
    }

    /**
     * @notice Distribute yield to vault
     * @param amount Amount of yield to distribute
     */
    function distributeYield(uint256 amount) external onlyRole(TREASURY_ROLE) {
        if (amount == 0) revert Types.ZeroAmount();
        
    IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        
        emit YieldDistributed(amount, block.timestamp);
    }
    
    /**
     * @notice Receive bridged liquidity back from BufferVault
     * @dev Called after CCTP mints USDC back from venue chains
     */
    function receiveFromVenue() external onlyRole(BRIDGE_MANAGER_ROLE) nonReentrant {
        // No-op: USDC is already in the vault via CCTP mint
        // This function just provides an audit trail
        uint256 currentBalance = IERC20(asset()).balanceOf(address(this));
        emit LiquidityReceivedFromVenue(currentBalance, block.timestamp);
    }

    // Pausable functions
    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSE_ROLE) {
        _unpause();
    }

    // ============ Bridge Functions ============
    
    /**
     * @notice Bridge liquidity to BufferVault on venue chain
     * @param destinationDomain CCTP domain ID of destination chain
     * @param bufferVault Address of BufferVault on destination chain
     * @param amount Amount of USDC to bridge
     * @param bridgeData Additional bridge-specific data (fees, hooks, etc.)
     * @return messageId Unique identifier for cross-chain message
     */
    function bridgeToVenue(
        uint32 destinationDomain,
        address bufferVault,
        uint256 amount,
        bytes calldata bridgeData
    ) external onlyRole(BRIDGE_MANAGER_ROLE) nonReentrant returns (bytes32 messageId) {
        if (amount == 0) revert Types.ZeroAmount();
        if (bufferVault == address(0)) revert Types.ZeroAddress();
        
        // Check BufferVault is authorized
        if (!authorizedRecipients[destinationDomain][bufferVault]) {
            revert UnauthorizedRecipient(destinationDomain, bufferVault);
        }
        
        // Check bridge adapter exists
        address adapter = bridgeAdapters[destinationDomain];
        if (adapter == address(0)) revert NoBridgeAdapter(destinationDomain);
        
        // Check sufficient liquidity (may need to withdraw from yield)
        uint256 idleLiquidity = IERC20(asset()).balanceOf(address(this));
        if (amount > idleLiquidity) {
            _withdrawFromYield(amount - idleLiquidity);
        }
        
        // Approve adapter to spend USDC
        IERC20(asset()).approve(adapter, amount);
        
        // Execute bridge to BufferVault
        messageId = IBridgeAdapter(adapter).bridgeUSDC(
            amount,
            destinationDomain,
            bufferVault,
            bridgeData
        );
        
        emit LiquidityBridged(destinationDomain, bufferVault, amount, messageId);
    }
    
    /**
     * @notice Set bridge adapter for a domain
     * @param destinationDomain CCTP domain ID
     * @param adapter Address of bridge adapter contract
     */
    function setBridgeAdapter(
        uint32 destinationDomain,
        address adapter
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldAdapter = bridgeAdapters[destinationDomain];
        bridgeAdapters[destinationDomain] = adapter;
        
        emit BridgeAdapterSet(destinationDomain, oldAdapter, adapter);
    }
    
    /**
     * @notice Authorize BufferVault on destination chain
     * @param destinationDomain CCTP domain ID
     * @param bufferVault Address of BufferVault on destination chain
     * @param authorized Whether to authorize or revoke
     */
    function setAuthorizedRecipient(
        uint32 destinationDomain,
        address bufferVault,
        bool authorized
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bufferVault == address(0)) revert Types.ZeroAddress();
        
        authorizedRecipients[destinationDomain][bufferVault] = authorized;
        
        emit RecipientAuthorizationSet(destinationDomain, bufferVault, authorized);
    }
    
    // ============ Yield Strategy Functions ============
    
    /**
     * @notice Deploy idle liquidity to yield strategy
     * @param adapter Address of yield adapter
     * @param amount Amount of USDC to deploy
     * @return shares Amount of yield-bearing tokens received
     */
    function deployToYield(
        address adapter,
        uint256 amount
    ) external onlyRole(YIELD_MANAGER_ROLE) nonReentrant returns (uint256 shares) {
        if (amount == 0) revert Types.ZeroAmount();
        if (!isYieldAdapter[adapter]) revert InvalidYieldAdapter(adapter);
        
        // Check sufficient idle liquidity
        uint256 idleLiquidity = IERC20(asset()).balanceOf(address(this));
        if (amount > idleLiquidity - pendingFees) revert InsufficientLiquidity();
        
        // Approve adapter
        IERC20(asset()).approve(adapter, amount);
        
        // Deploy to yield
        shares = IYieldAdapter(adapter).deposit(amount);
        totalDeployedToYield += amount;
        
        emit YieldDeployed(adapter, amount, shares);
    }
    
    /**
     * @notice Withdraw from yield strategy
     * @param adapter Address of yield adapter
     * @param amount Amount of USDC to withdraw
     * @return shares Amount of yield-bearing tokens burned
     */
    function withdrawFromYield(
        address adapter,
        uint256 amount
    ) external onlyRole(YIELD_MANAGER_ROLE) nonReentrant returns (uint256 shares) {
        if (amount == 0) revert Types.ZeroAmount();
        if (!isYieldAdapter[adapter]) revert InvalidYieldAdapter(adapter);
        
        shares = IYieldAdapter(adapter).withdraw(amount);
        totalDeployedToYield -= amount;
        
        emit YieldWithdrawn(adapter, amount, shares);
    }
    
    /**
     * @notice Add yield adapter
     * @param adapter Address of yield adapter
     */
    function addYieldAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0)) revert Types.ZeroAddress();
        if (isYieldAdapter[adapter]) revert YieldAdapterAlreadyExists(adapter);
        
        yieldAdapters.push(adapter);
        isYieldAdapter[adapter] = true;
        
        emit YieldAdapterAdded(adapter);
    }
    
    /**
     * @notice Remove yield adapter
     * @param adapter Address of yield adapter
     */
    function removeYieldAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isYieldAdapter[adapter]) revert InvalidYieldAdapter(adapter);
        
        // Find and remove from array
        for (uint256 i = 0; i < yieldAdapters.length; i++) {
            if (yieldAdapters[i] == adapter) {
                yieldAdapters[i] = yieldAdapters[yieldAdapters.length - 1];
                yieldAdapters.pop();
                break;
            }
        }
        
        isYieldAdapter[adapter] = false;
        
        emit YieldAdapterRemoved(adapter);
    }
    
    /**
     * @notice Get all yield adapters
     * @return Array of yield adapter addresses
     */
    function getYieldAdapters() external view returns (address[] memory) {
        return yieldAdapters;
    }
    
    /**
     * @notice Internal function to withdraw from yield strategies
     * @param amount Amount needed
     */
    function _withdrawFromYield(uint256 amount) internal {
        uint256 remaining = amount;
        
        // Withdraw proportionally from all adapters
        for (uint256 i = 0; i < yieldAdapters.length && remaining > 0; i++) {
            uint256 adapterBalance = IYieldAdapter(yieldAdapters[i]).totalAssets();
            uint256 toWithdraw = remaining > adapterBalance ? adapterBalance : remaining;
            
            if (toWithdraw > 0) {
                IYieldAdapter(yieldAdapters[i]).withdraw(toWithdraw);
                remaining -= toWithdraw;
                totalDeployedToYield -= toWithdraw;
            }
        }
        
        if (remaining > 0) revert InsufficientLiquidity();
    }

    // Internal functions
    function _collectFeesInternal() internal returns (uint256 feeAmount) {
        feeAmount = pendingFees;
        if (feeAmount > 0) {
            pendingFees = 0;
            IERC20(asset()).safeTransfer(treasury, feeAmount);
            emit FeesCollected(asset(), feeAmount);
        }
    }

    // Override functions to resolve conflicts
    function convertToShares(uint256 assets) public view override(ERC4626Upgradeable, ILPVault) returns (uint256) {
        return super.convertToShares(assets);
    }

    function convertToAssets(uint256 shares) public view override(ERC4626Upgradeable, ILPVault) returns (uint256) {
        return super.convertToAssets(shares);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ============ Errors ============
    
    error UnauthorizedRecipient(uint32 domain, address recipient);
    error NoBridgeAdapter(uint32 domain);
    error InsufficientLiquidity();
    error InvalidYieldAdapter(address adapter);
    error YieldAdapterAlreadyExists(address adapter);

    // Gap for future storage variables
    uint256[40] private __gap; // Reduced from 50 to account for new storage
}