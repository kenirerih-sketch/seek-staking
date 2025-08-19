// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
    /// @dev Covers explicit `AmountZero` revert branch.
    function testFundRewards_RevertOnZero() public {
        vm.expectRevert(SinglePoolStaking.AmountZero.selector);
        staking.fundRewards(0);
    }

    /// @notice Only the owner can call `fundRewards`.
    /// @dev Covers `OwnableUnauthorizedAccount` revert.
    function testFundRewards_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.fundRewards(1 ether);
    }

    /// @notice Funding uses balance-delta; unrelated stake balance changes should not affect reserves.
    /// @dev Stakes increase contract balance but should not be counted as reserves (assert deltas against fund amount).
    function testFundRewards_UsesBalanceDelta() public {
        _stake(alice, 1_000 ether);

        uint256 beforeRes = staking.rewardReserves();
        uint256 beforeBal = stakeToken.balanceOf(address(staking));

        staking.fundRewards(5_000 ether);

        assertEq(staking.rewardReserves() - beforeRes, 5_000 ether, "reserves delta mismatch");
        assertEq(stakeToken.balanceOf(address(staking)) - beforeBal, 5_000 ether, "balance delta mismatch");
    }

    /// @notice Defensive branch: `fundRewards` reverts when no tokens are actually received.
    /// @dev Uses a token that returns `true` on `transferFrom` but does not change balances, making `received == 0`.
    function testFundRewards_RevertWhenReceivedZero() public {
        WeirdRewardToken weird = new WeirdRewardToken("WRD", "WRD", 1_000_000 ether);
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, IERC20(address(weird)), 1e18, address(this), 1e18, 1);

        weird.approve(address(s), type(uint256).max);
        weird.setNoMove(true);

        vm.expectRevert(SinglePoolStaking.AmountZero.selector);
        s.fundRewards(123 ether);
    }

    /// @notice Snapshot across rate change using propose/execute; assert by claiming (mutative), not via pure view.
    /// @dev Window1: [0,10) @1e18 → 10 tokens; Window2: [10,20) @2e18 → 20 tokens. Total paid on claim = 30 tokens.
    ///      Uses 1s delay set in BaseSinglePoolStaking to minimize test warp noise.
    function testProposeRewardRate_Snapshot_ClaimBased() public {
        _stake(alice, 100 ether);

        // t in [0,10): old rate 1e18 => 10 tokens (includes +1 delay for propose to be executed)
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

        // t in [10+1, 20+1): effectively another 10s @2e18
        vm.warp(block.timestamp + 10);

        uint256 before = stakeToken.balanceOf(alice);
        _getReward(alice); // triggers _updateGlobal and pays
        uint256 paid = stakeToken.balanceOf(alice) - before;

        assertEq(paid, 30 ether, "snapshot (10) + new rate window (20) != 30");
        assertEq(staking.earned(alice), 0, "accrued not zeroed after claim");
    }

    /// @notice `stake` reverts on zero amount.
    /// @dev Covers explicit `AmountZero` revert branch.
    function testStake_RevertOnZero() public {
        vm.expectRevert(SinglePoolStaking.AmountZero.selector);
        staking.stake(0);
    }

    /// @notice Basic stake→accrue→withdraw flow; verifies rounding via contract’s integer math.
    /// @dev RPT = floor((newly * 1e18) / totalBefore). Expected earned = floor(300 * RPT / 1e18).
    function testStakeAndWithdraw() public {
        _stake(alice, 300 ether);
        vm.warp(block.timestamp + 5);

        vm.expectEmit(true, true, false, true);
        emit Withdrawn(alice, alice, 100 ether);
        _withdraw(alice, 100 ether);

        assertEq(staking.balanceOf(alice), 200 ether, "post-withdraw balance mismatch");
        assertEq(staking.totalStaked(), 200 ether, "post-withdraw totalStaked mismatch");

        // Compute expected earned using the same integer math as the contract
        uint256 elapsed = 5;
        uint256 newly = elapsed * 1 ether; // 5 ether
        uint256 totalBefore = 300 ether; // totalStaked before withdraw
        uint256 deltaRpt = (newly * 1e18) / totalBefore; // floor division
        uint256 expectedEarned = (300 ether * deltaRpt) / 1e18;

        uint256 earned = staking.earned(alice);
        assertEq(earned, expectedEarned, "accrued but unclaimed mismatch");
    }

    /// @notice `getRewardTo` sends rewards to a custom recipient; user’s accrued is zeroed.
    /// @dev Validates recipient balance increase and user reward reset.
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

    /// @notice `emergencyWithdraw` forfeits rewards and returns principal immediately.
    /// @dev Ensures rewards are zeroed, stake balance reset, and event emitted.
    function testEmergencyWithdraw_ForfeitsRewards() public {
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
    /// @dev Covers invalid-token branches and a successful rescue with event assertion.
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
    /// @dev Covers `InvalidToken` branch.
    function testConstructor_RevertOnZeroStakeToken() public {
        vm.expectRevert(SinglePoolStaking.InvalidToken.selector);
        new SinglePoolStaking(IERC20(address(0)), stakeToken, 1e18, address(this), 1e18, 1);
    }

    /// @notice Constructor: zero-address guard for reward token.
    /// @dev Covers `InvalidToken` branch.
    function testConstructor_RevertOnZeroRewardToken() public {
        vm.expectRevert(SinglePoolStaking.InvalidToken.selector);
        new SinglePoolStaking(stakeToken, IERC20(address(0)), 1e18, address(this), 1e18, 1);
    }

    /// @notice `balanceOf` reflects user stake balance.
    /// @dev Mirrors internal users mapping state via public view.
    function testView_balanceOf() public {
        assertEq(staking.balanceOf(alice), 0, "initial balance non-zero");
        _stake(alice, 200 ether);
        assertEq(staking.balanceOf(alice), 200 ether, "post-stake balance mismatch");
    }

    /// @notice `lastTimeRewardApplicable` equals `block.timestamp`.
    /// @dev Confirms design choice (no period end cap).
    function testView_lastTimeRewardApplicable() public {
        uint256 now1 = staking.lastTimeRewardApplicable();
        assertEq(now1, block.timestamp, "initial lastTime mismatch");
        vm.warp(block.timestamp + 123);
        uint256 now2 = staking.lastTimeRewardApplicable();
        assertEq(now2, block.timestamp, "advanced lastTime mismatch");
    }

    /// @notice `rewardPerToken` short-circuits when (a) no stakers or (b) elapsed == 0.
    /// @dev Exercises both early-return branches in the view path.
    function testView_rewardPerToken_NoStakers_ElapsedZero() public {
        uint256 rpt0 = staking.rewardPerToken();
        assertEq(rpt0, staking.rewardPerTokenStored(), "no-stakers RPT changed unexpectedly");

        _stake(alice, 100 ether);
        uint256 before = staking.rewardPerToken();
        uint256 afterView = staking.rewardPerToken();
        assertEq(before, afterView, "elapsed==0 changed RPT unexpectedly");
    }

    /// @notice `rewardPerToken` is capped by `rewardReserves` in the view path.
    /// @dev Uses a fresh instance with tiny reserves; asserts RPT == (reserves * 1e18) / totalStaked.
    function testView_rewardPerToken_CapsByReserves() public {
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, stakeToken, 1e18, address(this), 1e18, 1);
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
    /// @dev Baseline check at 1 token/second.
    function testView_earned_Simple() public {
        _stake(alice, 100 ether);
        vm.warp(block.timestamp + 10);
        assertEq(staking.earned(alice), 10 ether, "earned mismatch after 10s");
    }

    /// @notice Reserves are consumed only on state updates that call `_updateGlobal()`.
    /// @dev View reads do not reduce reserves; claiming does. Asserts 10 tokens are consumed on claim.
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
    /// @dev Covers owner-gate on propose; shows that a non-owner can execute after delay if desired.
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

        // Anyone can execute after delay (permissionless execution pattern)
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectEmit(false, false, false, true);
        emit RewardRateUpdated(1e18, 2e18);
        staking.executeRewardRateChange();

        assertEq(staking.rewardRate(), 2e18, "rewardRate not updated");
    }

    /// @notice Propose does not affect `lastUpdateTime`; execute updates it once (no drift within same block).
    /// @dev With a 1s delay: propose (no change), warp+execute (updates to now), then propose again (no change).
    function testProposeRewardRate_IdempotentSameBlockUpdateTime() public {
        // Propose new rate: should NOT touch lastUpdateTime
        uint64 before = staking.lastUpdateTime();
        uint64 executeAfter = uint64(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardRateProposed(2e18, executeAfter);
        staking.proposeRewardRate(2e18);
        uint64 mid1 = staking.lastUpdateTime();
        assertEq(mid1, before, "propose should not change lastUpdateTime");

        // Execute after delay: should set lastUpdateTime to current block
        vm.warp(block.timestamp + 1);
        staking.executeRewardRateChange();
        uint64 mid2 = staking.lastUpdateTime();
        assertLe(before, mid2, "lastUpdateTime should advance on execute");

        // Propose again in same block: no change to lastUpdateTime
        vm.expectEmit(false, false, false, true);
        emit RewardRateProposed(3e18, uint64(block.timestamp + 1));
        staking.proposeRewardRate(3e18);
        uint64 afterUpdate = staking.lastUpdateTime();
        assertEq(afterUpdate, mid2, "propose (same block) should not change lastUpdateTime");
    }

    /// @notice Cannot rescue the reward token when stake != reward (distinct invalid branch).
    /// @dev Deploys a fresh instance with a different reward token and asserts `InvalidToken`.
    function testRescueTokens_InvalidForRewardToken_WhenDifferentTokens() public {
        ERC20Token reward2 = new ERC20Token("R", "R", 1_000_000 ether, address(this));
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, reward2, 1e18, address(this), 1e18, 1);
        vm.expectRevert(SinglePoolStaking.InvalidToken.selector);
        s.rescueTokens(reward2, address(this), 1 ether);
    }

    /// @notice `stakeFor` accrues existing rewards, adds to recipient balance, and emits `Staked`.
    /// @dev Pre-accrual (10 tokens) must remain owed; principal increases to 300.
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

    /// @notice `withdraw` reverts on zero amount.
    /// @dev Covers `AmountZero` branch.
    function testWithdraw_RevertOnZero() public {
        vm.expectRevert(SinglePoolStaking.AmountZero.selector);
        staking.withdraw(0);
    }

    /// @notice `withdraw` reverts when user has insufficient balance.
    /// @dev Covers `InsufficientBalance` branch.
    function testWithdraw_RevertOnInsufficient() public {
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.InsufficientBalance.selector);
        staking.withdraw(1);
    }

    /// @notice `getReward` reverts when user has no rewards.
    /// @dev Immediate claim after stake (same block) should revert.
    function testGetReward_RevertWhenZero() public {
        _stake(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.InsufficientBalance.selector);
        staking.getReward();
    }

    /// @notice `getReward` transfers to sender, emits `RewardPaid`, and zeroes owed amount.
    /// @dev Also checks user balance increment equals the owed amount.
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

    /// @notice `getRewardTo` reverts when user has no rewards.
    /// @dev Covers revert path for zero-owed `getRewardTo`.
    function testGetRewardTo_RevertWhenZero() public {
        _stake(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.InsufficientBalance.selector);
        staking.getRewardTo(bob);
    }

    /// @notice `exit` withdraws principal and rewards in one call; both events emitted when > 0.
    /// @dev Validates balances reset and rewards zeroed.
    function testExit_BothPrincipalAndReward() public {
        _stake(alice, 150 ether);
        vm.warp(block.timestamp + 6);

        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(alice, alice, 150 ether);
        vm.expectEmit(true, true, false, true);
        emit RewardPaid(alice, alice, 6 ether);
        staking.exit();
        vm.stopPrank();

        assertEq(staking.balanceOf(alice), 0, "stake not zeroed");
        assertEq(staking.earned(alice), 0, "rewards not zeroed");
    }

    /// @notice `exit` with reward only emits just `RewardPaid` (no principal).
    /// @dev Withdraw principal first, then call `exit` to claim owed rewards only.
    function testExit_RewardOnly() public {
        _stake(alice, 100 ether);
        vm.warp(block.timestamp + 4);
        _withdraw(alice, 100 ether);

        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true);
        emit RewardPaid(alice, alice, 4 ether);
        staking.exit();
        vm.stopPrank();

        assertEq(staking.balanceOf(alice), 0, "principal unexpectedly present");
        assertEq(staking.earned(alice), 0, "rewards not zeroed");
    }

    /// @notice `emergencyWithdraw` reverts when user has no stake.
    /// @dev Covers explicit `InsufficientBalance` revert.
    function testEmergencyWithdraw_RevertWhenNoStake() public {
        vm.prank(alice);
        vm.expectRevert(SinglePoolStaking.InsufficientBalance.selector);
        staking.emergencyWithdraw();
    }

    /// @notice After emergencyWithdraw, user does not accrue retroactively; new accrual starts only after restake.
    function testEmergencyWithdraw_NoBackAccrualThenRestake() public {
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
    /// @dev 10s @1 token/sec with two equal stakers → 5 tokens each (view path).
    function testAccrual_ProportionalDistribution() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        vm.warp(block.timestamp + 10); // total 10 tokens -> 5/5
        assertEq(staking.earned(alice), 5 ether, "alice share mismatch");
        assertEq(staking.earned(bob), 5 ether, "bob share mismatch");
    }

    /// @notice With no stakers, executing a rate change (which snaps global) does not consume reserves.
    /// @dev Triggers `_updateGlobal()` with `totalStaked == 0` via execute.
    function testAccrual_NoStakersDoesNotConsumeReserves() public {
        // fresh pool
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, stakeToken, 1e18, address(this), 1e18, 1);
        stakeToken.approve(address(s), type(uint256).max);
        s.fundRewards(1_000 ether);

        uint256 before = s.rewardReserves();

        // propose & execute a no-op rate change (same rate)
        s.proposeRewardRate(1e18);
        vm.warp(block.timestamp + 1);
        s.executeRewardRateChange();

        uint256 afterRes = s.rewardReserves();
        assertEq(afterRes, before, "reserves consumed without stakers");
    }

    /// @notice State-path reserve cap: accrual is limited by reserves and consumed on update.
    /// @dev View: `earned()` is capped; State: `getReward()` consumes at most the cap (reserves).
    function testAccrual_StatePathCappedByReserves() public {
        SinglePoolStaking s = new SinglePoolStaking(stakeToken, stakeToken, 1e18, address(this), 1e18, 1);
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
    /// @dev 10s @1 token/sec should accrue exactly 10 tokens (view path).
    function testStakeAndEarnBasic() public {
        _stake(alice, 100 ether);
        vm.warp(block.timestamp + 10);
        assertEq(staking.earned(alice), 10 ether, "basic earned mismatch");
    }

    /// @notice Ownable2Step: only pending owner can accept; after accept, only new owner can propose.
    /// @dev Also checks permissionless execution after delay.
    function testOwnership_TwoStepFlow() public {
        address newOwner = makeAddr("newOwner");

        // transferOwnership sets pending but does not change owner
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
    /// @dev Covers the `pending == 0` branch in `executeRewardRateChange`.
    function testExecuteRewardRateChange_Revert_NoPending() public {
        // Ensure there is no pending change
        // (Fresh state after Base setUp has no pending)
        vm.expectRevert(SinglePoolStaking.NoPendingRate.selector);
        staking.executeRewardRateChange();
    }

    /// @notice Executing before the delay elapses should revert.
    /// @dev Covers the "delay not met" branch in `executeRewardRateChange`.
    function testExecuteRewardRateChange_Revert_BeforeDelay() public {
        staking.proposeRewardRate(2e18);
        // Try to execute in the same block (delay not met)
        vm.expectRevert(); // use specific selector if exposed (e.g., SinglePoolStaking.RateChangeDelayNotMet.selector)
        staking.executeRewardRateChange();
    }

    /// @notice Only owner can cancel; cancel clears pending state and prevents execution.
    /// @dev Also asserts event and that execution after cancel reverts (no pending).
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
        vm.expectRevert(); // use specific selector if exposed
        staking.executeRewardRateChange();
    }

    /// @notice Proposing a new rate while one is already pending should overwrite the previous pending rate & timestamp.
    /// @dev Ensures the *latest* proposal is the one that takes effect after the new delay.
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
    /// @dev Hits the "zero rate" value path; useful for auditors evaluating pause semantics.
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
}
