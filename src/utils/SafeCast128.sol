// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @dev Supplementary math functions.
 */
library SafeCast128 {
    /**
     * @dev Converts an unsigned uint128 into a signed int128.
     *
     * Requirements:
     *
     * - input must be less than or equal to maxInt128.
     */
    function toInt128(uint128 value) internal pure returns (int128) {
        // Note: Unsafe cast below is okay because `type(int128).max` is guaranteed to be positive
        if (value > uint128(type(int128).max)) {
            revert SafeCast.SafeCastOverflowedUintToInt(value);
        }
        return int128(value);
    }

    /**
     * @dev Converts a signed int128 into an unsigned uint128.
     *
     * Requirements:
     *
     * - input must be greater than or equal to 0.
     */
    function toUint128(int128 value) internal pure returns (uint128) {
        if (value < 0) {
            revert SafeCast.SafeCastOverflowedIntToUint(value);
        }
        return uint128(value);
    }
}