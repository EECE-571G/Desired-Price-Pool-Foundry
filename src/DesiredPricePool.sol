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
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {BeforeSwapInfo, BeforeSwapInfoLibrary, toBeforeSwapInfo} from "./types/BeforeSwapInfo.sol";
import {PriceUpdate} from "./types/PriceUpdate.sol";
import {Reward, RewardQueue} from "./types/Reward.sol";

function abs24(int24 x) pure returns (int24) {
    return x < 0 ? -x : x;
}

function abs(int256 x) pure returns (int256) {
    return x < 0 ? -x : x;
}

function max(int256 x, int256 y) pure returns (int256) {
	return x <= y ? y : x;
}

function min(int256 x, int256 y) pure returns (int256) {
	return x <= y ? x : y;
}

contract DesiredPricePool is BaseHook, Owned, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using PositionInfoLibrary for PositionInfo;
    using CustomRevert for bytes4;
    using SafeCast for uint256;
	using SafeCast for int256;

    error UnauthorizedPoolInitialization();
    error UnexpectedReentrancy();
    error InvalidPositionId(uint256 positionId);
	error InvalidTickBounds(int24 tickLower, int24 tickUpper, int24 tickSpacing);
	error InvalidAddress(address addr);
	error NotPositionOwner(address owner, address sender);

    /// @notice The rate of fee per tick managed by Uniswap V4 in pips.
    uint24 public constant DEFAULT_BASE_FEE_PER_TICK = 30;
    /// @notice The percentage of hook fees on top of the base fee.
    uint8 public constant DEFAULT_HOOK_FEE = 25;
	/// @notice The maximum tick spacing for the pool.
	int24 public constant MAX_TICK_SPACING = 200;
	uint24 public constant REWARD_LOCK_PERIOD = 1 days;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    mapping(PoolId => int24 tick) public desiredPriceTicks;
    mapping(PoolId => uint24 pip) public baseFees;
    mapping(PoolId => uint8 percent) public hookFees;

    mapping(PoolId => BalanceDelta) internal feesCollected;
	mapping(PoolId => uint256) internal totalWeights;
	mapping(PoolId => uint24) internal priceUpdateIds;
	mapping(PoolId => mapping(uint24 => PriceUpdate)) internal priceUpdates;
    mapping(uint256 positionId => RewardQueue) internal rewards;
	mapping(uint256 positionId => uint256) collectableRewards;

    IPositionManager public immutable posm;

	BeforeSwapInfo private _beforeSwapInfo = BeforeSwapInfoLibrary.UNSET;

    constructor(IPoolManager _poolManager, IPositionManager _positionManager, address _owner)
        BaseHook(_poolManager)
        Owned(_owner)
    {
        posm = _positionManager;
    }

    function createPool(
        Currency _currency0,
        Currency _currency1,
        int24 _tickSpacing,
        uint160 _sqrtPriceX96,
        int24 _desiredPriceTick
    ) external onlyOwner {
        require(!(_currency0 == _currency1), "Invalid currency pair");
        require(_tickSpacing >= 1 && _tickSpacing <= MAX_TICK_SPACING, "Invalid tick spacing");

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
        baseFees[id] = uint24(_tickSpacing) * DEFAULT_BASE_FEE_PER_TICK;
        hookFees[id] = DEFAULT_HOOK_FEE;
		_setDesiredPrice(id, _desiredPriceTick);

        poolManager.initialize(key, _sqrtPriceX96);
    }

	function getCollectableRewardWeight(uint256 positionId) external returns (uint256 weight) {
		uint40 timestamp = block.timestamp.toUint40();
		(, weight) = _updateCollectableReward(positionId, timestamp);
	}

	function calculateReward(PoolKey calldata key, uint256 weight) external view returns (uint256 amount0, uint256 amount1) {
		PoolId id = key.toId();
		(amount0, amount1, , ) = _calculateReward(id, key.currency0, key.currency1, weight);
	}

	function calculateReward(uint256 positionId, uint256 weight) external view returns (uint256 amount0, uint256 amount1) {
		(PoolKey memory key, ) = posm.getPoolAndPositionInfo(positionId);
		PoolId id = key.toId();
		(amount0, amount1, , ) = _calculateReward(id, key.currency0, key.currency1, weight);
	}

	function calculateReward(uint256 positionId) external returns (uint256 amount0, uint256 amount1) {
		(PoolKey memory key, ) = posm.getPoolAndPositionInfo(positionId);
		PoolId id = key.toId();
		uint40 timestamp = block.timestamp.toUint40();
		(, uint256 weight) = _updateCollectableReward(positionId, timestamp);
		(amount0, amount1, , ) = _calculateReward(id, key.currency0, key.currency1, weight);
	}

	function collectReward(uint256 positionId, address recipient) external nonReentrant {
		if (recipient == address(0)) {
			InvalidAddress.selector.revertWith(recipient);
		}
		IERC721 positionToken = IERC721(address(posm));
		address owner = positionToken.ownerOf(positionId);
		if (msg.sender != owner) {
			NotPositionOwner.selector.revertWith(msg.sender, owner);
		}
		uint40 timestamp = block.timestamp.toUint40();
		(, uint256 collectable) = _updateCollectableReward(positionId, timestamp);
		if (collectable == 0) {
			return;
		}

		(PoolKey memory key, ) = posm.getPoolAndPositionInfo(positionId);
		PoolId id = key.toId();
		(uint256 amountToSend0, uint256 amountToSend1, uint256 totalWeight, BalanceDelta fees) =
			_calculateReward(id, key.currency0, key.currency1, collectable);

		collectableRewards[positionId] = 0;
		totalWeights[id] = totalWeight - collectable;
		feesCollected[id] = fees - toBalanceDelta(amountToSend0.toInt256().toInt128(), amountToSend1.toInt256().toInt128());
		if (amountToSend0 > 0) {
			key.currency0.transfer(recipient, amountToSend0);
		}
		if (amountToSend1 > 0) {
			key.currency1.transfer(recipient, amountToSend1);
		}
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

	function _calculateReward(
		PoolId id,
		Currency currency0,
		Currency currency1,
		uint256 weight
	) internal view returns (uint256 amount0, uint256 amount1, uint256 totalWeight, BalanceDelta fees) {
		totalWeight = totalWeights[id];
		fees = feesCollected[id];
		if (totalWeight == 0) {
			return (0, 0, totalWeight, fees);
		}
		uint256 fees0 = uint128(fees.amount0());
		uint256 fees1 = uint128(fees.amount1());
		uint256 balance0 = currency0.balanceOfSelf();
		uint256 balance1 = currency1.balanceOfSelf();
		amount0 = Math.min(balance0, fees0) * weight / totalWeight;
		amount1 = Math.min(balance1, fees1) * weight / totalWeight;
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
		BeforeSwapInfo beforeSwapInfo = _beforeSwapInfo;
        if (beforeSwapInfo != BeforeSwapInfoLibrary.UNSET) {
            UnexpectedReentrancy.selector.revertWith();
        }
        PoolId id = key.toId();
        (, int24 priceTick, uint24 protocolFee,) = poolManager.getSlot0(id);
        uint16 currentProtocolFee = swapParams.zeroForOne
            ? ProtocolFeeLibrary.getZeroForOneFee(protocolFee)
            : ProtocolFeeLibrary.getOneForZeroFee(protocolFee);
        uint24 fee = baseFees[id];
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
        uint24 baseFee = baseFees[id];
        uint24 hookFeePip = baseFee * hookFees[id] / 100;
        uint256 hookFeeAmountBase =
            abs(int256(deltaUnspecified)).toUint256() * (1e6 - beforeSwapInfo.swapFee()) * uint256(hookFeePip) / 1e12;

        (, int24 afterSwapTick,,) = poolManager.getSlot0(id);
        int24 desiredPrice = desiredPriceTicks[id];
        int24 tickDiff = abs24(afterSwapTick - desiredPrice) - abs24(beforeSwapInfo.tick() - desiredPrice);

        uint256 hookFeeAmount; // 1 / (1 + tickDiff / (4 * sqrt(tickSpacing)))
        if (tickDiff == 0) {
            hookFeeAmount = hookFeeAmountBase;
        } else {
            uint256 factor = Math.sqrt(int256(key.tickSpacing).toUint256() << 232) << 2;
            hookFeeAmount = hookFeeAmountBase * factor / (factor + (int256(abs24(tickDiff)).toUint256() << 116));
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
		_verifyTickBounds(params.tickLower, params.tickUpper, key.tickSpacing);

        PoolId id = key.toId();
        int256 desiredPrice = desiredPriceTicks[id];
		int256 rewardRange = _checkRewardRange(desiredPrice, params.tickLower, params.tickUpper, key.tickSpacing);
		if (rewardRange == 0) {
			return BaseHook.beforeAddLiquidity.selector;
		}

		uint256 positionId = _verifyPositionId(id, params, hookData);
        uint256 weight = _calculateWeight(params, desiredPrice, key.tickSpacing, rewardRange);
		uint40 timestamp = block.timestamp.toUint40();
		RewardQueue storage queue = rewards[positionId];
		bool done = false;
		if (!queue.empty()) {
			uint128 endIdx = queue.end - 1;
			Reward memory latest = queue.data[endIdx];
			if (latest.timestamp == timestamp) {
				latest.weight += weight;
				queue.data[endIdx] = latest;
				done = true;
			}
		}
		if (!done) {
			uint24 currentId = priceUpdateIds[id] - 1;
			Reward memory reward = Reward({
				timestamp: timestamp,
				priceUpdateId: currentId,
				lockPeriod: REWARD_LOCK_PERIOD,
				weight: weight
			});
			queue.pushLatest(reward);
		}
		totalWeights[id] += weight;
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
		_verifyTickBounds(params.tickLower, params.tickUpper, key.tickSpacing);

        PoolId id = key.toId();
        int256 desiredPrice = desiredPriceTicks[id];
		int256 rewardRange = _checkRewardRange(desiredPrice, params.tickLower, params.tickUpper, key.tickSpacing);
		if (rewardRange == 0) {
			return BaseHook.beforeAddLiquidity.selector;
		}

		uint256 positionId = _verifyPositionId(id, params, hookData);
		RewardQueue storage queue = rewards[positionId];
		if (queue.empty()) {
			return BaseHook.beforeRemoveLiquidity.selector;
		}

		uint40 timestamp = block.timestamp.toUint40();
        uint256 weight = _calculateWeight(params, desiredPrice, key.tickSpacing, rewardRange);
		uint256 remainingWeight = weight;
		uint128 endIdx = queue.end - 1;
		Reward memory latest = queue.data[endIdx];
		if (latest.timestamp == timestamp) {
			if (latest.weight > weight) {
				latest.weight -= weight;
				queue.data[endIdx] = latest;
				remainingWeight = 0;
			}
			else {
				remainingWeight -= latest.weight;
				queue.popLatest();
			}
		}
		if (remainingWeight > 0) {
			(bool empty, ) = _updateCollectableReward(positionId, timestamp);
			if (!empty) {
				do {
					Reward memory earliest = queue.peekEarliest();
					if (earliest.weight > remainingWeight) {
						earliest.weight -= remainingWeight;
						queue.data[queue.begin] = earliest;
						remainingWeight = 0;
					}
					else {
						remainingWeight -= earliest.weight;
						queue.popEarliest();
					}
				} while (!queue.empty() && remainingWeight > 0);
			}
		}
		totalWeights[id] -= weight - remainingWeight;
        return BaseHook.beforeRemoveLiquidity.selector;
    }

	function _setDesiredPrice(PoolId id, int24 desiredPrice) private {
		PriceUpdate memory update = PriceUpdate({
			timestamp: block.timestamp.toUint40(),
			oldPriceTick: desiredPriceTicks[id],
			newPriceTick: desiredPrice
		});
		uint24 nextId = priceUpdateIds[id];
		priceUpdates[id][nextId] = update;
		priceUpdateIds[id] = nextId + 1;
		desiredPriceTicks[id] = desiredPrice;
	}

	function _verifyTickBounds(int24 tickLower, int24 tickUpper, int24 tickSpacing) internal pure {
		if (tickLower >= tickUpper) {
			revert InvalidTickBounds(tickLower, tickUpper, tickSpacing);
		}
		if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) {
			revert InvalidTickBounds(tickLower, tickUpper, tickSpacing);
		}
		if (abs24(tickLower) > TickMath.MAX_TICK || abs24(tickUpper) > TickMath.MAX_TICK) {
			revert InvalidTickBounds(tickLower, tickUpper, tickSpacing);
		}
	}

	function _checkRewardRange(int256 desiredPrice, int24 tickLower, int24 tickUpper, int24 _tickSpacing) internal pure returns (int256 rewardRange) {
		uint256 tickSpacing = uint24(_tickSpacing);
		int256 range = ((Math.log2(tickSpacing) + 2) * uint24(MAX_TICK_SPACING) >> 2).toInt256();
		return tickLower < desiredPrice - range || tickUpper >= desiredPrice + range ? int256(0) : range;
	}

	function _verifyPositionId(
		PoolId id,
		IPoolManager.ModifyLiquidityParams calldata params,
		bytes calldata hookData
	) internal view returns (uint256 positionId) {
        positionId = abi.decode(hookData, (uint256));
        PositionInfo position = posm.positionInfo(positionId);
        bytes25 positionPoolId = position.poolId();
        if (positionPoolId != bytes25(PoolId.unwrap(id))) {
            revert InvalidPositionId(positionId);
        }
        if (position.tickLower() != params.tickLower || position.tickUpper() != params.tickUpper) {
            revert InvalidPositionId(positionId);
        }
    }

    function _calculateWeight(
		IPoolManager.ModifyLiquidityParams calldata params,
		int256 desiredPrice,
		int24 tickSpacing,
		int256 rewardRange
	) internal pure returns (uint256 weight) {
		int256 left = max(params.tickLower, desiredPrice - rewardRange);
		int256 right = min(params.tickUpper, desiredPrice + rewardRange + tickSpacing);
        uint256 factor = Math.sqrt(int256(tickSpacing).toUint256() << 232) << 2;
		uint256 sum = 0;
		for (int256 i = left; i < right; i += tickSpacing) {
			sum += (factor << 16) / (factor + (int256(abs(i - desiredPrice)).toUint256() << 116));
		}
		return (sum * abs(params.liquidityDelta).toUint256()) >> 16;
    }

	function _updateCollectableReward(uint256 positionId, uint40 timestamp) internal returns (bool empty, uint256 collectable) {
		RewardQueue storage queue = rewards[positionId];
		collectable = collectableRewards[positionId];
		if (queue.empty()) {
			return (true, collectable);
		}
		empty = true;
		do {
			Reward memory earliest = queue.peekEarliest();
			if (earliest.timestamp + earliest.lockPeriod > timestamp) {
				empty = false;
				break;
			}
			collectable += earliest.weight;
			queue.popEarliest();
		} while (!queue.empty());
		collectableRewards[positionId] = collectable;
	}
}