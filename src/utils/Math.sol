// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Supplementary math functions.
 */
library Math {
    function abs8(int8 x) internal pure returns (int8) {
        return x < 0 ? -x : x;
    }

    function abs24(int24 x) internal pure returns (int24) {
        return x < 0 ? -x : x;
    }

    function abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
    }

    function max(int256 x, int256 y) internal pure returns (int256) {
        return x <= y ? y : x;
    }

    function min(int256 x, int256 y) internal pure returns (int256) {
        return x <= y ? x : y;
    }
}