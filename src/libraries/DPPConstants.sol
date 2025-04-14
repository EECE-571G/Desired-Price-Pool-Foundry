// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

library DPPConstants {
    /// @notice Address suffix of the hook contract.
    uint160 internal constant PERMISSION_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    int24 public constant MAX_TICK_SPACING = 256;

    bytes4 public constant HOOK_DATA_PREFIX = bytes4("DPP:");

    uint256 public constant HOOK_DATA_LENGTH = 36; // 4 + 32 bytes
}