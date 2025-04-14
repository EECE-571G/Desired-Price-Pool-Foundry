// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

interface IHookReward {
    error InvalidPositionId(uint256 positionId);
    error InvalidAddress(address addr);
    error NotPositionOwner(address owner, address sender);

    function positionManager() external view returns (IPositionManager);

    function calculateReward(PoolKey calldata key, uint256 weight) external view returns (uint256 amount0, uint256 amount1);

    function calculateReward(uint256 positionId, uint256 weight) external view returns (uint256 amount0, uint256 amount1);

    function calculateReward(uint256 positionId) external returns (uint256 amount0, uint256 amount1);

    function getCollectableRewardWeight(uint256 positionId) external returns (uint256);

    function collectReward(uint256 positionId, address recipient) external;
}