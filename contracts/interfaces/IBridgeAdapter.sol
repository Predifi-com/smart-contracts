// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IBridgeAdapter
 * @notice Interface for cross-chain bridge adapters (CCTP, L2ToL2, Via Labs)
 */
interface IBridgeAdapter {
    /**
     * @notice Bridge USDC to another chain
     * @param amount Amount of USDC to bridge
     * @param destinationDomain Domain ID of destination chain
     * @param recipient Address to receive USDC on destination
     * @param bridgeData Additional bridge-specific parameters
     * @return messageId Unique identifier for the bridge message
     */
    function bridgeUSDC(
        uint256 amount,
        uint32 destinationDomain,
        address recipient,
        bytes calldata bridgeData
    ) external returns (bytes32 messageId);
    
    /**
     * @notice Get estimated bridge fee
     * @param amount Amount to bridge
     * @param destinationDomain Destination domain
     * @param bridgeData Bridge-specific parameters
     * @return fee Estimated fee in USDC
     */
    function estimateBridgeFee(
        uint256 amount,
        uint32 destinationDomain,
        bytes calldata bridgeData
    ) external view returns (uint256 fee);
}
