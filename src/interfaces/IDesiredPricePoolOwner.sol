// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IDesiredPriceOwner} from "./IDesiredPriceOwner.sol";
import {IGoveranceTokenOwner} from "./IGoveranceTokenOwner.sol";

interface IDesiredPricePoolOwner is IDesiredPriceOwner, IGoveranceTokenOwner {
    error UnauthorizedPoolInitialization();

    function createPool(
        Currency _currency0,
        Currency _currency1,
        int24 _tickSpacing,
        uint160 _sqrtPriceX96,
        int24 _desiredPriceTick
    ) external returns (PoolKey memory key);
}