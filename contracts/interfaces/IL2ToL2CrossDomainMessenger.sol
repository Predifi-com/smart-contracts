// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IL2ToL2CrossDomainMessenger
 * @notice Minimal interface for Optimism Superchain intra-L2 messaging
 * @dev See: https://specs.optimism.io
 */
interface IL2ToL2CrossDomainMessenger {
    /**
     * @notice Sends a cross-domain message to a target on another OP Stack chain.
     * @param targetChainId Destination L2 chain ID within the Superchain
     * @param target Target contract address on the destination L2
     * @param message Calldata to execute on the target
     * @return msgHash Unique identifier for the message
     */
    function sendMessage(
        uint256 targetChainId,
        address target,
        bytes calldata message
    ) external payable returns (bytes32 msgHash);

    /**
     * @notice Returns the cross-domain message sender
     * @return sender_ Address of the sender on the source chain
     */
    function crossDomainMessageSender() external view returns (address sender_);

    /**
     * @notice Returns the cross-domain message source chain ID
     * @return source_ Chain ID of the source chain
     */
    function crossDomainMessageSource() external view returns (uint256 source_);

    /**
     * @notice Returns the cross-domain message context
     * @return sender_ Address of the sender on the source chain
     * @return source_ Chain ID of the source chain
     */
    function crossDomainMessageContext() external view returns (address sender_, uint256 source_);
}
