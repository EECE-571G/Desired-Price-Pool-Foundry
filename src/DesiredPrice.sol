// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {IDesiredPrice} from "./interfaces/IDesiredPrice.sol";
import {IDesiredPriceOwner} from "./interfaces/IDesiredPriceOwner.sol";
import {IGoveranceToken} from "./interfaces/IGoveranceToken.sol";
import {Poll} from "./libraries/Poll.sol";
import {PriceUpdate} from "./types/PriceUpdate.sol";
import {VoteInfo} from "./types/VoteInfo.sol";
import {SafeCast128} from "./utils/SafeCast128.sol";
import {GoveranceToken} from "./GoveranceToken.sol";

abstract contract DesiredPrice is IDesiredPrice, IDesiredPriceOwner, Context, Owned {
    using PoolIdLibrary for PoolKey;
    using CustomRevert for bytes4;
    using Poll for *;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast128 for uint128;
    using SafeCast128 for int128;

    uint40 internal constant UNDELEGATE_DELAY = 1 days;

    GoveranceToken internal immutable govToken;

    mapping(PoolId => mapping(address => VoteInfo)) internal voteInfos;
    mapping(PoolId => Poll.State) internal polls;

    mapping(PoolId => int24 tick) public desiredPrice;
    mapping(PoolId => uint24) internal priceUpdateIds;
    mapping(PoolId => mapping(uint24 => PriceUpdate)) internal priceUpdates;

    constructor(address _owner) Owned(_owner) {
        govToken = new GoveranceToken(_owner);
    }

    modifier whenPollNotPaused(PoolId id) {
        Poll.State storage poll = polls[id];
        if (poll.isPaused()) {
            revert PollCurrentlyPaused(id);
        }
        _;
    }

    function goveranceToken() external view returns (IGoveranceToken) {
        return govToken;
    }

    function votingPowerOf(PoolId id, address from) external view returns (uint256) {
        return voteInfos[id][from].votingPower;
    }

    function getDelegation(PoolId id, address from, address to) external view returns (uint256) {
        return voteInfos[id][from].delegation[to];
    }

    function hasVoted(PoolId id, address voter) external view returns (bool) {
        uint16 pollId = polls[id].id;
        return voteInfos[id][voter].hasVotedFor(pollId);
    }

    function startPoll(PoolId id) external onlyOwner {
        Poll.StartPauseResult result = polls[id].start();
        if (result == Poll.StartPauseResult.Started) {
            emit PollStarted(id, polls[id].id, block.timestamp.toUint40());
        }
        else if (result == Poll.StartPauseResult.PauseCanceled) {
            emit PollPauseCanceled(id, polls[id].id, block.timestamp.toUint40());
        }
    }

    function pausePoll(PoolId id) external onlyOwner {
        Poll.StartPauseResult result = polls[id].pause();
        if (result == Poll.StartPauseResult.PauseRequested) {
            emit PollPauseRequested(id, polls[id].id, block.timestamp.toUint40());
        }
    }

    function updatePollFlags(PoolId id, uint8 flagsToSet, uint8 flagsToClear) external onlyOwner {
        Poll.State storage poll = polls[id];
        poll.setFlags(flagsToSet);
        poll.clearFlags(flagsToClear);
    }

    function delegateVote(PoolId id, address to, uint128 power) external {
        _updateDelegation(id, _msgSender(), to, power.toInt128());
    }

    function undelegateVote(PoolId id, address to, uint128 power) external {
        _updateDelegation(id, _msgSender(), to, -power.toInt128());
    }

    function undelegateVote(PoolId id, address to) external {
        VoteInfo storage voteInfo = voteInfos[id][_msgSender()];
        int128 currentDelegation = int128(int256(voteInfo.delegation[to]));
        _updateDelegation(id, _msgSender(), to, -currentDelegation);
    }

    function castVote(PoolId id, int8 lowerSlot, int8 upperSlot) external {
        _castVote(id, _msgSender(), lowerSlot, upperSlot);
    }

    function castVote(PoolId id, int8 slot) external {
        _castVote(id, _msgSender(), slot, slot + 1);
    }

    function execute(PoolId id) external {
        _execute(id);
    }

    function _setDesiredPrice(PoolId id, int24 priceTick) internal {
        PriceUpdate memory update = PriceUpdate({
            timestamp: block.timestamp.toUint40(),
            oldPriceTick: desiredPrice[id],
            newPriceTick: priceTick
        });
        uint24 nextId = priceUpdateIds[id];
        priceUpdates[id][nextId] = update;
        priceUpdateIds[id] = nextId + 1;
        desiredPrice[id] = priceTick;
        emit PriceUpdated(id, update.oldPriceTick, priceTick);
    }

    function _updateDelegation(PoolId id, address from, address to, int128 power) internal {
        if (power == 0) {
            ZeroDelegation.selector.revertWith();
        }
        Poll.State storage poll = polls[id];
        if (power > 0) {
            if (poll.isPaused()) {
                revert PollCurrentlyPaused(id);
            }
            Poll.Stage stage = poll.getStage();
            if (stage == Poll.Stage.FinalVote) {
                NoDelegationDuringFinalVote.selector.revertWith();
            }
            //TODO: Minimum liquidity check
        }
        VoteInfo storage fromInfo = voteInfos[id][from];
        VoteInfo storage toInfo = to == from ? fromInfo : voteInfos[id][to];
        if (power < 0 && toInfo.hasVotedFor(poll.id)) {
            uint40 unlockTime = toInfo.voteTime + UNDELEGATE_DELAY;
            if (unlockTime > block.timestamp) {
                revert UndelegationLocked(id, from, to, unlockTime);
            }
        }
        uint128 powerDelta = uint128(power < 0 ? -power : power);
        if (power > 0) {
            govToken.lock(from, powerDelta);
            fromInfo.delegation[to] += powerDelta;
            toInfo.votingPower += powerDelta;
            emit VoteDelegated(id, from, to, powerDelta);
        }
        else {
            uint256 currentDelegation = fromInfo.delegation[to];
            if (currentDelegation < powerDelta) {
                revert InsufficientDelegation(id, from, to, currentDelegation);
            }
            govToken.unlock(from, powerDelta);
            fromInfo.delegation[to] = currentDelegation - powerDelta;
            toInfo.votingPower -= powerDelta;
            emit VoteUndelegated(id, from, to, powerDelta);
        }
    }

    function _castVote(PoolId id, address voter, int8 lowerSlot, int8 upperSlot) internal whenPollNotPaused(id) {
        VoteInfo storage info = voteInfos[id][voter];
        uint128 votingPower = info.votingPower;
        if (votingPower == 0) {
            ZeroVotingPower.selector.revertWith(voter);
        }
        Poll.State storage poll = polls[id];
        if (info.hasVotedFor(poll.id)) {
            revert AlreadyVoted(voter, info.voteTime);
        }
        Poll.Stage stage = poll.getStage();
        if (stage != Poll.Stage.Vote && stage != Poll.Stage.FinalVote) {
            revert NotInVotableStage(id, stage);
        }
        poll.updateVote(lowerSlot, upperSlot, votingPower);
        info.pollId = poll.id;
        info.voteTime = block.timestamp.toUint40();
        emit VoteCasted(id, poll.id, voter, lowerSlot, upperSlot, votingPower);
    }

    function _checkPollExecution(PoolId id) internal {
        Poll.State storage poll = polls[id];
        if (poll.hasFlags(Poll.FLAG_IN_TIME_EXECUTION) && poll.getStage() == Poll.Stage.ExecutionReady) {
            if (poll.hasFlags(Poll.FLAG_MANUAL_EXECUTION)) {
                revert PendingPollExecution(id);
            }
            _executePoll(id, poll);
        }
    }

    function _tryExecute(PoolId id) internal whenPollNotPaused(id) returns (bool) {
        Poll.State storage poll = polls[id];
        if (poll.getStage() != Poll.Stage.ExecutionReady) {
            return false;
        }
        _executePoll(id, poll);
        return true;
    }

    function _execute(PoolId id) internal whenPollNotPaused(id) {
        Poll.State storage poll = polls[id];
        if (poll.getStage() != Poll.Stage.ExecutionReady) {
            ExecutionNotReady.selector.revertWith();
        }
        _executePoll(id, poll);
    }

    function _executePoll(PoolId id, Poll.State storage poll) private {
        (Poll.Result result, int24 tickDelta) = poll.getResult();
        if (tickDelta != 0) {
            int24 currentTick = desiredPrice[id];
            _setDesiredPrice(id, currentTick + tickDelta);
        }
        emit PollEnded(id, poll.id, result, poll.startTime, poll.totalVotes);
        Poll.StartPauseResult res = poll.reset();
        if (res == Poll.StartPauseResult.Paused) {
            emit PollPaused(id, poll.id, block.timestamp.toUint40());
        }
    }
}