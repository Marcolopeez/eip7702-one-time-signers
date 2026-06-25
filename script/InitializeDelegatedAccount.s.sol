// SPDX-License-Identifier: MIT
/**
 * Attaches the EIP-7702 delegation and initializes the delegated EOA.
 *
 * The authority key is the native EOA key used to install delegation. The first
 * auth and recovery signers come from the TypeScript wallet derivation flow.
 */

pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {OneTimeSignerAccount} from "../src/OneTimeSignerAccount.sol";

contract InitializeDelegatedAccount is Script {
    function run() external {
        uint256 authorityPrivateKey = vm.envUint("AUTHORITY_PRIVATE_KEY");

        address authority = vm.addr(authorityPrivateKey);
        address implementation = vm.envAddress("IMPLEMENTATION_ADDRESS");
        address firstAuthorizedSigner = vm.envAddress("FIRST_AUTHORIZED_SIGNER");
        address firstRecoverySigner = vm.envAddress("FIRST_RECOVERY_SIGNER");

        address[] memory initialRecoverySigners = new address[](1);
        initialRecoverySigners[0] = firstRecoverySigner;

        console2.log("Authority / delegated EOA:", authority);
        console2.log("Implementation:", implementation);
        console2.log("First authorized signer:", firstAuthorizedSigner);
        console2.log("First recovery signer:", firstRecoverySigner);
        
        // Fund the account that sends the transaction
        vm.deal(authority, 1 ether);

        vm.startBroadcast(authorityPrivateKey);

        // After this cheatcode, calls to the authority EOA execute the implementation code.
        vm.signAndAttachDelegation(implementation, authorityPrivateKey);

        // initialize() writes to the delegated EOA storage, not to the implementation.
        OneTimeSignerAccount(payable(authority)).initialize(
            firstAuthorizedSigner,
            initialRecoverySigners
        );

        vm.stopBroadcast();

        // Sanity checks catch setup mistakes before the wallet creates local state.
        bool initialized = OneTimeSignerAccount(payable(authority)).isInitialized();
        bool paused = OneTimeSignerAccount(payable(authority)).isPaused();
        address currentSigner = OneTimeSignerAccount(payable(authority)).currentAuthorizedSigner();
        bool recoveryActive = OneTimeSignerAccount(payable(authority)).isActiveRecoverySigner(firstRecoverySigner);

        console2.log("Initialized:", initialized);
        console2.log("Paused:", paused);
        console2.log("Current authorized signer:", currentSigner);
        console2.log("Recovery signer active:", recoveryActive);

        require(initialized, "not initialized");
        require(!paused, "unexpected paused state");
        require(currentSigner == firstAuthorizedSigner, "wrong current authorized signer");
        require(recoveryActive, "recovery signer not active");
    }
}