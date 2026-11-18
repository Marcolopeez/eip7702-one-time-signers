// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {C0Base} from "./C0Base.sol";
import {OneTimeSignerAccount} from "../../src/OneTimeSignerAccount.sol";
import {Witness} from "./mocks/C0Fixtures.sol";
import {OperationForwarder, ReturnBombTarget} from "./mocks/ExperimentTargets.sol";

/// @notice X3 bajo C0, lado contrato (celdas C0-cl-R, C0-ql-R, C0-qr-R; ESPECIFICACION §1.1).
/// El lado wallet está en wallet/H2_walletDivergence.test.ts (H2) y wallet/X3_*.test.ts.
/// La redelegación con la management key (μ_j, D-29) necesita OTS-C1: no es ejecutable en C0.
contract X3_RecoveryTest is C0Base {
    OperationForwarder internal fwd;
    ReturnBombTarget internal bomb;
    uint256 internal constant ADV_REC_PK = 0xBADEC;
    address internal advRec;

    function setUp() public override {
        super.setUp();
        _migrate();
        fwd = new OperationForwarder();
        bomb = new ReturnBombTarget();
        advRec = vm.addr(ADV_REC_PK);
    }

    function _ping(address next) internal view returns (OneTimeSignerAccount.Operation memory) {
        return op(address(witness), abi.encodeCall(Witness.ping, ()), next);
    }

    /// Recuperación de Alicia con R1 -> (S3, R3) y oráculo posterior común.
    function _recoverAndCheck(address expectedPrevious) internal {
        OneTimeSignerAccount.RecoveryOperation memory r = _rec(S3, R3);
        vm.prank(relayer);
        (bool ok,) = acct().signedRecovery(r, signRecovery(R1_PK, r));
        assertTrue(ok, "OP-rec");
        assertEq(acct().currentAuthorizedSigner(), S3);
        assertFalse(acct().isPaused());
        assertFalse(acct().isActiveRecoverySigner(R1), "R1 consumida");
        assertTrue(acct().isActiveRecoverySigner(R2), "R2 sigue activa");
        assertTrue(acct().isActiveRecoverySigner(R3), "R3 instalada");
        // OP-rec con la ρ consumida revierte.
        OneTimeSignerAccount.RecoveryOperation memory r2 = _rec(vm.addr(0x5151), vm.addr(0x5252));
        bytes memory sigR1 = signRecovery(R1_PK, r2);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.RecoverySignerNotActive.selector, R1));
        acct().signedRecovery(r2, sigR1);
        // OP-adv con el firmante anterior (retirado o del atacante) revierte.
        OneTimeSignerAccount.Operation memory adv1 = _ping(attacker);
        bytes memory sigPrev = sign(expectedPrevious == attacker ? ATTACKER_PK : S1_PK, adv1);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, expectedPrevious, S3));
        acct().executeSignedAndRotate(adv1, sigPrev);
        // OP-s(S3) ejecuta.
        OneTimeSignerAccount.Operation memory o = _ping(vm.addr(0x6161));
        assertTrue(_send(o, sign(S3_PK, o)), "OP-s(S3)");
        // h sigue activa y no por efecto de la recuperación: OP-tx incluida.
        uint256 calls = witness.calls();
        _opTx();
        assertEq(witness.calls(), calls + 1);
        assertEq(witness.lastOrigin(), A);
    }

    // ---------------------------------------------------------------- C0-cl-R

    function test_X3_cl_fromPaused() public {
        OneTimeSignerAccount.Operation memory o = _ping(address(0)); // sucesor inválido
        vm.prank(relayer);
        (bool success,) = acct().executeSignedAndRotate(o, sign(S1_PK, o));
        assertFalse(success);
        assertTrue(acct().isPaused(), "PAUSED");
        assertEq(acct().currentAuthorizedSigner(), S1, "S1 expuesta, sin sucesor");
        // S1 no opera mientras está pausada.
        OneTimeSignerAccount.Operation memory o2 = _ping(S2);
        bytes memory sig2 = sign(S1_PK, o2);
        vm.expectRevert(OneTimeSignerAccount.AccountIsPaused.selector);
        acct().executeSignedAndRotate(o2, sig2);
        _recoverAndCheck(S1);
    }

    /// Divergencia por H1: la rotación se deshizo, la firma de S1 está retenida (la wallet queda en PENDING_OPERATION).
    function test_X3_cl_fromH1Divergence_recoveryAlsoKillsRetainedSignature() public {
        OneTimeSignerAccount.Operation memory o = op(address(bomb), abi.encodeCall(ReturnBombTarget.setNumber, (1)), S2);
        bytes memory sig = sign(S1_PK, o);
        vm.prank(relayer);
        (bool ok,) = A.call{gas: 5_000_000}(abi.encodeCall(OneTimeSignerAccount.executeSignedAndRotate, (o, sig)));
        assertFalse(ok);
        assertTrue(stillAcceptable(o, sig), "firma retenida");
        assertFalse(acct().isPaused(), "cuenta activa");
        _recoverAndCheck(S1);
        // La firma retenida ya no se puede hacer efectiva.
        bomb.setArmed(false);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, S1, vm.addr(0x6161)));
        acct().executeSignedAndRotate(o, sig);
    }

    /// Divergencia por H4: wrapper que revierte.
    function test_X3_cl_fromH4Divergence_recoveryAlsoKillsRetainedSignature() public {
        OneTimeSignerAccount.Operation memory o = _ping(S2);
        bytes memory sig = sign(S1_PK, o);
        vm.expectRevert(bytes("WRAPPER_REVERT"));
        fwd.forward(acct(), o, sig, true);
        assertTrue(stillAcceptable(o, sig));
        _recoverAndCheck(S1);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, S1, vm.addr(0x6161)));
        acct().executeSignedAndRotate(o, sig);
    }

    /// Divergencia por sucesor desconocido (capturado), con la cuenta activa.
    function test_X3_cl_fromUnknownSuccessor() public {
        OneTimeSignerAccount.Operation memory cap = _ping(attacker);
        vm.prank(attacker);
        acct().executeSignedAndRotate(cap, sign(S1_PK, cap));
        assertEq(acct().currentAuthorizedSigner(), attacker);
        _recoverAndCheck(attacker);
    }

    // ---------------------------------------------------------------- C0-ql-R

    /// ρ llega tras su consumo final: inútil. h llega con retraso: tras OP-auth ninguna ρ sirve.
    function test_X3_ql_consumedRhoUseless_but_hRedelegates() public {
        OneTimeSignerAccount.RecoveryOperation memory r = _rec(S3, R3);
        vm.prank(relayer);
        acct().signedRecovery(r, signRecovery(R1_PK, r));
        // ρ consumida en manos del atacante:
        OneTimeSignerAccount.RecoveryOperation memory rA = _rec(attacker, advRec);
        bytes memory sigA = signRecovery(R1_PK, rA);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.RecoverySignerNotActive.selector, R1));
        acct().signedRecovery(rA, sigA);
        assertEq(acct().currentAuthorizedSigner(), S3);
        // h con retraso: OP-auth.
        _opAuthToAdversary();
        assertEq(A.code, _ind(address(adv)));
        // OP-rec de Alicia con R2 (activa en el storage) ya no llega a OTS.
        OneTimeSignerAccount.RecoveryOperation memory r2 = _rec(vm.addr(0x7171), vm.addr(0x7272));
        bytes32 d = keccak256(
            abi.encodePacked(
                "\x19\x01",
                keccak256(
                    abi.encode(
                        implementation.DOMAIN_TYPEHASH(), implementation.NAME_HASH(), implementation.VERSION_HASH(),
                        block.chainid, A
                    )
                ),
                implementation.recoveryOperationStructHash(r2)
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(R2_PK, d);
        vm.prank(relayer);
        (bool ok,) = A.call(abi.encodeCall(OneTimeSignerAccount.signedRecovery, (r2, bytes.concat(rr, ss, bytes1(v)))));
        assertFalse(ok, "OP-rec tras OP-auth: el codigo de a ya no es OTS");
        assertEq(A.code, _ind(address(adv)));
        // El storage de OTS sigue ahí, pero sin código que lo use.
        assertEq(address(uint160(uint256(vm.load(A, bytes32(uint256(0))) >> 16))), S3, "slot 0: currentAuthorizedSigner");
    }

    // ---------------------------------------------------------------- C0-qr-R

    /// Alicia usa R1; el atacante la obtiene del mempool y se adelanta con su RecoveryOperation.
    /// Después: carrera sin fin entre R2 (Alicia) y la ρ instalada por el atacante; ninguna puede revocar a la otra.
    function test_X3_qr_recoveryRace_noRevocationOfOtherRho() public {
        OneTimeSignerAccount.RecoveryOperation memory alice = _rec(S3, R3);
        bytes memory sigAlice = signRecovery(R1_PK, alice); // E
        OneTimeSignerAccount.RecoveryOperation memory cap = _rec(attacker, advRec);
        vm.prank(attacker);
        acct().signedRecovery(cap, signRecovery(R1_PK, cap)); // incluida antes
        assertEq(acct().currentAuthorizedSigner(), attacker);
        assertTrue(acct().isActiveRecoverySigner(advRec), "rho del atacante activa");
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.RecoverySignerNotActive.selector, R1));
        acct().signedRecovery(alice, sigAlice);
        // Alicia aún tiene R2 activa: recupera.
        OneTimeSignerAccount.RecoveryOperation memory back = _rec(S3, R3);
        vm.prank(relayer);
        acct().signedRecovery(back, signRecovery(R2_PK, back));
        assertEq(acct().currentAuthorizedSigner(), S3);
        assertTrue(acct().isActiveRecoverySigner(advRec), "la rho del atacante sigue activa: OTS no la puede revocar");
        // El atacante vuelve a recuperar con su ρ.
        OneTimeSignerAccount.RecoveryOperation memory again = _rec(vm.addr(0xBAD3), vm.addr(0xBAD4));
        vm.prank(attacker);
        acct().signedRecovery(again, signRecovery(ADV_REC_PK, again));
        assertEq(acct().currentAuthorizedSigner(), vm.addr(0xBAD3), "R falla: carrera");
        assertTrue(acct().isActiveRecoverySigner(R3), "y Alicia conserva R3");
    }
}
