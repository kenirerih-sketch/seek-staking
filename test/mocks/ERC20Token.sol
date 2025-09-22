// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ERC20Token is ERC20, Ownable {
    constructor(string memory name, string memory symbol, uint256 totalSupply, address owner)
        ERC20(name, symbol)
        Ownable(owner)
    {
        _mint(owner, totalSupply * 10 ** decimals());
    }
}
