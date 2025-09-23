// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SinglePoolStakingBase} from "./BaseSinglePoolStaking.t.sol";
import {SinglePoolStaking} from "../src/SinglePoolStaking.sol";
import {ERC20Token} from "./mocks/ERC20Token.sol";
import {WeirdRewardToken} from "./mocks/WeirdRewardToken.sol";

/// @title SinglePoolStaking — Unit Test Suite
/// @notice Focused, deterministic unit tests for the SinglePoolStaking contract.
/// @dev Assumptions:
///      - Stake token == reward token with 18 decimals.
///      - Default rewardRate = 1e18 (1 token/second).
///      - Reserves are prefunded in Base `setUp()` using `fundRewards` (balance-delta semantics).
///      Test philosophy:
///      - Prefer mutative-path assertions (triggering `_updateGlobal()`) when verifying accrual snapshots.
///      - When comparing expected values, mirror the contract’s integer math & rounding (floor).
///      - Cover owner-gates, revert branches, reserve capping (view + state), and event emissions.
contract SinglePoolStaking_Unit is SinglePoolStakingBase {
    /// @notice Verify constructor state (immutables & defaults).
    /// @dev Checks stake/reward token addresses, initial rewardRate, totalStaked=0, and that `lastUpdateTime` is initialized.
    function testInitialState() public view {
        assertEq(address(staking.STAKE_TOKEN()), address(stakeToken), "stake token mismatch");
        assertEq(address(staking.REWARD_TOKEN()), address(stakeToken), "reward token mismatch");
        assertEq(staking.rewardRate(), 1e18, "initial rewardRate mismatch");
        assertEq(staking.totalStaked(), 0, "initial totalStaked");
        assertLe(staking.lastUpdateTime(), uint64(block.timestamp), "lastUpdateTime not initialized");
    }

    /// @notice `fundRewards` increases reserves and the contract token balance; emits `RewardsFunded`.
    /// @dev Uses balance-delta semantics to derive the exact received amount for resilience to non-standard ERC20s.
    function testFundRewards_IncreasesAndEmits() public {
        uint256 beforeRes = staking.rewardReserves();
        uint256 beforeBal = stakeToken.balanceOf(address(staking));
        uint256 amt = 12_345 ether;

        vm.expectEmit(true, false, false, true);
        emit RewardsFunded(address(this), amt, beforeRes + amt);
        staking.fundRewards(amt);

        assertEq(staking.rewardReserves(), beforeRes + amt, "reserves not increased correctly");
        assertEq(stakeToken.balanceOf(address(staking)), beforeBal + amt, "balance not increased correctly");
    }

    /// @notice `fundRewards` reverts when amount is zero.
    function testFundRewards_RevertOnZero() public {
        vm.expectRevert(SinglePoolStaking.AmountZero.selector);
        staking.fundRewards(0);
    }

    /// @notice Only the owner can call `fundRewards`.
    function testFundRewards_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.fundRewards(1 ether);
    }

    /// @notice Funding uses balance-delta; unrelated stake balance changes should not affect reserves.
    function testFundRewards_UsesBalanceDelta() public {
        _stake(alice, 1_000 ether);

        uint256 beforeRes = staking.rewardReserves();
        uint256 beforeBal = stakeToken.balanceOf(address(staking));

        staking.fundRewards(5_000 ether);

        assertEq(staking.rewardReserves() - beforeRes, 5_000 ether, "reserves delta mismatch");
        assertEq(stakeToken.balanceOf(address(staking)) - beforeBal, 5_000 ether, "balance delta mismatch");
    }

    /// @notice Defensive branch: `fundRewards` reverts when no tokens are actually received.
    function testFundRewards_RevertWhenReceivedZero() public {
        WeirdRewardToken weird = new WeirdRewardToken("WRD", "WRD", 1_000_000 ether);
        // reward token is weird; withdraw delay and min stake are trivial for tests
        SinglePoolStaking s =
            new SinglePoolStaking(stakeToken, IERC20(address(weird)), 1e18, address(this), 1e18, 0, 1, 1, 0);

        weird.approve(address(s), type(uint256).max);
        weird.setNoMove(true);

        vm.expectRevert(SinglePoolStaking.AmountZero.selector);
        s.fundRewards(123 ether);
    }

    /// @notice Snapshot across rate change using propose/execute; assert by claiming (mutative), not via pure view.
    /// @dev Window1: [0,10) @1e18 → 10 tokens; Window2: [10,20) @2e18 → 20 tokens. Total paid on claim = 30 tokens.
    function testProposeRewardRate_Snapshot_ClaimBased() public {
        _stake(alice, 100 ether);

        // t in [0,10): old rate 1e18 => ~10 tokens
        vm.warp(block.timestamp + 9);

        // Propose new rate (owner-only)
        uint64 executeAfter = uint64(block.timestamp + 1); // delay = 1 (from Base)
        vm.expectEmit(false, false, false, true);
        emit RewardRateProposed(2e18, executeAfter);
        staking.proposeRewardRate(2e18);

        // Wait for delay then execute
        vm.warp(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateUpdated(1e18, 2e18);
        staking.executeRewardRateChange();

        // t in next 10s @2e18
        vm.warp(block.timestamp + 10);

        uint256 before = stakeToken.balanceOf(alice);
        _getReward(alice); // triggers update and pays
        uint256 paid = stakeToken.balanceOf(alice) - before;

        assertEq(paid, 30 ether, "snapshot (10) + new rate window (20) != 30");
        assertEq(staking.earned(alice), 0, "accrued not zeroed after claim");
    }

    /// @notice `stake` reverts on zero amount.
    function testStake_RevertOnZero() public {
        vm.expectRevert(SinglePoolStaking.AmountZero.selector);
        staking.stake(0);
    }

    /// @notice Stake → accrue → request withdrawal → complete after delay; verifies accrual math & events.
    /// @dev Earned is snapshotted at request time; completing withdrawal does not affect rewards.
    function testStake_RequestAndCompleteWithdrawal() public {
        _stake(alice, 300 ether);
        vm.warp(block.timestamp + 5);

        uint64 delay = staking.withdrawDelay();

        // Expect request
        vm.expectEmit(true, false, false, true);
        emit WithdrawalRequested(alice, 100 ether, uint64(block.timestamp) + delay);
        vm.prank(alice);
        staking.requestWithdrawal(100 ether);

        // After request: 200 staked
        assertEq(staking.balanceOf(alice), 200 ether, "post-request stake mismatch");
        assertEq(staking.totalStaked(), 200 ether, "post-request totalStaked mismatch");

        // Earned for the first 5s with totalStaked = 300
        uint256 elapsed1 = 5;
        uint256 newly1 = elapsed1 * 1 ether; // rate = 1e18
        uint256 totalBefore = 300 ether;
        uint256 deltaRpt1 = (newly1 * 1e18) / totalBefore; // floor
        uint256 expectedEarned1 = (300 ether * deltaRpt1) / 1e18;

        // Additional accrual during the delay on remaining 200 with totalStaked = 200
        uint256 totalAfter = 200 ether;
        uint256 remaining = 200 ether;
        uint256 newly2 = uint256(delay) * 1 ether;
        uint256 deltaRpt2 = (newly2 * 1e18) / totalAfter; // floor
        uint256 expectedEarnedAfter = expectedEarned1 + (remaining * deltaRpt2) / 1e18;

        // Warp delay
        vm.warp(block.timestamp + delay);

        // (Optional) Assert completion does not change earned within the same block
        uint256 beforeComplete = staking.earned(alice);

        vm.expectEmit(true, false, false, true);
        emit WithdrawalCompleted(alice, 100 ether);
        vm.prank(alice);
        staking.completeWithdrawal();

        assertEq(staking.balanceOf(alice), 200 ether, "post-complete stake mismatch");
        assertEq(staking.earned(alice), expectedEarnedAfter, "earned after completion mismatch");
        assertEq(staking.earned(alice), beforeComplete, "completion should not change earned");
    }

    /// @notice `requestWithdrawal` reverts on zero amount and on insufficient balance.
    function testRequestWithdrawal_RevertOnZero() public {
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.AmountZero.selector);
        staking.requestWithdrawal(0);
    }

    function testRequestWithdrawal_RevertOnInsufficient() public {
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.InsufficientBalance.selector);
        staking.requestWithdrawal(1);
    }

    /// @notice `completeWithdrawal` reverts when called before unlock or when no pending exists.
    function testCompleteWithdrawal_RevertBeforeUnlockAndNoPending() public {
        _stake(alice, 10 ether);
        vm.prank(alice);
        staking.requestWithdrawal(5 ether);

        // Before unlock
        vm.prank(alice);
        vm.expectRevert(); // WithdrawalNotUnlocked
        staking.completeWithdrawal();

        // Let it unlock and complete once
        vm.warp(block.timestamp + staking.withdrawDelay());
        vm.prank(alice);
        staking.completeWithdrawal();

        // No pending now
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.NoPendingWithdrawal.selector);
        staking.completeWithdrawal();
    }

    /// @notice `cancelWithdrawal` returns pending to staking; rewards do not backfill for pending period.
    function testCancelWithdrawal_ReStakeAndAccrualBehavior() public {
        _stake(alice, 100 ether);
        vm.warp(block.timestamp + 3);

        vm.prank(alice);
        staking.requestWithdrawal(60 ether); // 40 remains staked

        // accrue more time; pending does NOT earn
        vm.warp(block.timestamp + 5);
        uint256 earnedWith40 = staking.earned(alice);

        // cancel returns 60 to stake; accrual resumes on full 100 after this point
        vm.prank(alice);
        staking.cancelWithdrawal();

        assertEq(staking.balanceOf(alice), 100 ether, "principal not restored on cancel");

        // accrue more & compare delta (post-cancel accrues on 100)
        vm.warp(block.timestamp + 10);
        uint256 earnedAfter = staking.earned(alice);
        assertGt(earnedAfter - earnedWith40, 10 ether - 1, "post-cancel accrual too small"); // rough sanity
    }

    /// @notice cancelWithdrawal should revert when user has no pending withdrawal.
    function testCancelWithdrawal_Revert_NoPending() public {
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.NoPendingWithdrawal.selector);
        staking.cancelWithdrawal();
    }

    /// @notice `getRewardTo` sends rewards to a custom recipient; user’s accrued is zeroed.
    function testGetRewardTo_SendsToRecipient() public {
        _stake(alice, 100 ether);
        vm.warp(block.timestamp + 7);

        uint256 before = stakeToken.balanceOf(vault);
        vm.prank(alice);
        staking.getRewardTo(vault);
        uint256 afterBal = stakeToken.balanceOf(vault);

        assertEq(afterBal - before, 7 ether, "recipient transfer mismatch");
        assertEq(staking.earned(alice), 0, "user rewards not zeroed");
    }

    /// @notice getRewardTo: explicit coverage of both branches: zero-owed revert and success.
    /// @dev Some solc/coverage combos mark one branch as uncovered unless both are exercised in isolation here.
    function testGetRewardTo_Branches_RevertAndSuccess() public {
        // Zero-owed -> revert
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.InsufficientBalance.selector);
        staking.getRewardTo(bob);

        // Earn something then succeed path
        _stake(alice, 42 ether);
        vm.warp(block.timestamp + 3);
        uint256 owed = staking.earned(alice);

        vm.expectEmit(true, true, false, true);
        emit RewardPaid(alice, bob, owed);
        vm.prank(alice);
        staking.getRewardTo(bob);

        assertEq(staking.earned(alice), 0, "owed not zeroed after getRewardTo");
    }

    /// @notice `emergencyWithdraw` forfeits rewards and returns principal immediately (when enabled).
    function testEmergencyWithdraw_ForfeitsRewards() public {
        // enable emergency exit first
        staking.setEmergencyExitEnabled(true);

        _stake(alice, 200 ether);
        vm.warp(block.timestamp + 9);

        uint256 before = stakeToken.balanceOf(alice);
        vm.expectEmit(true, true, false, true);
        emit EmergencyWithdraw(alice, alice, 200 ether);
        vm.prank(alice);
        staking.emergencyWithdraw();

        assertEq(stakeToken.balanceOf(alice) - before, 200 ether, "principal not refunded");
        assertEq(staking.balanceOf(alice), 0, "stake not reset");
        assertEq(staking.earned(alice), 0, "rewards not forfeited");
    }

    /// @notice Cannot rescue the stake/reward token; can rescue unrelated tokens.
    function testRescueTokens_InvalidAndValid() public {
        vm.expectRevert(SinglePoolStaking.InvalidToken.selector);
        staking.rescueTokens(stakeToken, address(this), 1 ether);

        ERC20Token other = new ERC20Token("OTHER", "OTR", 10_000 ether, address(this));
        bool success = other.transfer(address(staking), 1_234 ether);
        require(success, "Failed to transfer OTHER to staking");

        vm.expectEmit(true, true, false, true);
        emit RescueTokens(address(other), address(this), 1_234 ether);
        staking.rescueTokens(other, address(this), 1_234 ether);

        assertEq(other.balanceOf(address(staking)), 0, "other token not drained");
    }

    /// @notice Constructor: zero-address guard for stake token.
    function testConstructor_RevertOnZeroStakeToken() public {
        vm.expectRevert(SinglePoolStaking.InvalidToken.selector);
        new SinglePoolStaking(IERC20(address(0)), stakeToken, 1e18, address(this), 1e18, 0, 1, 1, 0);
    }

    /// @notice Constructor: zero-address guard for reward token.
    function testConstructor_RevertOnZeroRewardToken() public {
        vm.expectRevert(SinglePoolStaking.InvalidToken.selector);
        new SinglePoolStaking(stakeToken, IERC20(address(0)), 1e18, address(this), 1e18, 0, 1, 1, 0);
    }

    /// @notice Constructor: zero-address guard for contract owner.
    function testConstructor_RevertOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SinglePoolStaking(stakeToken, stakeToken, 1e18, address(0), 1e18, 0, 1, 1, 0);
    }

    /// @notice Constructor: initial withdraw delay > MAX_WITHDRAW_DELAY must revert.
    function testConstructor_Revert_OnInitialWithdrawDelayTooLong() public {
        uint64 tooLong = uint64(30 days) + 1; // keep in sync with constant
        vm.expectRevert(abi.encodeWithSelector(SinglePoolStaking.DelayTooLong.selector, tooLong, 30 days));
        new SinglePoolStaking(
            stakeToken,
            stakeToken,
            1e18, // initial rate
            address(this), // owner
            1e18, // max rate
            0, // min rate
            1, // rate change delay
            tooLong, // initial withdraw delay (too large)
            0 // min stake
        );
    }

    /// @notice `balanceOf` reflects user stake balance.
    function testView_balanceOf() public {
        assertEq(staking.balanceOf(alice), 0, "initial balance non-zero");
        _stake(alice, 200 ether);
        assertEq(staking.balanceOf(alice), 200 ether, "post-stake balance mismatch");
    }

    /// @notice `lastTimeRewardApplicable` equals `block.timestamp`.
    function testView_lastTimeRewardApplicable() public {
        uint256 now1 = staking.lastTimeRewardApplicable();
        assertEq(now1, block.timestamp, "initial lastTime mismatch");
        vm.warp(block.timestamp + 123);
        uint256 now2 = staking.lastTimeRewardApplicable();
        assertEq(now2, block.timestamp, "advanced lastTime mismatch");
    }

    /// @notice `rewardPerToken` short-circuits when (a) no stakers or (b) elapsed == 0.
    function testView_rewardPerToken_NoStakers_ElapsedZero() public {
        uint256 rpt0 = staking.rewardPerToken();
        assertEq(rpt0, staking.rewardPerTokenStored(), "no-stakers RPT changed unexpectedly");

        _stake(alice, 100 ether);
        uint256 before = staking.rewardPerToken();
        uint256 afterView = staking.rewardPerToken();
        assertEq(before, afterView, "elapsed==0 changed RPT unexpectedly");
    }

    /// @notice `rewardPerToken` is capped by `rewardReserves` in the view path.
    function testView_rewardPerToken_CapsByReserves() public {
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, stakeToken, 1e18, address(this), 1e18, 0, 1, 1, 0);
        stakeToken.approve(address(s), type(uint256).max);
        s.fundRewards(10 ether);

        address u = makeAddr("u");
        bool success = stakeToken.transfer(u, 100 ether);
        require(success, "Failed to transfer to user");

        vm.startPrank(u);
        stakeToken.approve(address(s), type(uint256).max);
        s.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 1000);
        uint256 rpt = s.rewardPerToken(); // (10 * 1e18) / 100e18
        assertEq(rpt, (10 ether * 1e18) / 100 ether, "RPT not capped by reserves");
    }

    /// @notice `earned()` accrues linearly for a single staker (view path).
    function testView_earned_Simple() public {
        _stake(alice, 100 ether);
        vm.warp(block.timestamp + 10);
        assertEq(staking.earned(alice), 10 ether, "earned mismatch after 10s");
    }

    /// @notice Reserves are consumed only on state updates that call `_updateGlobal()`.
    function testFundRewards_ReservesConsumedByAccrual() public {
        _stake(alice, 100 ether);
        staking.fundRewards(1_000 ether);
        uint256 beforeRes = staking.rewardReserves();

        vm.warp(block.timestamp + 10);
        assertEq(staking.earned(alice), 10 ether, "view earned mismatch");

        _getReward(alice);
        uint256 afterRes = staking.rewardReserves();
        assertEq(beforeRes - afterRes, 10 ether, "reserves not consumed on update");
    }

    /// @notice Only the owner can propose a new reward rate; execution is permissionless after delay (safer UX).
    function testProposeRewardRate_OnlyOwner() public {
        // Non-owner proposing reverts
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.proposeRewardRate(2e18);

        // Owner proposes
        uint64 executeAfter = uint64(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateProposed(2e18, executeAfter);
        staking.proposeRewardRate(2e18);

        // Anyone can execute after delay
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectEmit(false, false, false, true);
        emit RewardRateUpdated(1e18, 2e18);
        staking.executeRewardRateChange();

        assertEq(staking.rewardRate(), 2e18, "rewardRate not updated");
    }

    /// @notice Propose does not affect `lastUpdateTime`; execute updates it once (no drift within same block).
    function testProposeRewardRate_IdempotentSameBlockUpdateTime() public {
        uint64 before = staking.lastUpdateTime();
        uint64 executeAfter = uint64(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateProposed(2e18, executeAfter);
        staking.proposeRewardRate(2e18);
        uint64 mid1 = staking.lastUpdateTime();
        assertEq(mid1, before, "propose should not change lastUpdateTime");

        vm.warp(block.timestamp + 1);
        staking.executeRewardRateChange();
        uint64 mid2 = staking.lastUpdateTime();
        assertLe(before, mid2, "lastUpdateTime should advance on execute");

        vm.expectEmit(false, false, false, true);
        emit RewardRateProposed(3e18, uint64(block.timestamp + 1));
        staking.proposeRewardRate(3e18);
        uint64 afterUpdate = staking.lastUpdateTime();
        assertEq(afterUpdate, mid2, "propose (same block) should not change lastUpdateTime");
    }

    /// @notice Cannot rescue the reward token when stake != reward (distinct invalid branch).
    function testRescueTokens_InvalidForRewardToken_WhenDifferentTokens() public {
        ERC20Token reward2 = new ERC20Token("R", "R", 1_000_000 ether, address(this));
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, reward2, 1e18, address(this), 1e18, 0, 1, 1, 0);
        vm.expectRevert(SinglePoolStaking.InvalidToken.selector);
        s.rescueTokens(reward2, address(this), 1 ether);
    }

    /// @notice `stakeFor` accrues existing rewards, adds to recipient balance, and emits `Staked`.
    function testStakeFor_Success_EventAndAccounting() public {
        _stake(alice, 100 ether);
        vm.warp(block.timestamp + 10);

        bool success = stakeToken.transfer(bob, 500 ether);
        require(success, "Failed to transfer to Bob");

        vm.startPrank(bob);
        stakeToken.approve(address(staking), type(uint256).max);
        vm.expectEmit(true, true, false, true);
        emit Staked(bob, alice, 200 ether);
        staking.stakeFor(200 ether, alice);
        vm.stopPrank();

        assertEq(staking.earned(alice), 10 ether, "pre-accrual not preserved");
        assertEq(staking.balanceOf(alice), 300 ether, "recipient principal mismatch");
        assertEq(staking.totalStaked(), 300 ether, "totalStaked mismatch");
    }

    /// @notice `getReward` reverts when user has no rewards.
    function testGetReward_RevertWhenZero() public {
        _stake(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.InsufficientBalance.selector);
        staking.getReward();
    }

    /// @notice `getReward` transfers to sender, emits `RewardPaid`, and zeroes owed amount.
    function testGetReward_Success_EventAndBalance() public {
        _stake(alice, 100 ether);
        vm.warp(block.timestamp + 7);
        uint256 owed = staking.earned(alice);

        vm.expectEmit(true, true, false, true);
        emit RewardPaid(alice, alice, owed);

        uint256 before = stakeToken.balanceOf(alice);
        _getReward(alice);
        uint256 afterBal = stakeToken.balanceOf(alice);

        assertEq(afterBal - before, 7 ether, "reward transfer mismatch");
        assertEq(staking.earned(alice), 0, "owed not zeroed");
    }

    /// @notice Simulates "exit" semantics: withdraw all principal via delayed flow, then claim rewards.
    function testWithdrawAllViaDelay_ThenClaimReward() public {
        _stake(alice, 150 ether);
        vm.warp(block.timestamp + 6);

        // Request all principal
        vm.expectEmit(true, false, false, true);
        emit WithdrawalRequested(alice, 150 ether, uint64(block.timestamp) + staking.withdrawDelay());
        vm.prank(alice);
        staking.requestWithdrawal(150 ether);

        // Complete after delay
        vm.warp(block.timestamp + staking.withdrawDelay());
        vm.expectEmit(true, false, false, true);
        emit WithdrawalCompleted(alice, 150 ether);
        vm.prank(alice);
        staking.completeWithdrawal();

        // Claim owed rewards
        vm.expectEmit(true, true, false, true);
        emit RewardPaid(alice, alice, 6 ether);
        vm.prank(alice);
        staking.getReward();

        assertEq(staking.balanceOf(alice), 0, "stake not zeroed");
        assertEq(staking.earned(alice), 0, "rewards not zeroed");
    }

    /// @notice `emergencyWithdraw` reverts when disabled or when user has no stake (after enabled).
    function testEmergencyWithdraw_RevertWhenNoStake() public {
        // Disabled => specific revert
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.EmergencyExitDisabled.selector);
        staking.emergencyWithdraw();

        // Enable but no stake => InsufficientBalance
        staking.setEmergencyExitEnabled(true);
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.InsufficientBalance.selector);
        staking.emergencyWithdraw();
    }

    /// @notice After emergencyWithdraw, user does not accrue retroactively; new accrual starts only after restake.
    function testEmergencyWithdraw_NoBackAccrualThenRestake() public {
        staking.setEmergencyExitEnabled(true);

        _stake(alice, 200 ether);
        vm.warp(block.timestamp + 5);
        vm.prank(alice);
        staking.emergencyWithdraw();

        // Warp more — with no stake, earned must remain 0
        vm.warp(block.timestamp + 10);
        assertEq(staking.earned(alice), 0, "no accrual post-emergency without stake");

        // Restake and accrue again
        _stake(alice, 100 ether);
        vm.warp(block.timestamp + 3);
        assertEq(staking.earned(alice), 3 ether, "new accrual after restake only");
    }

    /// @notice Equal stakers share rewards proportionally.
    function testAccrual_ProportionalDistribution() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        vm.warp(block.timestamp + 10); // total 10 tokens -> 5/5
        assertEq(staking.earned(alice), 5 ether, "alice share mismatch");
        assertEq(staking.earned(bob), 5 ether, "bob share mismatch");
    }

    /// @notice With no stakers, executing a rate change (which snaps global) does not consume reserves.
    function testAccrual_NoStakersDoesNotConsumeReserves() public {
        // fresh pool
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, stakeToken, 1e18, address(this), 1e18, 0, 1, 1, 0);
        stakeToken.approve(address(s), type(uint256).max);
        s.fundRewards(1_000 ether);

        uint256 before = s.rewardReserves();

        s.proposeRewardRate(1e18);
        vm.warp(block.timestamp + 1);
        s.executeRewardRateChange();

        uint256 afterRes = s.rewardReserves();
        assertEq(afterRes, before, "reserves consumed without stakers");
    }

    /// @notice State-path reserve cap: accrual is limited by reserves and consumed on update.
    function testAccrual_StatePathCappedByReserves() public {
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, stakeToken, 1e18, address(this), 1e18, 0, 1, 1, 0);
        stakeToken.approve(address(s), type(uint256).max);
        s.fundRewards(5 ether);

        address u = makeAddr("capUser");
        bool success = stakeToken.transfer(u, 100 ether);
        require(success, "Failed to transfer to capUser");

        vm.startPrank(u);
        stakeToken.approve(address(s), type(uint256).max);
        s.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 1000);
        assertEq(s.earned(u), 5 ether, "view path not capped at reserves");

        uint256 beforeRes = s.rewardReserves();
        vm.prank(u);
        s.getReward();
        uint256 afterRes = s.rewardReserves();

        assertEq(beforeRes - afterRes, 5 ether, "state path consumed more than reserves");
    }

    /// @notice Basic stake→earn sanity (single user).
    function testStakeAndEarnBasic() public {
        _stake(alice, 100 ether);
        vm.warp(block.timestamp + 10);
        assertEq(staking.earned(alice), 10 ether, "basic earned mismatch");
    }

    /// @notice Ownable2Step: only pending owner can accept; after accept, only new owner can propose.
    function testOwnership_TwoStepFlow() public {
        address newOwner = makeAddr("newOwner");

        staking.transferOwnership(newOwner);
        // Old owner still can fund
        staking.fundRewards(1 ether);

        // Non-pending cannot accept
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.acceptOwnership();

        // Pending accepts
        vm.prank(newOwner);
        staking.acceptOwnership();

        // Old owner loses perms to propose
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        staking.proposeRewardRate(2e18);

        // New owner can propose
        vm.prank(newOwner);
        uint64 executeAfter = uint64(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateProposed(3e18, executeAfter);
        staking.proposeRewardRate(3e18);

        // Anyone executes after delay
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectEmit(false, false, false, true);
        emit RewardRateUpdated(1e18, 3e18);
        staking.executeRewardRateChange();

        assertEq(staking.rewardRate(), 3e18);
    }

    /// @notice Proposing a rate above the configured max should revert with `RewardRateTooHigh`.
    function testProposeRewardRate_RevertAboveMax() public {
        uint256 max = staking.MAX_REWARD_RATE();
        uint256 requested = max + 1;

        vm.expectRevert(abi.encodeWithSelector(SinglePoolStaking.RewardRateTooHigh.selector, requested, max));
        staking.proposeRewardRate(requested);
    }

    /// @notice Proposing exactly MAX_REWARD_RATE should succeed and execute after delay.
    function testProposeRewardRate_AtMax_SucceedsAndEmits() public {
        uint256 max = staking.MAX_REWARD_RATE();

        // Propose = max
        uint64 executeAfter = uint64(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateProposed(max, executeAfter);
        staking.proposeRewardRate(max);

        // Execute after delay
        vm.warp(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateUpdated(1e18, max);
        staking.executeRewardRateChange();

        assertEq(staking.rewardRate(), max, "rewardRate not set to max");
    }

    /// @notice Executing without any pending proposal should revert.
    function testExecuteRewardRateChange_Revert_NoPending() public {
        vm.expectRevert(SinglePoolStaking.NoPendingRate.selector);
        staking.executeRewardRateChange();
    }

    /// @notice Executing before the delay elapses should revert.
    function testExecuteRewardRateChange_Revert_BeforeDelay() public {
        staking.proposeRewardRate(2e18);
        vm.expectRevert(); // RateChangeDelayNotMet
        staking.executeRewardRateChange();
    }

    /// @notice Only owner can cancel; cancel clears pending state and prevents execution.
    function testCancelRewardRateChange_OnlyOwnerAndResets() public {
        // Propose a change
        staking.proposeRewardRate(2e18);

        // Non-owner cannot cancel
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.cancelRewardRateChange();

        // Owner cancels
        vm.expectEmit(false, false, false, true);
        emit RewardRateChangeCanceled(2e18);
        staking.cancelRewardRateChange();

        // After cancel, executing should revert (no pending)
        vm.warp(block.timestamp + 1);
        vm.expectRevert(); // NoPendingRate
        staking.executeRewardRateChange();
    }

    /// @notice Proposing a new rate while one is already pending should overwrite the previous pending rate & timestamp.
    function testProposeRewardRate_OverridePending_UsesLatest() public {
        // First proposal
        uint64 executeAfter1 = uint64(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateProposed(2e18, executeAfter1);
        staking.proposeRewardRate(2e18);

        // Second proposal overrides the first in SAME block (updates pending & executeAfter)
        uint64 executeAfter2 = uint64(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateProposed(3e18, executeAfter2);
        staking.proposeRewardRate(3e18);

        // After the new delay, executing should set to 3e18 (the latest)
        vm.warp(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateUpdated(1e18, 3e18);
        staking.executeRewardRateChange();

        assertEq(staking.rewardRate(), 3e18, "should execute latest pending rate only");
    }

    /// @notice Proposing a zero rate (pause) and executing should set emission to 0 after delay.
    function testProposeRewardRate_Zero_SetsToZeroAfterDelay() public {
        // Propose pause
        uint64 executeAfter = uint64(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateProposed(0, executeAfter);
        staking.proposeRewardRate(0);

        // Execute after delay
        vm.warp(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateUpdated(1e18, 0);
        staking.executeRewardRateChange();

        assertEq(staking.rewardRate(), 0, "rewardRate not set to zero");
    }

    /// @notice `cancelRewardRateChange` reverts when there is no pending proposal.
    function testCancelRewardRateChange_Revert_NoPending() public {
        vm.expectRevert(SinglePoolStaking.NoPendingRate.selector);
        staking.cancelRewardRateChange();
    }

    /// @notice `rewardsRunwaySeconds` returns reserves/rate; with rate=0 returns max.
    function testView_rewardsRunwaySeconds_PositiveAndZeroRate() public {
        // Positive rate case (default: rewardRate = 1 ether/sec, reserves = 100_000 ether from Base)
        uint256 runway = staking.rewardsRunwaySeconds();
        assertEq(runway, 100_000, "runway seconds mismatch with positive rate");

        // Set rate to zero via propose/execute and assert max
        uint64 executeAfter = uint64(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateProposed(0, executeAfter);
        staking.proposeRewardRate(0);
        vm.warp(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateUpdated(1e18, 0);
        staking.executeRewardRateChange();

        assertEq(staking.rewardsRunwaySeconds(), type(uint256).max, "runway should be max when rate == 0");
    }

    /// @notice Owner can set withdraw delay; non-owner reverts; too-large delay reverts.
    function testAdmin_setWithdrawDelay_Succeeds_RevertsOnTooLong_OnlyOwner() public {
        // Non-owner cannot set
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setWithdrawDelay(2 days);

        // Owner sets a valid delay; event should emit
        uint64 oldDelay = staking.withdrawDelay();
        uint64 newDelay = 2 days;
        vm.expectEmit(false, false, false, true);
        emit WithdrawDelayUpdated(oldDelay, newDelay);
        staking.setWithdrawDelay(newDelay);
        assertEq(staking.withdrawDelay(), newDelay, "withdrawDelay not updated");

        // Too long reverts (> MAX_WITHDRAW_DELAY)
        uint64 tooLong = staking.MAX_WITHDRAW_DELAY() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(SinglePoolStaking.DelayTooLong.selector, tooLong, staking.MAX_WITHDRAW_DELAY())
        );
        staking.setWithdrawDelay(tooLong);
    }

    /// @notice Owner can set min stake; enforced on stake; non-owner reverts.
    function testAdmin_setMinStakeAmount_Enforced_OnlyOwner() public {
        // Non-owner cannot set
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setMinStakeAmount(50 ether);

        // Owner sets min stake; event should emit
        uint256 oldMin = staking.minStakeAmount();
        uint256 minAmt = 50 ether;
        vm.expectEmit(false, false, false, true);
        emit MinStakeAmountUpdated(oldMin, minAmt);
        staking.setMinStakeAmount(minAmt);
        assertEq(staking.minStakeAmount(), minAmt, "minStakeAmount not updated");

        // Below-min reverts
        vm.startPrank(alice);
        stakeToken.approve(address(staking), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SinglePoolStaking.AmountTooLow.selector, 49 ether, minAmt));
        staking.stake(49 ether);

        // Equal-to-min succeeds
        staking.stake(50 ether);
        vm.stopPrank();
        assertEq(staking.balanceOf(alice), 50 ether, "stake at min should succeed");
    }

    /// @notice Requesting a second withdrawal while one is pending should revert.
    function testRequestWithdrawal_RevertWhenPendingExists() public {
        _stake(alice, 10 ether);
        vm.prank(alice);
        staking.requestWithdrawal(4 ether);
        // Second request should revert
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.PendingWithdrawalExists.selector);
        staking.requestWithdrawal(1 ether);
    }

    /// @notice Emergency withdraw returns both staked and pending amounts; totalStaked reduces by only staked.
    function testEmergencyWithdraw_IncludesPendingAmount() public {
        staking.setEmergencyExitEnabled(true);
        _stake(alice, 100 ether);

        // Move some to pending
        vm.prank(alice);
        staking.requestWithdrawal(30 ether);

        uint256 beforeBal = stakeToken.balanceOf(alice);

        // Expect to withdraw staked(70) + pending(30) = 100
        vm.expectEmit(true, true, false, true);
        emit EmergencyWithdraw(alice, alice, 100 ether);
        vm.prank(alice);
        staking.emergencyWithdraw();

        assertEq(stakeToken.balanceOf(alice) - beforeBal, 100 ether, "did not receive staked + pending");
        assertEq(staking.balanceOf(alice), 0, "stake not zeroed");
        assertEq(staking.totalStaked(), 0, "totalStaked should subtract only staked (now zero)");
        // No pending remains
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.NoPendingWithdrawal.selector);
        staking.completeWithdrawal();
    }

    /// @notice Test that prevents rounding grief attack where rewardReserves are consumed without accruing rewards.
    /// @dev This test verifies the fix for the audit issue where setting rewardRate=1 wei/sec with totalStaked > 1 ether
    ///      would cause rewardReserves to be decremented even when rewardPerTokenStored rounds down to 0.
    function testRoundingGriefAttack_Prevented() public {
        // Ensure we have sufficient reserves for the test
        staking.fundRewards(1000 ether);

        // Set up the attack scenario: rewardRate = 1 wei/sec, totalStaked > 1 ether
        staking.proposeRewardRate(1); // 1 wei per second
        vm.warp(block.timestamp + 1); // execute after delay
        staking.executeRewardRateChange();

        // Stake a large amount (> 1 ether) to trigger the rounding issue
        uint256 largeStake = 2 ether;
        _stake(alice, largeStake);

        // Record initial state
        uint256 initialRewardReserves = staking.rewardReserves();
        uint256 initialRewardPerTokenStored = staking.rewardPerTokenStored();

        // Advance time by 1 second - this should trigger the rounding issue
        // newly = 1 * 1 = 1 wei
        // rewardPerTokenIncrease = (1 * 1e18) / 2e18 = 0 (due to integer division)
        vm.warp(block.timestamp + 1);

        // Trigger _updateGlobal() by calling a function that updates user state
        // We use requestWithdrawal instead of getReward since getReward reverts when rewards = 0
        vm.prank(alice);
        staking.requestWithdrawal(1 ether);

        // Verify that rewardReserves were NOT decremented when rewardPerTokenStored didn't increase
        uint256 finalRewardReserves = staking.rewardReserves();
        uint256 finalRewardPerTokenStored = staking.rewardPerTokenStored();

        // The key assertion: reserves should remain unchanged when no rewards are actually accrued
        assertEq(
            finalRewardReserves,
            initialRewardReserves,
            "rewardReserves should not decrease when rounding causes zero accrual"
        );
        assertEq(
            finalRewardPerTokenStored,
            initialRewardPerTokenStored,
            "rewardPerTokenStored should not increase when rounding causes zero accrual"
        );

        // Verify that alice received no rewards due to the rounding
        assertEq(staking.earned(alice), 0, "user should receive no rewards when rounding causes zero accrual");
    }

    /// @notice Constructor: initial reward rate below minimum should revert.
    function testConstructor_RevertOnInitialRewardRateTooLow() public {
        vm.expectRevert(abi.encodeWithSelector(SinglePoolStaking.RewardRateTooLow.selector, 0, 1e18));
        new SinglePoolStaking(
            stakeToken,
            stakeToken,
            0, // initial rate (too low)
            address(this),
            5e18, // max rate
            1e18, // min rate
            1, // rate change delay
            1, // withdraw delay
            0 // min stake amount
        );
    }

    /// @notice Constructor: initial reward rate above maximum should revert.
    function testConstructor_RevertOnInitialRewardRateTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(SinglePoolStaking.RewardRateTooHigh.selector, 6e18, 5e18));
        new SinglePoolStaking(
            stakeToken,
            stakeToken,
            6e18, // initial rate (too high)
            address(this),
            5e18, // max rate
            0, // min rate
            1, // rate change delay
            1, // withdraw delay
            0 // min stake amount
        );
    }

    /// @notice Constructor: min reward rate above max reward rate should revert.
    function testConstructor_RevertOnMinRewardRateAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(SinglePoolStaking.RewardRateTooLow.selector, 2e18, 1e18));
        new SinglePoolStaking(
            stakeToken,
            stakeToken,
            1e18, // initial rate
            address(this),
            1e18, // max rate
            2e18, // min rate (above max)
            1, // rate change delay
            1, // withdraw delay
            0 // min stake amount
        );
    }

    /// @notice Propose reward rate below minimum should revert.
    function testProposeRewardRate_RevertBelowMin_NewValidation() public {
        // Create a staking contract with min reward rate = 1e18
        SinglePoolStaking s = new SinglePoolStaking(
            stakeToken,
            stakeToken,
            1e18, // initial rate
            address(this),
            5e18, // max rate
            1e18, // min rate
            1, // rate change delay
            1, // withdraw delay
            0 // min stake amount
        );

        vm.expectRevert(abi.encodeWithSelector(SinglePoolStaking.RewardRateTooLow.selector, 0, 1e18));
        s.proposeRewardRate(0); // below minimum
    }

    /// @notice Propose reward rate above maximum should revert (new validation test).
    function testProposeRewardRate_RevertAboveMax_NewValidation() public {
        vm.expectRevert(abi.encodeWithSelector(SinglePoolStaking.RewardRateTooHigh.selector, 6e18, 5e18));
        staking.proposeRewardRate(6e18); // above maximum
    }

    /// @notice Propose reward rate within bounds should succeed.
    function testProposeRewardRate_WithinBounds_Succeeds() public {
        // Should succeed with rate between min (0) and max (5e18)
        staking.proposeRewardRate(2e18);

        // Verify the proposal was set
        assertEq(staking.pendingRewardRate(), 2e18, "pending reward rate not set");
        assertGt(staking.rateChangeExecuteAfter(), 0, "execute after timestamp not set");
    }

    /// @notice Test that the reserve griefing attack via rounding is fixed.
    /// @dev This test reproduces the PoC provided by auditors to verify the fix.
    ///      The attack: when newly = 1 and totalStaked = 100 ether, the calculation
    ///      (newly * 1e18) / totalStaked = (1 * 1e18) / (100 * 1e18) = 0 due to rounding.
    ///      Before the fix, reserves were consumed even when no rewards were accounted.
    ///      After the fix, reserves should only be consumed when rewards are actually accounted.
    function testReserveDrain_ViaRounding_Fixed() public {
        // Setup: Stake 100 ether and set reward rate to 1 token/sec
        _stake(alice, 100 ether);
        staking.proposeRewardRate(1);
        vm.warp(block.timestamp + 1);
        staking.executeRewardRateChange();
        assertEq(staking.rewardRate(), 1, "reward rate should be 1");

        uint256 reservesBefore = staking.rewardReserves();

        // Attempt the attack: repeatedly request/cancel withdrawal to trigger _updateGlobal
        // Each iteration should advance time by 1 second, creating newly = 1
        // With totalStaked = 100 ether, rewardPerTokenIncrease = (1 * 1e18) / (100 * 1e18) = 0
        uint256 iterations = 20;
        vm.startPrank(alice);
        for (uint256 i = 0; i < iterations; i++) {
            vm.warp(block.timestamp + 1); // elapsed = 1s → newly = 1
            staking.requestWithdrawal(1);
            staking.cancelWithdrawal();
        }
        vm.stopPrank();

        uint256 reservesAfter = staking.rewardReserves();

        // With the fix, reserves should NOT be drained
        // Before fix: reservesBefore - reservesAfter = iterations (20)
        // After fix: reservesBefore - reservesAfter = 0 (no drain)
        assertEq(reservesBefore, reservesAfter, "Reserves should not be drained due to rounding");
    }

    /// @notice Test that demonstrates the reserve grief attack via emergency exit (auditor's PoC).
    /// @dev This test shows the FIXED behavior: emergencyWithdraw() now returns forfeited rewards to reserves,
    ///      preventing the grief attack where reserves would be consumed but rewards forfeited.
    function testBlockOnEmergencyExit() public {
        uint256 elapsed = 10;
        staking.setEmergencyExitEnabled(true);
        _stake(alice, 100 ether);
        vm.warp(block.timestamp + elapsed);
        uint256 resBefore = staking.rewardReserves();
        vm.prank(alice);
        staking.emergencyWithdraw();
        uint256 resAfter = staking.rewardReserves();

        // With the fix: reserves should NOT be consumed because forfeited rewards are returned
        // Before fix: resBefore - resAfter = expectedConsume (reserves consumed but not claimable)
        // After fix: resBefore - resAfter = 0 (reserves returned via forfeited rewards)
        assertEq(resBefore, resAfter, "reserves should be returned via forfeited rewards (grief attack fixed)");
        assertEq(staking.balanceOf(alice), 0, "alice stake not cleared");
        assertEq(staking.earned(alice), 0, "alice rewards not forfeited");
    }

    /// @notice Test that verifies the fix for emergency exit reserve grief attack.
    /// @dev After the fix, forfeited rewards should be returned to reserves, preventing the grief attack.
    function testEmergencyExitReserveGrief_Fixed() public {
        uint256 elapsed = 10;
        staking.setEmergencyExitEnabled(true);
        _stake(alice, 100 ether);
        vm.warp(block.timestamp + elapsed);

        uint256 resBefore = staking.rewardReserves();

        // Calculate expected forfeited rewards
        uint256 expectedForfeitedRewards = staking.earned(alice);

        vm.prank(alice);
        staking.emergencyWithdraw();

        uint256 resAfter = staking.rewardReserves();

        // With the fix: reserves should be consumed by _updateGlobal() but then returned by forfeited rewards
        // Net effect: reserves should remain unchanged (or very close due to rounding)
        assertEq(resBefore, resAfter, "reserves should be returned via forfeited rewards");
        assertEq(staking.balanceOf(alice), 0, "alice stake not cleared");
        assertEq(staking.earned(alice), 0, "alice rewards not forfeited");

        // Verify that the forfeited rewards were actually calculated
        assertGt(expectedForfeitedRewards, 0, "should have had rewards to forfeit");
    }
}
