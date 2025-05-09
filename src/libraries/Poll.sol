// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "../utils/Math.sol";

library Poll {
    using Poll for State;

    error InvalidVoteSlotRange(int8 lowerSlot, int8 upperSlot);

    int8 constant VOTE_RANGE = 10;
    uint256 constant VOTE_SLOTS = 21; // VOTE_RANGE * 2 + 1
    uint256 constant CYCLE = 5;

    uint256 constant REGULAR_POLL_PREVOTE_END = 1 days;
    uint256 constant REGULAR_POLL_VOTE_END = 3 days;
    uint256 constant REGULAR_POLL_FINALVOTE_END = 4 days;
    uint256 constant REGULAR_POLL_EXECUTION_READY = 5 days;

    uint256 constant MAJOR_POLL_PREVOTE_END = 1 days;
    uint256 constant MAJOR_POLL_VOTE_END = 6 days;
    uint256 constant MAJOR_POLL_FINALVOTE_END = 8 days;
    uint256 constant MAJOR_POLL_EXECUTION_READY = 10 days;

    uint8 constant FLAG_MANUAL_EXECUTION = 1 << 0;
    uint8 constant FLAG_IN_TIME_EXECUTION = 1 << 1;

    enum Stage {
        PreVote,
        Vote,
        FinalVote,
        PreExecution,
        ExecutionReady
    }

    enum Result {
        NotReady,
        InsufficientVotes,
        NoMajority,
        Hold,
        MoveDown,
        MoveUp
    }

    enum StartPauseResult {
        Unchanged,
        Started,
        PauseRequested,
        PauseCanceled,
        Paused
    }

    struct State {
        uint16 id;
        uint40 startTime;
        bool pauseRequested;
        uint8 flags;
        uint128 totalVotes;
        int128[VOTE_SLOTS] voteDiffs;
    }

    struct CurrentInfo {
        uint16 id;
        uint40 startTime;
        uint40 currentTime;
        bool isMajor;
        Stage stage;
        Result result;
        uint128 totalVotes;
        uint128[VOTE_SLOTS] votes;
    }

    function verifyVoteRange(int8 lowerSlot, int8 upperSlot) internal pure {
        if (lowerSlot < -VOTE_RANGE || upperSlot > VOTE_RANGE + 1 || lowerSlot >= upperSlot) {
            revert InvalidVoteSlotRange(lowerSlot, upperSlot);
        }
    }

    function isPaused(State storage self) internal view returns (bool) {
        return self.startTime == 0;
    }

    function isMajorPoll(State storage self) internal view returns (bool) {
        return self.id % CYCLE == CYCLE - 1;
    }

    function hasFlags(State storage self, uint8 flags) internal view returns (bool) {
        return (self.flags & flags) != 0;
    }

    function setFlags(State storage self, uint8 flags) internal {
        self.flags |= flags;
    }

    function clearFlags(State storage self, uint8 flags) internal {
        self.flags &= ~flags;
    }

    function getStage(State storage self) internal view returns (Stage stage) {
        uint40 timePassed = uint40(block.timestamp) - self.startTime;
        if (self.isMajorPoll()) {
            if (timePassed < MAJOR_POLL_PREVOTE_END) {
                return Stage.PreVote;
            }
            if (timePassed < MAJOR_POLL_VOTE_END) {
                return Stage.Vote;
            }
            if (timePassed < MAJOR_POLL_FINALVOTE_END) {
                return Stage.FinalVote;
            }
            if (timePassed < MAJOR_POLL_EXECUTION_READY) {
                return Stage.PreExecution;
            }
            return Stage.ExecutionReady;
        }
        else {
            if (timePassed < REGULAR_POLL_PREVOTE_END) {
                return Stage.PreVote;
            }
            if (timePassed < REGULAR_POLL_VOTE_END) {
                return Stage.Vote;
            }
            if (timePassed < REGULAR_POLL_FINALVOTE_END) {
                return Stage.FinalVote;
            }
            if (timePassed < REGULAR_POLL_EXECUTION_READY) {
                return Stage.PreExecution;
            }
            return Stage.ExecutionReady;
        }
    }

    function calculateResult(int8 highestSlot, uint128 highestAmount, uint128 totalAmount) internal pure returns (Result result) {
        // TODO: total vote threshold
        if (highestAmount == 0) {
            return Result.InsufficientVotes;
        }
        // TODO: majority threshold
        if (highestAmount * 3 < totalAmount) {
            return Result.NoMajority;
        }
        return highestSlot == 0 ? Result.Hold : (highestSlot > 0 ? Result.MoveUp : Result.MoveDown);
    }

    function getResult(State storage self) internal view returns (Result result, int24 tickDelta) {
        Stage stage = self.getStage();
        if (stage != Stage.PreExecution && stage != Stage.ExecutionReady) {
            return (Result.NotReady, 0);
        }
        (int8 highestSlot, uint128 highestAmount,) = self.count();
        result = calculateResult(highestSlot, highestAmount, self.totalVotes);
        tickDelta = (result == Result.MoveDown || result == Result.MoveUp) ? self.slotToTickDelta(highestSlot) : int24(0);
    }

    function getCurrentInfo(State storage self) internal view returns (CurrentInfo memory info) {
        info.id = self.id;
        info.startTime = self.startTime;
        info.currentTime = uint40(block.timestamp);
        info.isMajor = self.isMajorPoll();
        info.stage = self.getStage();
        info.totalVotes = self.totalVotes;
        int8 highestSlot;
        uint128 highestAmount;
        (highestSlot, highestAmount, info.votes) = self.count();
        info.result = (info.stage != Stage.PreExecution && info.stage != Stage.ExecutionReady) 
            ? Result.NotReady
            : calculateResult(highestSlot, highestAmount, self.totalVotes);
    }

    function slotToTickDelta(State storage self, int8 voteSlot) internal view returns (int24) {
        if (voteSlot == 0) {
            return 0;
        }
        // Major poll: linear, 5.0% * slot, max 50%
        if (self.isMajorPoll()) {
            return int24(voteSlot) * 500;
        }
        // Regular poll: exponential, 0.01% * 2 ^ slot, max 10.24%
        else if (voteSlot > 0) {
            return int24(1) << uint8(voteSlot);
        }
        else {
            return int24(-1) << uint8(-voteSlot);
        }
    }

    function start(State storage self) internal returns (StartPauseResult result) {
        if (self.pauseRequested) {
            self.pauseRequested = false;
            result = StartPauseResult.PauseCanceled;
        }
        if (self.isPaused()) {
            self.startTime = uint40(block.timestamp);
            result = StartPauseResult.Started;
        }
    }

    function pause(State storage self) internal returns (StartPauseResult result) {
        if (!self.isPaused()) {
            self.pauseRequested = true;
            result = StartPauseResult.PauseRequested;
        }
    }

    function reset(State storage self) internal returns (StartPauseResult result) {
        self.id = self.id + 1;
        if (self.pauseRequested) {
            self.startTime = 0;
            result = StartPauseResult.Paused;
        }
        else {
            self.startTime = uint40(block.timestamp);
            result = StartPauseResult.Unchanged;
        }
        self.pauseRequested = false;
        self.totalVotes = 0;
        delete self.voteDiffs;
    }

    function updateVote(State storage self, int8 lowerSlot, int8 upperSlot, uint128 amount) internal {
        verifyVoteRange(lowerSlot, upperSlot);
        self.totalVotes += amount;
        self.voteDiffs[uint8(lowerSlot + VOTE_RANGE)] += int128(amount);
        if (upperSlot <= VOTE_RANGE) {
            self.voteDiffs[uint8(upperSlot + VOTE_RANGE)] -= int128(amount);
        }
    }

    function count(State storage self)
        internal
        view
        returns (int8 highestSlot, uint128 highestAmount, uint128[VOTE_SLOTS] memory votes)
    {
        if (self.totalVotes == 0) {
            return (0, 0, votes);
        }
        uint8 highestSlotRaw = 0;
        int8 offset = VOTE_RANGE;
        for (uint8 i = 0; i < VOTE_SLOTS; i++) {
            votes[i] = uint128(i == 0 ? self.voteDiffs[i] : int128(votes[i - 1]) + self.voteDiffs[i]);
            if (uint128(votes[i]) < highestAmount) {
                continue;
            }
            int8 curOffset = Math.abs8(int8(i) - VOTE_RANGE);
            if (uint128(votes[i]) == highestAmount && curOffset >= offset) {
                continue;
            }
            highestSlotRaw = i;
            highestAmount = uint128(votes[i]);
            offset = curOffset;
        }
        highestSlot = int8(highestSlotRaw) - VOTE_RANGE;
    }
}
