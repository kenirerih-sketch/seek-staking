// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HelperUtils} from "./utils/HelperUtils.s.sol";
import {SinglePoolStaking} from "../src/SinglePoolStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeploySinglePoolStaking is Script {
    address public stakingAddress;

    struct Cfg {
        address stakeToken;
        address rewardToken;
        address owner;
        uint256 rewardRate;
        uint256 maxRewardRate;
        uint256 minRewardRate;
        uint64 rateChangeDelay;
        uint64 withdrawDelay;
        uint256 minStakeAmount;
        string chainName;
        string configPath;
    }

    function run(bool testMode) external {
        // Derive basic paths first
        string memory root = vm.projectRoot();

        // These two are short-lived locals; fine to keep here
        bool isMainnet = HelperUtils.getIsMainnet(block.chainid);
        string memory chainName = HelperUtils.getChainName(block.chainid);

        // Build config path using minimal locals
        string memory configPath = isMainnet
            ? string.concat(root, "/script/config-mainnet.json")
            : string.concat(root, "/script/config-testnet.json");

        // Load config into a single memory struct (reduces stack usage)
        Cfg memory cfg = _loadConfig(configPath, chainName);

        vm.startBroadcast();

        SinglePoolStaking staking = new SinglePoolStaking(
            IERC20(cfg.stakeToken),
            IERC20(cfg.rewardToken),
            cfg.rewardRate,
            cfg.owner,
            cfg.maxRewardRate,
            cfg.minRewardRate,
            cfg.rateChangeDelay,
            cfg.withdrawDelay,
            cfg.minStakeAmount
        );
        stakingAddress = address(staking);

        vm.stopBroadcast();

        if (!testMode) {
            _writeOutput(cfg.chainName, stakingAddress);
        }
    }

    function _loadConfig(string memory configPath, string memory chainName) internal view returns (Cfg memory cfg) {
        cfg.stakeToken = HelperUtils.getAddressFromJson(vm, configPath, ".staking.stakeToken");
        cfg.rewardToken = HelperUtils.getAddressFromJson(vm, configPath, ".staking.rewardToken");
        cfg.owner = HelperUtils.getAddressFromJson(vm, configPath, ".owner");
        cfg.rewardRate = HelperUtils.getUintFromJson(vm, configPath, ".staking.rewardRate");
        cfg.maxRewardRate = HelperUtils.getUintFromJson(vm, configPath, ".staking.maxRewardRate");
        cfg.minRewardRate = HelperUtils.getUintFromJson(vm, configPath, ".staking.minRewardRate");
        cfg.rateChangeDelay = uint64(HelperUtils.getUintFromJson(vm, configPath, ".staking.rateChangeDelay"));
        cfg.withdrawDelay = uint64(HelperUtils.getUintFromJson(vm, configPath, ".staking.withdrawDelay"));
        cfg.minStakeAmount = HelperUtils.getUintFromJson(vm, configPath, ".staking.minStakeAmount");
        cfg.chainName = chainName;
        cfg.configPath = configPath;
    }

    function _writeOutput(string memory chainName, address deployed) internal {
        string memory jsonObj = "internal_key";
        string memory key = string.concat("deploySinglePoolStaking", chainName);
        string memory finalJson = vm.serializeAddress(jsonObj, key, deployed);
        string memory fileName = string.concat("./script/output/deploySinglePoolStaking_", chainName, ".json");

        console.log("Writing deployed staking address to file:", fileName);
        vm.writeJson(finalJson, fileName);
    }
}
