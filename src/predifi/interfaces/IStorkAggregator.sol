// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IStorkAggregator {
    function latest(bytes32 assetId)
        external
        view
        returns (int256 price, uint256 ts, uint8 decimals);

    function atOrBefore(bytes32 assetId, uint256 tsHint)
        external
        view
        returns (int256 price, uint256 ts, uint8 decimals);
}
