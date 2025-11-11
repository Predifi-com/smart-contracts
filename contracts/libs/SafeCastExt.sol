// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title SafeCastExt
 * @notice Extended safe casting utilities for the Predifi protocol
 */
library SafeCastExt {
    error SafeCastOverflow();
    error SafeCastUnderflow();

    /**
     * @notice Safely cast uint256 to uint128
     */
    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert SafeCastOverflow();
        return uint128(value);
    }

    /**
     * @notice Safely cast uint256 to uint64
     */
    function toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert SafeCastOverflow();
        return uint64(value);
    }

    /**
     * @notice Safely cast uint256 to uint32
     */
    function toUint32(uint256 value) internal pure returns (uint32) {
        if (value > type(uint32).max) revert SafeCastOverflow();
        return uint32(value);
    }

    /**
     * @notice Safely cast uint256 to uint16
     */
    function toUint16(uint256 value) internal pure returns (uint16) {
        if (value > type(uint16).max) revert SafeCastOverflow();
        return uint16(value);
    }

    /**
     * @notice Safely cast int256 to uint256
     */
    function toUint256(int256 value) internal pure returns (uint256) {
        if (value < 0) revert SafeCastUnderflow();
        return uint256(value);
    }

    /**
     * @notice Safely cast uint256 to int256
     */
    function toInt256(uint256 value) internal pure returns (int256) {
        if (value > uint256(type(int256).max)) revert SafeCastOverflow();
        return int256(value);
    }

    /**
     * @notice Calculate basis points safely
     */
    function bpsMul(uint256 amount, uint16 bps) internal pure returns (uint256) {
        return (amount * bps) / 10_000;
    }

    /**
     * @notice Validate basis points are within range
     */
    function validateBps(uint16 bps, uint16 maxBps) internal pure {
        if (bps > maxBps) revert SafeCastOverflow();
    }

    /**
     * @notice Safe division with rounding up
     */
    function divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}