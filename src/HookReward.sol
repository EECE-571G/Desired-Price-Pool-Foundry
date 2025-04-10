// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Reward, RewardQueue} from "./types/Reward.sol";
import {Math as Math2} from "./utils/Math.sol";
import {DesiredPrice} from "./DesiredPrice.sol";

abstract contract HookReward is DesiredPrice, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using PositionInfoLibrary for PositionInfo;
    using CustomRevert for bytes4;
    using SafeCast for uint256;
    using SafeCast for int256;

    error InvalidPositionId(uint256 positionId);
    error InvalidAddress(address addr);
    error NotPositionOwner(address owner, address sender);

    /// @notice The maximum tick spacing for the pool.
    int24 public constant MAX_TICK_SPACING = 200;
    uint24 public constant REWARD_LOCK_PERIOD = 1 days;

    mapping(PoolId => BalanceDelta) internal feesCollected;
    mapping(PoolId => uint256) internal totalWeights;
    mapping(uint256 positionId => RewardQueue) internal rewards;
    mapping(uint256 positionId => uint256) internal collectableRewards;

    IPositionManager public immutable posm;

    constructor(IPositionManager _positionManager) {
        posm = _positionManager;
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

    function _calculateRewardRange(int24 _tickSpacing) internal pure returns (int24 range) {
        uint256 tickSpacing = uint24(_tickSpacing);
        return ((Math.log2(tickSpacing) + 2) * uint24(MAX_TICK_SPACING) >> 2).toInt256().toInt24();
    }

    function _calculateWeight(
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        int24 desiredPrice,
        int24 rewardRange,
        int256 liquidityDelta
    ) internal pure returns (uint256 weight) {
        int256 left = Math2.max(tickLower, desiredPrice - rewardRange);
        int256 right = Math2.min(tickUpper, desiredPrice + rewardRange + 1);
        left = left / tickSpacing * tickSpacing;
        uint256 factor = Math.sqrt(int256(tickSpacing).toUint256() << 232) << 2;
        uint256 sum = 0;
        for (int256 i = left; i < right; i += tickSpacing) {
            sum += (factor << 16) / (factor + (int256(Math2.abs(i - desiredPrice)).toUint256() << 116));
        }
        return (sum * Math2.abs(liquidityDelta).toUint256()) >> 16;
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

    function _updatePendingReward(
        PoolId id,
        int24 tickSpacing,
        uint256 positionId,
        IPoolManager.ModifyLiquidityParams calldata params
    ) internal {
        int24 desiredPrice = desiredPriceTicks[id];
        int24 range = _calculateRewardRange(tickSpacing);
        if (params.tickLower < desiredPrice - range || params.tickUpper >= desiredPrice + range) {
            return;
        }

        bool isAddLiquidity = params.liquidityDelta > 0;
        RewardQueue storage queue = rewards[positionId];
        if (!isAddLiquidity && queue.empty()) {
            return;
        }

        uint40 timestamp = block.timestamp.toUint40();
        uint256 weight = _calculateWeight(
            params.tickLower,
            params.tickUpper,
            tickSpacing,
            desiredPrice,
            range,
            params.liquidityDelta
        );

        if (isAddLiquidity) {
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
        }
        else {
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
        }
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