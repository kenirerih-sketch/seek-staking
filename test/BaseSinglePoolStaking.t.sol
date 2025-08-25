// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SinglePoolStaking} from "../src/SinglePoolStaking.sol";
import {ERC20Token} from "./mocks/ERC20Token.sol";

/// @title SinglePoolStaking Base Test
/// @notice Shared setup & helpers for staking tests (unit & scenarios).
abstract contract SinglePoolStakingBase is Test {
    // Core under test
    SinglePoolStaking public staking;
    ERC20Token public stakeToken; // same as reward token

    // Actors
    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public chad = makeAddr("chad");
    address public vault = makeAddr("vault"); // auto-compound recipient

    // Mirror events for expectEmit
    event Staked(address indexed sender, address indexed to, uint256 amount);
    event RewardPaid(address indexed user, address indexed to, uint256 amount);
    event RewardRateProposed(uint256 proposedRate, uint64 executeAfter);
    event RewardRateChangeCanceled(uint256 canceledRate);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event RewardsFunded(address indexed from, uint256 amount, uint256 newReserves);
    event EmergencyWithdraw(address indexed user, address indexed to, uint256 amount);
    event RescueTokens(address indexed token, address indexed to, uint256 amount);
    event EmergencyExitEnabled(bool enabled);
    event MinStakeAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event WithdrawDelayUpdated(uint64 oldDelay, uint64 newDelay);
    event WithdrawalRequested(address indexed user, uint256 amount, uint64 unlockTimestamp);
    event WithdrawalCompleted(address indexed user, uint256 amount);
    event WithdrawalCanceled(address indexed user, uint256 amount);
    event Initialized(
        address indexed _stakeToken,
        address indexed _rewardToken,
        uint256 _initialRewardRate,
        address indexed initialOwner,
        uint256 _maxRewardRate,
        uint64 _rateChangeDelay,
        uint64 _initialWithdrawDelay,
        uint256 _minStakeAmount
    );

    /// @notice Deploys tokens, staking, and prefunds reserves.
    function setUp() public virtual {
        // Mint 1,000,000 tokens to owner
        stakeToken = new ERC20Token("Stake Token", "STK", 1_000_000 ether, owner);

        // Deploy staking: same token for stake & reward, rate = 1 token/s
        // params: (stakeToken, rewardToken, initialRate, owner, maxRate, rateChangeDelay, initialWithdrawDelay, minStakeAmount)
        staking = new SinglePoolStaking(
            stakeToken,
            stakeToken,
            1e18, // rewardRate = 1 token/s
            owner,
            5e18, // MAX_REWARD_RATE
            1, // RATE_CHANGE_DELAY (seconds)
            1, // withdrawDelay (seconds) — keeps tests snappy
            0 // minStakeAmount
        );

        // Distribute balances to actors
        bool aliceTransferSuccess = stakeToken.transfer(alice, 10_000 ether);
        require(aliceTransferSuccess, "Failed to transfer to Alice");
        bool bobTransferSuccess = stakeToken.transfer(bob, 10_000 ether);
        require(bobTransferSuccess, "Failed to transfer to Bob");
        bool chadTransferSuccess = stakeToken.transfer(chad, 10_000 ether);
        require(chadTransferSuccess, "Failed to transfer to Chad");

        // Prefund reserves (do NOT transfer directly)
        stakeToken.approve(address(staking), type(uint256).max);
        staking.fundRewards(100_000 ether);
    }

    /// @dev Approves max and stakes `amount` on behalf of `who`.
    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        stakeToken.approve(address(staking), type(uint256).max);
        staking.stake(amount);
        vm.stopPrank();
    }

    /// @dev Request a delayed withdrawal of `amount` for `who` (does not advance time).
    function _requestWithdrawal(address who, uint256 amount) internal {
        vm.prank(who);
        staking.requestWithdrawal(amount);
    }

    /// @dev Complete a previously requested withdrawal for `who` (assumes delay has elapsed).
    function _completeWithdrawal(address who) internal {
        vm.prank(who);
        staking.completeWithdrawal();
    }

    /// @dev Convenience: request withdrawal and then fast-forward by the contract's withdrawDelay, then complete.
    function _withdrawAfterDelay(address who, uint256 amount) internal {
        _requestWithdrawal(who, amount);
        uint64 delay = staking.withdrawDelay();
        vm.warp(block.timestamp + delay);
        _completeWithdrawal(who);
    }

    /// @dev Claims all accrued rewards for `who`.
    function _getReward(address who) internal {
        vm.prank(who);
        staking.getReward();
    }
}
