// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PredifiPool} from "../PredifiPool.sol";

contract UserRouter {
    using SafeERC20 for IERC20;

    address public immutable owner; // the user's AA wallet or EOA
    PredifiPool public immutable vault;
    IERC20 public immutable asset;

    event ForwardedToVault(uint256 amount);
    error NotOwner();

    constructor(address _owner, address _vault, address _asset) {
        owner = _owner;
        vault = PredifiPool(_vault);
        asset = IERC20(_asset);
    }

    // sweep is intentionally open to anyone — moves funds to safety
    function sweep() external {
        uint256 balance = asset.balanceOf(address(this));
        if (balance > 0) {
            asset.forceApprove(address(vault), balance);
            vault.deposit(balance);
            emit ForwardedToVault(balance);
        }
    }

    function withdraw(address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        asset.safeTransfer(to, amount);
    }
}
