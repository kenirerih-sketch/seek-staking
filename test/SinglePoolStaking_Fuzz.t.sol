// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SinglePoolStakingBase} from "./BaseSinglePoolStaking.t.sol";
import {SinglePoolStaking} from "../src/SinglePoolStaking.sol";

/// @title SinglePoolStaking — Fuzz Tests
/// @notice Property-based tests to exercise proportional accrual, reserves consumption, and rate snapshots.
/// @dev Bound inputs to stay within pre-funded reserves unless the test targets caps explicitly.
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
        staking.fundRewards(1 ether); // tiny top-up; optional

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
    /// @dev If totalStaked == 0, reserves must remain unchanged.
    function testFuzz_ReservesConsumption(uint96 stakeAmt, uint64 dt) public {
        // Case 1: with staker -> reserves drop by min(elapsed*rate, reservesBefore)
        {
            stakeAmt = uint96(bound(stakeAmt, 1 ether, 9_000 ether));
            dt = uint64(bound(dt, 1, 1_000));

            _stake(alice, stakeAmt);

            uint256 beforeRes = staking.rewardReserves();
            vm.warp(block.timestamp + dt);

            // Trigger _updateGlobal via a harmless mutative call
            staking.setRewardRate(staking.rewardRate());

            uint256 afterRes = staking.rewardReserves();
            uint256 expectedDrop = (uint256(dt) * 1e18);
            if (expectedDrop > beforeRes) expectedDrop = beforeRes;

            assertEq(beforeRes - afterRes, expectedDrop, "reserve consumption mismatch (with staker)");
        }

        // Case 2: no stakers -> reserves do not change on update
        {
            // Fresh instance with reserves and no stakes
            SinglePoolStaking s = new SinglePoolStaking(stakeToken, stakeToken, 1e18, owner);
            stakeToken.approve(address(s), type(uint256).max);
            s.fundRewards(10_000 ether);

            uint256 beforeRes2 = s.rewardReserves();
            vm.warp(block.timestamp + 777);
            s.setRewardRate(1e18); // _updateGlobal() runs with totalStaked == 0

            assertEq(s.rewardReserves(), beforeRes2, "reserves changed with no stakers");
        }
    }

    /// @notice Rate snapshot: single staker should earn exactly t1*rate1 + t2*rate2 (no rounding loss in single-staker).
    /// @dev We bound t1,t2,r2 so total accrued < prefunded reserves.
    function testFuzz_SetRewardRate_Snapshot(uint64 t1, uint64 t2, uint96 stakeAmt, uint128 r2) public {
        // Bounds
        stakeAmt = uint96(bound(stakeAmt, 1 ether, 9_000 ether));
        t1 = uint64(bound(t1, 1, 1_000));
        t2 = uint64(bound(t2, 0, 1_000)); // allow zero-length second window
        r2 = uint128(bound(r2, 0, 5e18)); // up to 5 tokens/sec

        _stake(alice, stakeAmt);

        // Window 1 at default rate = 1e18
        vm.warp(block.timestamp + t1);

        // Snapshot and switch to r2
        staking.setRewardRate(uint256(r2));

        // Window 2 at r2
        vm.warp(block.timestamp + t2);

        // Claim and measure
        uint256 before = stakeToken.balanceOf(alice);
        _getReward(alice);
        uint256 paid = stakeToken.balanceOf(alice) - before;

        // ---- Expected computed with the SAME rounding as the contract in THIS flow ----
        uint256 total = uint256(stakeAmt);

        // Window 1 (rate1 = 1e18)
        uint256 newly1 = uint256(t1) * 1e18;
        uint256 deltaRPT1 = (newly1 * 1e18) / total; // floor

        // Window 2 (rate2 = r2)
        uint256 newly2 = uint256(t2) * uint256(r2);
        uint256 deltaRPT2 = (newly2 * 1e18) / total; // floor

        // IMPORTANT: user is updated ONCE at the end → single floor on the SUM
        uint256 expected = (total * (deltaRPT1 + deltaRPT2)) / 1e18;

        assertEq(paid, expected, "snapshot + new-rate accrual mismatch (single staker)");

        // Optional sanity: never overpay the ideal (no rounding)
        uint256 ideal = newly1 + newly2;
        assertLe(paid, ideal, "paid exceeds idealized accrual");
    }
}
