// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ExperimentBase} from "./ExperimentBase.sol";
import {OneTimeSignerAccount} from "../../src/OneTimeSignerAccount.sol";
import {ReturnBombTarget, GasBurnerTarget} from "./mocks/ExperimentTargets.sol";

/// @notice H1 (AFIRMACIONES #23): ¿un target que devuelve datos muy grandes agota el gas de OTS después de la rotación?
/// @dev Código examinado: src/OneTimeSignerAccount.sol l. 387 (`(success, result) = target.call(...)` copia todo el
///      returndata a memoria), l. 389–398 (el evento vuelve a codificar `result`) y l. 342 (lo devuelve codificado).
///      Oráculo: tras el intento, ¿quién es `currentAuthorizedSigner` y sigue siendo aceptable la misma firma?
///      Las llamadas usan gas acotado: con el límite de gas por defecto de forge el target pediría memoria de TB.
contract H1_ReturnDataTest is ExperimentBase {
    ReturnBombTarget internal bomb;
    GasBurnerTarget internal burner;

    function setUp() public override {
        super.setUp();
        bomb = new ReturnBombTarget();
        burner = new GasBurnerTarget();
    }

    function _submit(OneTimeSignerAccount.Operation memory o, bytes memory sig, uint256 gasLimit)
        internal
        returns (bool ok)
    {
        vm.prank(relayer);
        (ok,) = address(A).call{gas: gasLimit}(abi.encodeCall(OneTimeSignerAccount.executeSignedAndRotate, (o, sig)));
    }

    /// Control: mismo target desarmado, mismo gas → ejecuta y rota.
    function test_H1_control_smallReturnData_rotates() public {
        bomb.setArmed(false);
        OneTimeSignerAccount.Operation memory o = op(address(bomb), abi.encodeCall(ReturnBombTarget.setNumber, (42)), S2);
        bytes memory sig = sign(S1_PK, o);

        assertTrue(_submit(o, sig, 1_000_000), "outer call should succeed");
        assertEq(acct().currentAuthorizedSigner(), S2, "rotation effective");
        assertEq(bomb.number(), 42);
        assertFalse(stillAcceptable(o, sig), "signature consumed");
    }

    /// H1: con returndata grande la transacción entera revierte por gas DESPUÉS de rotar, y la rotación se deshace.
    /// Se prueba con tres límites de gas: el target adapta el tamaño al gas que recibe.
    function test_H1_returnBomb_revertsWholeCall_rotationUndone() public {
        OneTimeSignerAccount.Operation memory o = op(address(bomb), abi.encodeCall(ReturnBombTarget.setNumber, (42)), S2);
        bytes memory sig = sign(S1_PK, o);

        uint256[3] memory limits = [uint256(1_000_000), 5_000_000, 30_000_000];
        for (uint256 i; i < limits.length; ++i) {
            assertFalse(_submit(o, sig, limits[i]), "outer call should run out of gas");
            assertEq(acct().currentAuthorizedSigner(), S1, "rotation undone: S1 still current");
            assertFalse(acct().isPaused(), "not paused");
            assertEq(bomb.number(), 0, "target effect undone too");
            assertTrue(stillAcceptable(o, sig), "same signature still acceptable (published, not consumed)");
        }
    }

    /// Operación posterior: quien controla el target decide cuándo la firma ya publicada se vuelve efectiva.
    function test_H1_targetOperatorChoosesWhenRotationTakesEffect() public {
        OneTimeSignerAccount.Operation memory o = op(address(bomb), abi.encodeCall(ReturnBombTarget.setNumber, (42)), S2);
        bytes memory sig = sign(S1_PK, o);

        assertFalse(_submit(o, sig, 1_000_000));
        assertEq(acct().currentAuthorizedSigner(), S1);

        bomb.setArmed(false);
        assertTrue(_submit(o, sig, 1_000_000), "replay of the same signature by anyone");
        assertEq(acct().currentAuthorizedSigner(), S2, "rotation effective only now");
        assertEq(bomb.number(), 42);
    }

    /// Control de la causa: un target que consume todo el gas pero no devuelve datos NO deshace la rotación,
    /// porque OTS conserva 1/64 del gas para emitir el evento y volver.
    function test_H1_control_gasBurnerWithoutReturnData_rotationPersists() public {
        OneTimeSignerAccount.Operation memory o = op(address(burner), abi.encodeCall(GasBurnerTarget.burn, ()), S2);
        bytes memory sig = sign(S1_PK, o);

        assertTrue(_submit(o, sig, 1_000_000), "outer call should succeed with success=false inside");
        assertEq(acct().currentAuthorizedSigner(), S2, "rotation persists");
    }
}
