// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SinglePoolStakingBase} from "./BaseSinglePoolStaking.t.sol";
import {SinglePoolStaking} from "../src/SinglePoolStaking.sol";

/// @title SinglePoolStaking Scenario Tests
/// @notice Realistic timelines & complex flows (kept separate to avoid stack pressure).
contract SinglePoolStaking_Scenarios is SinglePoolStakingBase {
    /// @notice Timeline accrual with multiple join/leave events; verifies per-user rewards across segments.
    /// @dev Uses BaseSinglePoolStaking actors (`alice`, `bob`, `chad`) and helpers (`_stake`).
    ///      Assumptions:
    ///        - rewardRate = 1e18 (1 token/sec)
    ///        - stakeToken == rewardToken, reserves are ample (prefunded in Base `setUp`)
    ///      Segment breakdown (seconds):
    ///        S1 [0,10):   Alice 100                     -> 10 tokens to Alice
    ///        S2 [10,25):  Alice 100, Bob 100 (200 tot)  -> 15 tokens, split 7.5 each (RPT += 0.075e18)
    ///        S3 [25,30):  Alice 100, Bob 100, Chad 100  -> 5 tokens, ~1.6666666666666666 each (floored)
    ///        S4 [30,37):  Bob 100, Chad 100 (200 tot)   -> 7 tokens, 3.5 each
    ///        S5 [37,42):  Bob 100                       -> 5 tokens to Bob
    ///      Exact integer (wei) expectations due to floor in S3:
    ///        deltaRPT_S3  = floor((5e18 * 1e18) / (300e18)) = floor(1e18 / 60) = 16_666_666_666_666_666
    ///        per-100 in S3 = (100e18 * deltaRPT_S3) / 1e18 = 1_666_666_666_666_666_600 wei
    ///      Totals (wei):
    ///        Alice @ t=30: 10e18 + 7.5e18 + 1_666_666_666_666_666_600 = 19_166_666_666_666_666_600
    ///        Bob   @ t=30: 7.5e18 + 1_666_666_666_666_666_600        =  9_166_666_666_666_666_600
    ///        Chad  @ t=30: 1_666_666_666_666_666_600
    ///        Bob   @ t=37: + 3.5e18                                   = 12_666_666_666_666_666_600
    ///        Chad  @ t=37: + 3.5e18                                   =  5_166_666_666_666_666_600
    ///        Bob   @ t=42: + 5e18                                     = 17_666_666_666_666_666_600
    function testScenario_MultiUserTimeline_JoinLeaveAccrual() public {
        // Record start time to anchor segment boundaries
        uint256 t0 = block.timestamp;

        // ---- t = 0: Alice stakes 100 ----
        vm.warp(t0 + 0);
        _stake(alice, 100 ether);

        // Balances & immediate earned checks (no time elapsed yet)
        assertEq(staking.totalStaked(), 100 ether, "t=0 totalStaked");
        assertEq(staking.balanceOf(alice), 100 ether, "t=0 alice stake");
        assertEq(staking.balanceOf(bob), 0, "t=0 bob stake");
        assertEq(staking.balanceOf(chad), 0, "t=0 chad stake");
        assertEq(staking.earned(alice), 0, "t=0 alice earned");
        assertEq(staking.earned(bob), 0, "t=0 bob earned");
        assertEq(staking.earned(chad), 0, "t=0 chad earned");

        // ---- t = 10: Bob stakes 100 ----
        vm.warp(t0 + 10);
        _stake(bob, 100 ether); // triggers global update to t=10

        // After Bob joins: S1 accrued to Alice only (10 tokens)
        assertEq(staking.totalStaked(), 200 ether, "t=10 totalStaked");
        assertEq(staking.balanceOf(alice), 100 ether, "t=10 alice stake");
        assertEq(staking.balanceOf(bob), 100 ether, "t=10 bob stake");
        assertEq(staking.earned(alice), 10 ether, "t=10 alice earned");
        assertEq(staking.earned(bob), 0, "t=10 bob earned");
        assertEq(staking.earned(chad), 0, "t=10 chad earned");

        // ---- t = 25: Chad stakes 100 ----
        vm.warp(t0 + 25);
        _stake(chad, 100 ether); // triggers global update to t=25

        // After Chad joins: S2 accrued (15 tokens -> 7.5 each to Alice & Bob)
        assertEq(staking.totalStaked(), 300 ether, "t=25 totalStaked");
        assertEq(staking.balanceOf(chad), 100 ether, "t=25 chad stake");

        assertEq(staking.earned(alice), 17_500_000_000_000_000_000, "t=25 alice earned (17.5)");
        assertEq(staking.earned(bob), 7_500_000_000_000_000_000, "t=25 bob earned (7.5)");
        assertEq(staking.earned(chad), 0, "t=25 chad earned");

        // ---- t = 30: Alice requests withdrawal of 100 (removes from staking immediately) ----
        vm.warp(t0 + 30);
        vm.prank(alice);
        staking.requestWithdrawal(100 ether); // triggers global update to t=30 (S3 accrual)

        // S3 accrual per 100 tokens (see @dev): 1_666_666_666_666_666_600 wei
        uint256 s3Per100 = 1_666_666_666_666_666_600;

        // Check balances & earned after Alice leaves (pending withdrawal)
        assertEq(staking.totalStaked(), 200 ether, "t=30 totalStaked after Alice leave");
        assertEq(staking.balanceOf(alice), 0, "t=30 alice stake");
        assertEq(staking.balanceOf(bob), 100 ether, "t=30 bob stake");
        assertEq(staking.balanceOf(chad), 100 ether, "t=30 chad stake");

        assertEq(staking.earned(alice), 19_166_666_666_666_666_600, "t=30 alice earned (10 + 7.5 + ~1.6666666)");
        assertEq(staking.earned(bob), 9_166_666_666_666_666_600, "t=30 bob earned (7.5 + ~1.6666666)");
        assertEq(staking.earned(chad), s3Per100, "t=30 chad earned (~1.6666666)");

        // ---- t = 37: Chad requests withdrawal of 100 (removed immediately) ----
        vm.warp(t0 + 37);
        vm.prank(chad);
        staking.requestWithdrawal(100 ether); // triggers global update to t=37 (S4 accrual)

        // After S4 (7s at 200 total): +3.5 ether to Bob and Chad
        assertEq(staking.totalStaked(), 100 ether, "t=37 totalStaked after Chad leave");
        assertEq(staking.balanceOf(chad), 0, "t=37 chad stake");

        assertEq(staking.earned(bob), 12_666_666_666_666_666_600, "t=37 bob earned (+3.5)");
        assertEq(staking.earned(chad), 5_166_666_666_666_666_600, "t=37 chad earned (s3 + 3.5)");
        // Alice unchanged since t=30
        assertEq(staking.earned(alice), 19_166_666_666_666_666_600, "t=37 alice earned unchanged");

        // ---- t = 42: Check Bob's earned (only Bob staked 100 for 5 more seconds) ----
        vm.warp(t0 + 42);
        assertEq(staking.totalStaked(), 100 ether, "t=42 totalStaked");
        assertEq(staking.balanceOf(bob), 100 ether, "t=42 bob stake");

        // S5 adds +5 ether to Bob
        assertEq(staking.earned(bob), 17_666_666_666_666_666_600, "t=42 bob total earned");
    }

    /// @notice End-to-end realistic scenario covering: staggered joins/leaves, partial withdrawals, multiple stakes,
    ///         frequent vs. infrequent claiming, reserve top-ups, rate pause/resume, reserve exhaustion (cap),
    ///         same-block updates, auto-compounder flow (getRewardTo + stakeFor), and post-withdraw claim behavior.
    /// @dev Uses BaseSinglePoolStaking actors (`alice`, `bob`, `chad`, `vault`) and helpers (`_stake`, `_getReward`).
    ///      Assumptions:
    ///        - rewardRate = 1e18 (1 token/sec), stake token == reward token
    ///        - Reserves are prefunded in Base `setUp()`
    ///      Goals:
    ///        - Claims frequency should not affect total accrual for identical stake windows
    ///        - Joining/leaving affects only future accrual (snapshot on update)
    ///        - Exercise pause/resume, reserve top-ups, and reserve-cap (view + state paths)
    ///        - Prove same-block updates do not mint phantom rewards
    function testScenario_Realistic_ComplexFlows() public {
        uint256 t0 = block.timestamp;

        // =========================================================================================
        // 1) Initial stakes (multiple stakes per user / DCA style) + same-block actions
        // =========================================================================================
        {
            // t = 0: Alice stakes 60 then 40 in the SAME block (no time elapsed)
            vm.warp(t0);
            vm.startPrank(alice);
            stakeToken.approve(address(staking), type(uint256).max);
            staking.stake(60 ether);
            staking.stake(40 ether); // same block, no time has passed
            vm.stopPrank();

            // No time elapsed yet -> no earnings
            assertEq(staking.totalStaked(), 100 ether, "t=0 totalStaked");
            assertEq(staking.balanceOf(alice), 100 ether, "t=0 alice stake");
            assertEq(staking.earned(alice), 0, "t=0 alice earned == 0");

            // t = 10: Bob joins with 100
            vm.warp(t0 + 10);
            _stake(bob, 100 ether);

            // Alice should have accrued 10 tokens (solo for 10s)
            assertEq(staking.totalStaked(), 200 ether, "t=10 totalStaked");
            assertEq(staking.balanceOf(alice), 100 ether, "t=10 alice stake");
            assertEq(staking.balanceOf(bob), 100 ether, "t=10 bob stake");
            assertEq(staking.earned(alice), 10 ether, "t=10 alice earned");
            assertEq(staking.earned(bob), 0, "t=10 bob earned");
        }

        // =========================================================================================
        // 2) Claim frequency independence
        //    Alice claims often, Bob does not. Totals should match when windows are identical.
        // =========================================================================================
        {
            // Segment [10,15): both 100 -> 5 tokens total => 2.5 each
            vm.warp(t0 + 15);
            uint256 aliceBalBeforeClaim1 = stakeToken.balanceOf(alice);
            vm.prank(alice);
            staking.getReward(); // claim at t=15
            uint256 alicePaid1 = stakeToken.balanceOf(alice) - aliceBalBeforeClaim1;

            // Bob joined at t=10, so at t=15 Bob has 2.5
            assertEq(staking.earned(bob), 2.5 ether, "t=15 bob earned (no claim)");
            // Alice had 10 (S1) + 2.5 (S2 first half) paid out
            assertEq(alicePaid1, 12.5 ether, "t=15 alice first claim paid");

            // Segment [15,20): both 100 -> +5 tokens => +2.5 each
            vm.warp(t0 + 20);
            uint256 aliceBalBeforeClaim2 = stakeToken.balanceOf(alice);
            vm.prank(alice);
            staking.getReward(); // claim at t=20
            uint256 alicePaid2 = stakeToken.balanceOf(alice) - aliceBalBeforeClaim2;
            assertEq(alicePaid2, 2.5 ether, "t=20 alice second claim paid");

            // Bob still has not claimed -> should be 2.5 (from [10,15)) + 2.5 (from [15,20)) = 5
            assertEq(staking.earned(bob), 5 ether, "t=20 bob earned");
        }

        // =========================================================================================
        // 3) New joiner + same-block update checks
        //    Chad joins, Bob adds more stake in the same block, then claims in the same block
        // =========================================================================================
        {
            // t = 25: Chad joins 100; total becomes 300 and global accrual snaps to t=25
            vm.warp(t0 + 25);
            _stake(chad, 100 ether);

            // At t=25 (after the global update), Bob has 7.5 accrued: 2.5 ([10,15)) + 2.5 ([15,20)) + 2.5 ([20,25))
            assertEq(staking.earned(bob), 7.5 ether, "t=25 bob pre-existing earned");

            // Bob stakes additional 50 in the same block (no time passes between actions)
            vm.startPrank(bob);
            stakeToken.approve(address(staking), type(uint256).max);
            staking.stake(50 ether);

            // Same-block claim: should only harvest what's already accrued at t=25 (7.5 ether)
            uint256 bobBalBeforeClaimSb = stakeToken.balanceOf(bob);
            staking.getReward();
            uint256 bobPaidSameBlock = stakeToken.balanceOf(bob) - bobBalBeforeClaimSb;
            vm.stopPrank();

            // Check balances at t=25
            assertEq(staking.totalStaked(), 350 ether, "t=25 totalStaked (alice 100 + bob 150 + chad 100)");
            assertEq(staking.balanceOf(alice), 100 ether, "t=25 alice stake");
            assertEq(staking.balanceOf(bob), 150 ether, "t=25 bob stake");
            assertEq(staking.balanceOf(chad), 100 ether, "t=25 chad stake");
            assertEq(bobPaidSameBlock, 7.5 ether, "t=25 bob same-block paid equals pre-existing accrued");
        }

        // =========================================================================================
        // 4) Auto-compounder flow: Alice claims to vault, vault stakes for Alice via stakeFor(...)
        // =========================================================================================
        {
            // t = 27: accrue 2s at 350 total -> 2 tokens total spread => alice earns 2*(100/350)
            vm.warp(t0 + 27);
            uint256 aliceBeforeGetTo = stakeToken.balanceOf(vault);
            vm.prank(alice);
            staking.getRewardTo(vault);
            uint256 toVault = stakeToken.balanceOf(vault) - aliceBeforeGetTo;

            // Vault stakes those rewards back for Alice (auto-compounding into principal)
            vm.startPrank(vault);
            stakeToken.approve(address(staking), type(uint256).max);
            staking.stakeFor(toVault, alice);
            vm.stopPrank();

            // Alice principal increased by exactly the claimed amount
            assertEq(staking.balanceOf(alice), 100 ether + toVault, "t=27 alice compounded principal increased");
        }

        // =========================================================================================
        // 5) Rate pause/resume + reserves top-up mid-stream
        // =========================================================================================
        {
            // t = 30: pause emissions (set rewardRate=0) and then top-up reserves
            vm.warp(t0 + 29);

            // IMPORTANT: pause first — this snapshots/consumes any pending accrual up to t=30
            staking.proposeRewardRate(0);

            vm.warp(t0 + 30);
            staking.executeRewardRateChange();

            // Now capture reserves AFTER the snapshot, so the top-up is a clean +delta check
            uint256 reservesBeforeTopup = staking.rewardReserves();

            // Top-up reserves
            staking.fundRewards(500 ether);
            assertEq(staking.rewardReserves(), reservesBeforeTopup + 500 ether, "reserves top-up mismatch");

            // t = 35: resume at 2 tokens/sec
            vm.warp(t0 + 34);
            staking.proposeRewardRate(2e18);

            vm.warp(t0 + 35);
            staking.executeRewardRateChange();

            // Check: no accrual happened during pause window [30,35) for any user
            uint256 a = staking.earned(alice);
            uint256 b = staking.earned(bob);
            uint256 c = staking.earned(chad);
            vm.warp(t0 + 35); // no-op warp to same second
            assertEq(staking.earned(alice), a, "pause window: alice accrued");
            assertEq(staking.earned(bob), b, "pause window: bob accrued");
            assertEq(staking.earned(chad), c, "pause window: chad accrued");
        }

        // =========================================================================================
        // 6) Reserve exhaustion (cap) on a fresh instance to isolate behavior
        // =========================================================================================
        {
            // Fresh pool with tiny reserves to fully exercise cap in both view and state paths
            SinglePoolStaking capped = new SinglePoolStaking(
                stakeToken,
                stakeToken,
                5e18, // 5 tokens/sec
                address(this),
                5e18, // MAX_REWARD_RATE
                0, // MIN_REWARD_RATE
                1, // RATE_CHANGE_DELAY
                1, // withdrawDelay
                0 // minStakeAmount
            );
            stakeToken.approve(address(capped), type(uint256).max);
            capped.fundRewards(7 ether); // reserves only 7 tokens

            // Two stakers equal stake
            address u1 = makeAddr("u1");
            address u2 = makeAddr("u2");
            bool u1Success = stakeToken.transfer(u1, 100 ether);
            require(u1Success, "Failed to transfer to u1");
            bool u2Success = stakeToken.transfer(u2, 100 ether);
            require(u2Success, "Failed to transfer to u2");

            vm.startPrank(u1);
            stakeToken.approve(address(capped), type(uint256).max);
            capped.stake(100 ether);
            vm.stopPrank();

            vm.startPrank(u2);
            stakeToken.approve(address(capped), type(uint256).max);
            capped.stake(100 ether);
            vm.stopPrank();

            // Warp a long time (e.g., 10s at 5/sec = 50 tokens theoretical), but reserves cap at 7 total
            vm.warp(block.timestamp + 10);

            // View: total earned across users must equal 7; with equal stake, each ~3.5 (subject to floor)
            uint256 u1View = capped.earned(u1);
            uint256 u2View = capped.earned(u2);
            assertEq(u1View + u2View, 7 ether, "view path capped by reserves exactly");

            // State: trigger update & consumption; claim both
            uint256 beforeResCap = capped.rewardReserves();
            vm.prank(u1);
            capped.getReward();
            vm.prank(u2);
            capped.getReward();
            uint256 afterResCap = capped.rewardReserves();
            assertEq(beforeResCap - afterResCap, 7 ether, "state path consumed capped amount only");

            // Further warp won't accrue because reserves are 0 until next top-up
            vm.warp(block.timestamp + 100);
            assertEq(capped.earned(u1), 0, "no further accrual when reserves exhausted");
            assertEq(capped.earned(u2), 0, "no further accrual when reserves exhausted");
        }

        // =========================================================================================
        // 7) Post-withdraw claim: user's owed stays constant after principal fully removed (via delayed flow)
        // =========================================================================================
        {
            // Ensure Bob has some additional accrual after resume
            vm.warp(t0 + 40); // with rate=2/sec active since t=35
            uint256 bobEarnBefore = staking.earned(bob);

            // Bob requests full withdrawal at t=40 (immediately removes from staking)
            uint256 bobPrincipal = staking.balanceOf(bob);
            vm.prank(bob);
            staking.requestWithdrawal(bobPrincipal);

            assertEq(staking.balanceOf(bob), 0, "bob principal not removed on request");
            uint256 bobEarnRightAfter = staking.earned(bob);
            assertEq(bobEarnRightAfter, bobEarnBefore, "post-request, earned snapshot not preserved");

            // Wait more time; since balance=0, earned should remain unchanged
            vm.warp(t0 + 50);
            assertEq(staking.earned(bob), bobEarnBefore, "accrual after zero balance");

            // Claim owed rewards once; amount should equal the preserved earned
            uint256 bobBalBeforeFinalClaim = stakeToken.balanceOf(bob);
            vm.prank(bob);
            staking.getReward();
            uint256 bobPaidFinal = stakeToken.balanceOf(bob) - bobBalBeforeFinalClaim;
            assertEq(bobPaidFinal, bobEarnBefore, "final claim != preserved earned after request");
        }
    }

    /// @notice Cancel a pending withdrawal: no backfill for pending period, accrues only after re-stake.
    function testScenario_CancelWithdrawal_NoBackfillThenResumeAccrual() public {
        _stake(alice, 300 ether);
        vm.warp(block.timestamp + 5);

        // Request 100: remaining staked = 200
        vm.prank(alice);
        staking.requestWithdrawal(100 ether);

        uint64 d = staking.withdrawDelay();
        // Accrue during pending on remaining 200 only
        vm.warp(block.timestamp + d);

        // Snapshot earned before cancel
        uint256 earnedBeforeCancel = staking.earned(alice);

        // Cancel: 100 returns to staking; should NOT backfill rewards for the pending period
        vm.prank(alice);
        staking.cancelWithdrawal();

        assertEq(staking.balanceOf(alice), 300 ether, "principal not restored on cancel");

        // Warp more; accrues on full 300 after cancel
        vm.warp(block.timestamp + 3);
        uint256 earnedAfter = staking.earned(alice);

        // After cancel, incremental earned ≈ 3 tokens (only one staker @ 1 token/s)
        assertEq(earnedAfter - earnedBeforeCancel, 3 ether, "post-cancel accrual incorrect");
    }

    /// @notice withdrawDelay = 0 allows same-block completion; earned must not change on completion.
    function testScenario_WithdrawDelayZero_ImmediateComplete() public {
        // Owner sets delay to 0
        staking.setWithdrawDelay(0);

        _stake(alice, 200 ether);
        vm.warp(block.timestamp + 4);

        vm.prank(alice);
        staking.requestWithdrawal(50 ether);

        uint256 before = staking.earned(alice);

        // Same block completion is allowed with delay=0
        vm.prank(alice);
        staking.completeWithdrawal();

        assertEq(staking.balanceOf(alice), 150 ether, "principal after complete");
        assertEq(staking.earned(alice), before, "earned changed on same-block completion");
    }

    /// @notice Emergency exit safety: disabled by default, enabled by owner, returns staked+pending and forfeits rewards.
    function testScenario_EmergencyExit_ToggleAndForfeit_MultiUser() public {
        _stake(alice, 120 ether);
        _stake(bob, 80 ether);
        vm.warp(block.timestamp + 5);

        // Move portion to pending for alice
        vm.prank(alice);
        staking.requestWithdrawal(20 ether);

        // Disabled path reverts
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.EmergencyExitDisabled.selector);
        staking.emergencyWithdraw();

        // Enable and exit
        staking.setEmergencyExitEnabled(true);

        uint256 aBefore = stakeToken.balanceOf(alice);
        vm.prank(alice);
        staking.emergencyWithdraw(); // refunds 100 (staked) + 20 (pending) = 120

        assertEq(stakeToken.balanceOf(alice) - aBefore, 120 ether, "alice refund mismatch");
        assertEq(staking.balanceOf(alice), 0, "alice stake not zeroed");
        assertEq(staking.earned(alice), 0, "alice rewards not forfeited");

        // Bob still can accrue/claim normally
        vm.warp(block.timestamp + 4);
        uint256 bBefore = stakeToken.balanceOf(bob);
        vm.prank(bob);
        staking.getReward();
        assertGt(stakeToken.balanceOf(bob) - bBefore, 0, "bob should receive rewards");
    }

    /// @notice Conservation check: sum of users' paid rewards == reserves consumed (in this window).
    function testScenario_Conservation_PaidEqualsReservesConsumed() public {
        // Fresh pool to isolate window
        SinglePoolStaking s = new SinglePoolStaking(
            stakeToken,
            stakeToken,
            1e18, // 1 token/sec
            address(this),
            5e18, // MAX_REWARD_RATE
            0, // MIN_REWARD_RATE
            1, // RATE_CHANGE_DELAY
            1, // withdrawDelay
            0 // minStakeAmount
        );
        stakeToken.approve(address(s), type(uint256).max);
        s.fundRewards(1_000 ether);

        address u1 = makeAddr("consU1");
        address u2 = makeAddr("consU2");
        stakeToken.transfer(u1, 100 ether);
        stakeToken.transfer(u2, 100 ether);

        vm.startPrank(u1);
        stakeToken.approve(address(s), type(uint256).max);
        s.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(u2);
        stakeToken.approve(address(s), type(uint256).max);
        s.stake(100 ether);
        vm.stopPrank();

        // Accrue 10s; then both claim in the same block
        vm.warp(block.timestamp + 10);
        uint256 resBefore = s.rewardReserves();

        uint256 b1 = stakeToken.balanceOf(u1);
        vm.prank(u1);
        s.getReward();
        uint256 paid1 = stakeToken.balanceOf(u1) - b1;

        uint256 b2 = stakeToken.balanceOf(u2);
        vm.prank(u2);
        s.getReward();
        uint256 paid2 = stakeToken.balanceOf(u2) - b2;

        uint256 resAfter = s.rewardReserves();
        assertEq((resBefore - resAfter), paid1 + paid2, "consumption != sum(paid)");
    }

    /// @notice Changing rate while a pending withdrawal exists does not affect unlock time and accrual behaves correctly.
    function testScenario_RateChangeDuringPendingWithdrawal_NoUnlockDrift() public {
        _stake(alice, 300 ether);

        vm.warp(block.timestamp + 5);
        // Move 100 to pending, keep 200 staked
        vm.prank(alice);
        staking.requestWithdrawal(100 ether);

        (uint256 amt, uint64 unlockAtBefore) = staking.pendingWithdrawals(alice);
        assertEq(amt, 100 ether, "pending amount mismatch");

        // Change rate mid-pending: propose 2x, execute after delay
        uint64 rdelay = staking.RATE_CHANGE_DELAY();
        staking.proposeRewardRate(2e18);
        vm.warp(block.timestamp + rdelay);
        staking.executeRewardRateChange();
        assertEq(staking.rewardRate(), 2e18, "rate not updated");

        // Unlock timestamp must not change
        (, uint64 unlockAtAfter) = staking.pendingWithdrawals(alice);
        assertEq(unlockAtAfter, unlockAtBefore, "unlock time drifted");

        // Accrue some time at new rate on remaining 200 stake
        vm.warp(block.timestamp + 3);
        uint256 beforeEarned = staking.earned(alice);
        assertGt(beforeEarned, 0, "no accrual after rate change with remaining stake");
    }

    /// @notice Extremely long warp is safe: accrual capped by reserves, no overflow.
    function testScenario_LargeWarp_ReserveCap_NoOverflow() public {
        // Fresh pool with controlled reserves
        SinglePoolStaking s = new SinglePoolStaking(
            stakeToken,
            stakeToken,
            1e18, // 1 token/sec
            address(this),
            5e18, // MAX_REWARD_RATE
            0, // MIN_REWARD_RATE
            1, // RATE_CHANGE_DELAY
            1, // withdrawDelay (arbitrary for this test)
            0 // minStakeAmount
        );

        // Fund only 3 ether in reserves
        stakeToken.approve(address(s), type(uint256).max);
        s.fundRewards(3 ether);

        // Alice stakes 1 ether into the fresh pool
        vm.startPrank(alice);
        stakeToken.approve(address(s), type(uint256).max);
        s.stake(1 ether);
        vm.stopPrank();

        // Huge warp — theoretical newly = 10,000,000 tokens, but reserves cap at 3 ether
        vm.warp(block.timestamp + 10_000_000);

        // View path is capped by reserves
        assertEq(s.earned(alice), 3 ether, "cap not respected after huge warp");

        // Claim consumes exactly 3 ether from reserves
        uint256 resBefore = s.rewardReserves();
        vm.prank(alice);
        s.getReward();
        uint256 resAfter = s.rewardReserves();
        assertEq(resBefore - resAfter, 3 ether, "reserves not consumed correctly");
    }
}
