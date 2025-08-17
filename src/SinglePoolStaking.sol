// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SinglePoolStaking
/// @notice Single-pool proportional reward staking with adjustable emission rate.
/// @dev Rewards are pre-funded (non-mintable). Uses a `rewardReserves` bucket to gate accrual,
///      which keeps same-token staking (stake==reward) safe from paying out staked principal.
contract SinglePoolStaking is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ====== Immutable tokens ======
    IERC20 public immutable STAKE_TOKEN;
    IERC20 public immutable REWARD_TOKEN;

    // ====== Emissions config ======
    /// @notice Rewards per second (can be changed by owner; snapshot first).
    uint256 public rewardRate;

    /// @notice Last timestamp when rewards were globally accounted.
    uint64 public lastUpdateTime;

    /// @notice Accumulated rewards per staked token, scaled by 1e18.
    uint256 public rewardPerTokenStored;

    /// @notice Prefunded reward reserves available for *future* accrual.
    ///         `_updateGlobal()` consumes from this bucket; claims do NOT touch it.
    uint256 public rewardReserves;

    // ====== Staking state ======
    uint256 public totalStaked;

    struct User {
        uint256 balance; // staked amount
        uint256 userRewardPerTokenPaid; // snapshot at last accounting
        uint256 rewards; // accrued but unclaimed
    }

    mapping(address => User) public users;

    // ====== Events ======
    event Staked(address indexed sender, address indexed to, uint256 amount);
    event Withdrawn(address indexed sender, address indexed to, uint256 amount);
    event RewardPaid(address indexed user, address indexed to, uint256 amount);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event RewardsFunded(address indexed from, uint256 amount, uint256 newReserves);
    event EmergencyWithdraw(address indexed user, address indexed to, uint256 amount);
    event RescueTokens(address indexed token, address indexed to, uint256 amount);

    // ====== Errors ======
    error AmountZero();
    error InsufficientBalance();
    error InvalidToken();

    constructor(IERC20 _stakeToken, IERC20 _rewardToken, uint256 _initialRewardRate, address initialOwner)
        Ownable(initialOwner)
    {
        if (address(_stakeToken) == address(0)) revert InvalidToken();
        if (address(_rewardToken) == address(0)) revert InvalidToken();

        STAKE_TOKEN = _stakeToken;
        REWARD_TOKEN = _rewardToken;
        rewardRate = _initialRewardRate;
        lastUpdateTime = uint64(block.timestamp);
    }

    // =========================
    //          Views
    // =========================

    function balanceOf(address account) external view returns (uint256) {
        return users[account].balance;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;

        uint256 elapsed = lastTimeRewardApplicable() - uint256(lastUpdateTime);
        if (elapsed == 0) return rewardPerTokenStored;

        uint256 newly = elapsed * rewardRate;
        if (newly > rewardReserves) {
            newly = rewardReserves; // cap by reserves so we never over-accrue
        }

        // 1e18 scaling
        return rewardPerTokenStored + (newly * 1e18) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        User memory u = users[account];
        uint256 rpt = rewardPerToken();
        return u.rewards + (u.balance * (rpt - u.userRewardPerTokenPaid)) / 1e18;
    }

    // =========================
    //          Admin
    // =========================

    /// @notice Adjust rewards per second. Snapshots accounting first so history is preserved.
    function setRewardRate(uint256 _newRate) external onlyOwner {
        _updateGlobal();
        emit RewardRateUpdated(rewardRate, _newRate);
        rewardRate = _newRate;
    }

    /// @notice Prefund rewards. Works when stake == reward or different tokens.
    /// Uses balance delta to be robust to non-standard ERC20s.
    function fundRewards(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert AmountZero();

        uint256 beforeBal = REWARD_TOKEN.balanceOf(address(this));
        REWARD_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = REWARD_TOKEN.balanceOf(address(this)) - beforeBal;
        if (received == 0) revert AmountZero(); // defensive

        rewardReserves += received;
        emit RewardsFunded(msg.sender, received, rewardReserves);
    }

    /// @notice Rescue unrelated tokens (never the stake or reward token).
    function rescueTokens(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (address(token) == address(STAKE_TOKEN)) revert InvalidToken();
        if (address(token) == address(REWARD_TOKEN)) revert InvalidToken();
        token.safeTransfer(to, amount);
        emit RescueTokens(address(token), to, amount);
    }

    // =========================
    //       User actions
    // =========================

    function stake(uint256 amount) external {
        stakeFor(amount, msg.sender);
    }

    function stakeFor(uint256 amount, address to) public nonReentrant {
        if (amount == 0) revert AmountZero();

        _updateUser(to);

        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        users[to].balance += amount;
        totalStaked += amount;

        emit Staked(msg.sender, to, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();

        _updateUser(msg.sender);

        User storage u = users[msg.sender];
        if (u.balance < amount) revert InsufficientBalance();

        u.balance -= amount;
        totalStaked -= amount;

        STAKE_TOKEN.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, msg.sender, amount);
    }

    function getReward() external nonReentrant {
        _updateUser(msg.sender);

        uint256 reward = users[msg.sender].rewards;
        if (reward == 0) revert InsufficientBalance();
        users[msg.sender].rewards = 0;

        REWARD_TOKEN.safeTransfer(msg.sender, reward);
        emit RewardPaid(msg.sender, msg.sender, reward);
    }

    /// @notice Claim rewards to a custom address (e.g., auto-compounder).
    function getRewardTo(address to) external nonReentrant {
        _updateUser(msg.sender);

        uint256 reward = users[msg.sender].rewards;
        if (reward == 0) revert InsufficientBalance();
        users[msg.sender].rewards = 0;

        REWARD_TOKEN.safeTransfer(to, reward);
        emit RewardPaid(msg.sender, to, reward);
    }

    /// @notice Withdraw stake and claim rewards in one tx.
    function exit() external nonReentrant {
        _updateUser(msg.sender);

        User storage u = users[msg.sender];
        uint256 amount = u.balance;
        uint256 reward = u.rewards;

        u.balance = 0;
        u.rewards = 0;
        totalStaked -= amount;

        if (amount > 0) {
            STAKE_TOKEN.safeTransfer(msg.sender, amount);
            emit Withdrawn(msg.sender, msg.sender, amount);
        }
        if (reward > 0) {
            REWARD_TOKEN.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, msg.sender, reward);
        }
    }

    /// @notice Withdraw principal immediately, forfeiting any accrued rewards.
    function emergencyWithdraw() external nonReentrant {
        _updateGlobal(); // keep global math consistent

        User storage u = users[msg.sender];
        uint256 amount = u.balance;
        if (amount == 0) revert InsufficientBalance();

        // Forfeit rewards
        u.balance = 0;
        u.rewards = 0;
        u.userRewardPerTokenPaid = rewardPerTokenStored;

        totalStaked -= amount;

        STAKE_TOKEN.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, msg.sender, amount);
    }

    // =========================
    //        Internals
    // =========================

    function _updateGlobal() internal {
        uint256 current = block.timestamp;
        uint256 last = uint256(lastUpdateTime);
        if (current == last) {
            return;
        }

        if (totalStaked > 0) {
            uint256 elapsed = current - last;
            uint256 newly = elapsed * rewardRate;

            // Cap accrual by reserves, so we never over-account rewards
            if (newly > rewardReserves) {
                newly = rewardReserves;
            }

            if (newly > 0) {
                rewardPerTokenStored += (newly * 1e18) / totalStaked;
                rewardReserves -= newly; // move from reserves to "owed but unpaid"
            }
        }

        lastUpdateTime = uint64(current);
    }

    function _updateUser(address account) internal {
        _updateGlobal();

        User storage u = users[account];
        if (u.balance > 0) {
            uint256 delta = rewardPerTokenStored - u.userRewardPerTokenPaid;
            if (delta != 0) {
                u.rewards += (u.balance * delta) / 1e18;
            }
        }
        u.userRewardPerTokenPaid = rewardPerTokenStored;
    }
}
