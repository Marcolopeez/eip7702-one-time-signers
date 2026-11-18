// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "../../lib/forge-std/src/console2.sol";
import {C0Base} from "./C0Base.sol";
import {OneTimeSignerAccount} from "../../src/OneTimeSignerAccount.sol";
import {RevertingTarget, StorageTarget, Witness} from "./mocks/C0Fixtures.sol";
import {OperationForwarder, ReturnBombTarget} from "./mocks/ExperimentTargets.sol";

/// @notice X2 bajo C0 (celdas C0-cl-O, C0-ql-O, C0-qr-O; ESPECIFICACION §1.1). ¿Cuándo deja de servir un firmante?
/// Foundry: F = I. La reorg (FI-9) se prueba en Anvil (experimentos/X2-ventana/scripts/).
contract X2_WindowTest is C0Base {
    RevertingTarget internal reverting;
    StorageTarget internal store;
    OperationForwarder internal fwd;
    ReturnBombTarget internal bomb;

    function setUp() public override {
        super.setUp();
        _migrate();
        reverting = new RevertingTarget();
        store = new StorageTarget();
        fwd = new OperationForwarder();
        bomb = new ReturnBombTarget();
    }

    function _ping(address next) internal view returns (OneTimeSignerAccount.Operation memory) {
        return op(address(witness), abi.encodeCall(Witness.ping, ()), next);
    }

    /// OP-adv con S1 retirada (cualquier contenido, sucesor del atacante) y OP-s con S2.
    function _postOracleS1RetiredS2Active() internal {
        OneTimeSignerAccount.Operation memory adv1 = _ping(attacker);
        bytes memory sigAdv = sign(S1_PK, adv1);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, S1, S2));
        acct().executeSignedAndRotate(adv1, sigAdv);
        OneTimeSignerAccount.Operation memory next = _ping(S3);
        assertTrue(_send(next, sign(S2_PK, next)), "OP-s(S2) ejecuta");
        assertEq(acct().currentAuthorizedSigner(), S3);
    }

    // ---------------------------------------------------------------- C0-cl-O

    /// Éxito; S1 inyectada DESPUÉS de su rotación (cl/ql: tras F).
    function test_X2_cl_success_s1InjectedAfterRotation_rejected() public {
        uint256 callsBefore = witness.calls();
        OneTimeSignerAccount.Operation memory o = _ping(S2);
        assertTrue(_send(o, sign(S1_PK, o)));
        assertEq(witness.calls(), callsBefore + 1);
        assertEq(witness.lastSender(), A);
        assertEq(acct().currentAuthorizedSigner(), S2);
        assertTrue(acct().isConsumedOrReservedSigner(S1));
        _postOracleS1RetiredS2Active();
    }

    /// Target que revierte: success=false, rotación persistente.
    function test_X2_cl_targetReverts_rotationPersists() public {
        OneTimeSignerAccount.Operation memory o = op(address(reverting), abi.encodeCall(RevertingTarget.fail, ()), S2);
        vm.prank(relayer);
        (bool success, bytes memory res) = acct().executeSignedAndRotate(o, sign(S1_PK, o));
        assertFalse(success);
        assertEq(res, abi.encodeWithSelector(RevertingTarget.TargetReverted.selector));
        assertEq(acct().currentAuthorizedSigner(), S2);
        assertFalse(stillAcceptable(o, sign(S1_PK, o)));
        _postOracleS1RetiredS2Active();
    }

    /// Wrapper que revierte: rotación deshecha, firma retenida; quien la reenvíe solo puede instalar S2.
    function test_X2_cl_wrapperReverts_signatureRetained_thenResubmitted() public {
        OneTimeSignerAccount.Operation memory o = _ping(S2);
        bytes memory sig = sign(S1_PK, o);
        vm.expectRevert(bytes("WRAPPER_REVERT"));
        fwd.forward(acct(), o, sig, true);
        assertEq(acct().currentAuthorizedSigner(), S1, "rotacion no efectiva");
        assertTrue(stillAcceptable(o, sig), "firma retenida y aceptable");
        // Reenvío por un tercero (después): se ejecuta el contenido firmado.
        vm.prank(attacker);
        acct().executeSignedAndRotate(o, sig);
        assertEq(acct().currentAuthorizedSigner(), S2);
        _postOracleS1RetiredS2Active();
    }

    struct Sweep {
        uint256 lastA;
        uint256 firstB;
        uint256 lastB;
        uint256 nB;
        uint256 firstC;
    }

    /// Barrido del gas del marco de la llamada a `a` (no es el gas límite de la transacción).
    /// Clases: (a) la llamada externa revierte y S1 sigue vigente; (b) la llamada externa termina, el target se queda
    /// sin gas (success=false) y la rotación persiste; (c) éxito completo.
    function _sweep(uint256 n, uint256 from, uint256 to, uint256 step) internal returns (Sweep memory w) {
        OneTimeSignerAccount.Operation memory o = op(address(store), abi.encodeCall(StorageTarget.write, (n)), S2);
        bytes memory cd = abi.encodeCall(OneTimeSignerAccount.executeSignedAndRotate, (o, sign(S1_PK, o)));
        for (uint256 g = from; g <= to; g += step) {
            uint256 snap = vm.snapshotState();
            vm.prank(relayer);
            (bool outerOk, bytes memory ret) = A.call{gas: g}(cd);
            address cur = acct().currentAuthorizedSigner();
            if (!outerOk) {
                assertEq(cur, S1, "(a): S1 sigue vigente");
                assertTrue(stillAcceptable(o, sign(S1_PK, o)), "(a): firma aceptable");
                w.lastA = g;
            } else {
                (bool success,) = abi.decode(ret, (bool, bytes));
                assertEq(cur, S2, "(b)/(c): rotacion persistente");
                if (!success) {
                    assertEq(store.writes(), 0, "(b): target sin efecto");
                    if (w.firstB == 0) w.firstB = g;
                    w.lastB = g;
                    w.nB++;
                } else {
                    assertEq(store.writes(), n);
                    if (w.firstC == 0) w.firstC = g;
                }
            }
            vm.revertToState(snap);
        }
        console2.log("X2 gas sweep, n de escrituras del target:", n);
        console2.log("  paso:", step);
        console2.log("  ultimo gas con (a) outer revert:", w.lastA);
        console2.log("  primer gas con (b) target sin gas y rotacion persistente:", w.firstB);
        console2.log("  ultimo gas con (b):", w.lastB);
        console2.log("  valores con (b):", w.nB);
        console2.log("  primer gas con (c) exito:", w.firstC);
    }

    /// Gas en los límites, target pequeño (5 escrituras): no hay banda (b); el 1/64 retenido no basta para terminar.
    function test_X2_cl_gasBoundaries_smallTarget_noConsumedWithoutEffect() public {
        Sweep memory w = _sweep(5, 20_000, 400_000, 1_000);
        assertEq(w.nB, 0, "sin banda (b) a esta resolucion");
        assertEq(w.firstC, w.lastA + 1_000, "(a) pasa directamente a (c)");
    }

    /// Gas en los límites, target grande (200 escrituras): existe una banda (b). Quien envía la operación puede elegir
    /// un gas con el que la firma se consume y la rotación persiste sin que el target tenga efecto.
    function test_X2_cl_gasBoundaries_largeTarget_consumedWithoutEffect() public {
        Sweep memory w = _sweep(200, 100_000, 6_000_000, 20_000);
        assertGt(w.lastA, 0, "hay casos (a)");
        assertGt(w.nB, 0, "existe banda (b)");
        assertGt(w.firstB, w.lastA);
        assertGt(w.firstC, w.lastB);
        // Operación posterior tras un caso (b): S1 retirada; S2 opera.
        OneTimeSignerAccount.Operation memory o = op(address(store), abi.encodeCall(StorageTarget.write, (200)), S2);
        vm.prank(relayer);
        (bool ok, bytes memory ret) =
            A.call{gas: w.firstB}(abi.encodeCall(OneTimeSignerAccount.executeSignedAndRotate, (o, sign(S1_PK, o))));
        assertTrue(ok);
        (bool success,) = abi.decode(ret, (bool, bytes));
        assertFalse(success);
        assertEq(store.writes(), 0);
        _postOracleS1RetiredS2Active();
    }

    /// H1 (returndata grande) con el oráculo completo de la celda.
    function test_X2_cl_H1_returnBomb_fullOracle() public {
        OneTimeSignerAccount.Operation memory o = op(address(bomb), abi.encodeCall(ReturnBombTarget.setNumber, (42)), S2);
        bytes memory sig = sign(S1_PK, o);
        vm.prank(relayer);
        (bool ok,) = A.call{gas: 5_000_000}(abi.encodeCall(OneTimeSignerAccount.executeSignedAndRotate, (o, sig)));
        assertFalse(ok);
        assertEq(acct().currentAuthorizedSigner(), S1);
        assertTrue(stillAcceptable(o, sig));
        bomb.setArmed(false); // quien opera el target decide cuándo
        vm.prank(attacker);
        acct().executeSignedAndRotate(o, sig);
        assertEq(acct().currentAuthorizedSigner(), S2, "solo el sucesor firmado");
        _postOracleS1RetiredS2Active();
    }

    // ---------------------------------------------------------------- C0-qr-O

    /// S1 inyectada ANTES de su rotación (qr: desde E). El atacante se adelanta con S1 y un sucesor suyo.
    function test_X2_qr_s1InjectedBeforeRotation_successorCaptured() public {
        OneTimeSignerAccount.Operation memory alice = _ping(S2);
        bytes memory sigAlice = sign(S1_PK, alice); // E: publicada en el mempool
        OneTimeSignerAccount.Operation memory cap = _ping(attacker);
        vm.prank(attacker);
        acct().executeSignedAndRotate(cap, sign(S1_PK, cap)); // incluida antes (orden simulado)
        assertEq(acct().currentAuthorizedSigner(), attacker);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, S1, attacker));
        acct().executeSignedAndRotate(alice, sigAlice);
        // Operación posterior: el sucesor del atacante ejecuta; S2 de Alicia no.
        OneTimeSignerAccount.Operation memory adv2 = _ping(vm.addr(0xBAD2));
        assertTrue(_send(adv2, sign(ATTACKER_PK, adv2)), "OP-adv con el sucesor del atacante ejecuta");
        OneTimeSignerAccount.Operation memory s2op = _ping(S3);
        bytes memory sigS2 = sign(S2_PK, s2op);
        vm.expectRevert(
            abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, S2, vm.addr(0xBAD2))
        );
        acct().executeSignedAndRotate(s2op, sigS2);
    }

    /// qr + wrapper: quien controla el wrapper retiene la firma y, con S1 obtenida de ella, captura.
    function test_X2_qr_wrapperRetention_thenCapture() public {
        OneTimeSignerAccount.Operation memory alice = _ping(S2);
        bytes memory sigAlice = sign(S1_PK, alice);
        vm.expectRevert(bytes("WRAPPER_REVERT"));
        fwd.forward(acct(), alice, sigAlice, true);
        OneTimeSignerAccount.Operation memory cap = _ping(attacker);
        vm.prank(attacker);
        acct().executeSignedAndRotate(cap, sign(S1_PK, cap));
        assertEq(acct().currentAuthorizedSigner(), attacker);
        assertFalse(stillAcceptable(alice, sigAlice), "la firma retenida de Alicia ya no sirve");
    }

    // ---------------------------------------------------------------- C0-ql-O

    /// S1 llega tras su F: revierte. Pero h (entregada con retraso en C0) prevalece (#16).
    function test_X2_ql_s1AfterF_rejected_but_hPrevails() public {
        OneTimeSignerAccount.Operation memory o = _ping(S2);
        assertTrue(_send(o, sign(S1_PK, o)));
        OneTimeSignerAccount.Operation memory adv1 = _ping(attacker);
        bytes memory sigAdv = sign(S1_PK, adv1);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, S1, S2));
        acct().executeSignedAndRotate(adv1, sigAdv);
        // h llega con retraso: OP-auth.
        _opAuthToAdversary();
        assertEq(A.code, _ind(address(adv)));
        assertFalse(_opSFails(S2_PK, S3), "OP-s(S2) ya no ejecuta OTS");
        // OP-tx: el atacante con h también puede vaciar `a`.
        uint256 bal = A.balance;
        vm.prank(A, A);
        payable(attacker).transfer(bal);
        assertEq(A.balance, 0);
    }
}
