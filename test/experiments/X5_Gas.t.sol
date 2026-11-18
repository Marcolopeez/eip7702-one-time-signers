// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "../../lib/forge-std/src/console2.sol";
import {Vm} from "../../lib/forge-std/src/Vm.sol";
import {C0Base} from "./C0Base.sol";
import {OneTimeSignerAccount} from "../../src/OneTimeSignerAccount.sol";
import {RevertingTarget, Witness} from "./mocks/C0Fixtures.sol";

/// @notice X5 (paso 22), Foundry: gas de ejecución de cada llamada (vm.lastCallGas: sin coste intrínseco de la
/// transacción ni calldata, sin la tupla 7702). Las cifras de transacción completa salen de los receipts de Anvil
/// (experimentos/X5-costes/scripts/anvil-x5.sh). Las cifras se registran en experimentos/X5-costes/resultados/.
contract X5_GasTest is C0Base {
    RevertingTarget internal reverting;

    function setUp() public override {
        super.setUp();
        reverting = new RevertingTarget();
    }

    function _log(string memory what) internal view returns (uint256 used) {
        Vm.Gas memory g = vm.lastCallGas();
        used = g.gasTotalUsed;
        console2.log(what, used);
    }

    function test_X5_gas_executionOfEachPhase() public {
        // Migración: solo la ejecución de initialize (la tupla la aplica el cheatcode).
        vm.signAndAttachDelegation(address(implementation), H_PK);
        address[] memory recovery = new address[](2);
        recovery[0] = R1;
        recovery[1] = R2;
        vm.prank(A);
        acct().initialize(S1, recovery);
        assertGt(_log("X5 foundry initialize (2 recuperaciones):"), 0);

        // Operación con éxito (primera y segunda: almacenamiento frío/caliente distinto).
        OneTimeSignerAccount.Operation memory o1 = op(address(witness), abi.encodeCall(Witness.ping, ()), S2);
        bytes memory s1 = sign(S1_PK, o1);
        vm.prank(relayer);
        acct().executeSignedAndRotate(o1, s1);
        assertGt(_log("X5 foundry operacion con exito (1a):"), 0);
        OneTimeSignerAccount.Operation memory o2 = op(address(witness), abi.encodeCall(Witness.ping, ()), S3);
        bytes memory s2 = sign(S2_PK, o2);
        vm.prank(relayer);
        acct().executeSignedAndRotate(o2, s2);
        assertGt(_log("X5 foundry operacion con exito (2a):"), 0);

        // Operación con fallo del target.
        address n4 = vm.addr(0x4444);
        OneTimeSignerAccount.Operation memory o3 = op(address(reverting), abi.encodeCall(RevertingTarget.fail, ()), n4);
        bytes memory s3 = sign(S3_PK, o3);
        vm.prank(relayer);
        (bool success,) = acct().executeSignedAndRotate(o3, s3);
        assertFalse(success);
        assertGt(_log("X5 foundry operacion con fallo del target:"), 0);

        // Operación con sucesor inválido (pausa).
        OneTimeSignerAccount.Operation memory o4 = op(address(witness), abi.encodeCall(Witness.ping, ()), address(0));
        bytes memory s4 = sign(0x4444, o4);
        vm.prank(relayer);
        acct().executeSignedAndRotate(o4, s4);
        assertGt(_log("X5 foundry operacion que pausa:"), 0); // antes de cualquier otra llamada
        assertTrue(acct().isPaused());

        // Recuperación desde PAUSED.
        OneTimeSignerAccount.RecoveryOperation memory r = _rec(vm.addr(0x5555), R3);
        bytes memory rs = signRecovery(R1_PK, r);
        vm.prank(relayer);
        acct().signedRecovery(r, rs);
        assertGt(_log("X5 foundry recuperacion desde PAUSED:"), 0);
        assertFalse(acct().isPaused());
    }
}
