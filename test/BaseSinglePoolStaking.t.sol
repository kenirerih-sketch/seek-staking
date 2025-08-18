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
    event Withdrawn(address indexed sender, address indexed to, uint256 amount);
    event RewardPaid(address indexed user, address indexed to, uint256 amount);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event RewardsFunded(address indexed from, uint256 amount, uint256 newReserves);
    event EmergencyWithdraw(address indexed user, address indexed to, uint256 amount);
    event RescueTokens(address indexed token, address indexed to, uint256 amount);

    /// @notice Deploys tokens, staking, and prefunds reserves.
    function setUp() public virtual {
        // Mint 1,000,000 tokens to owner
        stakeToken = new ERC20Token("Stake Token", "STK", 1_000_000 ether, owner);

        // Deploy staking: same token for stake & reward, rate = 1 token/s
        staking = new SinglePoolStaking(stakeToken, stakeToken, 1e18, owner);

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

    /// @dev Withdraws `amount` of staked tokens for `who`.
    function _withdraw(address who, uint256 amount) internal {
        vm.prank(who);
        staking.withdraw(amount);
    }

    /// @dev Claims all accrued rewards for `who`.
    function _getReward(address who) internal {
        vm.prank(who);
        staking.getReward();
    }
}
