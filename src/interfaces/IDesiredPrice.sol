// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/src/types/PoolId.sol";

import {Poll} from "../libraries/Poll.sol";
import {IGovernanceToken} from "./IGovernanceToken.sol";

interface IDesiredPrice {
    error PollCurrentlyPaused(PoolId id);
    error InsufficientDelegation(PoolId id, address from, address to, uint256 power);
    error ZeroDelegation();
    error NoDelegationDuringFinalVote();
    error UndelegationLocked(PoolId id, address from, address to, uint40 unlockTime);
    error ZeroVotingPower(address voter);
    error NotInVotableStage(PoolId id, Poll.Stage stage);
    error AlreadyVoted(address voter, uint40 voteTime);
    error ExecutionNotReady();
    error PendingPollExecution(PoolId id);

    event PriceUpdated(PoolId indexed id, int24 oldPriceTick, int24 newPriceTick);
    event VoteDelegated(PoolId indexed id, address indexed from, address indexed to, uint128 power);
    event VoteUndelegated(PoolId indexed id, address indexed from, address indexed to, uint128 power);
    event VoteCasted(PoolId indexed id, uint16 indexed pollId, address indexed voter, int8 lowerSlot, int8 upperSlot, uint128 votingPower);
    event PollEnded(PoolId indexed id, uint16 indexed pollId, Poll.Result result, uint40 startTime, uint128 totalVotes);

    function desiredPrice(PoolId id) external view returns (int24);

    function governanceToken() external view returns (IGovernanceToken);

    function votingPowerOf(PoolId id, address from) external view returns (uint256);

    function getDelegation(PoolId id, address from, address to) external view returns (uint256);

    function voteTimeOf(PoolId id, address voter) external view returns (uint40);

    function pollId(PoolId id) external view returns (uint16);

    function pollPaused(PoolId id) external view returns (bool);

    function pollWillPause(PoolId id) external view returns (bool);

    function pollCurrentInfo(PoolId id) external view returns (Poll.CurrentInfo memory);

    function delegateVote(PoolId id, address to, uint128 power) external;

    function undelegateVote(PoolId id, address to, uint128 power) external;

    function undelegateVote(PoolId id, address to) external;

    function castVote(PoolId id, int8 lowerSlot, int8 upperSlot) external;

    function castVote(PoolId id, int8 slot) external;

    function execute(PoolId id) external returns (Poll.Result result);
}