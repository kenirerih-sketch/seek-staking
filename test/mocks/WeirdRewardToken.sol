// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC20 that can return true on transferFrom without moving balances
contract WeirdRewardToken is ERC20 {
    bool public noMove;

    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function setNoMove(bool v) external {
        noMove = v;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (noMove) {
            // Pretend success but do NOT change balances; SafeERC20 sees success,
            // staking checks balance delta and reverts when 'received == 0'.
            return true;
        }
        return super.transferFrom(from, to, amount);
    }
}
