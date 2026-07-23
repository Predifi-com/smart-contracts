// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IOracleConfigValidator {
    function getSymbolValidation(string calldata symbol)
        external
        view
        returns (bool supported, uint8 targetDecimals);
}
