// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";

library HookData {
    error InvalidHookData(bytes hookData);

    bytes4 internal constant HOOK_DATA_PREFIX = bytes4("DPP:");
    uint256 internal constant LIQUIDITY_HOOK_DATA_LENGTH = 64;

    function encodeLiquidityHookData(uint256 tokenId) internal pure returns (bytes memory) {
        return abi.encode(HOOK_DATA_PREFIX, tokenId);
    }

    function decodeLiquidityHookData(bytes memory data) internal pure returns (uint256 tokenId) {
        if (data.length != LIQUIDITY_HOOK_DATA_LENGTH) {
            revert InvalidHookData(data);
        }
        bytes4 prefix;
        (prefix, tokenId) = abi.decode(data, (bytes4, uint256));
        if (prefix != HOOK_DATA_PREFIX) {
            revert InvalidHookData(data);
        }
    }
}