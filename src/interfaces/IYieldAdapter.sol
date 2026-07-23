// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IYieldAdapter {
    function asset() external view returns (address);
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function deposited() external view returns (uint256);
    function name() external view returns (string memory);
    function pool() external view returns (address);

    function sync() external view returns (uint256);
    function claimRewards(address rewardToken, bytes calldata data) external;

    event YieldDeposited(uint256 amount, uint256 totalDeployed);
    event YieldWithdrawn(uint256 amount, uint256 totalDeployed);
}
