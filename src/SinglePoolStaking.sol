// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

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

    /// @notice Token users deposit as principal (a.k.a. staked token). Standard ERC-20 (no fee/rebase).
    /// @dev Immutable at construction.
    IERC20 public immutable STAKE_TOKEN;

    /// @notice Token paid out as rewards. Standard ERC-20 (no fee/rebase).
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

    /// @notice Flag to enable emergency exit mode.
    /// @dev When enabled, users can withdraw their principal immediately, forfeiting any accrued rewards.
    ///      This is a governance-controlled feature that can be toggled by the owner.
    ///      When disabled, users must use the delayed withdrawal path to claim their principal.
    ///      This flag is set to `false` by default and can be toggled by the owner.
    bool public emergencyExitEnabled;

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

    // ====== Delayed withdrawal state ======

    /// @notice Lock duration between withdrawal request and claim (in seconds).
    /// @dev Configurable by owner. If set to 0, withdrawals can be completed immediately after requesting.
    uint64 public withdrawDelay;

    /// @notice User withdrawal request data.
    /// @param amount Requested amount that was removed from staking and no longer earns rewards.
    /// @param unlockTimestamp When the withdrawal can be completed.
    struct PendingWithdrawal {
        uint256 amount;
        uint64 unlockTimestamp;
    }

    /// @notice Mapping of user to their single active pending withdrawal (if any).
    mapping(address => PendingWithdrawal) public pendingWithdrawals;

    // ====== Events ======

    /// @notice Emitted when the contract is initialized with its parameters.
    /// @param _stakeToken The token users deposit as principal.
    /// @param _rewardToken The token used for rewards (may equal `_stakeToken`).
    /// @param _initialRewardRate Initial `rewardRate` in tokens per second.
    /// @param initialOwner Address to receive contract ownership.
    /// @param _maxRewardRate Governance max for `rewardRate` (tokens/sec).
    /// @param _rateChangeDelay Timelock delay for rate changes (in seconds).
    /// @param _initialWithdrawDelay Initial locked withdrawal delay (in seconds).
    /// @param _minStakeAmount Minimum amount required to stake.
    /// @dev Sets `lastUpdateTime` to `block.timestamp` and enforces `_initialRewardRate <= _maxRewardRate`.
    ///      Emits `RewardRateUpdated`, `WithdrawDelayUpdated`, and `MinStakeAmountUpdated` events.
    /// @dev This event is emitted when the contract is initialized with its parameters.
    ///      It provides a record of the initial configuration of the staking pool.
    ///      This is useful for transparency and auditing purposes, allowing users to
    ///      verify the initial setup of the staking contract.
    /// @dev This event is emitted when the contract is initialized with its parameters.
    event Initialized(
        address indexed _stakeToken,
        address indexed _rewardToken,
        uint256 _initialRewardRate,
        address indexed initialOwner,
        uint256 _maxRewardRate,
        uint256 _minRewardRate,
        uint64 _rateChangeDelay,
        uint64 _initialWithdrawDelay,
        uint256 _minStakeAmount
    );

    /// @notice Emitted when emergency exit mode is enabled/disabled.
    /// @dev When enabled, users can withdraw their principal immediately, forfeiting any accrued rewards.
    ///      When disabled, users must use the delayed withdrawal path to claim their principal.
    /// @param enabled True if emergency exits are enabled; false if disabled.
    event EmergencyExitEnabled(bool enabled);

    /// @notice Emitted when the minimum stake amount is updated.
    /// @param oldAmount The previous minimum stake amount.
    /// @param newAmount The new minimum stake amount.
    /// @dev This is a governance-controlled parameter that can be adjusted by the owner.
    ///      It sets the minimum amount required for users to stake or withdraw.
    ///      This is useful to prevent dust transactions and ensure meaningful participation.
    event MinStakeAmountUpdated(uint256 oldAmount, uint256 newAmount);

    /// @notice Emitted when `sender` stakes `amount` on behalf of `to`.
    /// @param sender The caller providing stake tokens.
    /// @param to The recipient whose balance increases.
    /// @param amount The amount staked.
    event Staked(address indexed sender, address indexed to, uint256 amount);

    /// @notice Emitted when `user` is paid `amount` of rewards to `to`.
    /// @param user The user whose rewards were claimed/reset.
    /// @param to Recipient of rewards.
    /// @param amount The reward amount paid.
    event RewardPaid(address indexed user, address indexed to, uint256 amount);

    /// @notice Emitted when emission rate is updated.
    /// @param oldRate Previous `rewardRate`.
    /// @param newRate New `rewardRate`.
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when a reward rate change is proposed with a timelock.
    /// @param proposedRate The proposed reward rate (tokens/sec).
    /// @param executeAfter The earliest timestamp when execution is allowed.
    event RewardRateProposed(uint256 proposedRate, uint64 executeAfter);

    /// @notice Emitted when a pending reward rate change is canceled.
    /// @param canceledRate The previously proposed reward rate that was canceled.
    event RewardRateChangeCanceled(uint256 canceledRate);

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

    /// @notice Emitted when a delayed withdrawal is requested.
    /// @param user The address requesting withdrawal.
    /// @param amount Amount removed from staking and placed into the pending queue.
    /// @param unlockTimestamp Timestamp when withdrawal becomes claimable.
    event WithdrawalRequested(address indexed user, uint256 amount, uint64 unlockTimestamp);

    /// @notice Emitted when a pending withdrawal is completed and principal is transferred out.
    /// @param user The address completing withdrawal.
    /// @param amount The amount withdrawn.
    event WithdrawalCompleted(address indexed user, uint256 amount);

    /// @notice Emitted when a pending withdrawal is canceled and principal is re-staked.
    /// @param user The address canceling withdrawal.
    /// @param amount The amount returned to staking.
    event WithdrawalCanceled(address indexed user, uint256 amount);

    /// @notice Emitted when the withdrawal delay is updated.
    /// @param oldDelay Previous delay (seconds).
    /// @param newDelay New delay (seconds).
    event WithdrawDelayUpdated(uint64 oldDelay, uint64 newDelay);

    // ====== Errors ======

    /// @notice Thrown when emergency exits are disabled and a user tries to withdraw immediately.
    error EmergencyExitDisabled();

    /// @notice Thrown when a provided amount is zero where a positive value is required.
    error AmountZero();

    /// @notice Thrown when a requested delay exceeds the maximum allowed.
    /// @param requested The requested delay in seconds.
    /// @param max The maximum allowed delay in seconds.
    error DelayTooLong(uint64 requested, uint64 max);

    /// @notice Thrown when a provided amount is below the minimum required for staking/unstaking.
    /// @param provided The amount provided by the user.
    /// @param minRequired The minimum amount required to proceed.
    error AmountTooLow(uint256 provided, uint256 minRequired);

    /// @notice Thrown when a user attempts to withdraw/claim more than available.
    error InsufficientBalance();

    /// @notice Thrown when an operation targets an invalid token address or disallowed token.
    error InvalidToken();

    /// @notice Thrown when a proposed rate exceeds `MAX_REWARD_RATE`.
    /// @param requested The requested rate.
    /// @param max The maximum allowed rate.
    error RewardRateTooHigh(uint256 requested, uint256 max);

    /// @notice Thrown when a proposed reward rate is below the minimum allowed rate.
    /// @param requested The requested rate.
    /// @param min The minimum allowed rate.
    error RewardRateTooLow(uint256 requested, uint256 min);

    /// @notice Thrown when trying to execute a rate change before the timelock elapses.
    /// @param executeAfter The timestamp after which execution is allowed.
    error RateChangeDelayNotMet(uint64 executeAfter);

    /// @notice Thrown when no pending reward rate exists to execute or cancel.
    error NoPendingRate();

    /// @notice Thrown when a user already has an active pending withdrawal.
    error PendingWithdrawalExists();

    /// @notice Thrown when a user has no pending withdrawal to act upon.
    error NoPendingWithdrawal();

    /// @notice Thrown when attempting to complete a withdrawal before it's unlocked.
    /// @param unlockTimestamp The timestamp when completion becomes allowed.
    error WithdrawalNotUnlocked(uint64 unlockTimestamp);

    // ====== Governance params (constructor-initialized) ======

    /// @notice Maximum allowed emission rate (tokens/sec).
    uint256 public immutable MAX_REWARD_RATE;

    /// @notice Minimum allowed emission rate (tokens/sec). Set to 0 to allow pausing.
    uint256 public immutable MIN_REWARD_RATE;

    /// @notice Maximum withdraw delay (in seconds).
    /// @dev This is a governance-controlled parameter that can be adjusted by the owner.
    ///      It sets the maximum delay for withdrawals, ensuring that users cannot set excessively long delays
    uint32 public constant MAX_WITHDRAW_DELAY = 30 days;

    /// @notice Delay required between proposing and executing a reward rate change.
    uint64 public immutable RATE_CHANGE_DELAY;

    /// @notice Proposed reward rate pending execution after `rateChangeExecuteAfter`.
    uint256 public pendingRewardRate;

    /// @notice Earliest timestamp when the pending reward rate can be executed.
    uint64 public rateChangeExecuteAfter;

    /// @notice Minimum amount required to stake/unstake
    uint256 public minStakeAmount;

    // ====== Construction ======

    /// @notice Deploy the staking pool.
    /// @param _stakeToken ERC-20 token users deposit as principal.
    /// @param _rewardToken ERC-20 token used for rewards (may equal `_stakeToken`).
    /// @param _initialRewardRate Initial `rewardRate` in tokens per second.
    /// @param initialOwner Address to receive contract ownership.
    /// @param _maxRewardRate Governance max for `rewardRate` (tokens/sec).
    /// @param _minRewardRate Governance min for `rewardRate` (tokens/sec). Set to 0 to allow pausing.
    /// @param _rateChangeDelay Timelock delay for rate changes (in seconds).
    /// @param _initialWithdrawDelay Initial locked withdrawal delay (in seconds).
    /// @param _minStakeAmount Minimum amount required to stake or withdraw.
    /// @dev Sets `lastUpdateTime` to `block.timestamp` and enforces `_minRewardRate <= _initialRewardRate <= _maxRewardRate`.
    constructor(
        IERC20 _stakeToken,
        IERC20 _rewardToken,
        uint256 _initialRewardRate,
        address initialOwner,
        uint256 _maxRewardRate,
        uint256 _minRewardRate,
        uint64 _rateChangeDelay,
        uint64 _initialWithdrawDelay,
        uint256 _minStakeAmount
    ) Ownable(initialOwner) {
        if (address(_stakeToken) == address(0)) revert InvalidToken();
        if (address(_rewardToken) == address(0)) revert InvalidToken();
        if (_initialWithdrawDelay > MAX_WITHDRAW_DELAY) revert DelayTooLong(_initialWithdrawDelay, MAX_WITHDRAW_DELAY);
        if (_minRewardRate > _maxRewardRate) revert RewardRateTooLow(_minRewardRate, _maxRewardRate);
        if (_initialRewardRate < _minRewardRate) revert RewardRateTooLow(_initialRewardRate, _minRewardRate);
        if (_initialRewardRate > _maxRewardRate) revert RewardRateTooHigh(_initialRewardRate, _maxRewardRate);

        STAKE_TOKEN = _stakeToken;
        REWARD_TOKEN = _rewardToken;
        MAX_REWARD_RATE = _maxRewardRate;
        MIN_REWARD_RATE = _minRewardRate;
        RATE_CHANGE_DELAY = _rateChangeDelay;

        rewardRate = _initialRewardRate;
        withdrawDelay = _initialWithdrawDelay;
        minStakeAmount = _minStakeAmount;
        lastUpdateTime = uint64(block.timestamp);

        emit Initialized(
            address(_stakeToken),
            address(_rewardToken),
            _initialRewardRate,
            initialOwner,
            _maxRewardRate,
            _minRewardRate,
            _rateChangeDelay,
            _initialWithdrawDelay,
            _minStakeAmount
        );
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

    /// @notice View the total rewards reserves runway in seconds.
    /// @dev If `rewardRate == 0`, returns `type(uint256).max` (infinite runway).
    ///      Otherwise, computes `rewardReserves / rewardRate`.
    /// @return seconds The number of seconds the current reserves can sustain at the current rate.
    function rewardsRunwaySeconds() external view returns (uint256) {
        if (rewardRate == 0) return type(uint256).max;
        return rewardReserves / rewardRate;
    }

    // =========================
    //          Admin
    // =========================

    /// @notice Propose a new reward emission rate (tokens per second), subject to a delay.
    /// @dev Enforces `MIN_REWARD_RATE` and `MAX_REWARD_RATE`. Allows pausing with `0` if `MIN_REWARD_RATE` is 0. Emits `RewardRateProposed`.
    /// @param _newRate The proposed `rewardRate` value (tokens/sec).
    function proposeRewardRate(uint256 _newRate) external onlyOwner {
        if (_newRate < MIN_REWARD_RATE) revert RewardRateTooLow(_newRate, MIN_REWARD_RATE);
        if (_newRate > MAX_REWARD_RATE) revert RewardRateTooHigh(_newRate, MAX_REWARD_RATE);
        uint64 execAfter = uint64(block.timestamp) + RATE_CHANGE_DELAY;

        pendingRewardRate = _newRate;
        rateChangeExecuteAfter = execAfter;

        emit RewardRateProposed(_newRate, execAfter);
    }

    /// @notice Execute a previously proposed reward rate after the timelock elapses. Intentionally callable by anyone.
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

    /// @notice Set the withdrawal delay (in seconds) for delayed withdrawals.
    /// @dev Emits `WithdrawDelayUpdated`. Can be set to 0 to allow immediate completion after request.
    /// @param newDelay The new delay duration in seconds.
    function setWithdrawDelay(uint64 newDelay) external onlyOwner {
        if (newDelay > MAX_WITHDRAW_DELAY) revert DelayTooLong(newDelay, MAX_WITHDRAW_DELAY);
        uint64 old = withdrawDelay;
        withdrawDelay = newDelay;
        emit WithdrawDelayUpdated(old, newDelay);
    }

    /// @notice Enable/disable immediate emergency exits that forfeit rewards.
    /// @dev Default should be false in production; only enable during incidents.
    /// @param enabled True to enable emergency exits; false to disable.
    function setEmergencyExitEnabled(bool enabled) external onlyOwner {
        emergencyExitEnabled = enabled;
        emit EmergencyExitEnabled(enabled);
    }

    // @notice Set the minimum stake amount required for staking or withdrawing.
    /// @dev Emits `MinStakeAmountUpdated`. This is a governance-controlled parameter that can be adjusted by the owner.
    ///      It sets the minimum amount required for users to stake or withdraw.
    ///      This is useful to prevent dust transactions and ensure meaningful participation.
    /// @param newMinStakeAmount The new minimum stake amount in tokens.
    function setMinStakeAmount(uint256 newMinStakeAmount) external onlyOwner {
        uint256 oldMinStakeAmount = minStakeAmount;
        minStakeAmount = newMinStakeAmount;
        emit MinStakeAmountUpdated(oldMinStakeAmount, newMinStakeAmount);
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
        if (amount < minStakeAmount) revert AmountTooLow(amount, minStakeAmount);

        _updateUser(to);

        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        users[to].balance += amount;
        totalStaked += amount;

        emit Staked(msg.sender, to, amount);
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

    /// @notice Initiate a delayed withdrawal request.
    /// @dev
    /// - Updates accounting, then **removes** `amount` from staking so it stops earning immediately.
    /// - Records a single pending withdrawal that becomes claimable after `withdrawDelay`.
    /// - Reverts if a pending withdrawal already exists for the caller.
    /// @param amount Amount of staked tokens to request withdrawal for.
    function requestWithdrawal(uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();

        _updateUser(msg.sender);

        User storage u = users[msg.sender];
        if (u.balance < amount) revert InsufficientBalance();

        PendingWithdrawal storage p = pendingWithdrawals[msg.sender];
        if (p.amount > 0) revert PendingWithdrawalExists();

        // Remove principal from staking (stops rewards immediately)
        u.balance -= amount;
        totalStaked -= amount;

        uint64 unlockAt = uint64(block.timestamp) + withdrawDelay;
        p.amount = amount;
        p.unlockTimestamp = unlockAt;

        emit WithdrawalRequested(msg.sender, amount, unlockAt);
    }

    /// @notice Complete a previously requested withdrawal after the delay.
    /// @dev
    /// - Does **not** modify rewards; rewards remain claimable separately at any time.
    /// - Clears pending state before transfer to prevent reentrancy issues.
    function completeWithdrawal() external nonReentrant {
        PendingWithdrawal storage p = pendingWithdrawals[msg.sender];
        uint256 amount = p.amount;
        if (amount == 0) revert NoPendingWithdrawal();
        uint64 unlockAt = p.unlockTimestamp;
        if (block.timestamp < unlockAt) revert WithdrawalNotUnlocked(unlockAt);

        // Clear pending state first (effects)
        p.amount = 0;
        p.unlockTimestamp = 0;

        STAKE_TOKEN.safeTransfer(msg.sender, amount);

        emit WithdrawalCompleted(msg.sender, amount);
    }

    /// @notice Cancel a pending withdrawal and re-stake the principal.
    /// @dev
    /// - Updates accounting first so the user **does not** backfill rewards for the pending period.
    /// - Adds the pending amount back to `users[msg.sender].balance` and `totalStaked`.
    function cancelWithdrawal() external nonReentrant {
        PendingWithdrawal storage p = pendingWithdrawals[msg.sender];
        uint256 amount = p.amount;
        if (amount == 0) revert NoPendingWithdrawal();

        _updateUser(msg.sender);

        // return principal to staking
        users[msg.sender].balance += amount;
        totalStaked += amount;

        // clear pending
        p.amount = 0;
        p.unlockTimestamp = 0;

        emit WithdrawalCanceled(msg.sender, amount);
    }

    /// @notice Withdraw staked principal immediately, **forfeiting** any accrued rewards.
    /// @dev
    /// - Calls `_updateGlobal()` (not `_updateUser`) to keep global math consistent.
    /// - Calculates forfeited rewards and returns them to rewardReserves to prevent reserve grief.
    /// - Zeros user principal & rewards and snaps `userRewardPerTokenPaid` to the latest global index.
    function emergencyWithdraw() external nonReentrant {
        if (!emergencyExitEnabled) revert EmergencyExitDisabled();

        User storage u = users[msg.sender];
        PendingWithdrawal storage p = pendingWithdrawals[msg.sender];

        uint256 amount = u.balance + p.amount; // Include pending
        if (amount == 0) revert InsufficientBalance();

        // Calculate forfeited rewards before updating global state
        uint256 forfeitedRewards = 0;
        if (u.balance > 0) {
            uint256 rpt = rewardPerToken();
            forfeitedRewards = u.rewards + (u.balance * (rpt - u.userRewardPerTokenPaid)) / 1e18;
        }

        _updateGlobal(); // keep global math consistent

        totalStaked -= u.balance; // Only deduct actual staked amount

        // Return forfeited rewards to reserves to prevent grief attack
        if (forfeitedRewards > 0) {
            rewardReserves += forfeitedRewards;
        }

        // Forfeit rewards and reset state
        u.balance = 0;
        u.rewards = 0;
        u.userRewardPerTokenPaid = rewardPerTokenStored;
        p.amount = 0;
        p.unlockTimestamp = 0;

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
                uint256 rewardPerTokenIncrease = (newly * 1e18) / totalStaked;
                if (rewardPerTokenIncrease > 0) {
                    rewardPerTokenStored += rewardPerTokenIncrease;
                    rewardReserves -= newly; // move from reserves to "owed but unpaid"
                }
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
