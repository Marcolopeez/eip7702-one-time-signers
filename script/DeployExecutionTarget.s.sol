// SPDX-License-Identifier: MIT
/**
 * Deploys the test execution target used by local wallet flows.
 *
 * The wallet sends delegated-account operations to this contract to validate
 * successful calls, value forwarding, and target-level reverts.
 */

pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {ExecutionTarget} from "../test/mocks/ExecutionTarget.sol";

contract DeployExecutionTarget is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Deployer is only used to pay for deployment in the local environment.
        vm.startBroadcast(deployerPrivateKey);

        ExecutionTarget target = new ExecutionTarget();

        vm.stopBroadcast();

        console2.log("ExecutionTarget deployed at:", address(target));
    }
}