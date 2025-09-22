// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {HelperUtils} from "../script/utils/HelperUtils.s.sol";
import {DeploySinglePoolStaking} from "../script/DeploySinglePoolStaking.s.sol";

contract DeploySinglePoolStakingScriptCleanupTest is Test {
    DeploySinglePoolStaking script;

    function setUp() public {
        script = new DeploySinglePoolStaking();
    }

    // ---------- File snapshot helpers ----------

    struct FileSnap {
        string path;
        bool existed;
        string contents; // valid only if existed == true
    }

    // External wrapper to allow try/catch around readFile
    function _read(string memory path) external view returns (string memory) {
        return vm.readFile(path);
    }

    function _snapshot(string memory path) internal view returns (FileSnap memory s) {
        s.path = path;
        // try/catch only works on external calls
        try this._read(path) returns (string memory data) {
            s.existed = true;
            s.contents = data;
        } catch {
            s.existed = false;
        }
    }

    function _restore(FileSnap memory s) internal {
        if (s.existed) {
            vm.writeFile(s.path, s.contents); // exact restore
        } else {
            // no removeFile available and avoiding FFI -> zero out
            vm.writeFile(s.path, ""); // or "{}" if JSON is expected
        }
    }

    // ---------- Helpers for output path and key ----------

    function _outPath(uint256 chainId) internal pure returns (string memory) {
        string memory chainName = HelperUtils.getChainName(chainId);
        return string.concat("./script/output/deploySinglePoolStaking_", chainName, ".json");
    }

    function _jsonKey(uint256 chainId) internal pure returns (string memory) {
        return string.concat(".", "deploySinglePoolStaking", HelperUtils.getChainName(chainId));
    }

    // ---------- Tests with auto-cleanup ----------

    /// Drives the non-test mode branch, verifies write, then restores file to original.
    function test_Run_NotTestMode_WritesOutput_Testnet_WithCleanup() public {
        uint256 chainId = 11155111; // Sepolia
        vm.chainId(chainId);

        string memory path = _outPath(chainId);
        FileSnap memory snap = _snapshot(path);

        // Execute (writes file)
        script.run(false);

        // Validate
        string memory json = vm.readFile(path);
        address recorded = vm.parseJsonAddress(json, _jsonKey(chainId));
        assertEq(recorded, script.stakingAddress(), "JSON address != deployed address");

        // Cleanup: restore repository state
        _restore(snap);

        // Optional assert: after restore, compare file reverted to original
        if (snap.existed) {
            string memory afterChanges = vm.readFile(path);
            assertEq(afterChanges, snap.contents, "file not restored to original contents");
        } else {
            // If it didn't exist originally, ensure it’s gone now
            bool deleted;
            try this._read(path) returns (string memory) {
                deleted = false;
            } catch {
                deleted = true;
            }
            assertTrue(deleted, "file not deleted after cleanup");
        }
    }
}
