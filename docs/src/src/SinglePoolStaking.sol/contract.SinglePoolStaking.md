# SinglePoolStaking
[Git Source](https://github.com/TalismanSociety/seek-staking/blob/5127722128a2c621acd1ff1b33fab79798bcfc64/src/SinglePoolStaking.sol)

**Inherits:**
Ownable2Step, ReentrancyGuard

Single-pool proportional reward staking with an adjustable emission rate.

*
- Rewards are **prefunded** (non-mintable). Accrual is gated by `rewardReserves` to ensure the pool
never accounts more than the available reserves (prevents over-accrual/insolvency).
- Supports **same-token** staking (STAKE_TOKEN == REWARD_TOKEN) safely via reserve gating,
so reward payouts never consume staked principal.
- Uses a global `rewardPerTokenStored` (scaled by 1e18) with per-user snapshots to account rewards.
- All mutative paths that depend on time call `_updateGlobal()` first to snapshot history.
- This implementation assumes **standard ERC-20 semantics** for staking token transfers
(i.e., no fee-on-transfer on `stake()`/`withdraw()`). `fundRewards()` is robust via balance delta.*


## State Variables
### STAKE_TOKEN
Token users deposit as principal (a.k.a. staked token). Standard ERC-20 (no fee/rebase).

*Immutable at construction.*


```solidity
IERC20 public immutable STAKE_TOKEN;
```


### REWARD_TOKEN
Token paid out as rewards. Standard ERC-20 (no fee/rebase).

*Immutable at construction; can be same as `STAKE_TOKEN`.*


```solidity
IERC20 public immutable REWARD_TOKEN;
```


### rewardRate
Rewards emitted per second.

*Owner can adjust via governance-timelocked flow (see `proposeRewardRate` / `executeRewardRateChange`).*


```solidity
uint256 public rewardRate;
```


### lastUpdateTime
Last timestamp when global rewards were accounted (i.e., when `_updateGlobal()` last ran).

*Stored as uint64 to save gas; comparisons cast to uint256 where needed.*


```solidity
uint64 public lastUpdateTime;
```


### rewardPerTokenStored
Accumulated rewards per staked token, scaled by 1e18.

*Global index used to compute per-user deltas. Monotonic non-decreasing.*


```solidity
uint256 public rewardPerTokenStored;
```


### rewardReserves
Prefunded reward reserves available for **future** accrual.

*`_updateGlobal()` consumes from this bucket (moves to "owed but unpaid");
user claims **do not** touch `rewardReserves`.*


```solidity
uint256 public rewardReserves;
```


### emergencyExitEnabled
Flag to enable emergency exit mode.

*When enabled, users can withdraw their principal immediately, forfeiting any accrued rewards.
This is a governance-controlled feature that can be toggled by the owner.
When disabled, users must use the delayed withdrawal path to claim their principal.
This flag is set to `false` by default and can be toggled by the owner.*


```solidity
bool public emergencyExitEnabled;
```


### totalStaked
Total staked principal held by the contract.


```solidity
uint256 public totalStaked;
```


### users
Mapping of user address to their staking accounting data.


```solidity
mapping(address => User) public users;
```


### withdrawDelay
Lock duration between withdrawal request and claim (in seconds).

*Configurable by owner. If set to 0, withdrawals can be completed immediately after requesting.*


```solidity
uint64 public withdrawDelay;
```


### pendingWithdrawals
Mapping of user to their single active pending withdrawal (if any).


```solidity
mapping(address => PendingWithdrawal) public pendingWithdrawals;
```


### MAX_REWARD_RATE
Maximum allowed emission rate (tokens/sec).


```solidity
uint256 public immutable MAX_REWARD_RATE;
```


### MAX_WITHDRAW_DELAY
Maximum withdraw delay (in seconds).

*This is a governance-controlled parameter that can be adjusted by the owner.
It sets the maximum delay for withdrawals, ensuring that users cannot set excessively long delays*


```solidity
uint32 public constant MAX_WITHDRAW_DELAY = 30 days;
```


### RATE_CHANGE_DELAY
Delay required between proposing and executing a reward rate change.


```solidity
uint64 public immutable RATE_CHANGE_DELAY;
```


### pendingRewardRate
Proposed reward rate pending execution after `rateChangeExecuteAfter`.


```solidity
uint256 public pendingRewardRate;
```


### rateChangeExecuteAfter
Earliest timestamp when the pending reward rate can be executed.


```solidity
uint64 public rateChangeExecuteAfter;
```


### minStakeAmount
Minimum amount required to stake/unstake


```solidity
uint256 public minStakeAmount;
```


## Functions
### constructor

Deploy the staking pool.

*Sets `lastUpdateTime` to `block.timestamp` and enforces `_initialRewardRate <= _maxRewardRate`.*


```solidity
constructor(
    IERC20 _stakeToken,
    IERC20 _rewardToken,
    uint256 _initialRewardRate,
    address initialOwner,
    uint256 _maxRewardRate,
    uint64 _rateChangeDelay,
    uint64 _initialWithdrawDelay,
    uint256 _minStakeAmount
) Ownable(initialOwner);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_stakeToken`|`IERC20`|ERC-20 token users deposit as principal.|
|`_rewardToken`|`IERC20`|ERC-20 token used for rewards (may equal `_stakeToken`).|
|`_initialRewardRate`|`uint256`|Initial `rewardRate` in tokens per second.|
|`initialOwner`|`address`|Address to receive contract ownership.|
|`_maxRewardRate`|`uint256`|Governance max for `rewardRate` (tokens/sec).|
|`_rateChangeDelay`|`uint64`|Timelock delay for rate changes (in seconds).|
|`_initialWithdrawDelay`|`uint64`|Initial locked withdrawal delay (in seconds).|
|`_minStakeAmount`|`uint256`|Minimum amount required to stake or withdraw.|


### balanceOf

Current staked balance for `account`.


```solidity
function balanceOf(address account) external view returns (uint256 amount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`account`|`address`|The user to query.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|The staked principal.|


### lastTimeRewardApplicable

The timestamp used for reward calculations.

*Returns `block.timestamp`. Split out as a function for clarity/extensibility.*


```solidity
function lastTimeRewardApplicable() public view returns (uint256 ts);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`ts`|`uint256`|The timestamp at which rewards are applicable.|


### rewardPerToken

The current global rewards-per-token index (scaled by 1e18).

*
- If `totalStaked == 0`, returns the stored value (no accrual).
- Applies reserve cap: at most `rewardReserves` may be accounted.*


```solidity
function rewardPerToken() public view returns (uint256 rpt);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`rpt`|`uint256`|The current `rewardPerToken` value including any un-snapshotted elapsed window (view path).|


### earned

View the total rewards owed to `account` at the current timestamp.

*Computed as: `u.rewards + u.balance * (rewardPerToken() - u.userRewardPerTokenPaid) / 1e18`.
This is a **view**; reserves are not consumed here (consumption happens on state updates).*


```solidity
function earned(address account) public view returns (uint256 amount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`account`|`address`|The user to query.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|The accrued but unclaimed rewards.|


### rewardsRunwaySeconds

View the total rewards reserves runway in seconds.

*If `rewardRate == 0`, returns `type(uint256).max` (infinite runway).
Otherwise, computes `rewardReserves / rewardRate`.*


```solidity
function rewardsRunwaySeconds() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|seconds The number of seconds the current reserves can sustain at the current rate.|


### proposeRewardRate

Propose a new reward emission rate (tokens per second), subject to a delay.

*Enforces `MAX_REWARD_RATE`. Allows pausing with `0`. Emits `RewardRateProposed`.*


```solidity
function proposeRewardRate(uint256 _newRate) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_newRate`|`uint256`|The proposed `rewardRate` value (tokens/sec).|


### executeRewardRateChange

Execute a previously proposed reward rate after the timelock elapses. Intentionally callable by anyone.

*Snapshots global accounting first, then updates `rewardRate` and emits `RewardRateUpdated`.*


```solidity
function executeRewardRateChange() external;
```

### cancelRewardRateChange

Cancel a pending reward rate change.

*Clears pending state and emits `RewardRateChangeCanceled`.*


```solidity
function cancelRewardRateChange() external onlyOwner;
```

### fundRewards

Prefund rewards into the pool.

*
- Uses **balance delta** to compute the net tokens actually received, which makes it robust
to some non-standard ERC-20 implementations (e.g., fee-on-transfer).
- The **net** received amount is credited to `rewardReserves`.
- Reentrancy is guarded.*


```solidity
function fundRewards(uint256 amount) external onlyOwner nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|The nominal amount to transfer from the owner.|


### rescueTokens

Rescue unrelated tokens accidentally sent to this contract.

*Cannot rescue `STAKE_TOKEN` or `REWARD_TOKEN`.*


```solidity
function rescueTokens(IERC20 token, address to, uint256 amount) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`IERC20`|The ERC-20 token to rescue.|
|`to`|`address`|Recipient for rescued tokens.|
|`amount`|`uint256`|The amount to rescue.|


### setWithdrawDelay

Set the withdrawal delay (in seconds) for delayed withdrawals.

*Emits `WithdrawDelayUpdated`. Can be set to 0 to allow immediate completion after request.*


```solidity
function setWithdrawDelay(uint64 newDelay) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newDelay`|`uint64`|The new delay duration in seconds.|


### setEmergencyExitEnabled

Enable/disable immediate emergency exits that forfeit rewards.

*Default should be false in production; only enable during incidents.*


```solidity
function setEmergencyExitEnabled(bool enabled) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`enabled`|`bool`|True to enable emergency exits; false to disable.|


### setMinStakeAmount

*Emits `MinStakeAmountUpdated`. This is a governance-controlled parameter that can be adjusted by the owner.
It sets the minimum amount required for users to stake or withdraw.
This is useful to prevent dust transactions and ensure meaningful participation.*


```solidity
function setMinStakeAmount(uint256 newMinStakeAmount) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newMinStakeAmount`|`uint256`|The new minimum stake amount in tokens.|


### stake

Stake `amount` for yourself.


```solidity
function stake(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of `STAKE_TOKEN` to deposit.|


### stakeFor

Stake `amount` on behalf of `to`.

*
- Updates global & user accounting first to snapshot prior rewards.
- Transfers `amount` from `msg.sender` to the pool.
- **Note:** If `STAKE_TOKEN` is fee-on-transfer, the recipient may receive less than `amount`,
and this function does **not** use balance delta; such tokens are not supported.*


```solidity
function stakeFor(uint256 amount, address to) public nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of `STAKE_TOKEN` to deposit.|
|`to`|`address`|Recipient whose stake balance increases.|


### getReward

Claim your rewards to your own address.

*Updates accounting and pays out the owed rewards; resets `users[msg.sender].rewards` to 0.*


```solidity
function getReward() external nonReentrant;
```

### getRewardTo

Claim rewards to a custom address (e.g., auto-compounder).

*Updates accounting and pays out the owed rewards to `to`; resets internal owed to 0.*


```solidity
function getRewardTo(address to) external nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`to`|`address`|Recipient of the rewards.|


### requestWithdrawal

Initiate a delayed withdrawal request.

*
- Updates accounting, then **removes** `amount` from staking so it stops earning immediately.
- Records a single pending withdrawal that becomes claimable after `withdrawDelay`.
- Reverts if a pending withdrawal already exists for the caller.*


```solidity
function requestWithdrawal(uint256 amount) external nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of staked tokens to request withdrawal for.|


### completeWithdrawal

Complete a previously requested withdrawal after the delay.

*
- Does **not** modify rewards; rewards remain claimable separately at any time.
- Clears pending state before transfer to prevent reentrancy issues.*


```solidity
function completeWithdrawal() external nonReentrant;
```

### cancelWithdrawal

Cancel a pending withdrawal and re-stake the principal.

*
- Updates accounting first so the user **does not** backfill rewards for the pending period.
- Adds the pending amount back to `users[msg.sender].balance` and `totalStaked`.*


```solidity
function cancelWithdrawal() external nonReentrant;
```

### emergencyWithdraw

Withdraw staked principal immediately, **forfeiting** any accrued rewards.

*
- Calls `_updateGlobal()` (not `_updateUser`) to keep global math consistent.
- Zeros user principal & rewards and snaps `userRewardPerTokenPaid` to the latest global index.*


```solidity
function emergencyWithdraw() external nonReentrant;
```

### _updateGlobal

Update global reward accounting up to `block.timestamp`.

*
- No-op if `current == lastUpdateTime`.
- If `totalStaked > 0`, increases `rewardPerTokenStored` by:
`deltaRPT = min(elapsed * rewardRate, rewardReserves) * 1e18 / totalStaked`
and **consumes** the same (uncapped) `newly` from `rewardReserves`.
- Always updates `lastUpdateTime` to `current`.*


```solidity
function _updateGlobal() internal;
```

### _updateUser

Update a user's accounting against the latest global snapshot.

*
- Calls `_updateGlobal()` first (ensuring global index is up to date).
- If user has a positive balance, accrues:
`u.rewards += u.balance * (rewardPerTokenStored - u.userRewardPerTokenPaid) / 1e18`
- Sets `u.userRewardPerTokenPaid = rewardPerTokenStored`.*


```solidity
function _updateUser(address account) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`account`|`address`|The user to update.|


## Events
### Initialized
Emitted when the contract is initialized with its parameters.

*Sets `lastUpdateTime` to `block.timestamp` and enforces `_initialRewardRate <= _maxRewardRate`.
Emits `RewardRateUpdated`, `WithdrawDelayUpdated`, and `MinStakeAmountUpdated` events.*

*This event is emitted when the contract is initialized with its parameters.
It provides a record of the initial configuration of the staking pool.
This is useful for transparency and auditing purposes, allowing users to
verify the initial setup of the staking contract.*

*This event is emitted when the contract is initialized with its parameters.*


```solidity
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
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_stakeToken`|`address`|The token users deposit as principal.|
|`_rewardToken`|`address`|The token used for rewards (may equal `_stakeToken`).|
|`_initialRewardRate`|`uint256`|Initial `rewardRate` in tokens per second.|
|`initialOwner`|`address`|Address to receive contract ownership.|
|`_maxRewardRate`|`uint256`|Governance max for `rewardRate` (tokens/sec).|
|`_rateChangeDelay`|`uint64`|Timelock delay for rate changes (in seconds).|
|`_initialWithdrawDelay`|`uint64`|Initial locked withdrawal delay (in seconds).|
|`_minStakeAmount`|`uint256`|Minimum amount required to stake.|

### EmergencyExitEnabled
Emitted when emergency exit mode is enabled/disabled.

*When enabled, users can withdraw their principal immediately, forfeiting any accrued rewards.
When disabled, users must use the delayed withdrawal path to claim their principal.*


```solidity
event EmergencyExitEnabled(bool enabled);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`enabled`|`bool`|True if emergency exits are enabled; false if disabled.|

### MinStakeAmountUpdated
Emitted when the minimum stake amount is updated.

*This is a governance-controlled parameter that can be adjusted by the owner.
It sets the minimum amount required for users to stake or withdraw.
This is useful to prevent dust transactions and ensure meaningful participation.*


```solidity
event MinStakeAmountUpdated(uint256 oldAmount, uint256 newAmount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`oldAmount`|`uint256`|The previous minimum stake amount.|
|`newAmount`|`uint256`|The new minimum stake amount.|

### Staked
Emitted when `sender` stakes `amount` on behalf of `to`.


```solidity
event Staked(address indexed sender, address indexed to, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sender`|`address`|The caller providing stake tokens.|
|`to`|`address`|The recipient whose balance increases.|
|`amount`|`uint256`|The amount staked.|

### RewardPaid
Emitted when `user` is paid `amount` of rewards to `to`.


```solidity
event RewardPaid(address indexed user, address indexed to, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|The user whose rewards were claimed/reset.|
|`to`|`address`|Recipient of rewards.|
|`amount`|`uint256`|The reward amount paid.|

### RewardRateUpdated
Emitted when emission rate is updated.


```solidity
event RewardRateUpdated(uint256 oldRate, uint256 newRate);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`oldRate`|`uint256`|Previous `rewardRate`.|
|`newRate`|`uint256`|New `rewardRate`.|

### RewardRateProposed
Emitted when a reward rate change is proposed with a timelock.


```solidity
event RewardRateProposed(uint256 proposedRate, uint64 executeAfter);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`proposedRate`|`uint256`|The proposed reward rate (tokens/sec).|
|`executeAfter`|`uint64`|The earliest timestamp when execution is allowed.|

### RewardRateChangeCanceled
Emitted when a pending reward rate change is canceled.


```solidity
event RewardRateChangeCanceled(uint256 canceledRate);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`canceledRate`|`uint256`|The previously proposed reward rate that was canceled.|

### RewardsFunded
Emitted when rewards are prefunded.


```solidity
event RewardsFunded(address indexed from, uint256 amount, uint256 newReserves);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`from`|`address`|Funding source (owner).|
|`amount`|`uint256`|Net tokens received (uses balance delta, so may differ from input due to token quirks).|
|`newReserves`|`uint256`|Updated `rewardReserves` after funding.|

### EmergencyWithdraw
Emitted on emergency withdrawal (principal returned, rewards forfeited).


```solidity
event EmergencyWithdraw(address indexed user, address indexed to, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|The user who exited via emergency withdrawal.|
|`to`|`address`|Recipient of principal (typically `user`).|
|`amount`|`uint256`|Principal returned.|

### RescueTokens
Emitted when unrelated ERC-20 tokens are rescued.


```solidity
event RescueTokens(address indexed token, address indexed to, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|The rescued token address.|
|`to`|`address`|Recipient of rescued tokens.|
|`amount`|`uint256`|Amount rescued.|

### WithdrawalRequested
Emitted when a delayed withdrawal is requested.


```solidity
event WithdrawalRequested(address indexed user, uint256 amount, uint64 unlockTimestamp);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|The address requesting withdrawal.|
|`amount`|`uint256`|Amount removed from staking and placed into the pending queue.|
|`unlockTimestamp`|`uint64`|Timestamp when withdrawal becomes claimable.|

### WithdrawalCompleted
Emitted when a pending withdrawal is completed and principal is transferred out.


```solidity
event WithdrawalCompleted(address indexed user, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|The address completing withdrawal.|
|`amount`|`uint256`|The amount withdrawn.|

### WithdrawalCanceled
Emitted when a pending withdrawal is canceled and principal is re-staked.


```solidity
event WithdrawalCanceled(address indexed user, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|The address canceling withdrawal.|
|`amount`|`uint256`|The amount returned to staking.|

### WithdrawDelayUpdated
Emitted when the withdrawal delay is updated.


```solidity
event WithdrawDelayUpdated(uint64 oldDelay, uint64 newDelay);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`oldDelay`|`uint64`|Previous delay (seconds).|
|`newDelay`|`uint64`|New delay (seconds).|

## Errors
### EmergencyExitDisabled
Thrown when emergency exits are disabled and a user tries to withdraw immediately.


```solidity
error EmergencyExitDisabled();
```

### AmountZero
Thrown when a provided amount is zero where a positive value is required.


```solidity
error AmountZero();
```

### DelayTooLong
Thrown when a requested delay exceeds the maximum allowed.


```solidity
error DelayTooLong(uint64 requested, uint64 max);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`requested`|`uint64`|The requested delay in seconds.|
|`max`|`uint64`|The maximum allowed delay in seconds.|

### AmountTooLow
Thrown when a provided amount is below the minimum required for staking/unstaking.


```solidity
error AmountTooLow(uint256 provided, uint256 minRequired);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`provided`|`uint256`|The amount provided by the user.|
|`minRequired`|`uint256`|The minimum amount required to proceed.|

### InsufficientBalance
Thrown when a user attempts to withdraw/claim more than available.


```solidity
error InsufficientBalance();
```

### InvalidToken
Thrown when an operation targets an invalid token address or disallowed token.


```solidity
error InvalidToken();
```

### RewardRateTooHigh
Thrown when a proposed rate exceeds `MAX_REWARD_RATE`.


```solidity
error RewardRateTooHigh(uint256 requested, uint256 max);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`requested`|`uint256`|The requested rate.|
|`max`|`uint256`|The maximum allowed rate.|

### RateChangeDelayNotMet
Thrown when trying to execute a rate change before the timelock elapses.


```solidity
error RateChangeDelayNotMet(uint64 executeAfter);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`executeAfter`|`uint64`|The timestamp after which execution is allowed.|

### NoPendingRate
Thrown when no pending reward rate exists to execute or cancel.


```solidity
error NoPendingRate();
```

### PendingWithdrawalExists
Thrown when a user already has an active pending withdrawal.


```solidity
error PendingWithdrawalExists();
```

### NoPendingWithdrawal
Thrown when a user has no pending withdrawal to act upon.


```solidity
error NoPendingWithdrawal();
```

### WithdrawalNotUnlocked
Thrown when attempting to complete a withdrawal before it's unlocked.


```solidity
error WithdrawalNotUnlocked(uint64 unlockTimestamp);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`unlockTimestamp`|`uint64`|The timestamp when completion becomes allowed.|

## Structs
### User
Per-user accounting data.


```solidity
struct User {
    uint256 balance;
    uint256 userRewardPerTokenPaid;
    uint256 rewards;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`balance`|`uint256`|Current staked principal.|
|`userRewardPerTokenPaid`|`uint256`|User snapshot of `rewardPerTokenStored` at last accounting.|
|`rewards`|`uint256`|Accrued but unclaimed rewards (accounted via snapshots).|

### PendingWithdrawal
User withdrawal request data.


```solidity
struct PendingWithdrawal {
    uint256 amount;
    uint64 unlockTimestamp;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Requested amount that was removed from staking and no longer earns rewards.|
|`unlockTimestamp`|`uint64`|When the withdrawal can be completed.|

