// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/src/types/PoolId.sol";

import {Poll} from "../types/Poll.sol";
import {VoteInfo} from "../types/VoteInfo.sol";

interface IDesiredPriceOwner {
    event PollStarted(PoolId indexed id, uint16 indexed pollId, uint40 startTime);
    event PollPauseRequested(PoolId indexed id, uint16 indexed pollId, uint40 requestTime);
    event PollPauseCanceled(PoolId indexed id, uint16 indexed pollId, uint40 cancelTime);
    event PollPaused(PoolId indexed id, uint16 indexed pollId, uint40 pauseTime);

    function startPoll(PoolId id) external;

    function pausePoll(PoolId id) external;

    function updatePollFlags(PoolId id, uint8 flagsToSet, uint8 flagsToClear) external;
}