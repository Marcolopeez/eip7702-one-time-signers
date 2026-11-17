// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ExperimentBase} from "./ExperimentBase.sol";
import {OneTimeSignerAccount} from "../../src/OneTimeSignerAccount.sol";
import {PlainTarget} from "./mocks/ExperimentTargets.sol";

/// @notice H2 (AFIRMACIONES #24), lado contrato: ruta de salida desde un estado divergente.
/// @dev Estado divergente: la clave S1 se compromete antes de que su rotación sea final (cuántico rápido o robo);
///      el atacante firma con S1 una operación cuyo sucesor es suyo. La cuenta queda ACTIVA (no pausada).
///      El contrato permite recuperar sin pausa (l. 404–408: `signedRecovery` no lleva onlyUnpausedAccount ni
///      exige isPaused). La ruta de la wallet se prueba en wallet/H2_walletDivergence.test.ts.
contract H2_ContractRecoveryTest is ExperimentBase {
    PlainTarget internal target;

    function setUp() public override {
        super.setUp();
        target = new PlainTarget();
    }

    function test_H2_contractRoute_recoversActiveAccountUnderAttackerSuccessor() public {
        // Captura: el atacante usa S1 (inyectada) y nombra a su propio sucesor.
        OneTimeSignerAccount.Operation memory capture =
            op(address(target), abi.encodeCall(PlainTarget.setNumber, (666)), attacker);
        vm.prank(attacker);
        acct().executeSignedAndRotate(capture, sign(S1_PK, capture));
        assertEq(acct().currentAuthorizedSigner(), attacker, "divergent: attacker successor installed");
        assertFalse(acct().isPaused(), "account active, not paused");

        // Salida por el contrato: R1 recupera con la cuenta activa.
        OneTimeSignerAccount.RecoveryOperation memory r = OneTimeSignerAccount.RecoveryOperation({
            nextAuthorizedSigner: S3,
            nextRecoverySigner: R3,
            deadline: block.timestamp + 1 days
        });
        vm.prank(relayer);
        (bool ok,) = acct().signedRecovery(r, signRecovery(R1_PK, r));
        assertTrue(ok);
        assertEq(acct().currentAuthorizedSigner(), S3);

        // Operación posterior: el firmante del atacante ya no autoriza nada; S1 tampoco.
        OneTimeSignerAccount.Operation memory later =
            op(address(target), abi.encodeCall(PlainTarget.setNumber, (1)), vm.addr(0x5151));
        bytes memory sigAttacker = sign(ATTACKER_PK, later);
        bytes memory sigS1 = sign(S1_PK, later);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, attacker, S3));
        acct().executeSignedAndRotate(later, sigAttacker);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, S1, S3));
        acct().executeSignedAndRotate(later, sigS1);

        // Y el titular opera con S3.
        acct().executeSignedAndRotate(later, sign(S3_PK, later));
        assertEq(target.number(), 1);
    }
}
