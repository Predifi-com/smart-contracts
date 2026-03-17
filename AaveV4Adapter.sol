// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

// v4 Spoke interface — reserve-id-based; approve the Spoke before supply(), use onBehalfOf = address(this).
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

    /// @inheritdoc IYieldAdapter
    address public immutable override asset;
    IAaveV4Spoke public immutable spoke;
    uint256 public immutable reserveId;
    string private _name;

    /**
     * @param pool_       PredifiPool proxy — becomes Ownable owner.
     * @param asset_      USDC (or other) address on this chain.
     * @param spoke_      AAVE v4 Spoke proxy on this chain.
     * @param reserveId_  Reserve ID for asset_ on this Spoke.
     * @param name_       Human label, e.g. "AAVE v4 USDC (Base)".
     */
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

    /// @inheritdoc IYieldAdapter
    function pool() external view override returns (address) {
        return owner();
    }

    /// @inheritdoc IYieldAdapter
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

    // pass type(uint256).max to exit the full position
    function withdraw(uint256 amount) external override onlyOwner {
        if (amount == 0) revert ZeroAmount();

        (, uint256 received) = spoke.withdraw(reserveId, amount, address(this));
        IERC20(asset).safeTransfer(owner(), received);

        emit YieldWithdrawn(received, deposited());
    }

    /// @inheritdoc IYieldAdapter
    function deposited() public view override returns (uint256) {
        return spoke.getUserSuppliedAssets(reserveId, address(this));
    }
}
