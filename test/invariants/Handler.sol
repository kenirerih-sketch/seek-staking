// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {SinglePoolStaking} from "../../src/SinglePoolStaking.sol";
import {ERC20Token} from "../mocks/ERC20Token.sol";

/// @title SinglePoolStaking Invariant Handler
/// @notice Minimal action driver for invariant/property-based tests.
/// @dev This handler is intentionally side-effect free in the constructor (no cheatcodes).
///      It assumes the test `setUp()` has:
///        - Funded each `users[i]` with sufficient tokens
///        - Approved `address(s)` as spender for each user
///        - Prefunded `s.rewardReserves()`
///      Cheatcodes (`vm.prank`) are used inside actions to simulate calls from different actors.
contract Handler is Test {
    /// @notice Target staking contract under test.
    SinglePoolStaking public immutable s;

    /// @notice ERC20 token used for both staking and rewards in the invariants setup.
    ERC20Token public immutable t;

    /// @notice Actor set used by the fuzzer to pick a caller for actions.
    address[] public users;

    /// @notice Construct the handler with references and a fixed actor set.
    /// @dev No `vm.*` calls here; approvals & balances must be prepared in the test `setUp()`.
    /// @param _s The SinglePoolStaking instance to exercise.
    /// @param _t The ERC20 token used by the staking pool.
    /// @param _users The list of actors to select from (must be non-empty).
    constructor(SinglePoolStaking _s, ERC20Token _t, address[] memory _users) {
        s = _s;
        t = _t;
        users = _users;
    }

    /// @notice Pick an actor deterministically from `users` based on a seed.
    /// @dev Uses simple modulo selection; the invariant test framework supplies the seed.
    /// @param seed Pseudo-random seed from the fuzzer.
    /// @return The selected actor address from `users`.
    function _pick(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    /// @notice Stake an amount on behalf of a pseudo-randomly selected user.
    /// @dev Amount is bounded to `[1 ether, 1000 ether]`. Assumes the user:
    ///      - Holds at least `amt` tokens
    ///      - Has approved `address(s)` for at least `amt`
    /// @param seed Seed used to select the user (via `_pick`).
    /// @param amt Unbounded fuzz input; normalized to the supported range.
    function actStake(uint256 seed, uint256 amt) external {
        address u = _pick(seed);
        amt = 1 ether + (amt % (1000 ether));
        vm.prank(u);
        s.stake(amt);
    }
}
