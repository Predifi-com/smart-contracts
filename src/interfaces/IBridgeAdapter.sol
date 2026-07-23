// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IBridgeAdapter {
    function bridgeUSDC(
        uint256 amount,
        uint32 destinationDomain,
        address recipient,
        bytes calldata extraData
    ) external returns (bytes32 messageId);

    event BridgeInitiated(
        uint32 indexed destinationDomain,
        address indexed recipient,
        uint256 amount,
        bytes32 messageId
    );
}
