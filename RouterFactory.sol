// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {UserRouter} from "./UserRouter.sol";

contract RouterFactory {
    event RouterCreated(address indexed user, address router);
    error ZeroAddress();
    error Unauthorized();

    address public immutable vault;
    address public immutable asset;

    constructor(address _vault, address _asset) {
        if (_vault == address(0) || _asset == address(0)) revert ZeroAddress();
        vault = _vault;
        asset = _asset;
    }

    function createRouter(address user, bytes32 salt) external returns (address) {
        if (user == address(0)) revert ZeroAddress();
        if (msg.sender != user) revert Unauthorized();
        UserRouter router = new UserRouter{salt: salt}(user, vault, asset);
        emit RouterCreated(user, address(router));
        return address(router);
    }

    function computeRouterAddress(address user, bytes32 salt) external view returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(UserRouter).creationCode,
            abi.encode(user, vault, asset)
        );
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }
}
