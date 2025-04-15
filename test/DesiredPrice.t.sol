// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {SafeCast128} from "../src/utils/SafeCast128.sol";
import {IDesiredPrice} from "../src/interfaces/IDesiredPrice.sol";
import {IGovernanceToken} from "../src/interfaces/IGovernanceToken.sol";
import {Poll} from "../src/libraries/Poll.sol";
import {DPPTestBase} from "./DPPTestBase.sol";

contract DesiredPriceTest is DPPTestBase {
    using CurrencyLibrary for Currency;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeCast128 for uint128;
    using SafeCast128 for int128;

    IGovernanceToken govToken;

    function setUp() public override {
        super.setUp();
        govToken = dpp.governanceToken();
        govToken.transferFrom(address(govToken), address(this), 100 ether);
        dpp.startPoll(poolId);
    }

    function testRegularPoll() public {
        _testPoll(false);
    }

    function testMajorPoll() public {
        _skipPolls(4);
        _testPoll(true);
    }

    function _testPoll(bool major) internal {
        Poll.CurrentInfo memory info = dpp.pollCurrentInfo(poolId);
        uint256 startTime = info.startTime;
        assertEq(major, info.isMajor, "Poll type mismatch");
        assertTrue(info.stage == Poll.Stage.PreVote, "Stage should be PreVote");
        dpp.delegateVote(poolId, address(this), 50 ether);
        assertEq(dpp.votingPowerOf(poolId, address(this)), 50 ether, "Voting power should be 50 ether");
        assertEq(govToken.lockedBalanceOf(address(this)), 50 ether, "Locked balance should be 50 ether");
        assertEq(govToken.balanceOf(address(this)), 50 ether, "Balance should be 50 ether");
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        dpp.delegateVote(poolId, address(this), 100 ether);
        vm.expectPartialRevert(IDesiredPrice.NotInVotableStage.selector);
        dpp.castVote(poolId, 0);

        uint256 offset = major ? Poll.MAJOR_POLL_PREVOTE_END : Poll.REGULAR_POLL_PREVOTE_END;
        vm.warp(startTime + offset);
        info = dpp.pollCurrentInfo(poolId);
        assertTrue(info.stage == Poll.Stage.Vote, "Stage should be Vote");

        int8 slotLower = 2;
        int8 slotUpper = 5;
        offset = major ? Poll.MAJOR_POLL_VOTE_END : Poll.REGULAR_POLL_VOTE_END;
        vm.warp(startTime + offset);
        info = dpp.pollCurrentInfo(poolId);
        assertTrue(info.stage == Poll.Stage.FinalVote, "Stage should be FinalVote");
        vm.expectPartialRevert(IDesiredPrice.NoDelegationDuringFinalVote.selector);
        dpp.delegateVote(poolId, address(this), 25 ether);
        dpp.castVote(poolId, slotLower, slotUpper);
        vm.expectPartialRevert(IDesiredPrice.AlreadyVoted.selector);
        dpp.castVote(poolId, slotUpper);
        vm.expectPartialRevert(IDesiredPrice.UndelegationLocked.selector);
        dpp.undelegateVote(poolId, address(this));

        offset = major ? Poll.MAJOR_POLL_FINALVOTE_END : Poll.REGULAR_POLL_FINALVOTE_END;
        vm.warp(startTime + offset);
        info = dpp.pollCurrentInfo(poolId);
        assertTrue(info.stage == Poll.Stage.PreExecution, "Stage should be PreExecution");
        assertTrue(info.result == Poll.Result.MoveUp, "Result should be MoveUp");
        assertTrue(info.totalVotes == 50 ether, "Total votes should be 50 ether");
        vm.expectPartialRevert(IDesiredPrice.ExecutionNotReady.selector);
        dpp.execute(poolId);

        offset = major ? Poll.MAJOR_POLL_EXECUTION_READY : Poll.REGULAR_POLL_EXECUTION_READY;
        vm.warp(startTime + offset);
        int24 oldPrice = dpp.desiredPrice(poolId);
        console.log("Old price: %d", int256(oldPrice));
        dpp.execute(poolId);
        int24 newPrice = dpp.desiredPrice(poolId);
        console.log("New price: %d", int256(newPrice));
        int24 priceDiff = newPrice - oldPrice;
        if (major) {
            assertEq(priceDiff, int24(slotLower) * 500, "Desired price should be updated by slotLower * 500");
        }
        else {
            assertEq(priceDiff, int24(1) << uint8(slotLower), "Desired price should be updated by 1 << slotLower");
        }
    }

    function _skipPolls(uint256 count) internal {
        Poll.CurrentInfo memory info = dpp.pollCurrentInfo(poolId);
        if (info.stage == Poll.Stage.ExecutionReady) {
            dpp.execute(poolId);
        }
        int256 left = int256(count);
        while (left-- > 0) {
            info = dpp.pollCurrentInfo(poolId);
            uint256 offset = info.isMajor ? Poll.MAJOR_POLL_EXECUTION_READY : Poll.REGULAR_POLL_EXECUTION_READY;
            vm.warp(info.startTime + offset);
            dpp.execute(poolId);
        }
    }
}
