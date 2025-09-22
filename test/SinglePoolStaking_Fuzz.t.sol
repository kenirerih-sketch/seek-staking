// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {SinglePoolStakingBase} from "./BaseSinglePoolStaking.t.sol";
import {SinglePoolStaking} from "../src/SinglePoolStaking.sol";

/// @title SinglePoolStaking — Fuzz Tests
/// @notice Property-based tests to exercise proportional accrual, reserves consumption, and rate snapshots.
/// @dev Updated to comply with timelocked, capped reward-rate changes (propose/execute pattern)
///      and the new constructor signature (withdrawDelay, minStakeAmount).
contract SinglePoolStaking_Fuzz is SinglePoolStakingBase {
    /// @notice Proportional accrual: for two stakers with arbitrary (bounded) sizes, accrual splits by stake share.
    /// @dev We keep `dt` small enough so `newly = dt*rate` doesn’t hit the reserve cap.
    function testFuzz_ProportionalAccrual(uint96 aAmt, uint96 bAmt, uint64 dt) public {
        // Bound inputs (Base pre-funds each actor with 10_000 ether)
        aAmt = uint96(bound(aAmt, 1 ether, 9_000 ether));
        bAmt = uint96(bound(bAmt, 1 ether, 9_000 ether));
        dt = uint64(bound(dt, 1, 1_000)); // at 1 token/s => <= 1_000 ether accrued

        // Stake
        _stake(alice, aAmt);
        _stake(bob, bAmt);

        // Ensure reserves are ample (Base already added 100_000 ether; this is extra safety)
        staking.fundRewards(1 ether); // small top-up

        // Warp and check
        vm.warp(block.timestamp + dt);

        // Contract math (no cap expected here):
        // newly = dt * rate; rpt = (newly * 1e18) / (aAmt + bAmt)
        uint256 total = uint256(aAmt) + uint256(bAmt);
        uint256 newly = uint256(dt) * 1e18; // 1 token/sec
        uint256 rpt = (newly * 1e18) / total;

        uint256 expectedA = (uint256(aAmt) * rpt) / 1e18;
        uint256 expectedB = (uint256(bAmt) * rpt) / 1e18;

        assertEq(staking.earned(alice), expectedA, "alice proportional accrual mismatch");
        assertEq(staking.earned(bob), expectedB, "bob proportional accrual mismatch");
        // sanity: sum of floors <= newly (flooring loss)
        assertLe(staking.earned(alice) + staking.earned(bob), newly, "sum of floors should not exceed total");
    }

    /// @notice Reserves are consumed on state update by exactly min(elapsed * rate, reservesBefore) when totalStaked > 0.
    /// @dev If totalStaked == 0, reserves must remain unchanged (even when global updates happen).
    function testFuzz_ReservesConsumption(uint96 stakeAmt, uint64 dt) public {
        // Case 1: with staker -> reserves drop by min(elapsed*rate, reservesBefore)
        {
            stakeAmt = uint96(bound(stakeAmt, 1 ether, 9_000 ether));
            dt = uint64(bound(dt, 1, 1_000));

            _stake(alice, stakeAmt);

            uint256 beforeRes = staking.rewardReserves();
            vm.warp(block.timestamp + dt);

            // Trigger _updateGlobal via a claim (consumes reserves deterministically)
            _getReward(alice);

            uint256 afterRes = staking.rewardReserves();
            uint256 expectedDrop = (uint256(dt) * 1e18);
            if (expectedDrop > beforeRes) expectedDrop = beforeRes;

            assertEq(beforeRes - afterRes, expectedDrop, "reserve consumption mismatch (with staker)");
        }

        // Case 2: no stakers -> reserves do not change on a global update (via propose/execute)
        {
            // Fresh instance with reserves and no stakes (delay = 1, max = 1e18, withdrawDelay=1, minStake=0)
            SinglePoolStaking s = new SinglePoolStaking(
                stakeToken,
                stakeToken,
                1e18,
                address(this),
                1e18,
                0, // MIN_REWARD_RATE
                1, // RATE_CHANGE_DELAY
                1, // withdrawDelay
                0 // minStakeAmount
            );
            stakeToken.approve(address(s), type(uint256).max);
            s.fundRewards(10_000 ether);

            uint256 beforeRes2 = s.rewardReserves();

            // Propose same rate and execute after delay to force a global update
            s.proposeRewardRate(1e18);
            vm.warp(block.timestamp + s.RATE_CHANGE_DELAY());
            s.executeRewardRateChange();

            assertEq(s.rewardReserves(), beforeRes2, "reserves changed with no stakers");
        }
    }

    /// @notice Rate snapshot: single staker should earn exactly t1*rate1 + t2*rate2 (no rounding loss in single-staker).
    /// @dev We insert the required delay between proposal and execution *inside* t1 by warping `t1-1`, then +1 to execute.
    function testFuzz_SetRewardRate_Snapshot(uint64 t1, uint64 t2, uint96 stakeAmt, uint128 r2) public {
        // Bounds
        stakeAmt = uint96(bound(stakeAmt, 1 ether, 9_000 ether));
        t1 = uint64(bound(t1, 1, 1_000)); // >= 1 so we can spend 1s on the delay
        t2 = uint64(bound(t2, 0, 1_000)); // allow zero-length second window

        // Cap r2 by configured MAX_REWARD_RATE() to avoid revert
        uint256 maxRate = staking.MAX_REWARD_RATE();
        r2 = uint128(bound(r2, 0, uint128(maxRate)));

        _stake(alice, stakeAmt);

        // Window 1 at default rate = 1e18. We warp t1-1, then spend +delay seconds to execute,
        // so total old-rate time is exactly t1 and the expected math remains unchanged.
        vm.warp(block.timestamp + (t1 - 1));

        // Propose new rate (owner-only) and wait for delay
        staking.proposeRewardRate(uint256(r2));
        vm.warp(block.timestamp + staking.RATE_CHANGE_DELAY()); // execute-after delay

        // Execute switch to r2
        staking.executeRewardRateChange();

        // Window 2 at r2
        vm.warp(block.timestamp + t2);

        // Claim and measure
        uint256 before = stakeToken.balanceOf(alice);
        _getReward(alice);
        uint256 paid = stakeToken.balanceOf(alice) - before;

        // Expected computed with the SAME rounding as the contract in THIS flow
        uint256 total = uint256(stakeAmt);

        // Window 1 (rate1 = 1e18) for exactly t1 seconds
        uint256 newly1 = uint256(t1) * 1e18;
        uint256 deltaRpt1 = (newly1 * 1e18) / total; // floor

        // Window 2 (rate2 = r2) for t2 seconds
        uint256 newly2 = uint256(t2) * uint256(r2);
        uint256 deltaRpt2 = (newly2 * 1e18) / total; // floor

        // Single user updated once → single floor on the SUM of deltas
        uint256 expected = (total * (deltaRpt1 + deltaRpt2)) / 1e18;

        assertEq(paid, expected, "snapshot + new-rate accrual mismatch (single staker)");

        // Sanity: never overpay the ideal (no rounding)
        uint256 ideal = newly1 + newly2;
        assertLe(paid, ideal, "paid exceeds idealized accrual");
    }

    /// @notice Delayed withdrawal fuzz: requesting reduces stake immediately; completion doesn't change rewards in-block.
    /// @dev We fuzz stake size, request size, pre-request accrual window, and ensure same-block completion is neutral.
    function testFuzz_RequestWithdrawalAndComplete(uint96 stakeAmt, uint96 reqAmt, uint64 tBefore) public {
        // Bounds
        stakeAmt = uint96(bound(stakeAmt, 1 ether, 9_000 ether));
        reqAmt = uint96(bound(reqAmt, 1, stakeAmt));
        tBefore = uint64(bound(tBefore, 0, 300)); // accrue a bit before request

        // Stake and accrue some time first
        _stake(alice, stakeAmt);
        if (tBefore > 0) vm.warp(block.timestamp + tBefore);

        // Request withdrawal (removes from staking immediately)
        vm.prank(alice);
        staking.requestWithdrawal(reqAmt);

        assertEq(staking.balanceOf(alice), uint256(stakeAmt) - uint256(reqAmt), "stake not reduced on request");

        // Warp until unlock
        vm.warp(block.timestamp + staking.withdrawDelay());

        uint256 earnedBeforeComplete = staking.earned(alice);
        uint256 balBefore = stakeToken.balanceOf(alice);

        // Complete withdrawal — should only transfer principal; rewards unchanged in the same block
        vm.prank(alice);
        staking.completeWithdrawal();

        uint256 balAfter = stakeToken.balanceOf(alice);
        assertEq(balAfter - balBefore, uint256(reqAmt), "principal not transferred on completion");
        assertEq(staking.earned(alice), earnedBeforeComplete, "completion changed rewards unexpectedly");
    }
}
