// SPDX-License-Identifier: MIT
/**
 * Deploys the reusable EphemeralKeyAccount implementation.
 *
 * EIP-7702 delegated EOAs point to this implementation, but each delegated EOA
 * owns its own storage when the code executes through delegation.
 */

pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {EphemeralKeyAccount} from "../src/EphemeralKeyAccount.sol";

contract DeployImplementation is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Only the implementation contract is deployed here; no account is initialized.
        vm.startBroadcast(deployerPrivateKey);

        EphemeralKeyAccount implementation = new EphemeralKeyAccount();

        vm.stopBroadcast();

        console2.log("Implementation deployed at:", address(implementation));
        console2.log("Chain ID:", block.chainid);
    }
}