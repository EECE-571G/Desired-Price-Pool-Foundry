// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct VoteInfo {
    uint128 votingPower;
    uint16 pollId;
    uint40 voteTime;
    mapping(address => uint256) delegation;
}

using VoteInfoLibrary for VoteInfo global;

library VoteInfoLibrary {
    function hasVotedFor(VoteInfo storage self, uint16 pollId) internal view returns (bool) {
        return self.pollId == pollId && self.voteTime != 0;
    }
}