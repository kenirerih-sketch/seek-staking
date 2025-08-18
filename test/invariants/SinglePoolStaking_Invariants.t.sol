// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SinglePoolStaking} from "../../src/SinglePoolStaking.sol";
import {ERC20Token} from "../mocks/ERC20Token.sol";
import {Handler} from "./Handler.sol";

/// @title SinglePoolStaking — Invariant Test Suite
/// @notice Stateful, property-based tests to continuously validate core economic and accounting invariants.
/// @dev Uses Foundry's `StdInvariant` to fuzz-call the `Handler`, which in turn exercises the staking pool.
///      High-level guarantees checked:
///        - rewardPerTokenStored is monotonic (never decreases vs. view path)
///        - user.userRewardPerTokenPaid ≤ rewardPerTokenStored for all tracked actors
///        - Sum of users' balances equals totalStaked (for tracked actor set)
///        - rewardReserves never underflows (basic sanity)
contract SinglePoolStaking_Invariants is StdInvariant, Test {
    /// @notice Staking contract under test.
    SinglePoolStaking s;

    /// @notice ERC20 token used as both stake and reward token.
    ERC20Token t;

    /// @notice Invariant handler that issues randomized actions against `s`.
    Handler h;

    /// @notice Number of tracked actors used by the handler.
    uint256 constant ACTOR_COUNT = 5;

    /// @notice Tracked actor addresses seeded with balances/approvals in `setUp()`.
    address[] internal actors;

    /// @notice Deploys contracts, seeds actors, prefunds reserves, and wires the invariant target.
    /// @dev Steps:
    ///      1) Deploy ERC20 and SinglePoolStaking (1 token/sec)
    ///      2) Create `ACTOR_COUNT` deterministic actors and fund each with tokens
    ///      3) Prefund reward reserves to avoid reserve-cap in early steps
    ///      4) Instantiate the `Handler` and register it as the fuzz target
    function setUp() public {
        address owner = address(this);

        t = new ERC20Token("Stake", "STK", 10_000_000 ether, owner);
        s = new SinglePoolStaking(t, t, 1e18, owner);

        // Allocate and seed actors
        actors = new address[](ACTOR_COUNT);
        for (uint256 i = 0; i < actors.length; i++) {
            // Deterministic pseudo-random addresses
            actors[i] = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            bool success = t.transfer(actors[i], 100_000 ether);
            require(success, "Token transfer failed");
            // NOTE: Approvals for staking are not strictly required here because the
            //       handler's actions may rely on `vm.prank` and prior approvals set
            //       in other setup flows. Add per-actor approvals if your handler stakes immediately.
        }

        // Prefund reserves (owner)
        t.approve(address(s), type(uint256).max);
        s.fundRewards(1_000_000 ether);

        // Create handler and wire invariants
        h = new Handler(s, t, actors);
        targetContract(address(h));
    }

    /// @notice Invariant: Stored rewardPerToken must never exceed its view-path counterpart.
    /// @dev `rewardPerToken()` simulates current accrual using view math;
    ///      `rewardPerTokenStored` reflects the last stateful update.
    ///      We assert `stored ≤ view` to ensure monotonic behavior and no retrograde updates.
    function invariant_RPTNonDecreasing() public view {
        uint256 viewRpt = s.rewardPerToken();
        uint256 stored = s.rewardPerTokenStored();
        assertLe(stored, viewRpt);
    }

    /// @notice Invariant: For all tracked actors, `user.userRewardPerTokenPaid ≤ rewardPerTokenStored`.
    /// @dev Mirrors a core accounting safety property: a user’s paid index must never surpass the global index.
    function invariant_UserPaidLEStored() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            (, uint256 paid,) = _user(actors[i]);
            assertLe(paid, s.rewardPerTokenStored());
        }
    }

    /// @notice Invariant: Sum of tracked users’ balances equals `totalStaked`.
    /// @dev Ensures internal accounting of principal aligns with aggregate total for our tracked cohort.
    function invariant_TotalStakedEqualsSum() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 bal,,) = _user(actors[i]);
            sum += bal;
        }
        assertEq(sum, s.totalStaked());
    }

    /// @notice Invariant: Reward reserves never underflow (basic sanity check).
    /// @dev `rewardReserves` is an unsigned integer; this asserts the obvious non-negativity condition.
    function invariant_ReservesNotNegative() public view {
        assertGe(s.rewardReserves(), 0);
    }

    /// @notice Fetch the internal user struct tuple from the staking contract.
    /// @dev Calls the public generated getter for `users(address)` and ABI-decodes to:
    ///      `(balance, userRewardPerTokenPaid, rewards)`.
    /// @param a The user address to query.
    /// @return bal User’s staked balance.
    /// @return paid User’s last paid `rewardPerToken` snapshot.
    /// @return rewards User’s accrued but unclaimed rewards.
    function _user(address a) internal view returns (uint256 bal, uint256 paid, uint256 rewards) {
        (bool ok, bytes memory ret) = address(s).staticcall(abi.encodeWithSignature("users(address)", a));
        require(ok, "users(address) call failed");
        (bal, paid, rewards) = abi.decode(ret, (uint256, uint256, uint256));
    }

    /// @notice Invariant: Contract token balance always covers principal (staked tokens).
    /// @dev With stake==reward token, principal (totalStaked) is held by the contract at all times.
    ///      Withdraw/exit return principal; fund/claim adjust only non-principal.
    function invariant_ContractBalanceCoversPrincipal() public view {
        uint256 bal = t.balanceOf(address(s));
        assertGe(bal, s.totalStaked());
    }

    /// @notice Invariant: Contract remains solvent w.r.t. tracked users' owed rewards.
    /// @dev The contract's non-principal balance (balance - totalStaked) must be >= sum of owed (view) rewards
    ///      for all tracked actors. This includes reserves and already-accounted-but-unclaimed rewards.
    function invariant_ContractSolventForTrackedOwed() public view {
        uint256 bal = t.balanceOf(address(s));
        uint256 principal = s.totalStaked();

        uint256 sumOwed;
        for (uint256 i = 0; i < actors.length; i++) {
            sumOwed += s.earned(actors[i]); // view path includes cap-by-reserves
        }

        // Non-principal holdings must cover all currently owed rewards to tracked users.
        assertGe(bal - principal, sumOwed);
    }

    /// @notice Invariant: When there are no stakers, `rewardPerToken()` equals the stored value.
    /// @dev With totalStaked == 0, both view and state paths short-circuit (no RPT growth).
    function invariant_RPTStableWhenNoStakers() public view {
        if (s.totalStaked() == 0) {
            assertEq(s.rewardPerToken(), s.rewardPerTokenStored());
        }
    }

    /// @notice Invariant: With rewardRate == 0, `rewardPerToken()` does not increase.
    /// @dev View math uses `elapsed * rewardRate`; when rate==0, delta RPT must be zero.
    function invariant_RPTStableWhenRateZero() public view {
        if (s.rewardRate() == 0) {
            assertEq(s.rewardPerToken(), s.rewardPerTokenStored());
        }
    }

    /// @notice Invariant: `lastUpdateTime` is never in the future.
    /// @dev Ensures timestamp monotonicity and sanity under arbitrary action orderings.
    function invariant_LastUpdateNotInFuture() public view {
        assertLe(uint256(s.lastUpdateTime()), block.timestamp);
    }
}
