// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {C0Base} from "./C0Base.sol";
import {OneTimeSignerAccount} from "../../src/OneTimeSignerAccount.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    SenderVault, OwnedBox, OriginGated, PermitToken, SigGate, OTS1271Naive, OTS1271ApprovedHash, AdversaryCode
} from "./mocks/C0Fixtures.sol";
import {SignatureVerification} from "./mocks/vendor/permit2-cc56ad0f/SignatureVerification.sol";

/// @notice X4 bajo C0 (ESPECIFICACION §3): relaciones creadas con `a` todavía EOA; ensayo antes de migrar y después
/// en C0, cada uno con un ataque con `h` y un control legítimo de Alicia. Resultados en
/// experimentos/X4-relaciones/resultados/.
/// Limitación: X4-2 en Foundry no prueba la regla del protocolo. `vm.prank(a, a)` fija `tx.origin` a voluntad;
/// la regla de origen de 7702 (l. 191–195) no se ejerce aquí.
contract X4_RelationshipsTest is C0Base {
    SenderVault internal vault;
    OwnedBox internal box;
    OriginGated internal gated;
    PermitToken internal token;
    SigGate internal gate;

    address internal aliceDest = address(0xA1D);
    address internal spender = address(0x5E4D);

    function setUp() public override {
        super.setUp();
        // Relaciones creadas ANTES de migrar, con `a` como EOA (ind(a) vacío).
        assertEq(A.code.length, 0, "pre: a sin codigo");
        vault = new SenderVault();
        vm.prank(A, A);
        vault.deposit{value: 1 ether}();
        box = new OwnedBox(A);
        gated = new OriginGated();
        token = new PermitToken();
        token.mint(A, 100 ether);
        gate = new SigGate();
    }

    // ------------------------------------------------------------------ helpers

    function _permitDigest(address owner, address sp, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                sp,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function _signDigest(uint256 pk, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return bytes.concat(r, s, bytes1(v));
    }

    // ===================================================================== X4-1 msg.sender

    function test_X4_1_pre_attackWithH_and_legitControl() public {
        // Ataque con h antes de migrar: quien tenga h es `a`.
        vm.prank(A, A);
        vault.withdrawTo(payable(attacker), 0.4 ether);
        assertEq(attacker.balance, 0.4 ether);
        // Control legítimo (Alicia con h): mismo camino.
        vm.prank(A, A);
        vault.withdrawTo(payable(aliceDest), 0.1 ether);
        assertEq(aliceDest.balance, 0.1 ether);
        vm.prank(A, A);
        box.setValue(1);
        assertEq(box.value(), 1);
    }

    function test_X4_1_C0_legitControl_opS_keepsRelation() public {
        _migrate();
        assertEq(A.code, _ind(address(implementation)));
        OneTimeSignerAccount.Operation memory o =
            op(address(vault), abi.encodeCall(SenderVault.withdrawTo, (payable(aliceDest), 0.5 ether)), S2);
        assertTrue(_send(o, sign(S1_PK, o)), "OP-s withdraw");
        assertEq(aliceDest.balance, 0.5 ether);
        assertEq(vault.balanceOf(A), 0.5 ether);
        OneTimeSignerAccount.Operation memory o2 = op(address(box), abi.encodeCall(OwnedBox.setValue, (7)), S3);
        assertTrue(_send(o2, sign(S2_PK, o2)), "OP-s onlyOwner");
        assertEq(box.value(), 7);
        assertEq(box.owner(), A);
        // Estado final + operación posterior: OP-adv(S1) revierte.
        assertEq(acct().currentAuthorizedSigner(), S3);
        OneTimeSignerAccount.Operation memory o3 = op(address(box), abi.encodeCall(OwnedBox.setValue, (8)), vm.addr(0x77));
        bytes memory sigOld = sign(S1_PK, o3);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, S1, S3));
        acct().executeSignedAndRotate(o3, sigOld);
    }

    function test_X4_1_C0_attackWithH_opTx_coexistsWithOTS() public {
        _migrate();
        // OP-tx de h: retira del vault y cambia el valor del Ownable con OTS activo.
        vm.prank(A, A);
        vault.withdrawTo(payable(attacker), 1 ether);
        vm.prank(A, A);
        box.setValue(666);
        assertEq(attacker.balance, 1 ether);
        assertEq(box.value(), 666);
        // h también puede transferir la propiedad: la relación pasa al atacante.
        vm.prank(A, A);
        box.transferOwnership(attacker);
        assertEq(box.owner(), attacker);
        // Estado final: OTS intacto (ind(a) e inicialización); OP-s ejecuta, pero ya no es owner.
        assertEq(A.code, _ind(address(implementation)));
        assertEq(acct().currentAuthorizedSigner(), S1);
        OneTimeSignerAccount.Operation memory o = op(address(box), abi.encodeCall(OwnedBox.setValue, (1)), S2);
        vm.prank(relayer);
        (bool success, bytes memory res) = acct().executeSignedAndRotate(o, sign(S1_PK, o));
        assertFalse(success, "OP-s: target revierte (ya no es owner)");
        assertEq(res, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, A));
        assertEq(acct().currentAuthorizedSigner(), S2, "OTS rota igualmente");
    }

    function test_X4_1_C0_attackWithH_opAuth_takesRelation() public {
        _migrate();
        vm.signAndAttachDelegation(address(adv), H_PK);
        vm.prank(attacker);
        AdversaryCode(payable(A)).exec(
            address(vault), 0, abi.encodeCall(SenderVault.withdrawTo, (payable(attacker), 1 ether))
        );
        assertEq(attacker.balance, 1 ether);
        assertEq(A.code, _ind(address(adv)), "ind(a) = 0xef0100||Adv");
        // Operación posterior: OP-s de Alicia ya no llega a OTS.
        assertFalse(_opSFails(S1_PK, S2), "OP-s falla tras OP-auth");
    }

    // ===================================================================== X4-2 tx.origin

    function test_X4_2_pre_hUsesOriginGated() public {
        vm.prank(A, A);
        gated.claim();
        assertEq(gated.claims(A), 1);
    }

    function test_X4_2_C0_legitControl_opS_losesRelation() public {
        _migrate();
        OneTimeSignerAccount.Operation memory o = op(address(gated), abi.encodeCall(OriginGated.claim, ()), S2);
        vm.prank(relayer, relayer); // tx.origin = relayer
        (bool success, bytes memory res) = acct().executeSignedAndRotate(o, sign(S1_PK, o));
        assertFalse(success, "OP-s: msg.sender (a) != tx.origin (relayer)");
        assertEq(res, abi.encodeWithSignature("Error(string)", "ONLY_EOA"));
        assertEq(gated.claims(A), 0);
        assertEq(gated.claims(relayer), 0);
        // Estado final: firma consumida, rotación persistente.
        assertEq(acct().currentAuthorizedSigner(), S2);
    }

    function test_X4_2_C0_attackWithH_opTx_keepsRelation() public {
        _migrate();
        vm.prank(A, A); // modelo de una transacción de h (Foundry fija tx.origin; no prueba la regla de 7702)
        gated.claim();
        assertEq(gated.claims(A), 1, "quien tenga h sigue usando la relacion");
        // Operación posterior: OTS sigue activo y OP-s ejecuta (con otro target).
        _opTx();
        assertEq(witness.lastOrigin(), A);
        OneTimeSignerAccount.Operation memory o = op(address(witness), abi.encodeWithSignature("ping()"), S2);
        assertTrue(_send(o, sign(S1_PK, o)));
    }

    // ===================================================================== X4-3 ecrecover (ERC20Permit)

    function test_X4_3_pre_permitWithH() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 d = _permitDigest(A, spender, 10 ether, token.nonces(A), dl);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(H_PK, d);
        token.permit(A, spender, 10 ether, dl, v, r, s);
        assertEq(token.allowance(A, spender), 10 ether);
    }

    function test_X4_3_C0_attackWithH_oldAndNewPermitsAccepted() public {
        uint256 dl = block.timestamp + 30 days;
        // Firmado antes de migrar (nonce 0), usado después.
        bytes32 dOld = _permitDigest(A, spender, 10 ether, 0, dl);
        (uint8 v0, bytes32 r0, bytes32 s0) = vm.sign(H_PK, dOld);
        _migrate();
        assertGt(A.code.length, 0);
        token.permit(A, spender, 10 ether, dl, v0, r0, s0);
        assertEq(token.allowance(A, spender), 10 ether, "permit anterior a la migracion aceptado");
        // Firmado después de migrar (nonce 1).
        bytes32 dNew = _permitDigest(A, attacker, 90 ether, 1, dl);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(H_PK, dNew);
        token.permit(A, attacker, 90 ether, dl, v1, r1, s1);
        vm.prank(attacker);
        token.transferFrom(A, attacker, 90 ether);
        assertEq(token.balanceOf(attacker), 90 ether, "residuo: h vacia el token con OTS activo");
        // Operación posterior: OTS no lo impide; OP-s ejecuta y rota.
        OneTimeSignerAccount.Operation memory o = op(address(witness), abi.encodeWithSignature("ping()"), S2);
        assertTrue(_send(o, sign(S1_PK, o)));
        assertEq(acct().currentAuthorizedSigner(), S2);
    }

    function test_X4_3_C0_legitControl_approveViaOpS_and_noPermitWithoutH() public {
        _migrate();
        OneTimeSignerAccount.Operation memory o =
            op(address(token), abi.encodeWithSignature("approve(address,uint256)", spender, 5 ether), S2);
        assertTrue(_send(o, sign(S1_PK, o)), "approve via OP-s");
        assertEq(token.allowance(A, spender), 5 ether);
        // Alicia no puede firmar un permit con su firmante OTS: ERC20Permit solo acepta a `a` = addr(h).
        uint256 dl = block.timestamp + 1 days;
        bytes32 d = _permitDigest(A, spender, 1 ether, token.nonces(A), dl);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(S2_PK, d);
        vm.expectRevert(); // ERC2612InvalidSigner(S2, A)
        token.permit(A, spender, 1 ether, dl, v, r, s);
    }

    // ===================================================================== X4-4 ERC-1271 condicionado al código

    bytes32 internal constant MSG = keccak256("X4-4 message");

    function test_X4_4_pre_hAcceptedByBoth() public {
        bytes memory sig = _signDigest(H_PK, MSG);
        gate.actPermit2(A, MSG, sig);
        gate.actOZ(A, MSG, sig);
        assertEq(gate.actsPermit2(A), 1);
        assertEq(gate.actsOZ(A), 1);
    }

    function test_X4_4_C0_hRejected_oldAndNew_and_control1Rejected() public {
        bytes memory sigOld = _signDigest(H_PK, MSG); // firmada antes de migrar
        _migrate();
        assertEq(A.code.length, 23, "EXTCODESIZE = 23");
        bytes memory sigNew = _signDigest(H_PK, keccak256("X4-4 new"));
        // Permit2: llama a isValidSignature en `a`; OTS tal cual no la tiene ni tiene fallback -> revert.
        vm.expectRevert(bytes("")); // revert sin datos: selector inexistente en OTS
        gate.actPermit2(A, MSG, sigOld);
        vm.expectRevert(bytes(""));
        gate.actPermit2(A, keccak256("X4-4 new"), sigNew);
        // OZ: la staticcall falla -> false.
        vm.expectRevert(bytes("OZ_INVALID_SIGNATURE"));
        gate.actOZ(A, MSG, sigOld);
        // Control (1): Alicia con OTS tal cual, firmando con su firmante vigente: rechazada.
        bytes memory sigS1 = _signDigest(S1_PK, MSG);
        vm.expectRevert(bytes(""));
        gate.actPermit2(A, MSG, sigS1);
        vm.expectRevert(bytes("OZ_INVALID_SIGNATURE"));
        gate.actOZ(A, MSG, sigS1);
        assertEq(gate.actsPermit2(A) + gate.actsOZ(A), 0);
        // Operación posterior: OTS sigue operativo.
        OneTimeSignerAccount.Operation memory o = op(address(witness), abi.encodeWithSignature("ping()"), S2);
        assertTrue(_send(o, sign(S1_PK, o)));
    }

    /// Control (2), resuelto: hash aprobado en cadena mediante una operación de OTS que rota.
    function test_X4_4_C0_control2_approvedHash_acceptedAndRotates() public {
        OTS1271ApprovedHash impl2 = new OTS1271ApprovedHash();
        bytes memory sigOld = _signDigest(H_PK, MSG);
        _migrateTo(address(impl2));
        OneTimeSignerAccount.Operation memory o =
            op(A, abi.encodeCall(OTS1271ApprovedHash.approveHash, (MSG)), S2);
        vm.prank(relayer);
        (bool success,) = acct().executeSignedAndRotate(o, sign(S1_PK, o));
        assertTrue(success, "approveHash via OP-s (target = a)");
        assertEq(acct().currentAuthorizedSigner(), S2, "la aprobacion consume S1");
        // Permit2 y OZ aceptan con firma vacía: la relación depende de la política de la cuenta.
        gate.actPermit2(A, MSG, "");
        gate.actOZ(A, MSG, "");
        assertEq(gate.actsPermit2(A), 1);
        assertEq(gate.actsOZ(A), 1);
        // Ataque con h: sus firmas (antigua y nueva) no aprueban nada.
        bytes32 other = keccak256("X4-4 other");
        vm.expectRevert(SignatureVerification.InvalidContractSignature.selector);
        gate.actPermit2(A, other, _signDigest(H_PK, other));
        vm.expectRevert(bytes("OZ_INVALID_SIGNATURE"));
        gate.actOZ(A, other, sigOld);
        // Operación posterior: S1 retirada no aprueba (OP-adv revierte).
        OneTimeSignerAccount.Operation memory o2 =
            op(A, abi.encodeCall(OTS1271ApprovedHash.approveHash, (other)), vm.addr(0x99));
        bytes memory sigAdv = sign(S1_PK, o2);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, S1, S2));
        acct().executeSignedAndRotate(o2, sigAdv);
    }

    /// Variante ingenua: muestra el conflicto con O (no se propone como diseño).
    function test_X4_4_C0_naive1271_exposesActiveSigner_conflictWithO() public {
        OTS1271Naive implN = new OTS1271Naive();
        _migrateTo(address(implN));
        bytes memory sigS1 = _signDigest(S1_PK, MSG);
        gate.actPermit2(A, MSG, sigS1);
        assertEq(gate.actsPermit2(A), 1, "firma de S1 aceptada");
        assertEq(acct().currentAuthorizedSigner(), S1, "sin rotacion: S1 publicada y vigente");
        // qr: el atacante obtiene S1 de la firma publicada y captura el sucesor.
        OneTimeSignerAccount.Operation memory cap = op(address(witness), abi.encodeWithSignature("ping()"), attacker);
        vm.prank(attacker);
        acct().executeSignedAndRotate(cap, sign(S1_PK, cap));
        assertEq(acct().currentAuthorizedSigner(), attacker, "captura del sucesor");
        // Y la firma 1271 de S1 deja de valer al rotar (revocable).
        vm.expectRevert(SignatureVerification.InvalidContractSignature.selector);
        gate.actPermit2(A, MSG, sigS1);
    }
}
