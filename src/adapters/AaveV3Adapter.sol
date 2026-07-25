// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

contract AaveV3Adapter is Ownable, IYieldAdapter {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();

    address public immutable override asset;
    IAaveV3Pool public immutable aavePool;
    IERC20 public immutable aToken;
    string private _name;

    constructor(
        address pool_,
        address asset_,
        address aavePool_,
        address aToken_,
        string memory name_
    ) Ownable(pool_) {
        if (pool_ == address(0)) revert ZeroAddress();
        if (asset_ == address(0)) revert ZeroAddress();
        if (aavePool_ == address(0)) revert ZeroAddress();
        if (aToken_ == address(0)) revert ZeroAddress();
        asset = asset_;
        aavePool = IAaveV3Pool(aavePool_);
        aToken = IERC20(aToken_);
        _name = name_;
    }

    function pool() external view override returns (address) {
        return owner();
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function deposit(uint256 amount) external override onlyOwner {
        if (amount == 0) revert ZeroAmount();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(aavePool), amount);
        aavePool.supply(asset, amount, address(this), 0);

        emit YieldDeposited(amount, deposited());
    }

    function withdraw(uint256 amount) external override onlyOwner {
        if (amount == 0) revert ZeroAmount();

        uint256 received = aavePool.withdraw(asset, amount, address(this));
        IERC20(asset).safeTransfer(owner(), received);

        emit YieldWithdrawn(received, deposited());
    }

    function sync() external view override onlyOwner returns (uint256) {
        return deposited();
    }

    function claimRewards(address rewardToken, bytes calldata) external override onlyOwner {
        if (rewardToken == address(0)) revert ZeroAddress();

        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (balance > 0) {
            IERC20(rewardToken).safeTransfer(owner(), balance);
        }
    }

    function deposited() public view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }
}
