// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

contract ERC4626Adapter is Ownable, IYieldAdapter {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidVault();

    /// @inheritdoc IYieldAdapter
    address public immutable override asset;
    IERC4626 public immutable vault;
    string private _name;

    constructor(
        address pool_,
        address vault_,
        string memory name_
    ) Ownable(pool_) {
        if (pool_  == address(0)) revert ZeroAddress();
        if (vault_ == address(0)) revert ZeroAddress();

        IERC4626 v = IERC4626(vault_);
        address underlyingAsset = v.asset();
        if (underlyingAsset == address(0)) revert InvalidVault();

        vault = v;
        asset = underlyingAsset;
        _name = name_;
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
        IERC20(asset).forceApprove(address(vault), amount);
        vault.deposit(amount, address(this));

        emit YieldDeposited(amount, deposited());
    }

    // pass type(uint256).max to exit the full position
    function withdraw(uint256 amount) external override onlyOwner {
        if (amount == 0) revert ZeroAmount();

        uint256 withdrawAmount = amount == type(uint256).max ? deposited() : amount;
        // sends withdrawAmount of asset directly to owner()
        vault.withdraw(withdrawAmount, owner(), address(this));

        emit YieldWithdrawn(withdrawAmount, deposited());
    }

    /// @inheritdoc IYieldAdapter
    function deposited() public view override returns (uint256) {
        uint256 shares = vault.balanceOf(address(this));
        if (shares == 0) return 0;
        return vault.convertToAssets(shares);
    }
}
