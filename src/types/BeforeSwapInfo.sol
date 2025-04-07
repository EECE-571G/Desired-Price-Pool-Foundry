// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

type BeforeSwapInfo is int48;

using {eq as ==, neq as !=} for BeforeSwapInfo global;
using BeforeSwapInfoLibrary for BeforeSwapInfo global;

function toBeforeSwapInfo(int24 tick, uint24 swapFee) pure returns (BeforeSwapInfo beforeSwapInfo) {
    assembly ("memory-safe") {
        beforeSwapInfo := or(shl(24, tick), and(0xFFFFFF, swapFee))
    }
}

function eq(BeforeSwapInfo a, BeforeSwapInfo b) pure returns (bool) {
    return BeforeSwapInfo.unwrap(a) == BeforeSwapInfo.unwrap(b);
}

function neq(BeforeSwapInfo a, BeforeSwapInfo b) pure returns (bool) {
    return BeforeSwapInfo.unwrap(a) != BeforeSwapInfo.unwrap(b);
}

/// @notice Library for getting the amount0 and amount1 deltas from the BeforeSwapInfo type
library BeforeSwapInfoLibrary {
    /// @notice A BeforeSwapInfo of 0
    BeforeSwapInfo public constant UNSET = BeforeSwapInfo.wrap(type(int24).max << 24);

    function tick(BeforeSwapInfo beforeSwapInfo) internal pure returns (int24 _tick) {
		assembly ("memory-safe") {
			_tick := and(shr(24, beforeSwapInfo), 0xFFFFFF)
		}
    }

    function swapFee(BeforeSwapInfo beforeSwapInfo) internal pure returns (uint24 _swapFee) {
		assembly ("memory-safe") {
			_swapFee := and(beforeSwapInfo, 0xFFFFFF)
		}
    }
}
