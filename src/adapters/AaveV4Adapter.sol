// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

interface IAaveV4Spoke {
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
        external returns (uint256 suppliedShares, uint256 suppliedAmount);

    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf)
        external returns (uint256 withdrawnShares, uint256 withdrawnAmount);

    function getUserSuppliedAssets(uint256 reserveId, address user)
        external view returns (uint256);
}

contract AaveV4Adapter is Ownable, IYieldAdapter {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();

    address public immutable override asset;
    IAaveV4Spoke public immutable spoke;
    uint256 public immutable reserveId;
    string private _name;

    constructor(
        address pool_,
        address asset_,
        address spoke_,
        uint256 reserveId_,
        string memory name_
    ) Ownable(pool_) {
        if (pool_  == address(0)) revert ZeroAddress();
        if (asset_ == address(0)) revert ZeroAddress();
        if (spoke_ == address(0)) revert ZeroAddress();
        asset     = asset_;
        spoke     = IAaveV4Spoke(spoke_);
        reserveId = reserveId_;
        _name     = name_;
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
        IERC20(asset).forceApprove(address(spoke), amount);
        spoke.supply(reserveId, amount, address(this));

        emit YieldDeposited(amount, deposited());
    }

    function withdraw(uint256 amount) external override onlyOwner {
        if (amount == 0) revert ZeroAmount();

        (, uint256 received) = spoke.withdraw(reserveId, amount, address(this));
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
        return spoke.getUserSuppliedAssets(reserveId, address(this));
    }
}
