// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CCTPAdapter
 * @notice Bridge adapter for Circle's CCTP (Cross-Chain Transfer Protocol)
 * @dev Handles USDC bridging with attestation requirements
 */
contract CCTPAdapter is IBridgeAdapter {
    using SafeERC20 for IERC20;

    /// @notice Circle TokenMessenger contract
    address public immutable tokenMessenger;
    
    /// @notice Circle MessageTransmitter contract (for receiving)
    address public immutable messageTransmitter;
    
    /// @notice USDC token address
    address public immutable usdc;
    
    /// @notice Domain ID for this chain
    uint32 public immutable localDomain;

    event CCTPBridgeInitiated(
        bytes32 indexed messageId,
        uint64 indexed nonce,
        uint256 amount,
        uint32 destinationDomain,
        address recipient
    );

    event CCTPBridgeReceived(
        bytes32 indexed messageId,
        uint256 amount,
        address recipient
    );

    error InvalidAmount();
    error InvalidRecipient();
    error InvalidDomain();

    /**
     * @param _tokenMessenger Circle TokenMessenger address
     * @param _messageTransmitter Circle MessageTransmitter address
     * @param _usdc USDC token address
     * @param _localDomain CCTP domain ID for this chain
     */
    constructor(
        address _tokenMessenger,
        address _messageTransmitter,
        address _usdc,
        uint32 _localDomain
    ) {
        tokenMessenger = _tokenMessenger;
        messageTransmitter = _messageTransmitter;
        usdc = _usdc;
        localDomain = _localDomain;
    }

    /**
     * @notice Bridge USDC to another chain via CCTP
     * @param amount Amount of USDC to bridge
     * @param destinationDomain CCTP domain ID of destination chain
     * @param recipient Address to receive USDC on destination
     * @param bridgeData Additional data (unused for CCTP)
     * @return messageId Unique identifier for the bridge message
     * @dev Caller must approve this contract to spend USDC before calling
     * @dev Recipient on destination chain must wait for attestation and call receiveMessage
     */
    function bridgeUSDC(
        uint256 amount,
        uint32 destinationDomain,
        address recipient,
        bytes calldata bridgeData
    ) external override returns (bytes32 messageId) {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        if (destinationDomain == localDomain) revert InvalidDomain();

        // Transfer USDC from caller to this contract
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);

        // Approve TokenMessenger
        IERC20(usdc).forceApprove(tokenMessenger, amount);

        // Burn USDC and initiate cross-chain transfer
        bytes32 mintRecipient = bytes32(uint256(uint160(recipient)));
        
        // Call depositForBurn
        (bool success, bytes memory returnData) = tokenMessenger.call(
            abi.encodeWithSignature(
                "depositForBurn(uint256,uint32,bytes32,address)",
                amount,
                destinationDomain,
                mintRecipient,
                usdc
            )
        );
        
        require(success, "CCTP: depositForBurn failed");
        
        // Decode nonce from return data
        uint64 nonce = abi.decode(returnData, (uint64));
        
        // Generate message ID (hash of nonce + domain)
        messageId = keccak256(
            abi.encodePacked(
                localDomain,
                destinationDomain,
                nonce,
                amount,
                recipient
            )
        );

        emit CCTPBridgeInitiated(
            messageId,
            nonce,
            amount,
            destinationDomain,
            recipient
        );

        return messageId;
    }

    /**
     * @notice Estimate bridge fee for CCTP
     * @dev CCTP has no fees (gas-only)
     * @return fee Always returns 0 (no protocol fees)
     */
    function estimateBridgeFee(
        uint256,
        uint32,
        bytes calldata
    ) external pure override returns (uint256 fee) {
        return 0; // CCTP is free (only gas costs)
    }

    /**
     * @notice Receive USDC from another chain via CCTP
     * @param message The message bytes from CCTP
     * @param attestation The attestation signature from Circle
     * @dev This must be called by anyone after obtaining attestation from Circle API
     * @dev Attestation URL: https://iris-api-sandbox.circle.com/attestations/{messageHash}
     */
    function receiveMessage(
        bytes calldata message,
        bytes calldata attestation
    ) external {
        // Call MessageTransmitter to process the message
        (bool success, ) = messageTransmitter.call(
            abi.encodeWithSignature(
                "receiveMessage(bytes,bytes)",
                message,
                attestation
            )
        );
        
        require(success, "CCTP: receiveMessage failed");
        
        // Event emitted by MessageTransmitter, we just track it
        bytes32 messageId = keccak256(message);
        
        emit CCTPBridgeReceived(messageId, 0, address(0)); // Amount/recipient parsed from message
    }
}
