// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {DesiredPricePool} from "../src/DesiredPricePool.sol";
import {DPPLibrary} from "../src/libraries/DPPLibrary.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

abstract contract DPPTestBase is Test, Fixtures {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    DesiredPricePool dpp;
    PoolId poolId;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(DPPLibrary.PERMISSION_FLAGS ^ (0x4444 << 144)); // Namespace the hook to avoid collisions
        bytes memory constructorArgs = abi.encode(manager, posm, address(this));
        deployCodeTo("DesiredPricePool.sol:DesiredPricePool", constructorArgs, flags);
        dpp = DesiredPricePool(flags);

        // Create the pool
        key = dpp.createPool(currency0, currency1, 64, SQRT_PRICE_1_1, 0);
        poolId = key.toId();
    }

    function mintPosition(int24 tickLower, int24 tickUpper, uint128 liquidity) internal returns (uint256 tokenId) {
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidity,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }
}
