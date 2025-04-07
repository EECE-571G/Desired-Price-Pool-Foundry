// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct Reward {
    /// @notice The timestamp when the reward was created, i.e. when liquidity was added
    uint40 timestamp;
	/// @notice Time required to unlock the reward, in seconds
    uint32 lockPeriod;
	uint24 priceUpdateId;
    /// @notice The weight of the reward, used to calculate the reward amount
    uint256 weight;
}

struct RewardQueue {
    uint128 begin;
    uint128 end;
    mapping(uint128 => Reward) data;
}

using RewardQueueLibrary for RewardQueue global;

library RewardQueueLibrary {
    error QueueEmpty();
    error QueueFull();

    function pushLatest(RewardQueue storage queue, Reward memory reward) internal {
        unchecked {
            uint128 end = queue.end;
            if (end + 1 == queue.begin) {
                revert QueueFull();
            }
            queue.data[end] = reward;
            queue.end = end + 1;
        }
    }

	function popLatest(RewardQueue storage queue) internal returns (Reward memory value) {
        unchecked {
            uint128 end = queue.end;
            if (end == queue.begin) {
				revert QueueEmpty();
			}
            --end;
            value = queue.data[end];
            delete queue.data[end];
            queue.end = end;
        }
    }

    function popEarliest(RewardQueue storage queue) internal returns (Reward memory value) {
        unchecked {
            uint128 begin = queue.begin;
            if (begin == queue.end) {
                revert QueueEmpty();
            }
            value = queue.data[begin];
            delete queue.data[begin];
            queue.begin = begin + 1;
        }
    }

	function peekEarliest(RewardQueue storage queue) internal view returns (Reward memory value) {
		unchecked {
			uint128 begin = queue.begin;
			if (begin == queue.end) {
				revert QueueEmpty();
			}
			value = queue.data[begin];
		}
	}

	function peekLatest(RewardQueue storage queue) internal view returns (Reward memory value) {
		unchecked {
			uint128 end = queue.end;
			if (end == queue.begin) {
				revert QueueEmpty();
			}
			value = queue.data[end - 1];
		}
	}

    /**
     * @dev Returns the number of items in the queue.
     */
    function length(RewardQueue storage queue) internal view returns (uint256) {
        unchecked {
            return uint256(queue.end - queue.begin);
        }
    }

    /**
     * @dev Returns true if the queue is empty.
     */
    function empty(RewardQueue storage queue) internal view returns (bool) {
        return queue.end == queue.begin;
    }
}
