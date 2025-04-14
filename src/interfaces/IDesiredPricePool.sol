// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IImmutableState} from "v4-periphery/src/interfaces/IImmutableState.sol";

import {IDesiredPrice} from "./IDesiredPrice.sol";
import {IHookReward} from "./IHookReward.sol";

interface IDesiredPricePool is IDesiredPrice, IHookReward, IImmutableState {
    function lpFees(PoolId id) external view returns (uint24);

    function hookFees(PoolId id) external view returns (uint8);
}
