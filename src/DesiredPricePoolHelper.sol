// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IDesiredPricePool} from "./interfaces/IDesiredPricePool.sol";
import {DPPConstants} from "./libraries/DPPConstants.sol";
import {EasyPosm} from "./libraries/EasyPosm.sol";
import {SafeCast128} from "./utils/SafeCast128.sol";

contract DesiredPricePoolHelper is SafeCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;
    using EasyPosm for IPositionManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast128 for uint128;
    using SafeCast128 for int128;

    bytes constant ZERO_BYTES = new bytes(0);

    IDesiredPricePool public immutable dpp;

    constructor(IDesiredPricePool _dpp) SafeCallback(_dpp.poolManager()) {
        dpp = _dpp;
    }

    modifier borrow(uint256 tokenId) {
        IERC721 positionToken = IERC721(address(dpp.positionManager()));
        positionToken.transferFrom(msg.sender, address(this), tokenId);
        _;
        positionToken.transferFrom(address(this), msg.sender, tokenId);
    }

    function poolId(PoolKey memory key) public pure returns (PoolId) {
        return key.toId();
    }

    function currentPrice(PoolId id) public view returns (int24 tick, uint160 sqrtPriceX96) {
        IPoolManager pm = dpp.poolManager();
        (sqrtPriceX96, tick,,) = pm.getSlot0(id);
    }

    function getAmountsForLiquidity(
        PoolId id,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) public view returns (uint256 amount0, uint256 amount1) {
        (,uint160 sqrtPriceX96) = currentPrice(id);
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity.toUint128()
        );
    }

    function mint(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) external payable returns (uint256 tokenId, BalanceDelta delta) {
        IPositionManager posm = dpp.positionManager();
        uint256 deadline = type(uint256).max;
        (uint256 amount0Max, uint256 amount1Max) = getAmountsForLiquidity(
            poolKey.toId(), tickLower, tickUpper, liquidity
        );
        amount0Max += 1;
        amount1Max += 1;
        _receive(poolKey.currency0, amount0Max);
        _receive(poolKey.currency1, amount1Max);
        (tokenId, delta) = posm.mint(
            poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, msg.sender, deadline, ZERO_BYTES
        );
        _send(poolKey.currency0, poolKey.currency1, amount0Max, amount1Max, delta);
    }

    function burn(uint256 tokenId) external returns (BalanceDelta delta) {
        (IPositionManager posm, Currency currency0, Currency currency1, bytes memory hookData, uint256 deadline) =
            _getParams(tokenId);
        IERC721(address(posm)).transferFrom(msg.sender, address(this), tokenId);
        delta = posm.burn(tokenId, 0, 0, msg.sender, deadline, hookData);
        _send(currency0, currency1, delta);
    }

    function addLiquidity(uint256 tokenId, uint256 liquidity) external payable borrow(tokenId) returns (BalanceDelta delta) {
        (IPositionManager posm, Currency currency0, Currency currency1, bytes memory hookData, uint256 deadline) =
            _getParams(tokenId);
        (PoolKey memory key, PositionInfo info) = posm.getPoolAndPositionInfo(tokenId);
        (uint256 amount0Max, uint256 amount1Max) = getAmountsForLiquidity(
            key.toId(), info.tickLower(), info.tickUpper(), liquidity
        );
        amount0Max += 1;
        amount1Max += 1;
        _receive(currency0, amount0Max);
        _receive(currency1, amount1Max);
        delta = posm.increaseLiquidity(tokenId, liquidity, amount0Max, amount1Max, deadline, hookData);
        _send(currency0, currency1, amount0Max, amount1Max, delta);
    }

    function removeLiquidity(uint256 tokenId, uint256 liquidity) external borrow(tokenId) returns (BalanceDelta delta) {
        (IPositionManager posm, Currency currency0, Currency currency1, bytes memory hookData, uint256 deadline) =
            _getParams(tokenId);
        delta = posm.decreaseLiquidity(
            tokenId, liquidity, type(uint256).max, type(uint256).max, msg.sender, deadline, hookData
        );
        _send(currency0, currency1, delta);
    }

    function collect(uint256 tokenId) internal returns (BalanceDelta delta) {
        (IPositionManager posm, Currency currency0, Currency currency1, bytes memory hookData, uint256 deadline) =
            _getParams(tokenId);
        delta = posm.collect(tokenId, 0, 0, msg.sender, deadline, hookData);
        _send(currency0, currency1, delta);
    }

    function swapExactIn(PoolKey memory poolKey, bool zeroForOne, uint256 amount, uint160 sqrtPriceLimitX96)
        external
        returns (BalanceDelta delta)
    {
        return _swap(poolKey, zeroForOne, -amount.toInt256(), sqrtPriceLimitX96);
    }

    function swapExactOut(PoolKey memory poolKey, bool zeroForOne, uint256 amount, uint160 sqrtPriceLimitX96)
        external
        returns (BalanceDelta delta)
    {
        return _swap(poolKey, zeroForOne, amount.toInt256(), sqrtPriceLimitX96);
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        IPoolManager pm = dpp.poolManager();
        if (msg.sender != address(pm)) {
            revert ImmutableState.NotPoolManager();
        }
        (address sender, PoolKey memory poolKey, IPoolManager.SwapParams memory params) =
            abi.decode(data, (address, PoolKey, IPoolManager.SwapParams));
        BalanceDelta delta = pm.swap(poolKey, params, ZERO_BYTES);
        // Get the deltas for the currencies
        int256 delta0 = pm.currencyDelta(address(this), poolKey.currency0);
        int256 delta1 = pm.currencyDelta(address(this), poolKey.currency1);
        int256 hookDelta0 = pm.currencyDelta(address(dpp), poolKey.currency0);
        int256 hookDelta1 = pm.currencyDelta(address(dpp), poolKey.currency1);
        // Solve deltas
        _solve(poolKey.currency0, pm, sender, delta0);
        _solve(poolKey.currency1, pm, sender, delta1);
        _solve(poolKey.currency0, pm, address(dpp), hookDelta0);
        _solve(poolKey.currency1, pm, address(dpp), hookDelta1);
        return abi.encode(delta);
    }

    function _getParams(uint256 tokenId)
        internal
        view
        returns (IPositionManager posm, Currency currency0, Currency currency1, bytes memory hookData, uint256 deadline)
    {
        posm = dpp.positionManager();
        (currency0, currency1) = posm.getCurrencies(tokenId);
        hookData = abi.encode(DPPConstants.HOOK_DATA_PREFIX, tokenId);
        deadline = type(uint256).max;
    }

    /// @dev Because POSM uses permit2, we must execute 2 permits/approvals.
    function _approve(address token) internal {
        address posmAddr = address(dpp.positionManager());
        IAllowanceTransfer permit2 = Permit2Forwarder(posmAddr).permit2();
        // 1. First, the caller must approve permit2 on the token.
        IERC20(token).approve(address(permit2), type(uint256).max);
        // 2. Then, the caller must approve POSM as a spender of permit2
        permit2.approve(token, posmAddr, type(uint160).max, type(uint48).max);
    }

    function _receive(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            require(msg.value >= amount, "Insufficient ETH sent");
            if (msg.value > amount) {
                payable(msg.sender).transfer(msg.value - amount);
            }
        } else {
            IERC20 token = IERC20(Currency.unwrap(currency));
            token.transferFrom(msg.sender, address(this), amount);
            _approve(Currency.unwrap(currency));
        }
    }

    function _send(Currency currency0, Currency currency1, BalanceDelta delta) internal {
        currency0.transfer(msg.sender, delta.amount0().toUint128());
        currency1.transfer(msg.sender, delta.amount1().toUint128());
    }

    function _send(Currency currency0, Currency currency1, uint256 amount0Max, uint256 amount1Max, BalanceDelta delta)
        internal
    {
        int256 excess0 = amount0Max.toInt256() + delta.amount0();
        int256 excess1 = amount1Max.toInt256() + delta.amount1();
        if (excess0 > 0) {
            currency0.transfer(msg.sender, excess0.toUint256());
        }
        if (excess1 > 0) {
            currency1.transfer(msg.sender, excess1.toUint256());
        }
    }

    function _swap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta delta)
    {
        IPoolManager pm = dpp.poolManager();
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        bytes memory result = pm.unlock(abi.encode(msg.sender, poolKey, params));
        (delta) = abi.decode(result, (BalanceDelta));
    }

    function _solve(Currency currency, IPoolManager pm, address target, int256 delta) internal {
        if (delta < 0) {
            currency.settle(pm, target, (-delta).toUint256(), false);
        } else if (delta > 0) {
            currency.take(pm, target, delta.toUint256(), false);
        }
    }
}
