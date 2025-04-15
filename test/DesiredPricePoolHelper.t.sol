// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {SafeCast128} from "../src/utils/SafeCast128.sol";
import {DPPTestBase} from "./DPPTestBase.sol";

contract DesiredPricePoolHelperTest is DPPTestBase {
    using CurrencyLibrary for Currency;
    using PositionInfoLibrary for PositionInfo;
    using StateLibrary for IPoolManager;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeCast128 for uint128;
    using SafeCast128 for int128;

    uint256 tokenId;
    uint256 initialLiquidity;
    uint256 initialBalance0;
    uint256 initialBalance1;

    function setUp() public override {
        super.setUp();
        // Provide full-range liquidity to the pool
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        initialLiquidity = 100 ether;
        initialBalance0 = currency0.balanceOfSelf();
        initialBalance1 = currency1.balanceOfSelf();
        BalanceDelta delta;
        (tokenId, delta) = dppHelper.mint(key, tickLower, tickUpper, initialLiquidity);
        console.log("Token 0 sent: %e", (-delta.amount0()).toUint128());
        console.log("Token 1 sent: %e", (-delta.amount1()).toUint128());
    }

    function testMint() public view {
        uint128 liquidity = posm.getPositionLiquidity(tokenId);
        assertEq(liquidity, initialLiquidity, "Mint liquidity mismatch");
        uint256 amount0Sent = initialBalance0 - currency0.balanceOfSelf();
        uint256 amount1Sent = initialBalance1 - currency1.balanceOfSelf();
        assertEq(amount0Sent, currency0.balanceOf(address(manager)), "Currency0 balance mismatch after mint");
        assertEq(amount1Sent, currency1.balanceOf(address(manager)), "Currency1 balance mismatch after mint");
    }

    function testBurn() public {
        dppHelper.burn(tokenId);
        assertEq(currency0.balanceOfSelf(), initialBalance0, "Currency0 balance mismatch after burn");
        assertEq(currency1.balanceOfSelf(), initialBalance1, "Currency1 balance mismatch after burn");
    }

    function testAddLiquidity() public {
        uint128 liquidity = 50 ether;
        uint256 balance0 = currency0.balanceOfSelf();
        uint256 balance1 = currency1.balanceOfSelf();
        BalanceDelta delta = dppHelper.addLiquidity(tokenId, liquidity);
        assertEq(
            balance0 - currency0.balanceOfSelf(),
            (-delta.amount0()).toUint128(),
            "Currency0 balance mismatch after addLiquidity"
        );
        assertEq(
            balance1 - currency1.balanceOfSelf(),
            (-delta.amount1()).toUint128(),
            "Currency1 balance mismatch after addLiquidity"
        );
    }

    function testRemoveLiquidity() public {
        uint128 liquidity = 50 ether;
        uint256 balance0 = currency0.balanceOfSelf();
        uint256 balance1 = currency1.balanceOfSelf();
        BalanceDelta delta = dppHelper.removeLiquidity(tokenId, liquidity);
        assertEq(
            currency0.balanceOfSelf() - balance0,
            delta.amount0().toUint128(),
            "Currency0 balance mismatch after removeLiquidity"
        );
        assertEq(
            currency1.balanceOfSelf() - balance1,
            delta.amount1().toUint128(),
            "Currency1 balance mismatch after removeLiquidity"
        );
    }

    function testSwapExactIn() public {
        _testSwap(true, true);
        _testSwap(false, true);
    }

    function testSwapExactOut() public {
        _testSwap(true, false);
        _testSwap(false, false);
    }

    function _testSwap(bool zeroForOne, bool exactIn) internal {
        uint256 amount = 1 ether;
        uint256 balance0 = currency0.balanceOfSelf();
        uint256 balance1 = currency1.balanceOfSelf();
        Currency unspecified = zeroForOne == exactIn ? currency1 : currency0;
        uint256 hookBalance = unspecified.balanceOf(address(dpp));
        BalanceDelta delta = exactIn
            ? dppHelper.swapExactIn(key, zeroForOne, amount)
            : dppHelper.swapExactOut(key, zeroForOne, amount);
        int256 amount0Delta = currency0.balanceOfSelf().toInt256() - balance0.toInt256();
        int256 amount1Delta = currency1.balanceOfSelf().toInt256() - balance1.toInt256();
        assertEq(amount0Delta, delta.amount0(), "Currency0 balance mismatch after swap");
        assertEq(amount1Delta, delta.amount1(), "Currency1 balance mismatch after swap");
        assertGt(
            unspecified.balanceOf(address(dpp)),
            hookBalance,
            "Hook doesn't receive unspecified currency after swap"
        );
    }
}
