// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {C0Base} from "./C0Base.sol";
import {OneTimeSignerAccount} from "../../src/OneTimeSignerAccount.sol";
import {AdversaryCode, Witness} from "./mocks/C0Fixtures.sol";

/// @notice Filas M de C0 (C0-cl-M, C0-ql-M, C0-qr-M, C0-hc-*) y FI-2 en Foundry (ESPECIFICACION §1.1 y §2.5).
/// Foundry: `signAndAttachDelegation` modela la tupla 7702, no una transacción de tipo 4 real; el orden de
/// inclusión (C0-qr-M, FI-8) y la persistencia real de la tupla (FI-2) se prueban en Anvil
/// (experimentos/X1-migracion-C0/scripts/anvil-m.sh).
contract X1_MigrationC0Test is C0Base {
    function _drainByH() internal {
        uint256 bal = A.balance;
        vm.prank(A, A); // OP-tx: transacción de h con origen a
        payable(attacker).transfer(bal);
        assertEq(A.balance, 0, "OP-tx vacia a");
    }

    // ---------------------------------------------------------------- C0-cl-M

    function test_M_cl_migrationInstallsPolicy_but_hRetainsProtocolAuthority() public {
        assertEq(A.code.length, 0, "pre: a sin codigo");
        _migrate();
        assertEq(A.code, _ind(address(implementation)));
        assertTrue(acct().isInitialized());
        assertEq(acct().currentAuthorizedSigner(), S1);
        assertTrue(acct().isActiveRecoverySigner(R1));
        // h se roba después de F.
        _opAuthToAdversary();
        assertEq(A.code, _ind(address(adv)), "OP-auth: ind(a)=0xef0100||Adv");
        assertFalse(_opSFails(S1_PK, S2), "OP-s ya no ejecuta OTS");
        _drainByH();
    }

    // ---------------------------------------------------------------- C0-ql-M

    /// h llega con un retraso arbitrario (aquí, un año y 2,6M bloques): no cambia nada, porque en C0 h no se retira.
    function test_M_ql_hDeliveredMuchLater_stillRedelegatesAndDrains() public {
        _migrate();
        OneTimeSignerAccount.Operation memory o = op(address(witness), abi.encodeCall(Witness.ping, ()), S2);
        assertTrue(_send(o, sign(S1_PK, o)), "Alicia opera normalmente");
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 2_600_000);
        _opTx();
        assertEq(witness.lastOrigin(), A, "OP-tx de h incluida");
        _opAuthToAdversary();
        assertEq(A.code, _ind(address(adv)));
        assertFalse(_opSFails(S2_PK, S3));
        _drainByH();
    }

    // ---------------------------------------------------------------- C0-hc-M

    /// h en manos del atacante antes de migrar: quien delega el último decide el código.
    function test_M_hc_attackerBeforeAndAfterMigration() public {
        _opAuthToAdversary(); // antes de la migración
        assertEq(A.code, _ind(address(adv)));
        _migrate(); // Alicia migra igualmente (h es también suya)
        assertEq(A.code, _ind(address(implementation)));
        assertEq(acct().currentAuthorizedSigner(), S1);
        _opAuthToAdversary(); // y el atacante vuelve a redelegar
        assertEq(A.code, _ind(address(adv)), "sin garantia");
        assertFalse(_opSFails(S1_PK, S2));
    }

    // ---------------------------------------------------------------- C0-hc-O

    function test_M_hc_O_opTxDrainsWithOTSActive_thenOTSStillOperates() public {
        _migrate();
        _drainByH();
        assertEq(A.code, _ind(address(implementation)), "OTS sigue delegado");
        OneTimeSignerAccount.Operation memory o = op(address(witness), abi.encodeCall(Witness.ping, ()), S2);
        assertTrue(_send(o, sign(S1_PK, o)), "OP-s ejecuta: OTS no ve la transaccion de h");
        assertEq(acct().currentAuthorizedSigner(), S2);
    }

    // ---------------------------------------------------------------- C0-hc-R

    function test_M_hc_R_opAuthThenRecoveryFails() public {
        _migrate();
        _opAuthToAdversary();
        OneTimeSignerAccount.RecoveryOperation memory r = _rec(S3, R3);
        // Firma calculada con el dominio de OTS en a (hashRecoveryOperation ya no existe en a).
        bytes32 d = keccak256(
            abi.encodePacked(
                "\x19\x01",
                keccak256(
                    abi.encode(
                        implementation.DOMAIN_TYPEHASH(), implementation.NAME_HASH(), implementation.VERSION_HASH(),
                        block.chainid, A
                    )
                ),
                implementation.recoveryOperationStructHash(r)
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(R1_PK, d);
        vm.prank(relayer);
        (bool ok,) = A.call(abi.encodeCall(OneTimeSignerAccount.signedRecovery, (r, bytes.concat(rr, ss, bytes1(v)))));
        assertFalse(ok, "OP-rec no llega a OTS");
        assertEq(A.code, _ind(address(adv)));
    }

    // ---------------------------------------------------------------- FI-2

    /// Migración a medias: la tupla se procesa e `initialize` revierte (recuperación inválida, l. 268–270).
    function test_M_FI2_halfMigration_onlyHCanRetryInitialize() public {
        vm.signAndAttachDelegation(address(implementation), H_PK);
        address[] memory bad = new address[](1);
        bad[0] = S1; // ya reservado por initialize -> InvalidNewRecoverySigner
        vm.prank(A);
        vm.expectRevert(OneTimeSignerAccount.InvalidNewRecoverySigner.selector);
        acct().initialize(S1, bad);
        // Estado final (en Foundry la tupla ya está aplicada por el cheatcode; la persistencia real, en Anvil).
        assertEq(A.code, _ind(address(implementation)));
        assertFalse(acct().isInitialized());
        // OP-tx incluida.
        _opTx();
        // OP-s imposible.
        OneTimeSignerAccount.Operation memory o = op(address(witness), abi.encodeCall(Witness.ping, ()), S2);
        bytes memory sig = sign(S1_PK, o);
        vm.expectRevert(OneTimeSignerAccount.NotInitialized.selector);
        acct().executeSignedAndRotate(o, sig);
        // Un tercero no puede inicializar con sus firmantes.
        address[] memory advRec = new address[](1);
        advRec[0] = vm.addr(0xBADEC);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.UnauthorizedInitializer.selector, attacker, A));
        acct().initialize(attacker, advRec);
        // Solo h (llamada desde a) reintenta.
        address[] memory good = new address[](2);
        good[0] = R1;
        good[1] = R2;
        vm.prank(A);
        acct().initialize(S1, good);
        assertTrue(acct().isInitialized());
        assertTrue(_send(o, sig), "OP-s tras el reintento");
    }
}
