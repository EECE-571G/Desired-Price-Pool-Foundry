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
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {IDesiredPricePool} from "./interfaces/IDesiredPricePool.sol";
import {IDesiredPricePoolOwner} from "./interfaces/IDesiredPricePoolOwner.sol";
import {BeforeSwapInfo, BeforeSwapInfoLibrary, toBeforeSwapInfo} from "./types/BeforeSwapInfo.sol";
import {PriceUpdate} from "./types/PriceUpdate.sol";
import {Reward, RewardQueue} from "./types/Reward.sol";
import {Math as Math2} from "./utils/Math.sol";
import {DesiredPrice} from "./DesiredPrice.sol";
import {HookReward} from "./HookReward.sol";

contract DesiredPricePool is IDesiredPricePool, IDesiredPricePoolOwner, HookReward, BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using CustomRevert for bytes4;
    using SafeCast for uint256;
    using SafeCast for int256;

    error UnexpectedReentrancy();
    error InvalidTickRange(int24 lowerTick, int24 upperTick, int24 tickSpacing);

    /// @notice The rate of fee per tick managed by Uniswap V4 in pips.
    uint24 public constant DEFAULT_BASE_FEE_PER_TICK = 30;
    /// @notice The percentage of hook fees on top of the base fee.
    uint8 public constant DEFAULT_HOOK_FEE = 25;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    mapping(PoolId => uint24 pip) public lpFees;
    mapping(PoolId => uint8 percent) public hookFees;

    BeforeSwapInfo private _beforeSwapInfo = BeforeSwapInfoLibrary.UNSET;

    constructor(
        IPoolManager _poolManager,
        IPositionManager _posm,
        address _owner
    ) HookReward(_posm) BaseHook(_poolManager) DesiredPrice(_owner) {}

    function createPool(
        Currency _currency0,
        Currency _currency1,
        int24 _tickSpacing,
        uint160 _sqrtPriceX96,
        int24 _desiredPriceTick
    ) external onlyOwner returns (PoolKey memory key) {
        require(!(_currency0 == _currency1), "Invalid currency pair");
        require(_tickSpacing >= 1 && _tickSpacing <= MAX_TICK_SPACING, "Invalid tick spacing");

        if (_currency0 > _currency1) {
            (_currency0, _currency1) = (_currency1, _currency0);
        }
        key = PoolKey({
            currency0: _currency0,
            currency1: _currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: _tickSpacing,
            hooks: IHooks(address(this))
        });
        PoolId id = key.toId();

        require(lpFees[id] == 0, "Pool already exists");
        lpFees[id] = uint24(_tickSpacing) * DEFAULT_BASE_FEE_PER_TICK;
        hookFees[id] = DEFAULT_HOOK_FEE;
        _setDesiredPrice(id, _desiredPriceTick);

        poolManager.initialize(key, _sqrtPriceX96);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
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
        if (sender != address(this) || lpFees[id] == 0) {
            UnauthorizedPoolInitialization.selector.revertWith();
        }
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata swapParams, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        BeforeSwapInfo beforeSwapInfo = _beforeSwapInfo;
        if (beforeSwapInfo != BeforeSwapInfoLibrary.UNSET) {
            UnexpectedReentrancy.selector.revertWith();
        }
        PoolId id = key.toId();
        _checkPollExecution(id);
        (, int24 priceTick, uint24 protocolFee,) = poolManager.getSlot0(id);
        uint16 currentProtocolFee = swapParams.zeroForOne
            ? ProtocolFeeLibrary.getZeroForOneFee(protocolFee)
            : ProtocolFeeLibrary.getOneForZeroFee(protocolFee);
        uint24 fee = lpFees[id];
        uint24 swapFee = ProtocolFeeLibrary.calculateSwapFee(currentProtocolFee, fee);
        _beforeSwapInfo = toBeforeSwapInfo(priceTick, swapFee);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        BeforeSwapInfo beforeSwapInfo = _beforeSwapInfo;
        _beforeSwapInfo = BeforeSwapInfoLibrary.UNSET;

        PoolId id = key.toId();
        bool chargeCurrency1 = swapParams.zeroForOne == (swapParams.amountSpecified < 0);
        int128 deltaUnspecified = chargeCurrency1 ? delta.amount1() : delta.amount0();
        uint24 baseFee = lpFees[id];
        uint24 hookFeePip = baseFee * hookFees[id] / 100;
        uint256 hookFeeAmountBase =
            Math2.abs(int256(deltaUnspecified)).toUint256() * (1e6 - beforeSwapInfo.swapFee()) * uint256(hookFeePip) / 1e12;

        (, int24 afterSwapTick,,) = poolManager.getSlot0(id);
        int24 dp = desiredPrice[id];
        int24 tickDiff = Math2.abs24(afterSwapTick - dp) - Math2.abs24(beforeSwapInfo.tick() - dp);

        uint256 hookFeeAmount; // 1 / (1 + tickDiff / (4 * sqrt(tickSpacing)))
        if (tickDiff == 0) {
            hookFeeAmount = hookFeeAmountBase;
        } else {
            uint256 factor = Math.sqrt(int256(key.tickSpacing).toUint256() << 232) << 2;
            hookFeeAmount = hookFeeAmountBase * factor / (factor + (int256(Math2.abs24(tickDiff)).toUint256() << 116));
            if (tickDiff > 0) {
                hookFeeAmount = (hookFeeAmountBase << 1) - hookFeeAmount;
            }
        }
        int128 hookFeeAmountInt128 = hookFeeAmount.toInt256().toInt128();
        BalanceDelta hookDelta = chargeCurrency1 ? toBalanceDelta(0, hookFeeAmountInt128) : toBalanceDelta(hookFeeAmountInt128, 0);
        feesCollected[id] = feesCollected[id] + hookDelta;
        return (BaseHook.afterSwap.selector, hookFeeAmountInt128);
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        if (params.liquidityDelta == 0 || hookData.length == 0) {
            return BaseHook.beforeAddLiquidity.selector;
        }
        _verifyTickRange(params.tickLower, params.tickUpper, key.tickSpacing);
        PoolId id = key.toId();
        _checkPollExecution(id);
        uint256 positionId = _verifyPositionId(id, params, hookData);
        _updatePendingReward(id, key.tickSpacing, positionId, params);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        if (params.liquidityDelta == 0) {
            return BaseHook.beforeRemoveLiquidity.selector;
        }
        _verifyTickRange(params.tickLower, params.tickUpper, key.tickSpacing);
        PoolId id = key.toId();
        _checkPollExecution(id);
        uint256 positionId = _verifyPositionId(id, params, hookData);
        _updatePendingReward(id, key.tickSpacing, positionId, params);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _verifyTickRange(int24 tickLower, int24 tickUpper, int24 tickSpacing) internal pure {
        if (tickLower >= tickUpper) {
            revert InvalidTickRange(tickLower, tickUpper, tickSpacing);
        }
        if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) {
            revert InvalidTickRange(tickLower, tickUpper, tickSpacing);
        }
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) {
            revert InvalidTickRange(tickLower, tickUpper, tickSpacing);
        }
    }
}