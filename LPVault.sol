// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";

/// @notice Minimal WETH / WHBAR interface — wrap and unwrap native gas token.
interface IWETH {
    function deposit()                             external payable;
    function withdraw(uint256 amount)              external;
    function approve(address spender, uint256 amt) external returns (bool);
}

contract LPVault is
    ERC4626Upgradeable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant PAUSER_ROLE         = keccak256("PAUSER_ROLE");
    bytes32 public constant BRIDGE_MANAGER_ROLE = keccak256("BRIDGE_MANAGER_ROLE");
    bytes32 public constant YIELD_MANAGER_ROLE  = keccak256("YIELD_MANAGER_ROLE");

    // Constants
    uint256 public constant MAX_YIELD_ADAPTERS = 10;

    // State

    mapping(uint32 => address) public bridgeAdapters;
    mapping(uint32 => mapping(address => bool)) public authorizedRecipients;
    address[] public yieldAdapters;

    mapping(address => bool) public isYieldAdapter;
    uint256 public totalDeployedToYield;

    // Dual-yield reward state

    address public rewardToken;
    uint256 public rewardsDuration;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public rewardDust;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    address public nativeWrapper;

    // Events

    event YieldAdapterAdded(address indexed adapter, string adapterName);
    event YieldAdapterRemoved(address indexed adapter);
    event YieldDeployed(address indexed adapter, uint256 amount, uint256 totalDeployed);
    event YieldWithdrawn(address indexed adapter, uint256 amountRequested, uint256 totalDeployed);

    event BridgeAdapterSet(uint32 indexed domain, address oldAdapter, address newAdapter);
    event RecipientAuthorizationSet(uint32 indexed domain, address indexed recipient, bool authorized);
    event LiquidityBridged(uint32 indexed domain, address indexed recipient, uint256 amount, bytes32 messageId);
    event LiquidityReceivedFromVenue(uint256 balance);

    event RewardTokenSet(address indexed token, uint256 duration);
    event RewardAdded(uint256 reward, uint256 periodFinish);
    event RewardClaimed(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);

    event NativeWrapperSet(address indexed wrapper);
    event DepositedETH(address indexed receiver, uint256 ethAmount, uint256 shares);
    event WithdrawnETH(address indexed receiver, uint256 ethAmount, uint256 shares);

    // Errors

    error ZeroAddress();
    error ZeroAmount();
    error TooManyAdapters();
    error InvalidYieldAdapter(address adapter);
    error YieldAdapterAlreadyExists(address adapter);
    error NoBridgeAdapter(uint32 domain);
    error UnauthorizedRecipient(uint32 domain, address recipient);
    error InsufficientIdle(uint256 requested, uint256 available);
    error InsufficientYield(uint256 requested, uint256 remaining);
    error RewardTokenNotSet();
    error RewardTokenAlreadySet();
    error RewardPeriodNotFinished(uint256 periodFinish);
    error InvalidRewardsDuration();
    error NativeWrapperNotSet();
    error AdapterHasBalance(address adapter, uint256 balance);
    error NativeWrapperAlreadySet();
    error AssetIsNotWrapper();
    error ETHTransferFailed();

    /// @dev Checkpoints reward accumulator for `account` before any share balance changes.
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime       = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account]               = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // initializer

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    /**
     * @notice Initialise the LP vault.
     * @param asset_   Underlying ERC-20 (USDC).
     * @param name_    Vault LP-token name, e.g. "Predifi LP USDC".
     * @param symbol_  Vault LP-token symbol, e.g. "pdLP-USDC".
     * @param admin_   Granted DEFAULT_ADMIN_ROLE + PAUSER_ROLE.
     *                 Use PredifiAdmin proxy address in production.
     */
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin_
    ) external initializer {
        if (address(asset_) == address(0)) revert ZeroAddress();
        if (admin_ == address(0))          revert ZeroAddress();

        __ERC4626_init(asset_);
        __ERC20_init(name_, symbol_);
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE,        admin_);
    }

    function _checkpointRewards(address account) private {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _checkpointRewards(from);
        if (to != address(0)) _checkpointRewards(to);
        super._update(from, to, value);
    }

    // ERC-4626 overrides

    /// @notice Total assets: idle balance + all yield adapter positions.
    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        uint256 len   = yieldAdapters.length;
        for (uint256 i; i < len; ++i) {
            total += IYieldAdapter(yieldAdapters[i]).deposited();
        }
        return total;
    }

    /// @notice Deposit assets and mint shares to receiver.
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets   == 0)            revert ZeroAmount();
        if (receiver == address(0))   revert ZeroAddress();
        return super.deposit(assets, receiver);
    }

    /// @notice Mint exact shares, depositing required assets.
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares   == 0)            revert ZeroAmount();
        if (receiver == address(0))   revert ZeroAddress();
        return super.mint(shares, receiver);
    }

    /// @notice Withdraw assets to receiver by burning owner's shares.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets   == 0)            revert ZeroAmount();
        if (receiver == address(0))   revert ZeroAddress();

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) revert InsufficientIdle(assets, idle);

        return super.withdraw(assets, receiver, owner);
    }

    /// @notice Redeem shares for assets.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares   == 0)            revert ZeroAmount();
        if (receiver == address(0))   revert ZeroAddress();

        uint256 expectedAssets = previewRedeem(shares);
        uint256 idle           = IERC20(asset()).balanceOf(address(this));
        if (expectedAssets > idle) revert InsufficientIdle(expectedAssets, idle);

        return super.redeem(shares, receiver, owner);
    }

    // Yield management

    /// @notice Deploy idle USDC into a yield adapter. YIELD_MANAGER_ROLE only.
    function deployToYield(
        address adapter,
        uint256 amount
    ) external onlyRole(YIELD_MANAGER_ROLE) nonReentrant {
        if (amount == 0)                      revert ZeroAmount();
        if (!isYieldAdapter[adapter])         revert InvalidYieldAdapter(adapter);

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (amount > idle)                    revert InsufficientIdle(amount, idle);

        IERC20(asset()).forceApprove(adapter, amount);
        IYieldAdapter(adapter).deposit(amount);
        totalDeployedToYield += amount;

        emit YieldDeployed(adapter, amount, totalDeployedToYield);
    }

    /// @notice Pull back funds from a yield adapter. YIELD_MANAGER_ROLE only.
    function withdrawFromYield(
        address adapter,
        uint256 amount
    ) external onlyRole(YIELD_MANAGER_ROLE) nonReentrant {
        if (amount == 0)                   revert ZeroAmount();
        if (!isYieldAdapter[adapter])      revert InvalidYieldAdapter(adapter);

        uint256 inAdapter = IYieldAdapter(adapter).deposited();
        uint256 toRecall  = amount > inAdapter ? inAdapter : amount;
        if (toRecall == 0)                 revert InsufficientYield(amount, 0);

        IYieldAdapter(adapter).withdraw(toRecall);
        // totalDeployedToYield tracks principal; yield > principal is possible
        if (toRecall <= totalDeployedToYield) {
            totalDeployedToYield -= toRecall;
        } else {
            totalDeployedToYield = 0;
        }

        emit YieldWithdrawn(adapter, toRecall, totalDeployedToYield);
    }

    /// @notice Register a yield adapter.
    function addYieldAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0))         revert ZeroAddress();
        if (isYieldAdapter[adapter])       revert YieldAdapterAlreadyExists(adapter);
        if (yieldAdapters.length >= MAX_YIELD_ADAPTERS) revert TooManyAdapters();

        yieldAdapters.push(adapter);
        isYieldAdapter[adapter] = true;

        emit YieldAdapterAdded(adapter, IYieldAdapter(adapter).name());
    }

    function removeYieldAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isYieldAdapter[adapter]) revert InvalidYieldAdapter(adapter);
        uint256 bal = IYieldAdapter(adapter).deposited();
        if (bal != 0) revert AdapterHasBalance(adapter, bal);

        uint256 len = yieldAdapters.length;
        for (uint256 i; i < len; ++i) {
            if (yieldAdapters[i] == adapter) {
                yieldAdapters[i] = yieldAdapters[len - 1];
                yieldAdapters.pop();
                break;
            }
        }
        isYieldAdapter[adapter] = false;

        emit YieldAdapterRemoved(adapter);
    }


    function getYieldAdapters() external view returns (address[] memory) {
        return yieldAdapters;
    }

    // Bridge management (M2 EVM multi-chain)

    /**
     * @notice Bridge `amount` USDC to the mirror LPVault on another EVM chain.
     * @dev BRIDGE_MANAGER_ROLE only. Reverts with NoBridgeAdapter on Hedera
     *      (correct — Hedera LP capital stays on Hedera).
     * @param destinationDomain  Circle CCTP domain ID of the destination chain.
     * @param recipient          Mirror LPVault address on the destination chain.
     * @param amount             Amount of USDC to bridge.
     * @param bridgeData         Adapter-specific extra data (slippage, hooks, etc.).
     * @return messageId         CCTP message hash for off-chain attestation tracking.
     */
    function bridgeToVenue(
        uint32  destinationDomain,
        address recipient,
        uint256 amount,
        bytes calldata bridgeData
    ) external onlyRole(BRIDGE_MANAGER_ROLE) nonReentrant returns (bytes32 messageId) {
        if (amount    == 0)             revert ZeroAmount();
        if (recipient == address(0))    revert ZeroAddress();
        if (!authorizedRecipients[destinationDomain][recipient])
            revert UnauthorizedRecipient(destinationDomain, recipient);

        address adapter = bridgeAdapters[destinationDomain];
        if (adapter == address(0))      revert NoBridgeAdapter(destinationDomain);

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (amount > idle)              revert InsufficientIdle(amount, idle);

        IERC20(asset()).forceApprove(adapter, amount);
        messageId = IBridgeAdapter(adapter).bridgeUSDC(
            amount,
            destinationDomain,
            recipient,
            bridgeData
        );

        emit LiquidityBridged(destinationDomain, recipient, amount, messageId);
    }

    /**
     * @notice Acknowledgement hook called by backend after inbound CCTP mint.
     * @dev USDC is already in the vault by the time this is called (CCTP mints
     *      directly to this address). This function only emits an audit event.
     */
    function receiveFromVenue() external onlyRole(BRIDGE_MANAGER_ROLE) {
        emit LiquidityReceivedFromVenue(IERC20(asset()).balanceOf(address(this)));
    }

    /**
     * @notice Register or update the bridge adapter for a CCTP domain.
     * @dev Set to address(0) to deregister.
     */
    function setBridgeAdapter(
        uint32  destinationDomain,
        address adapter
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = bridgeAdapters[destinationDomain];
        bridgeAdapters[destinationDomain] = adapter;
        emit BridgeAdapterSet(destinationDomain, old, adapter);
    }

    /**
     * @notice Authorise or revoke a recipient on a destination domain.
     * @dev Should always be the mirror LPVault proxy on that chain.
     */
    function setAuthorizedRecipient(
        uint32  destinationDomain,
        address recipient,
        bool    authorized
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        authorizedRecipients[destinationDomain][recipient] = authorized;
        emit RecipientAuthorizationSet(destinationDomain, recipient, authorized);
    }

    // Dual-yield reward distribution

    /**
     * @notice Set the secondary reward token and distribution window.
     * @dev DEFAULT_ADMIN_ROLE only. Can only be called once — revert if already set.
     *      To support multiple reward tokens in future, upgrade the contract.
     * @param token_    ERC-20 address of the reward token (e.g. native governance token,
     *                  or USDC when the vault's deposit asset is ETH/WETH).
     * @param duration_ Length of each reward period in seconds (e.g. 7 days = 604800).
     */
    function setRewardToken(
        address token_,
        uint256 duration_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token_    == address(0)) revert ZeroAddress();
        if (rewardToken != address(0)) revert RewardTokenAlreadySet();
        if (duration_ == 0)          revert InvalidRewardsDuration();
        rewardToken      = token_;
        rewardsDuration  = duration_;
        emit RewardTokenSet(token_, duration_);
    }

    /**
     * @notice Update the reward distribution window for future periods.
     * @dev DEFAULT_ADMIN_ROLE only. Cannot shorten an active period.
     *      Safe to call only when periodFinish < block.timestamp.
     */
    function setRewardsDuration(
        uint256 duration_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration_ == 0)                      revert InvalidRewardsDuration();
        if (block.timestamp < periodFinish)      revert RewardPeriodNotFinished(periodFinish);
        rewardsDuration = duration_;
        emit RewardsDurationUpdated(duration_);
    }

    /// @notice Inject rewards and start/extend the distribution period (Synthetix pattern).
    function notifyRewardAmount(
        uint256 amount
    ) external onlyRole(YIELD_MANAGER_ROLE) updateReward(address(0)) {
        if (rewardToken == address(0)) revert RewardTokenNotSet();
        if (amount == 0)               revert ZeroAmount();

        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 distributable = amount + rewardDust;

        if (block.timestamp >= periodFinish) {
            rewardRate = distributable / rewardsDuration;
        } else {
            uint256 remaining   = periodFinish - block.timestamp;
            uint256 leftover    = remaining * rewardRate;
            distributable      += leftover;
            rewardRate          = distributable / rewardsDuration;
        }

        rewardDust = distributable % rewardsDuration;

        lastUpdateTime = block.timestamp;
        periodFinish   = block.timestamp + rewardsDuration;

        emit RewardAdded(amount, periodFinish);
    }

    function claimRewards() external nonReentrant updateReward(msg.sender) {
        if (rewardToken == address(0)) revert RewardTokenNotSet();
        uint256 reward = rewards[msg.sender];
        if (reward == 0) return;
        rewards[msg.sender] = 0;
        IERC20(rewardToken).safeTransfer(msg.sender, reward);
        emit RewardClaimed(msg.sender, reward);
    }


    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }


    function rewardPerToken() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + (lastTimeRewardApplicable() - lastUpdateTime)
            * rewardRate
            * 1e18
            / supply;
    }


    function earned(address account) public view returns (uint256) {
        return balanceOf(account)
            * (rewardPerToken() - userRewardPerTokenPaid[account])
            / 1e18
            + rewards[account];
    }

    /// @notice Set the WETH/WHBAR wrapper contract once. Vault must have been initialised with it as asset_.
    function setNativeWrapper(address wrapper_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (wrapper_      == address(0)) revert ZeroAddress();
        if (nativeWrapper != address(0)) revert NativeWrapperAlreadySet();
        if (wrapper_      != asset())    revert AssetIsNotWrapper();
        nativeWrapper = wrapper_;
        emit NativeWrapperSet(wrapper_);
    }

    /// @notice Wrap msg.value → WETH and deposit into vault, crediting shares to receiver.
    /// previewDeposit must be called BEFORE wrapping to avoid share price inflation.
    function depositETH(address receiver) external payable nonReentrant whenNotPaused returns (uint256 shares) {
        if (nativeWrapper == address(0)) revert NativeWrapperNotSet();
        uint256 assets = msg.value;
        if (assets   == 0)            revert ZeroAmount();
        if (receiver == address(0))   revert ZeroAddress();

        // snapshot shares before wrap — IWETH.deposit inflates totalAssets
        shares = previewDeposit(assets);
        IWETH(nativeWrapper).deposit{value: assets}();
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
        emit DepositedETH(receiver, assets, shares);
    }

    /// @notice Burn shares, unwrap WETH → ETH and push to receiver.
    function withdrawETH(
        uint256 shares,
        address receiver,
        address owner
    ) external nonReentrant whenNotPaused returns (uint256 assets) {
        if (nativeWrapper == address(0)) revert NativeWrapperNotSet();
        if (shares   == 0)            revert ZeroAmount();
        if (receiver == address(0))   revert ZeroAddress();

        assets = previewRedeem(shares);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) revert InsufficientIdle(assets, idle);

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        IWETH(nativeWrapper).withdraw(assets);
        (bool ok, ) = payable(receiver).call{value: assets}("");
        if (!ok) revert ETHTransferFailed();

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        emit WithdrawnETH(receiver, assets, shares);
    }

    receive() external payable {
        if (msg.sender != nativeWrapper) revert ETHTransferFailed();
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[35] private _gap;
}
