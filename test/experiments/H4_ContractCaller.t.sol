// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ExperimentBase} from "./ExperimentBase.sol";
import {OneTimeSignerAccount} from "../../src/OneTimeSignerAccount.sol";
import {OperationForwarder, PlainTarget} from "./mocks/ExperimentTargets.sol";

/// @notice H4 (AFIRMACIONES #26): ¿OTS acepta llamadas desde contratos?
/// @dev Código examinado: `executeSignedAndRotate` (l. 337–343) y `signedRecovery` (l. 404–408) solo llevan los
///      modificadores onlyDelegatedAccount / onlyInitialized / onlyUnpausedAccount; no comprueban msg.sender ni
///      tx.origin. Oráculo: firmante actual tras la llamada y aceptabilidad de la misma firma.
contract H4_ContractCallerTest is ExperimentBase {
    OperationForwarder internal fwd;
    PlainTarget internal target;

    function setUp() public override {
        super.setUp();
        fwd = new OperationForwarder();
        target = new PlainTarget();
    }

    function test_H4_contractCallerIsAccepted() public {
        OneTimeSignerAccount.Operation memory o = op(address(target), abi.encodeCall(PlainTarget.setNumber, (7)), S2);
        bytes memory sig = sign(S1_PK, o);

        assertGt(address(fwd).code.length, 0, "caller is a contract");
        vm.prank(relayer, relayer);
        (bool success,) = fwd.forward(acct(), o, sig, false);

        assertTrue(success);
        assertEq(acct().currentAuthorizedSigner(), S2, "rotation effective");
        assertEq(target.lastSender(), A, "target sees the account");
    }

    /// Un contrato que revierte después de llamar deshace la rotación; la firma sigue siendo aceptable.
    function test_H4_wrapperRevert_undoesRotation_signatureRemainsAcceptable() public {
        OneTimeSignerAccount.Operation memory o = op(address(target), abi.encodeCall(PlainTarget.setNumber, (7)), S2);
        bytes memory sig = sign(S1_PK, o);

        vm.prank(relayer, relayer);
        vm.expectRevert(bytes("WRAPPER_REVERT"));
        fwd.forward(acct(), o, sig, true);

        assertEq(acct().currentAuthorizedSigner(), S1, "rotation undone");
        assertTrue(stillAcceptable(o, sig), "signature still acceptable");

        // Operación posterior: la misma firma, enviada después por cualquiera, se ejecuta con el contenido firmado.
        vm.prank(attacker);
        acct().executeSignedAndRotate(o, sig);
        assertEq(acct().currentAuthorizedSigner(), S2, "only the signed successor can be installed");
        assertEq(target.number(), 7);
    }

    function test_H4_contractCallerCanSubmitSignedRecovery() public {
        OneTimeSignerAccount.RecoveryOperation memory r = OneTimeSignerAccount.RecoveryOperation({
            nextAuthorizedSigner: S3,
            nextRecoverySigner: R3,
            deadline: block.timestamp + 1 days
        });
        bytes memory sig = signRecovery(R1_PK, r);

        (bool success,) = fwd.forwardRecovery(acct(), r, sig);

        assertTrue(success);
        assertEq(acct().currentAuthorizedSigner(), S3);
        assertFalse(acct().isActiveRecoverySigner(R1));
    }
}
