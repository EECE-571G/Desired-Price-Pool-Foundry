// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PriceUpdate} from "./types/PriceUpdate.sol";

abstract contract DesiredPrice {
    using PoolIdLibrary for PoolKey;
    using CustomRevert for bytes4;
    using SafeCast for uint256;
    using SafeCast for int256;

    mapping(PoolId => int24 tick) public desiredPriceTicks;
    mapping(PoolId => uint24) internal priceUpdateIds;
    mapping(PoolId => mapping(uint24 => PriceUpdate)) internal priceUpdates;

    IERC20 public immutable govToken;

    constructor(IERC20 _govToken) {
        govToken = _govToken;
    }

    function _setDesiredPrice(PoolId id, int24 priceTick) internal {
        PriceUpdate memory update = PriceUpdate({
            timestamp: block.timestamp.toUint40(),
            oldPriceTick: desiredPriceTicks[id],
            newPriceTick: priceTick
        });
        uint24 nextId = priceUpdateIds[id];
        priceUpdates[id][nextId] = update;
        priceUpdateIds[id] = nextId + 1;
        desiredPriceTicks[id] = priceTick;
    }
}