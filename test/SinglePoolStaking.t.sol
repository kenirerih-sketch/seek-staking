// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SinglePoolStaking} from "../src/SinglePoolStaking.sol";
import {ERC20Token} from "./mocks/ERC20Token.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {WeirdRewardToken} from "./mocks/WeirdRewardToken.sol";

/// @title SinglePoolStaking — Comprehensive Foundry Test Suite
/// @notice Covers public/external functions, events, branches, and critical edge cases for SinglePoolStaking.
/// @dev Assumes stake token == reward token with 18 decimals. Default rewardRate is 1e18 (1 token/sec).
///      Tests validate reserve capping, rounding behavior, only-owner gates, state vs view accrual,
///      and event emissions. Designed for audit-grade clarity and maintainability.
contract SinglePoolStakingTest is Test {
    // ==========
    // Test State
    // ==========
    SinglePoolStaking public staking;
    ERC20Token public stakeToken; // same as reward token

    address public user = address(0x1);
    address public owner = address(this);

    // ==========
    // Events (for expectEmit)
    // ==========
    /// @notice Mirror of SinglePoolStaking.Staked for event expectation checks.
    event Staked(address indexed sender, address indexed to, uint256 amount);
    /// @notice Mirror of SinglePoolStaking.Withdrawn for event expectation checks.
    event Withdrawn(address indexed sender, address indexed to, uint256 amount);
    /// @notice Mirror of SinglePoolStaking.RewardPaid for event expectation checks.
    event RewardPaid(address indexed user, address indexed to, uint256 amount);
    /// @notice Mirror of SinglePoolStaking.RewardRateUpdated for event expectation checks.
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    /// @notice Mirror of SinglePoolStaking.RewardsFunded for event expectation checks.
    event RewardsFunded(address indexed from, uint256 amount, uint256 newReserves);
    /// @notice Mirror of SinglePoolStaking.EmergencyWithdraw for event expectation checks.
    event EmergencyWithdraw(address indexed user, address indexed to, uint256 amount);
    /// @notice Mirror of SinglePoolStaking.RescueTokens for event expectation checks.
    event RescueTokens(address indexed token, address indexed to, uint256 amount);

    // ==========
    // Setup
    // ==========
    /// @notice Deploys the staking contract and prefunds reward reserves.
    /// @dev Uses same token for staking and rewards. Reserves funded via fundRewards (balance-delta semantics).
    function setUp() public {
        // Mint 1,000,000 tokens to owner (18 decimals)
        stakeToken = new ERC20Token("Stake Token", "STK", 1_000_000 ether, owner);

        // Deploy staking with same token for stake & reward
        staking = new SinglePoolStaking(stakeToken, stakeToken, 1e18, owner); // 1 token/sec

        // Distribute some to the user for staking
        bool success = stakeToken.transfer(user, 1_000 ether);
        if (!success) revert("Transfer failed");

        // Prefund reward bucket via fundRewards (IMPORTANT: do not transfer directly)
        stakeToken.approve(address(staking), type(uint256).max);
        staking.fundRewards(100_000 ether); // credits rewardReserves
    }

    // ======================
    // Helpers (readability)
    // ======================

    /// @dev Approves max and stakes `amount` on behalf of `who`.
    /// @param who The staker address.
    /// @param amount Token amount in wei (18 decimals).
    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        stakeToken.approve(address(staking), type(uint256).max);
        staking.stake(amount);
        vm.stopPrank();
    }

    /// @dev Withdraws `amount` of staked tokens for `who`.
    /// @param who The staker address.
    /// @param amount Token amount in wei (18 decimals).
    function _withdraw(address who, uint256 amount) internal {
        vm.prank(who);
        staking.withdraw(amount);
    }

    /// @dev Claims all accrued rewards for `who`.
    /// @param who The staker address.
    function _getReward(address who) internal {
        vm.prank(who);
        staking.getReward();
    }

    // ==========================================
    // 1) Constructor & View Functions
    // ==========================================

    /// @notice Verifies constructor sets immutables and initial state properly.
    /// @dev Assumes reserves were funded in setUp.
    function testConstructor_InitialState() public view {
        assertEq(address(staking.STAKE_TOKEN()), address(stakeToken), "stake token mismatch");
        assertEq(address(staking.REWARD_TOKEN()), address(stakeToken), "reward token mismatch");
        assertEq(staking.rewardRate(), 1e18, "initial rewardRate mismatch");
        assertEq(staking.rewardPerTokenStored(), 0, "initial rpt stored");
        assertEq(staking.rewardReserves(), 100_000 ether, "initial reserves funded in setUp");
        assertEq(staking.totalStaked(), 0, "initial totalStaked");
        // lastUpdateTime should be block.timestamp at deploy or the latest call
        // Not strictly equalable post-setup, but should be <= now.
        assertLe(staking.lastUpdateTime(), uint64(block.timestamp), "lastUpdateTime should be set");
    }

    /// @notice Constructor: reverts when stake token is zero address.
    function testConstructor_RevertOnZeroStakeToken() public {
        vm.expectRevert(SinglePoolStaking.InvalidToken.selector);
        new SinglePoolStaking(ERC20Token(address(0)), stakeToken, 1e18, owner);
    }

    /// @notice Constructor: reverts when reward token is zero address.
    function testConstructor_RevertOnZeroRewardToken() public {
        vm.expectRevert(SinglePoolStaking.InvalidToken.selector);
        new SinglePoolStaking(stakeToken, ERC20Token(address(0)), 1e18, owner);
    }

    /// @notice balanceOf mirrors users mapping.
    function testView_balanceOf() public {
        assertEq(staking.balanceOf(user), 0, "before stake balance");
        _stake(user, 200 ether);
        assertEq(staking.balanceOf(user), 200 ether, "after stake balance");
    }

    /// @notice lastTimeRewardApplicable returns `block.timestamp`.
    function testView_lastTimeRewardApplicable() public {
        uint256 now1 = staking.lastTimeRewardApplicable();
        assertEq(now1, block.timestamp, "should equal block.timestamp");
        vm.warp(block.timestamp + 123);
        uint256 now2 = staking.lastTimeRewardApplicable();
        assertEq(now2, block.timestamp, "should track current timestamp");
    }

    /// @notice rewardPerToken short-circuits when (a) totalStaked == 0 and (b) elapsed == 0.
    function testView_rewardPerToken_NoStakers_ElapsedZero() public {
        // no stakers -> rpt should be stored value
        uint256 rpt0 = staking.rewardPerToken();
        assertEq(rpt0, staking.rewardPerTokenStored(), "rpt unchanged w/ no stakers");

        // add a staker then call rpt immediately (elapsed == 0)
        _stake(user, 100 ether);
        uint256 before = staking.rewardPerToken();
        // no time warp or state-changing call -> elapsed==0 in view path
        uint256 afterView = staking.rewardPerToken();
        assertEq(before, afterView, "rpt unchanged when elapsed == 0");
    }

    /// @notice rewardPerToken caps by rewardReserves in the view path.
    /// @dev Uses a fresh instance with tiny reserves to assert the cap.
    function testView_rewardPerToken_CapsByReserves() public {
        // Fresh local instance with tiny reserves for a clean cap test
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, stakeToken, 1e18, owner);
        // fund only 10 tokens into reserves
        stakeToken.approve(address(s), type(uint256).max);
        s.fundRewards(10 ether);

        // give user2 tokens and stake in this fresh instance
        address user2 = address(0x2);
        bool success = stakeToken.transfer(user2, 100 ether);
        if (!success) revert("Transfer failed");

        vm.startPrank(user2);
        stakeToken.approve(address(s), type(uint256).max);
        s.stake(100 ether);
        vm.stopPrank();

        // warp a long time (e.g., 1000s => would accrue 1000 tokens if not capped)
        vm.warp(block.timestamp + 1000);

        // View path computes rpt with min(elapsed*rate, reserves) = 10
        uint256 rpt = s.rewardPerToken(); // (10 * 1e18) / totalStaked(100) = 0.1e18
        assertEq(rpt, (10 ether * 1e18) / 100 ether, "rpt must be capped by reserves");
    }

    /// @notice earned() reflects time-based accrual in the view path.
    function testView_earned_Simple() public {
        _stake(user, 100 ether);
        vm.warp(block.timestamp + 10); // at 1 token/sec
        uint256 earned = staking.earned(user);
        assertEq(earned, 10 ether, "view earned should reflect elapsed * rate");
    }

    // ==========================================
    // 2) Admin: fundRewards
    // ==========================================

    /// @notice fundRewards increases reserves and contract balance; emits `RewardsFunded`.
    /// @dev Uses balance-delta semantics to measure received amount.
    function testFundRewards_IncreasesReservesAndBalance_EmitsEvent() public {
        uint256 beforeReserves = staking.rewardReserves();
        uint256 beforeBal = stakeToken.balanceOf(address(staking));
        uint256 amount = 50_000 ether;

        vm.expectEmit(true, false, false, true);
        emit RewardsFunded(address(this), amount, beforeReserves + amount);
        staking.fundRewards(amount);

        assertEq(staking.rewardReserves(), beforeReserves + amount, "reserve inc");
        assertEq(stakeToken.balanceOf(address(staking)), beforeBal + amount, "balance inc");
    }

    /// @notice fundRewards reverts on zero amount.
    function testFundRewards_RevertOnZeroAmount() public {
        vm.expectRevert(SinglePoolStaking.AmountZero.selector);
        staking.fundRewards(0);
    }

    /// @notice Only the owner can call fundRewards.
    function testFundRewards_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        staking.fundRewards(1 ether);
    }

    /// @notice Funding uses balance delta; unrelated stake balance should not affect reserves.
    /// @dev Ensures that staking (which also increases contract balance) is not miscounted as reserves.
    function testFundRewards_UsesBalanceDelta_NotAffectedByExistingStakeBalance() public {
        _stake(user, 1_000 ether); // increases contract token balance

        uint256 beforeReserves = staking.rewardReserves();
        uint256 beforeBal = stakeToken.balanceOf(address(staking));

        uint256 fundAmt = 5_000 ether;
        staking.fundRewards(fundAmt);

        assertEq(staking.rewardReserves() - beforeReserves, fundAmt, "reserves delta");
        assertEq(stakeToken.balanceOf(address(staking)) - beforeBal, fundAmt, "balance delta");
    }

    /// @notice Reserves are consumed only on state-changing accounting (e.g., claim).
    /// @dev View functions do not reduce reserves; `_updateGlobal()` during a state change does.
    function testFundRewards_ReservesConsumedByAccrual() public {
        _stake(user, 100 ether);
        staking.fundRewards(1_000 ether);
        uint256 beforeReserves = staking.rewardReserves();

        vm.warp(block.timestamp + 10); // 10 tokens should accrue
        // earned() reflects view math; reserves are not yet consumed
        assertEq(staking.earned(user), 10 ether, "pre-claim earned incorrect");

        // Claim triggers _updateGlobal() which consumes reserves
        _getReward(user);
        uint256 afterReserves = staking.rewardReserves();
        assertEq(beforeReserves - afterReserves, 10 ether, "reserves not consumed on update");
    }

    /// @notice Triggers the defensive revert path in `fundRewards` when no tokens are actually received.
    /// @dev Uses a `WeirdRewardToken` that returns `true` on `transferFrom` but does not change balances,
    ///      causing `received == 0` inside `fundRewards` and reverting with `AmountZero`.
    ///      This specifically covers the `received == 0` branch in `SinglePoolStaking.fundRewards`.
    /// @custom:coverage Covers SinglePoolStaking.fundRewards branch where `received == 0`.
    function testFundRewards_RevertWhenReceivedZero() public {
        // Fresh staking where REWARD_TOKEN is a weird token that pretends to transfer
        WeirdRewardToken weird = new WeirdRewardToken("WRD", "WRD", 1_000_000 ether);
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, ERC20Token(address(weird)), 1e18, owner);

        // Approve but configure the token to not move balances on transferFrom
        weird.approve(address(s), type(uint256).max);
        weird.setNoMove(true);

        vm.expectRevert(SinglePoolStaking.AmountZero.selector);
        s.fundRewards(123 ether);
    }

    // ==========================================
    // 3) Admin: setRewardRate
    // ==========================================

    /// @notice Only the owner can change `rewardRate`.
    function testSetRewardRate_OnlyOwner() public {
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        staking.setRewardRate(2e18);
    }

    /// @notice Emits `RewardRateUpdated` and snapshots accrual at old rate before switching to new rate.
    /// @dev Earned should equal 10*1 + 10*2 = 30 tokens across two distinct periods.
    function testSetRewardRate_EmitsAndSnapshotsAccrual() public {
        _stake(user, 100 ether);

        // accrue 10s at old rate (1e18)
        vm.warp(block.timestamp + 10);

        vm.expectEmit(false, false, false, true);
        emit RewardRateUpdated(1e18, 2e18);
        staking.setRewardRate(2e18);

        // Now 10s at new rate (2e18)
        vm.warp(block.timestamp + 10);

        // View earned should be 10*1 + 10*2 = 30
        uint256 earned = staking.earned(user);
        assertEq(earned, 30 ether, "earned should reflect snapshot + new rate");
    }

    /// @notice Calling setRewardRate twice in the same block should keep lastUpdateTime consistent.
    /// @dev No warp between calls; ensures no drift in `lastUpdateTime`.
    function testSetRewardRate_IdempotentSameBlockUpdateTime() public {
        uint64 before = staking.lastUpdateTime();
        staking.setRewardRate(2e18);
        uint64 mid = staking.lastUpdateTime();
        staking.setRewardRate(3e18);
        uint64 afterUpdate = staking.lastUpdateTime();

        // no warp => current == last, path returns early; still updates lastUpdateTime to current
        assertEq(mid, afterUpdate, "lastUpdateTime should not drift within same block");
        assertLe(before, mid, "lastUpdateTime should be current or later");
    }

    // ==========================================
    // 4) Admin: rescueTokens
    // ==========================================

    /// @notice Cannot rescue the stake or reward token (same token in this setup).
    function testRescueTokens_RevertForStakeOrRewardToken() public {
        vm.expectRevert(SinglePoolStaking.InvalidToken.selector);
        staking.rescueTokens(stakeToken, address(this), 1 ether);

        // In same-token setup this is redundant, but we assert explicitly
        vm.expectRevert(SinglePoolStaking.InvalidToken.selector);
        staking.rescueTokens(stakeToken, address(this), 1 ether);
    }

    /// @notice Can rescue unrelated tokens; emits `RescueTokens`.
    /// @dev Asserts no net change in owner balance (restored after rescue) and zero balance on staking.
    function testRescueTokens_OtherToken_SucceedsAndEmits() public {
        // Deploy a different token and send to staking
        ERC20Token other = new ERC20Token("Other", "OTR", 10_000 ether, address(this));

        uint256 ownerBefore = other.balanceOf(address(this));

        uint256 amount = 1_234 ether;
        bool success = other.transfer(address(staking), amount);
        if (!success) revert("Transfer failed");

        assertEq(other.balanceOf(address(staking)), amount, "funded amount mismatch");

        vm.expectEmit(true, true, false, true);
        emit RescueTokens(address(other), address(this), amount);
        staking.rescueTokens(other, address(this), amount);

        // Staking contract emptied of 'other'
        assertEq(other.balanceOf(address(staking)), 0, "other token not drained");

        // Owner balance restored exactly to pre-transfer amount (no net change)
        uint256 ownerAfter = other.balanceOf(address(this));
        assertEq(ownerAfter, ownerBefore, "owner should recover rescued tokens");
    }

    /// @notice Cannot rescue the reward token if reward != stake (covers distinct invalid branch).
    /// @dev Deploys a fresh instance with a different reward token to hit the branch.
    function testRescueTokens_InvalidForRewardToken_WhenDifferentTokens() public {
        // Fresh staking with different reward token so we can hit the 2nd invalid branch
        ERC20Token reward2 = new ERC20Token("R", "R", 1_000_000 ether, address(this));
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, reward2, 1e18, owner);

        vm.expectRevert(SinglePoolStaking.InvalidToken.selector);
        s.rescueTokens(reward2, address(this), 1 ether);
    }

    // ==========================================
    // 5) User: stake / stakeFor
    // ==========================================

    /// @notice stake reverts on zero amount.
    function testStake_RevertOnZero() public {
        vm.expectRevert(SinglePoolStaking.AmountZero.selector);
        staking.stake(0);
    }

    /// @notice stake updates balances and emits `Staked`.
    function testStake_Success_EventAndState() public {
        vm.startPrank(user);
        stakeToken.approve(address(staking), type(uint256).max);

        vm.expectEmit(true, true, false, true);
        emit Staked(user, user, 250 ether);
        staking.stake(250 ether);
        vm.stopPrank();

        assertEq(staking.balanceOf(user), 250 ether, "user balance");
        assertEq(staking.totalStaked(), 250 ether, "totalStaked");
    }

    /// @notice stakeFor accrues existing rewards, adds balance to `to`, and emits `Staked`.
    /// @dev Validates sender and recipient are tracked correctly and that pre-accrued rewards persist.
    function testStakeFor_Success_EventAndAccounting() public {
        address sponsor = address(0xABCD);
        bool success = stakeToken.transfer(sponsor, 500 ether);
        if (!success) revert("Transfer failed");

        // target stakes first and accrues some rewards
        _stake(user, 100 ether);
        vm.warp(block.timestamp + 10); // accrue some rewards

        // sponsor stakes for user
        vm.startPrank(sponsor);
        stakeToken.approve(address(staking), type(uint256).max);
        vm.expectEmit(true, true, false, true);
        emit Staked(sponsor, user, 200 ether);
        staking.stakeFor(200 ether, user);
        vm.stopPrank();

        // user earned should reflect pre-stakeFor accrual
        uint256 earnedView = staking.earned(user);
        // Pre-stakeFor: 10 tokens accrued to user
        assertEq(earnedView, 10 ether, "accrued before balance increase");

        // balances
        assertEq(staking.balanceOf(user), 300 ether, "new user balance");
        assertEq(staking.totalStaked(), 300 ether, "new totalStaked");
    }

    // ==========================================
    // 6) User: withdraw
    // ==========================================

    /// @notice withdraw reverts on zero amount.
    function testWithdraw_RevertOnZero() public {
        vm.expectRevert(SinglePoolStaking.AmountZero.selector);
        staking.withdraw(0);
    }

    /// @notice withdraw reverts when user has insufficient balance.
    function testWithdraw_RevertOnInsufficient() public {
        vm.prank(user);
        vm.expectRevert(SinglePoolStaking.InsufficientBalance.selector);
        staking.withdraw(1);
    }

    /// @notice withdraw updates stake balances and emits `Withdrawn`; rewards remain accrued and unclaimed.
    /// @dev Integer math floors RPT:
    ///      newly=5e18, total=300e18 → deltaRPT=floor((5e18*1e18)/300e18)=16_666_666_666_666_666,
    ///      expected earned = 300e18*deltaRPT/1e18 = 4_999_999_999_999_999_800 (200 wei short of 5e18).
    function testWithdraw_Success_EventAndState() public {
        _stake(user, 300 ether);
        vm.warp(block.timestamp + 5); // accrue 5

        vm.expectEmit(true, true, false, true);
        emit Withdrawn(user, user, 100 ether);
        _withdraw(user, 100 ether);

        assertEq(staking.balanceOf(user), 200 ether, "post-withdraw stake");
        assertEq(staking.totalStaked(), 200 ether, "post-withdraw totalStaked");

        // Compute expected earned using the same integer math as the contract
        uint256 elapsed = 5;
        uint256 newly = elapsed * 1 ether; // 5 ether
        uint256 totalBefore = 300 ether; // totalStaked before withdraw
        uint256 deltaRPT = (newly * 1e18) / totalBefore; // floor division
        uint256 expectedEarned = (300 ether * deltaRPT) / 1e18;

        uint256 earned = staking.earned(user);
        assertEq(earned, expectedEarned, "accrued but unclaimed");
    }

    // ==========================================
    // 7) User: getReward / getRewardTo
    // ==========================================

    /// @notice getReward reverts when user has no rewards to claim.
    function testGetReward_RevertWhenZero() public {
        _stake(user, 100 ether);
        // immediately claim => zero rewards
        vm.prank(user);
        vm.expectRevert(SinglePoolStaking.InsufficientBalance.selector);
        staking.getReward();
    }

    /// @notice getReward transfers rewards to msg.sender, emits `RewardPaid`, and zeroes owed amount.
    function testGetReward_Success_EventAndBalance() public {
        _stake(user, 100 ether);
        vm.warp(block.timestamp + 7);
        uint256 owed = staking.earned(user);
        assertEq(owed, 7 ether, "pre-claim owed");

        vm.expectEmit(true, true, false, true);
        emit RewardPaid(user, user, owed);

        uint256 before = stakeToken.balanceOf(user);
        _getReward(user);
        uint256 afterBal = stakeToken.balanceOf(user);

        assertEq(afterBal - before, 7 ether, "net reward transfer");
        assertEq(staking.earned(user), 0, "zeroed after claim");
    }

    /// @notice getRewardTo reverts when user has no rewards to claim.
    function testGetRewardTo_RevertWhenZero() public {
        _stake(user, 100 ether);
        vm.prank(user);
        vm.expectRevert(SinglePoolStaking.InsufficientBalance.selector);
        staking.getRewardTo(address(0xCAFE));
    }

    /// @notice getRewardTo transfers rewards to a custom recipient and emits `RewardPaid`.
    function testGetRewardTo_Success() public {
        _stake(user, 100 ether);
        vm.warp(block.timestamp + 8);
        uint256 owed = staking.earned(user);

        address recipient = address(0xCAFE);
        vm.expectEmit(true, true, false, true);
        emit RewardPaid(user, recipient, owed);

        uint256 before = stakeToken.balanceOf(recipient);
        vm.prank(user);
        staking.getRewardTo(recipient);
        uint256 afterBal = stakeToken.balanceOf(recipient);

        assertEq(afterBal - before, 8 ether, "recipient received rewards");
        assertEq(staking.earned(user), 0, "user rewards reset");
    }

    // ==========================================
    // 8) User: exit
    // ==========================================

    /// @notice exit withdraws principal and rewards in one call; emits both events when amounts > 0.
    function testExit_BothPrincipalAndReward() public {
        _stake(user, 150 ether);
        vm.warp(block.timestamp + 6); // owe 6

        vm.startPrank(user);
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(user, user, 150 ether);
        vm.expectEmit(true, true, false, true);
        emit RewardPaid(user, user, 6 ether);
        staking.exit();
        vm.stopPrank();

        assertEq(staking.balanceOf(user), 0, "principal withdrawn");
        assertEq(staking.earned(user), 0, "rewards claimed");
    }

    /// @notice exit with reward only (no principal) triggers only `RewardPaid`.
    function testExit_RewardOnly() public {
        _stake(user, 100 ether);
        vm.warp(block.timestamp + 4);
        // withdraw principal only (still leaves rewards accrued)
        _withdraw(user, 100 ether);

        // now exit: amount==0, reward>0
        vm.startPrank(user);
        vm.expectEmit(true, true, false, true);
        emit RewardPaid(user, user, 4 ether);
        staking.exit();
        vm.stopPrank();

        assertEq(staking.balanceOf(user), 0, "no principal left");
        assertEq(staking.earned(user), 0, "rewards claimed");
    }

    // ==========================================
    // 9) User: emergencyWithdraw
    // ==========================================

    /// @notice emergencyWithdraw forfeits rewards and returns principal; emits `EmergencyWithdraw`.
    /// @dev Ensures rewards are zeroed and user stake reset, while reserves math remains consistent.
    function testEmergencyWithdraw_ForfeitsRewards() public {
        _stake(user, 200 ether);
        vm.warp(block.timestamp + 9); // accrue 9

        uint256 beforeBal = stakeToken.balanceOf(user);

        vm.expectEmit(true, true, false, true);
        emit EmergencyWithdraw(user, user, 200 ether);
        vm.prank(user);
        staking.emergencyWithdraw();

        // principal returned
        assertEq(stakeToken.balanceOf(user) - beforeBal, 200 ether, "principal refunded");
        // rewards forfeited
        assertEq(staking.earned(user), 0, "rewards forfeited");
        // user balance reset
        assertEq(staking.balanceOf(user), 0, "stake reset");
    }

    /// @notice emergencyWithdraw reverts when user has no stake.
    function testEmergencyWithdraw_RevertWhenNoStake() public {
        vm.prank(user);
        vm.expectRevert(SinglePoolStaking.InsufficientBalance.selector);
        staking.emergencyWithdraw();
    }

    // ==========================================
    // 10) Distribution & Accounting Integration
    // ==========================================

    /// @notice Multiple stakers share rewards proportionally to stake.
    /// @dev With equal stakes and rate 1 token/sec for 10 sec (and sufficient reserves),
    ///      each receives 5 tokens out of total 10 accrued.
    function testAccrual_ProportionalDistribution() public {
        address user2 = address(0x2);
        bool success = stakeToken.transfer(user2, 1_000 ether);
        if (!success) revert("Transfer failed");

        _stake(user, 100 ether);
        _stake(user2, 100 ether);

        // fund a small, known amount to isolate
        staking.fundRewards(100 ether); // add to existing reserves but known yardstick

        // warp 10s => 10 tokens accrued in total, split evenly
        vm.warp(block.timestamp + 10);

        // trigger update via claim for user
        uint256 earned1 = staking.earned(user);
        uint256 earned2 = staking.earned(user2);

        assertEq(earned1, 5 ether, "user1 half");
        assertEq(earned2, 5 ether, "user2 half");
    }

    /// @notice With no stakers, global update should NOT consume reserves.
    /// @dev Calls an admin function to hit `_updateGlobal` while `totalStaked == 0`.
    function testAccrual_NoStakersDoesNotConsumeReserves() public {
        // Deploy fresh instance with known reserves; do not stake
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, stakeToken, 1e18, owner);
        stakeToken.approve(address(s), type(uint256).max);
        s.fundRewards(1_000 ether);

        uint256 before = s.rewardReserves();
        vm.warp(block.timestamp + 100);
        // call an admin function to hit _updateGlobal with totalStaked == 0
        s.setRewardRate(1e18);

        uint256 afterRes = s.rewardReserves();
        assertEq(afterRes, before, "reserves should not be consumed without stakers");
    }

    /// @notice `_updateGlobal` state-path reserve cap when `newly > rewardReserves`.
    /// @dev Uses tiny reserves so both view and state paths cap accrual to 5 ether exactly.
    function testAccrual_StatePathCappedByReserves() public {
        // Fresh instance with tight reserves so cap triggers in _updateGlobal (state)
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, stakeToken, 1e18, owner);
        stakeToken.approve(address(s), type(uint256).max);
        s.fundRewards(5 ether); // Very small reserve

        address user3 = address(0x3333);
        bool success = stakeToken.transfer(user3, 100 ether);
        if (!success) revert("Transfer failed");

        vm.startPrank(user3);
        stakeToken.approve(address(s), type(uint256).max);
        s.stake(100 ether);
        vm.stopPrank();

        // Large elapsed so "newly" would exceed reserves
        vm.warp(block.timestamp + 1000);

        // View shows the cap
        assertEq(s.earned(user3), 5 ether, "view path should be capped by reserves");

        // Trigger state update -> consumes exactly capped amount
        uint256 beforeRes = s.rewardReserves();
        vm.prank(user3);
        s.getReward();
        uint256 afterRes = s.rewardReserves();

        assertEq(beforeRes - afterRes, 5 ether, "state path must consume only the capped amount");
    }

    // ==========================================
    // 11) Original basic flow test (kept)
    // ==========================================

    /// @notice Basic flow: single stake accrues linearly and is visible via `earned()`.
    function testStakeAndEarn() public {
        // user stakes 100 tokens
        vm.startPrank(user);
        stakeToken.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        // advance time by 10 seconds
        vm.warp(block.timestamp + 10);

        // earned should be exactly 10 tokens
        uint256 earned = staking.earned(user);
        uint256 expectedEarned = 10 ether;

        assertEq(earned, expectedEarned, "Earned should be exactly 10 tokens");
    }
}
