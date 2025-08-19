// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeploySinglePoolStaking} from "../script/DeploySinglePoolStaking.s.sol";
import {SinglePoolStaking} from "../src/SinglePoolStaking.sol";

contract DeploySinglePoolStakingTest is Test {
    DeploySinglePoolStaking deployScript;
    SinglePoolStaking staking;
    bool testMode = true;

    function setUp() public {
        deployScript = new DeploySinglePoolStaking();
    }

    function testDeploySinglePoolStakingTestnet() public {
        // Test variables (mock values) to match config-testnet.json
        address stakeToken = address(0xe8B39856C78027BEb569B5e399d58f9f1674EaB8);
        address rewardToken = address(0xe8B39856C78027BEb569B5e399d58f9f1674EaB8);
        address owner = 0x7a8A6cF34a185e6e134108E941b14d011c8FD054;
        uint256 rewardRate = 1e18; // 1 token
        uint256 maxRewardRate = 1e18; // 1 token
        uint64 rateChangeDelay = 86400; // 1 day

        uint256 chainId = 11155111; // Ethereum Sepolia

        vm.chainId(chainId);

        // Run script
        deployScript.run(testMode);

        // Assertions to validate the deployment
        staking = SinglePoolStaking(deployScript.stakingAddress());
        assertEq(address(staking.STAKE_TOKEN()), stakeToken);
        assertEq(address(staking.REWARD_TOKEN()), rewardToken);
        assertEq(staking.rewardRate(), rewardRate);
        assertEq(staking.owner(), owner);
        assertEq(staking.MAX_REWARD_RATE(), maxRewardRate);
        assertEq(staking.RATE_CHANGE_DELAY(), rateChangeDelay);
    }

    function testDeploySinglePoolStakingMainnet() public {
        // Test variables (mock values) to match config-mainnet.json
        address stakeToken = address(0x6982508145454Ce325dDbE47a25d4ec3d2311933);
        address rewardToken = address(0x6982508145454Ce325dDbE47a25d4ec3d2311933);
        address owner = 0x5C9EBa3b10E45BF6db77267B40B95F3f91Fc5f67;
        uint256 rewardRate = 0.15844513e18;
        uint256 maxRewardRate = 1e18; // 1 token
        uint64 rateChangeDelay = 7 days;

        uint256 chainId = 1; // Ethereum Mainnet

        vm.chainId(chainId);

        // Run script
        deployScript.run(testMode);

        // Assertions to validate the deployment
        staking = SinglePoolStaking(deployScript.stakingAddress());
        assertEq(address(staking.STAKE_TOKEN()), stakeToken);
        assertEq(address(staking.REWARD_TOKEN()), rewardToken);
        assertEq(staking.rewardRate(), rewardRate);
        assertEq(staking.owner(), owner);
        assertEq(staking.MAX_REWARD_RATE(), maxRewardRate);
        assertEq(staking.RATE_CHANGE_DELAY(), rateChangeDelay);
    }
}
