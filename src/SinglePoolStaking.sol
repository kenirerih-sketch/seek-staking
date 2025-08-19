// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*

████████╗ █████╗ ██╗     ██╗███████╗███╗   ███╗ █████╗ ███╗   ██╗
╚══██╔══╝██╔══██╗██║     ██║██╔════╝████╗ ████║██╔══██╗████╗  ██║
   ██║   ███████║██║     ██║███████╗██╔████╔██║███████║██╔██╗ ██║
   ██║   ██╔══██║██║     ██║╚════██║██║╚██╔╝██║██╔══██║██║╚██╗██║
   ██║   ██║  ██║███████╗██║███████║██║ ╚═╝ ██║██║  ██║██║ ╚████║
   ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝╚══════╝╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝

*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SinglePoolStaking
/// @notice Single-pool proportional reward staking with an adjustable emission rate.
/// @dev
/// - Rewards are **prefunded** (non-mintable). Accrual is gated by `rewardReserves` to ensure the pool
///   never accounts more than the available reserves (prevents over-accrual/insolvency).
/// - Supports **same-token** staking (STAKE_TOKEN == REWARD_TOKEN) safely via reserve gating,
///   so reward payouts never consume staked principal.
/// - Uses a global `rewardPerTokenStored` (scaled by 1e18) with per-user snapshots to account rewards.
/// - All mutative paths that depend on time call `_updateGlobal()` first to snapshot history.
/// - This implementation assumes **standard ERC-20 semantics** for staking token transfers
///   (i.e., no fee-on-transfer on `stake()`/`withdraw()`). `fundRewards()` is robust via balance delta.
///
contract SinglePoolStaking is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ====== Immutable tokens ======

    /// @notice Token users deposit as principal (a.k.a. staked token).
    /// @dev Immutable at construction.
    IERC20 public immutable STAKE_TOKEN;

    /// @notice Token paid out as rewards.
    /// @dev Immutable at construction; can be same as `STAKE_TOKEN`.
    IERC20 public immutable REWARD_TOKEN;

    // ====== Emissions config ======

    /// @notice Rewards emitted per second.
    /// @dev Owner can adjust via governance-timelocked flow (see `proposeRewardRate` / `executeRewardRateChange`).
    uint256 public rewardRate;

    /// @notice Last timestamp when global rewards were accounted (i.e., when `_updateGlobal()` last ran).
    /// @dev Stored as uint64 to save gas; comparisons cast to uint256 where needed.
    uint64 public lastUpdateTime;

    /// @notice Accumulated rewards per staked token, scaled by 1e18.
    /// @dev Global index used to compute per-user deltas. Monotonic non-decreasing.
    uint256 public rewardPerTokenStored;

    /// @notice Prefunded reward reserves available for **future** accrual.
    /// @dev `_updateGlobal()` consumes from this bucket (moves to "owed but unpaid");
    ///      user claims **do not** touch `rewardReserves`.
    uint256 public rewardReserves;

    // ====== Staking state ======

    /// @notice Total staked principal held by the contract.
    uint256 public totalStaked;

    /// @notice Per-user accounting data.
    /// @param balance Current staked principal.
    /// @param userRewardPerTokenPaid User snapshot of `rewardPerTokenStored` at last accounting.
    /// @param rewards Accrued but unclaimed rewards (accounted via snapshots).
    struct User {
        uint256 balance;
        uint256 userRewardPerTokenPaid;
        uint256 rewards;
    }

    /// @notice Mapping of user address to their staking accounting data.
    mapping(address => User) public users;

    // ====== Events ======

    /// @notice Emitted when `sender` stakes `amount` on behalf of `to`.
    /// @param sender The caller providing stake tokens.
    /// @param to The recipient whose balance increases.
    /// @param amount The amount staked.
    event Staked(address indexed sender, address indexed to, uint256 amount);

    /// @notice Emitted when `sender` withdraws `amount` to `to`.
    /// @param sender The user withdrawing their stake.
    /// @param to Recipient of returned principal (typically `sender`).
    /// @param amount The amount withdrawn.
    event Withdrawn(address indexed sender, address indexed to, uint256 amount);

    /// @notice Emitted when `user` is paid `amount` of rewards to `to`.
    /// @param user The user whose rewards were claimed/reset.
    /// @param to Recipient of rewards.
    /// @param amount The reward amount paid.
    event RewardPaid(address indexed user, address indexed to, uint256 amount);

    /// @notice Emitted when emission rate is updated.
    /// @param oldRate Previous `rewardRate`.
    /// @param newRate New `rewardRate`.
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when rewards are prefunded.
    /// @param from Funding source (owner).
    /// @param amount Net tokens received (uses balance delta, so may differ from input due to token quirks).
    /// @param newReserves Updated `rewardReserves` after funding.
    event RewardsFunded(address indexed from, uint256 amount, uint256 newReserves);

    /// @notice Emitted on emergency withdrawal (principal returned, rewards forfeited).
    /// @param user The user who exited via emergency withdrawal.
    /// @param to Recipient of principal (typically `user`).
    /// @param amount Principal returned.
    event EmergencyWithdraw(address indexed user, address indexed to, uint256 amount);

    /// @notice Emitted when unrelated ERC-20 tokens are rescued.
    /// @param token The rescued token address.
    /// @param to Recipient of rescued tokens.
    /// @param amount Amount rescued.
    event RescueTokens(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when a reward rate change is proposed with a timelock.
    /// @param proposedRate The proposed reward rate (tokens/sec).
    /// @param executeAfter The earliest timestamp when execution is allowed.
    event RewardRateProposed(uint256 proposedRate, uint64 executeAfter);

    /// @notice Emitted when a pending reward rate change is canceled.
    /// @param canceledRate The previously proposed reward rate that was canceled.
    event RewardRateChangeCanceled(uint256 canceledRate);

    // ====== Errors ======

    /// @notice Thrown when a provided amount is zero where a positive value is required.
    error AmountZero();

    /// @notice Thrown when a user attempts to withdraw/claim more than available.
    error InsufficientBalance();

    /// @notice Thrown when an operation targets an invalid token address or disallowed token.
    error InvalidToken();

    /// @notice Thrown when a proposed rate exceeds `MAX_REWARD_RATE`.
    /// @param requested The requested rate.
    /// @param max The maximum allowed rate.
    error RewardRateTooHigh(uint256 requested, uint256 max);

    /// @notice Thrown when trying to execute a rate change before the timelock elapses.
    /// @param executeAfter The timestamp after which execution is allowed.
    error RateChangeDelayNotMet(uint64 executeAfter);

    /// @notice Thrown when no pending reward rate exists to execute or cancel.
    error NoPendingRate();

    // ====== Governance params (constructor-initialized) ======

    /// @notice Maximum allowed emission rate (tokens/sec).
    uint256 public MAX_REWARD_RATE;

    /// @notice Delay required between proposing and executing a reward rate change.
    uint64 public RATE_CHANGE_DELAY;

    /// @notice Proposed reward rate pending execution after `rateChangeExecuteAfter`.
    uint256 public pendingRewardRate;

    /// @notice Earliest timestamp when the pending reward rate can be executed.
    uint64 public rateChangeExecuteAfter;

    // ====== Construction ======

    /// @notice Deploy the staking pool.
    /// @param _stakeToken ERC-20 token users deposit as principal.
    /// @param _rewardToken ERC-20 token used for rewards (may equal `_stakeToken`).
    /// @param _initialRewardRate Initial `rewardRate` in tokens per second.
    /// @param initialOwner Address to receive contract ownership.
    /// @param _maxRewardRate Governance max for `rewardRate` (tokens/sec).
    /// @param _rateChangeDelay Timelock delay for rate changes (in seconds).
    /// @dev Sets `lastUpdateTime` to `block.timestamp` and enforces `_initialRewardRate <= _maxRewardRate`.
    constructor(
        IERC20 _stakeToken,
        IERC20 _rewardToken,
        uint256 _initialRewardRate,
        address initialOwner,
        uint256 _maxRewardRate,
        uint64 _rateChangeDelay
    ) Ownable(initialOwner) {
        if (address(_stakeToken) == address(0)) revert InvalidToken();
        if (address(_rewardToken) == address(0)) revert InvalidToken();

        STAKE_TOKEN = _stakeToken;
        REWARD_TOKEN = _rewardToken;

        MAX_REWARD_RATE = _maxRewardRate;
        RATE_CHANGE_DELAY = _rateChangeDelay;

        if (_initialRewardRate > MAX_REWARD_RATE) revert RewardRateTooHigh(_initialRewardRate, MAX_REWARD_RATE);
        rewardRate = _initialRewardRate;

        lastUpdateTime = uint64(block.timestamp);
    }

    // =========================
    //          Views
    // =========================

    /// @notice Current staked balance for `account`.
    /// @param account The user to query.
    /// @return amount The staked principal.
    function balanceOf(address account) external view returns (uint256 amount) {
        return users[account].balance;
    }

    /// @notice The timestamp used for reward calculations.
    /// @dev Returns `block.timestamp`. Split out as a function for clarity/extensibility.
    /// @return ts The timestamp at which rewards are applicable.
    function lastTimeRewardApplicable() public view returns (uint256 ts) {
        return block.timestamp;
    }

    /// @notice The current global rewards-per-token index (scaled by 1e18).
    /// @dev
    /// - If `totalStaked == 0`, returns the stored value (no accrual).
    /// - Applies reserve cap: at most `rewardReserves` may be accounted.
    /// @return rpt The current `rewardPerToken` value including any un-snapshotted elapsed window (view path).
    function rewardPerToken() public view returns (uint256 rpt) {
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

    /// @notice View the total rewards owed to `account` at the current timestamp.
    /// @dev Computed as: `u.rewards + u.balance * (rewardPerToken() - u.userRewardPerTokenPaid) / 1e18`.
    ///      This is a **view**; reserves are not consumed here (consumption happens on state updates).
    /// @param account The user to query.
    /// @return amount The accrued but unclaimed rewards.
    function earned(address account) public view returns (uint256 amount) {
        User memory u = users[account];
        uint256 rpt = rewardPerToken();
        return u.rewards + (u.balance * (rpt - u.userRewardPerTokenPaid)) / 1e18;
    }

    // =========================
    //          Admin
    // =========================

    /// @notice Propose a new reward emission rate (tokens per second), subject to a delay.
    /// @dev Enforces `MAX_REWARD_RATE`. Allows pausing with `0`. Emits `RewardRateProposed`.
    /// @param _newRate The proposed `rewardRate` value (tokens/sec).
    function proposeRewardRate(uint256 _newRate) external onlyOwner {
        if (_newRate > MAX_REWARD_RATE) revert RewardRateTooHigh(_newRate, MAX_REWARD_RATE);
        uint64 execAfter = uint64(block.timestamp) + RATE_CHANGE_DELAY;

        pendingRewardRate = _newRate;
        rateChangeExecuteAfter = execAfter;

        emit RewardRateProposed(_newRate, execAfter);
    }

    /// @notice Execute a previously proposed reward rate after the timelock elapses.
    /// @dev Snapshots global accounting first, then updates `rewardRate` and emits `RewardRateUpdated`.
    function executeRewardRateChange() external {
        uint64 execAfter = rateChangeExecuteAfter;
        if (execAfter == 0) revert NoPendingRate();
        if (block.timestamp < execAfter) revert RateChangeDelayNotMet(execAfter);

        _updateGlobal();

        uint256 old = rewardRate;
        uint256 next = pendingRewardRate;

        // clear pending first
        pendingRewardRate = 0;
        rateChangeExecuteAfter = 0;

        emit RewardRateUpdated(old, next);
        rewardRate = next;
    }

    /// @notice Cancel a pending reward rate change.
    /// @dev Clears pending state and emits `RewardRateChangeCanceled`.
    function cancelRewardRateChange() external onlyOwner {
        uint256 oldPending = pendingRewardRate;
        if (oldPending == 0) revert NoPendingRate();

        pendingRewardRate = 0;
        rateChangeExecuteAfter = 0;

        emit RewardRateChangeCanceled(oldPending);
    }

    /// @notice Prefund rewards into the pool.
    /// @dev
    /// - Uses **balance delta** to compute the net tokens actually received, which makes it robust
    ///   to some non-standard ERC-20 implementations (e.g., fee-on-transfer).
    /// - The **net** received amount is credited to `rewardReserves`.
    /// - Reentrancy is guarded.
    /// @param amount The nominal amount to transfer from the owner.
    function fundRewards(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert AmountZero();

        uint256 beforeBal = REWARD_TOKEN.balanceOf(address(this));
        REWARD_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = REWARD_TOKEN.balanceOf(address(this)) - beforeBal;
        if (received == 0) revert AmountZero(); // defensive: nothing moved

        rewardReserves += received;
        emit RewardsFunded(msg.sender, received, rewardReserves);
    }

    /// @notice Rescue unrelated tokens accidentally sent to this contract.
    /// @dev Cannot rescue `STAKE_TOKEN` or `REWARD_TOKEN`.
    /// @param token The ERC-20 token to rescue.
    /// @param to Recipient for rescued tokens.
    /// @param amount The amount to rescue.
    function rescueTokens(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (address(token) == address(STAKE_TOKEN)) revert InvalidToken();
        if (address(token) == address(REWARD_TOKEN)) revert InvalidToken();
        token.safeTransfer(to, amount);
        emit RescueTokens(address(token), to, amount);
    }

    // =========================
    //       User actions
    // =========================

    /// @notice Stake `amount` for yourself.
    /// @param amount Amount of `STAKE_TOKEN` to deposit.
    function stake(uint256 amount) external {
        stakeFor(amount, msg.sender);
    }

    /// @notice Stake `amount` on behalf of `to`.
    /// @dev
    /// - Updates global & user accounting first to snapshot prior rewards.
    /// - Transfers `amount` from `msg.sender` to the pool.
    /// - **Note:** If `STAKE_TOKEN` is fee-on-transfer, the recipient may receive less than `amount`,
    ///   and this function does **not** use balance delta; such tokens are not supported.
    /// @param amount Amount of `STAKE_TOKEN` to deposit.
    /// @param to Recipient whose stake balance increases.
    function stakeFor(uint256 amount, address to) public nonReentrant {
        if (amount == 0) revert AmountZero();

        _updateUser(to);

        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        users[to].balance += amount;
        totalStaked += amount;

        emit Staked(msg.sender, to, amount);
    }

    /// @notice Withdraw `amount` of your staked principal.
    /// @dev Updates global & user accounting first; accrued rewards remain unclaimed.
    /// @param amount Amount to withdraw.
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

    /// @notice Claim your rewards to your own address.
    /// @dev Updates accounting and pays out the owed rewards; resets `users[msg.sender].rewards` to 0.
    function getReward() external nonReentrant {
        _updateUser(msg.sender);

        uint256 reward = users[msg.sender].rewards;
        if (reward == 0) revert InsufficientBalance();
        users[msg.sender].rewards = 0;

        REWARD_TOKEN.safeTransfer(msg.sender, reward);
        emit RewardPaid(msg.sender, msg.sender, reward);
    }

    /// @notice Claim rewards to a custom address (e.g., auto-compounder).
    /// @dev Updates accounting and pays out the owed rewards to `to`; resets internal owed to 0.
    /// @param to Recipient of the rewards.
    function getRewardTo(address to) external nonReentrant {
        _updateUser(msg.sender);

        uint256 reward = users[msg.sender].rewards;
        if (reward == 0) revert InsufficientBalance();
        users[msg.sender].rewards = 0;

        REWARD_TOKEN.safeTransfer(to, reward);
        emit RewardPaid(msg.sender, to, reward);
    }

    /// @notice Withdraw principal and claim rewards in one transaction.
    /// @dev Updates accounting, then transfers principal and rewards if non-zero; emits events accordingly.
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

    /// @notice Withdraw staked principal immediately, **forfeiting** any accrued rewards.
    /// @dev
    /// - Calls `_updateGlobal()` (not `_updateUser`) to keep global math consistent.
    /// - Zeros user principal & rewards and snaps `userRewardPerTokenPaid` to the latest global index.
    function emergencyWithdraw() external nonReentrant {
        _updateGlobal(); // keep global math consistent

        User storage u = users[msg.sender];
        uint256 amount = u.balance;
        if (amount == 0) revert InsufficientBalance();

        // Forfeit rewards and reset state
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

    /// @notice Update global reward accounting up to `block.timestamp`.
    /// @dev
    /// - No-op if `current == lastUpdateTime`.
    /// - If `totalStaked > 0`, increases `rewardPerTokenStored` by:
    ///       `deltaRPT = min(elapsed * rewardRate, rewardReserves) * 1e18 / totalStaked`
    ///   and **consumes** the same (uncapped) `newly` from `rewardReserves`.
    /// - Always updates `lastUpdateTime` to `current`.
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

    /// @notice Update a user's accounting against the latest global snapshot.
    /// @dev
    /// - Calls `_updateGlobal()` first (ensuring global index is up to date).
    /// - If user has a positive balance, accrues:
    ///       `u.rewards += u.balance * (rewardPerTokenStored - u.userRewardPerTokenPaid) / 1e18`
    /// - Sets `u.userRewardPerTokenPaid = rewardPerTokenStored`.
    /// @param account The user to update.
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
