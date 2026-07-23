// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
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
    bytes32 public constant PAUSER_ROLE         = keccak256("PAUSER_ROLE");
    bytes32 public constant BRIDGE_MANAGER_ROLE = keccak256("BRIDGE_MANAGER_ROLE");
    bytes32 public constant YIELD_MANAGER_ROLE  = keccak256("YIELD_MANAGER_ROLE");
    uint256 public constant MAX_YIELD_ADAPTERS = 10;
    uint256 public constant DEFAULT_VALUATION_MAX_AGE = 15 minutes;

    mapping(uint32 => address) public bridgeAdapters;
    mapping(uint32 => mapping(address => bool)) public authorizedRecipients;
    address[] public yieldAdapters;

    mapping(address => bool) public isYieldAdapter;
    uint256 private _totalDeployedToYieldDeprecated;
    uint256 public totalDeployedToBridge;
    uint256 public valuationMaxAge;
    uint256 public lastYieldSync;

    address public rewardToken;
    uint256 public rewardsDuration;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public rewardDust;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public lastRewardNotificationBlock;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    address public nativeWrapper;

    event YieldAdapterAdded(address indexed adapter, string adapterName);
    event YieldAdapterRemoved(address indexed adapter);
    event YieldDeployed(address indexed adapter, uint256 amount, uint256 totalDeployed);
    event YieldWithdrawn(address indexed adapter, uint256 amountRequested, uint256 totalDeployed);
    event YieldValuationSynced(address indexed adapter, uint256 deployedBalance, uint256 syncedAt);
    event ValuationMaxAgeUpdated(uint256 maxAge);

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
    error RewardTokenIsAsset();
    error NoRewardsToClaim();
    error InvalidValuationMaxAge();
    error StaleYieldValuation(uint256 lastSync, uint256 maxAge);
    error RewardActionBlocked(uint256 rewardBlock);

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime       = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account]               = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

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

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE,        admin_);
        _grantRole(BRIDGE_MANAGER_ROLE, admin_);
        _grantRole(YIELD_MANAGER_ROLE,  admin_);

        valuationMaxAge = DEFAULT_VALUATION_MAX_AGE;
        lastYieldSync = block.timestamp;
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

    function _decimalsOffset() internal pure override returns (uint8) { return 18; }

    function totalDeployedToYield() public view returns (uint256) {
        return _currentYieldBalance();
    }

    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this)) + _currentYieldBalance();
        total += totalDeployedToBridge;
        return total;
    }

    function _currentYieldBalance() internal view returns (uint256 total) {
        uint256 len = yieldAdapters.length;
        for (uint256 i; i < len; ++i) {
            total += IYieldAdapter(yieldAdapters[i]).deposited();
        }
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets   == 0)            revert ZeroAmount();
        if (receiver == address(0))   revert ZeroAddress();
        _enforceRewardActionCooldown();
        _syncAllYieldAdapters();
        return super.deposit(assets, receiver);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares   == 0)            revert ZeroAmount();
        if (receiver == address(0))   revert ZeroAddress();
        _enforceRewardActionCooldown();
        _syncAllYieldAdapters();
        return super.mint(shares, receiver);
    }

    function maxDeposit(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        return paused() ? 0 : super.maxWithdraw(owner_);
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        return paused() ? 0 : super.maxRedeem(owner_);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets   == 0)            revert ZeroAmount();
        if (receiver == address(0))   revert ZeroAddress();

        _enforceRewardActionCooldown();
        _syncAllYieldAdapters();
        _ensureIdle(assets);

        return super.withdraw(assets, receiver, owner);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares   == 0)            revert ZeroAmount();
        if (receiver == address(0))   revert ZeroAddress();

        _enforceRewardActionCooldown();
        _syncAllYieldAdapters();
        uint256 expectedAssets = previewRedeem(shares);
        _ensureIdle(expectedAssets);

        return super.redeem(shares, receiver, owner);
    }

    function _syncAllYieldAdapters() internal {
        uint256 len = yieldAdapters.length;
        for (uint256 i; i < len; ++i) {
            _syncYieldAdapter(yieldAdapters[i]);
        }
    }

    function _ensureIdle(uint256 requiredAssets) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= requiredAssets) return;

        uint256 len = yieldAdapters.length;
        for (uint256 i; i < len && idle < requiredAssets; ++i) {
            address adapter = yieldAdapters[i];
            uint256 inAdapter = IYieldAdapter(adapter).deposited();
            if (inAdapter == 0) continue;

            uint256 shortfall = requiredAssets - idle;
            uint256 toRecall = inAdapter < shortfall ? inAdapter : shortfall;
            IYieldAdapter(adapter).withdraw(toRecall);
            idle = IERC20(asset()).balanceOf(address(this));
        }

        if (yieldAdapters.length != 0) {
            lastYieldSync = block.timestamp;
        }

        if (idle < requiredAssets) revert InsufficientIdle(requiredAssets, idle);
    }

    function _syncYieldAdapter(address adapter) internal returns (uint256 deployedBalance) {
        deployedBalance = IYieldAdapter(adapter).sync();
        lastYieldSync = block.timestamp;
        emit YieldValuationSynced(adapter, deployedBalance, block.timestamp);
    }

    function syncYieldAdapters() external onlyRole(YIELD_MANAGER_ROLE) nonReentrant returns (uint256 totalDeployed) {
        uint256 len = yieldAdapters.length;
        for (uint256 i; i < len; ++i) {
            totalDeployed += _syncYieldAdapter(yieldAdapters[i]);
        }
    }

    function setValuationMaxAge(uint256 maxAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxAge == 0) revert InvalidValuationMaxAge();
        valuationMaxAge = maxAge;
        emit ValuationMaxAgeUpdated(maxAge);
    }

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

        uint256 totalDeployed = _syncYieldAdapter(adapter);

        emit YieldDeployed(adapter, amount, totalDeployed);
    }

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

        uint256 totalDeployed = _syncYieldAdapter(adapter);

        emit YieldWithdrawn(adapter, toRecall, totalDeployed);
    }

    function addYieldAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0))         revert ZeroAddress();
        if (isYieldAdapter[adapter])       revert YieldAdapterAlreadyExists(adapter);
        if (yieldAdapters.length >= MAX_YIELD_ADAPTERS) revert TooManyAdapters();

        yieldAdapters.push(adapter);
        isYieldAdapter[adapter] = true;
        lastYieldSync = block.timestamp;

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
        lastYieldSync = block.timestamp;

        emit YieldAdapterRemoved(adapter);
    }


    function getYieldAdapters() external view returns (address[] memory) {
        return yieldAdapters;
    }

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

        totalDeployedToBridge += amount;
        emit LiquidityBridged(destinationDomain, recipient, amount, messageId);
    }

    function receiveFromVenue(uint256 amount) external onlyRole(BRIDGE_MANAGER_ROLE) {
        if (totalDeployedToBridge >= amount) {
            totalDeployedToBridge -= amount;
        } else {
            totalDeployedToBridge = 0;
        }
        emit LiquidityReceivedFromVenue(IERC20(asset()).balanceOf(address(this)));
    }

    function setBridgeAdapter(
        uint32  destinationDomain,
        address adapter
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = bridgeAdapters[destinationDomain];
        bridgeAdapters[destinationDomain] = adapter;
        emit BridgeAdapterSet(destinationDomain, old, adapter);
    }

    function setAuthorizedRecipient(
        uint32  destinationDomain,
        address recipient,
        bool    authorized
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        authorizedRecipients[destinationDomain][recipient] = authorized;
        emit RecipientAuthorizationSet(destinationDomain, recipient, authorized);
    }

    function setRewardToken(
        address token_,
        uint256 duration_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token_    == address(0)) revert ZeroAddress();
        if (rewardToken != address(0)) revert RewardTokenAlreadySet();
        if (token_ == asset())       revert RewardTokenIsAsset();
        if (duration_ == 0)          revert InvalidRewardsDuration();
        rewardToken      = token_;
        rewardsDuration  = duration_;
        emit RewardTokenSet(token_, duration_);
    }

    function setRewardsDuration(
        uint256 duration_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration_ == 0)                      revert InvalidRewardsDuration();
        if (block.timestamp < periodFinish)      revert RewardPeriodNotFinished(periodFinish);
        rewardsDuration = duration_;
        emit RewardsDurationUpdated(duration_);
    }

    function notifyRewardAmount(
        uint256 amount
    ) external nonReentrant onlyRole(YIELD_MANAGER_ROLE) updateReward(address(0)) {
        if (rewardToken == address(0)) revert RewardTokenNotSet();
        if (amount == 0)               revert ZeroAmount();
        if (totalSupply() == 0)        revert ZeroAmount();

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
        lastRewardNotificationBlock = block.number;

        emit RewardAdded(amount, periodFinish);
    }

    function _enforceRewardActionCooldown() internal view {
        uint256 rewardBlock = lastRewardNotificationBlock;
        if (rewardBlock != 0 && block.number == rewardBlock) {
            revert RewardActionBlocked(rewardBlock);
        }
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
        uint256 scale = 10 ** (18 + _decimalsOffset());
        return rewardPerTokenStored
            + (lastTimeRewardApplicable() - lastUpdateTime)
            * rewardRate
            * scale
            / supply;
    }


    function earned(address account) public view returns (uint256) {
        uint256 scale = 10 ** (18 + _decimalsOffset());
        return balanceOf(account)
            * (rewardPerToken() - userRewardPerTokenPaid[account])
            / scale
            + rewards[account];
    }

    function setNativeWrapper(address wrapper_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (wrapper_      == address(0)) revert ZeroAddress();
        if (nativeWrapper != address(0)) revert NativeWrapperAlreadySet();
        if (wrapper_      != asset())    revert AssetIsNotWrapper();
        nativeWrapper = wrapper_;
        emit NativeWrapperSet(wrapper_);
    }

    function depositETH(address receiver) external payable nonReentrant whenNotPaused returns (uint256 shares) {
        if (nativeWrapper == address(0)) revert NativeWrapperNotSet();
        uint256 assets = msg.value;
        if (assets   == 0)            revert ZeroAmount();
        if (receiver == address(0))   revert ZeroAddress();
        _enforceRewardActionCooldown();
        _syncAllYieldAdapters();

        shares = previewDeposit(assets);
        IWETH(nativeWrapper).deposit{value: assets}();
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
        emit DepositedETH(receiver, assets, shares);
    }

    function withdrawETH(
        uint256 shares,
        address receiver,
        address owner
    ) external nonReentrant whenNotPaused returns (uint256 assets) {
        if (nativeWrapper == address(0)) revert NativeWrapperNotSet();
        if (shares   == 0)            revert ZeroAmount();
        if (receiver == address(0))   revert ZeroAddress();

        _enforceRewardActionCooldown();
        _syncAllYieldAdapters();
        assets = previewRedeem(shares);
        _ensureIdle(assets);

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        IWETH(nativeWrapper).withdraw(assets);
        (bool ok, ) = payable(receiver).call{value: assets}("");
        if (!ok) revert ETHTransferFailed();

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        emit WithdrawnETH(receiver, assets, shares);
    }

    function claimAdapterRewards(
        address rewardAsset,
        address recipient
    ) external onlyRole(YIELD_MANAGER_ROLE) nonReentrant {
        _claimAdapterRewards(address(0), rewardAsset, recipient, bytes(""));
    }

    function claimAdapterRewards(
        address adapter,
        address rewardAsset,
        address recipient,
        bytes calldata claimData
    ) external onlyRole(YIELD_MANAGER_ROLE) nonReentrant {
        _claimAdapterRewards(adapter, rewardAsset, recipient, claimData);
    }

    function _claimAdapterRewards(
        address adapter,
        address rewardAsset,
        address recipient,
        bytes memory claimData
    ) internal {
        if (rewardAsset == address(0)) revert ZeroAddress();
        if (recipient   == address(0)) revert ZeroAddress();

        if (adapter == address(0)) {
            uint256 len = yieldAdapters.length;
            for (uint256 i; i < len; ++i) {
                IYieldAdapter(yieldAdapters[i]).claimRewards(rewardAsset, bytes(""));
            }
        } else {
            if (!isYieldAdapter[adapter]) revert InvalidYieldAdapter(adapter);
            IYieldAdapter(adapter).claimRewards(rewardAsset, claimData);
        }

        uint256 bal = IERC20(rewardAsset).balanceOf(address(this));
        if (bal == 0) revert NoRewardsToClaim();
        IERC20(rewardAsset).safeTransfer(recipient, bal);
    }

    receive() external payable {
        if (msg.sender != nativeWrapper) revert ETHTransferFailed();
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[35] private _gap;
}
