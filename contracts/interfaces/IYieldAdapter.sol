// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IYieldAdapter
 * @notice Interface for yield strategy adapters (Morpho, Aave, Compound, etc.)
 */
interface IYieldAdapter {
    /**
     * @notice Deposit USDC into yield protocol
     * @param amount Amount of USDC to deposit
     * @return shares Amount of yield-bearing tokens received
     */
    function deposit(uint256 amount) external returns (uint256 shares);
    
    /**
     * @notice Withdraw USDC from yield protocol
     * @param amount Amount of USDC to withdraw
     * @return shares Amount of yield-bearing tokens burned
     */
    function withdraw(uint256 amount) external returns (uint256 shares);
    
    /**
     * @notice Get total assets deposited in yield protocol
     * @return Total USDC value deposited
     */
    function totalAssets() external view returns (uint256);
    
    /**
     * @notice Get current APY of the yield strategy
     * @return APY in basis points (e.g., 500 = 5%)
     */
    function currentAPY() external view returns (uint256);
    
    /**
     * @notice Get yield adapter name
     * @return Name of the yield protocol (e.g., "Morpho", "Aave")
     */
    function name() external view returns (string memory);
}
