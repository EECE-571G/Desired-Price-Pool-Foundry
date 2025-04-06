// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

function abs24(int24 x) pure returns (int24) {
    return x < 0 ? -x : x;
}

function abs(int256 x) pure returns (int256) {
    return x < 0 ? -x : x;
}

contract DesiredPricePool is BaseHook, Owned {
    using PoolIdLibrary for PoolKey;
    using CustomRevert for bytes4;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    error UnauthorizedPoolInitialization();
    error UnexpectedReentrancy();

    /// @notice The rate of fee per tick managed by Uniswap V4 in pips.
    uint24 public constant DEFAULT_BASE_FEE_PER_TICK = 30;
    /// @notice The percentage of hook fees on top of the base fee.
    uint8 public constant DEFAULT_HOOK_FEE = 25;

    int24 private BEFORE_SWAP_TICK_UNSET = TickMath.MAX_TICK + 1;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    mapping(PoolId => int24 tick) public desiredPriceTicks;
    mapping(PoolId => uint24 pip) public baseFees;
    mapping(PoolId => uint8 percent) public hookFees;

    int24 private beforeSwapTick = BEFORE_SWAP_TICK_UNSET;
    uint24 private swapFee = 0;

    constructor(IPoolManager _poolManager, address _owner) BaseHook(_poolManager) Owned(_owner) {}

    function createPool(
        Currency _currency0,
        Currency _currency1,
        int24 _tickSpacing,
        uint160 _sqrtPriceX96,
        int24 _desiredPriceTick
    ) external onlyOwner {
        require(!(_currency0 == _currency1), "Invalid currency pair");
        require(_tickSpacing >= 1 && _tickSpacing <= 200, "Invalid tick spacing");

        if (_currency0 > _currency1) {
            (_currency0, _currency1) = (_currency1, _currency0);
        }
        PoolKey memory key = PoolKey({
            currency0: _currency0,
            currency1: _currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: _tickSpacing,
            hooks: IHooks(address(this))
        });
        PoolId id = key.toId();

        require(baseFees[id] == 0, "Pool already exists");
        desiredPriceTicks[id] = _desiredPriceTick;
        baseFees[id] = uint24(_tickSpacing) * DEFAULT_BASE_FEE_PER_TICK;
        hookFees[id] = DEFAULT_HOOK_FEE;

        poolManager.initialize(key, _sqrtPriceX96);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        PoolId id = key.toId();
        if (sender != address(this) || baseFees[id] == 0) {
            UnauthorizedPoolInitialization.selector.revertWith();
        }
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata swapParams, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (beforeSwapTick != BEFORE_SWAP_TICK_UNSET) {
            UnexpectedReentrancy.selector.revertWith();
        }
        PoolId id = key.toId();
        uint24 protocolFee;
        (, beforeSwapTick, protocolFee,) = poolManager.getSlot0(id);
        uint16 currentProtocolFee = swapParams.zeroForOne
            ? ProtocolFeeLibrary.getZeroForOneFee(protocolFee)
            : ProtocolFeeLibrary.getOneForZeroFee(protocolFee);
        uint24 fee = baseFees[id];
        swapFee = ProtocolFeeLibrary.calculateSwapFee(currentProtocolFee, fee);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (beforeSwapTick == BEFORE_SWAP_TICK_UNSET) {
            UnexpectedReentrancy.selector.revertWith();
        }
        PoolId id = key.toId();
        int128 deltaUnspecified =
            swapParams.zeroForOne == (swapParams.amountSpecified < 0) ? delta.amount1() : delta.amount0();
        uint24 baseFee = baseFees[id];
        uint24 hookFeePip = baseFee * hookFees[id] / 100;
        int128 hookFeeAmountBase = SafeCast.toInt128(
            abs(int256(deltaUnspecified)) * (1e6 - SafeCast.toInt256(swapFee)) * SafeCast.toInt256(hookFeePip) / 1e12
        );

        (, int24 afterSwapTick,,) = poolManager.getSlot0(id);
        int24 desiredPrice = desiredPriceTicks[id];
        int24 tickDiff = abs24(afterSwapTick - desiredPrice) - abs24(beforeSwapTick - desiredPrice);
        beforeSwapTick = BEFORE_SWAP_TICK_UNSET;

        if (tickDiff == 0) {
            return (BaseHook.afterSwap.selector, hookFeeAmountBase);
        }
        int128 hookFeeAmount = tickDiff < 0
            ? ((hookFeeAmountBase << 1) * (tickDiff - 1) / (tickDiff - 2))
            : ((hookFeeAmountBase << 1) / (2 + tickDiff));
        return (BaseHook.afterSwap.selector, hookFeeAmount);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }
}
