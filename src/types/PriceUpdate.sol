// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "v4-core/src/types/PoolId.sol";

struct PriceUpdate {
    /// @notice The timestamp when the price update happened
    uint40 timestamp;
	/// @notice The price tick before the update
	int24 oldPriceTick;
	/// @notice The price tick after the update
	int24 newPriceTick;
}
