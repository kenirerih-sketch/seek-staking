# SinglePoolStaking
[Git Source](https://github.com/TalismanSociety/seek-staking/blob/3e183f9a84b2fa7a0da367f2e3986f9f9e406b93/src/SinglePoolStaking.sol)

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
Token users deposit as principal (a.k.a. staked token).

*Immutable at construction.*


```solidity
IERC20 public immutable STAKE_TOKEN;
```


### REWARD_TOKEN
Token paid out as rewards.

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


### MAX_REWARD_RATE
Maximum allowed emission rate (tokens/sec).


```solidity
uint256 public MAX_REWARD_RATE;
```


### RATE_CHANGE_DELAY
Delay required between proposing and executing a reward rate change.


```solidity
uint64 public RATE_CHANGE_DELAY;
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
    uint64 _rateChangeDelay
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

Execute a previously proposed reward rate after the timelock elapses.

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


### withdraw

Withdraw `amount` of your staked principal.

*Updates global & user accounting first; accrued rewards remain unclaimed.*


```solidity
function withdraw(uint256 amount) external nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount to withdraw.|


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


### exit

Withdraw principal and claim rewards in one transaction.

*Updates accounting, then transfers principal and rewards if non-zero; emits events accordingly.*


```solidity
function exit() external nonReentrant;
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

### Withdrawn
Emitted when `sender` withdraws `amount` to `to`.


```solidity
event Withdrawn(address indexed sender, address indexed to, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sender`|`address`|The user withdrawing their stake.|
|`to`|`address`|Recipient of returned principal (typically `sender`).|
|`amount`|`uint256`|The amount withdrawn.|

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

## Errors
### AmountZero
Thrown when a provided amount is zero where a positive value is required.


```solidity
error AmountZero();
```

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

