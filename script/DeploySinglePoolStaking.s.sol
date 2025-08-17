// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperUtils} from "./utils/HelperUtils.s.sol";
import {SinglePoolStaking} from "../src/SinglePoolStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeploySinglePoolStaking is Script {
    address public stakingAddress;

    function run(bool _testMode) external {
        // Set the test mode flag
        bool testMode = _testMode;

        // Get the chain name based on the current chain ID
        string memory chainName = HelperUtils.getChainName(block.chainid);
        bool isMainnet = HelperUtils.getIsMainnet(block.chainid);

        // Define the path to the config.json file
        string memory root = vm.projectRoot();
        string memory configPath = isMainnet
            ? string.concat(root, "/script/config-mainnet.json")
            : string.concat(root, "/script/config-testnet.json");

        // Extract token parameters from the config.json file
        address stakeToken = HelperUtils.getAddressFromJson(vm, configPath, ".staking.stakeToken");
        address rewardToken = HelperUtils.getAddressFromJson(vm, configPath, ".staking.rewardToken");
        address owner = HelperUtils.getAddressFromJson(vm, configPath, ".owner");
        uint256 rewardRate = HelperUtils.getUintFromJson(vm, configPath, ".staking.rewardRate");

        vm.startBroadcast();

        // Deploy the staking contract
        SinglePoolStaking staking = new SinglePoolStaking(IERC20(stakeToken), IERC20(rewardToken), rewardRate, owner);
        stakingAddress = address(staking);

        vm.stopBroadcast();

        // Skip file writing in test mode
        if (!testMode) {
            // Prepare to write the deployed token address to a JSON file
            string memory jsonObj = "internal_key";
            string memory key = string(abi.encodePacked("deploySinglePoolStaking", chainName));
            string memory finalJson = vm.serializeAddress(jsonObj, key, stakingAddress);

            // Define the output file path for the deployed token address
            string memory fileName =
                string(abi.encodePacked("./script/output/deploySinglePoolStaking_", chainName, ".json"));

            console.log("Writing deployed staking address to file:", fileName);
            vm.writeJson(finalJson, fileName);
        }
    }
}
