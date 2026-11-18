// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ExperimentBase} from "./ExperimentBase.sol";
import {OneTimeSignerAccount} from "../../src/OneTimeSignerAccount.sol";
import {AdversaryCode, Witness} from "./mocks/C0Fixtures.sol";

/// @notice Base de X1-C0 a X5 (18-11-2026): como ExperimentBase, pero sin migrar en setUp, para poder registrar el
/// preestado. `_migrate` usa la misma ruta que el TFM (`signAndAttachDelegation` + `initialize` desde `a`).
/// Convenciones de Foundry (ESPECIFICACION §0.2): no hay finalidad, F = I. OP-tx se modela con `vm.prank(a, a)`;
/// OP-auth, con `signAndAttachDelegation(·, H_PK)` seguido de una llamada de un tercero.
abstract contract C0Base is ExperimentBase {
    AdversaryCode internal adv;
    Witness internal witness;

    function setUp() public virtual override {
        A = payable(vm.addr(H_PK));
        S1 = vm.addr(S1_PK);
        S2 = vm.addr(S2_PK);
        S3 = vm.addr(S3_PK);
        R1 = vm.addr(R1_PK);
        R2 = vm.addr(R2_PK);
        R3 = vm.addr(R3_PK);
        attacker = vm.addr(ATTACKER_PK);
        relayer = vm.addr(RELAYER_PK);

        implementation = new OneTimeSignerAccount();
        adv = new AdversaryCode(attacker);
        witness = new Witness();
        vm.deal(A, 10 ether);
    }

    function _migrateTo(address impl) internal {
        vm.signAndAttachDelegation(impl, H_PK);
        address[] memory recovery = new address[](2);
        recovery[0] = R1;
        recovery[1] = R2;
        vm.prank(A);
        OneTimeSignerAccount(A).initialize(S1, recovery);
    }

    function _migrate() internal {
        _migrateTo(address(implementation));
    }

    /// ind(a) esperado para una delegación 7702 hacia `d`.
    function _ind(address d) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"ef0100", d);
    }

    /// OP-auth: un tercero incluye una autorización 7702 de `h` hacia el código del atacante.
    function _opAuthToAdversary() internal {
        vm.signAndAttachDelegation(address(adv), H_PK);
        vm.prank(attacker);
        AdversaryCode(payable(A)).exec(address(witness), 0, abi.encodeCall(Witness.ping, ()));
    }

    /// OP-tx: transacción ECDSA de `h` con origen `a` al contrato testigo.
    function _opTx() internal {
        vm.prank(A, A);
        witness.ping();
    }

    /// OP-s tras OP-auth: la llamada a `executeSignedAndRotate` ya no llega a OTS.
    function _opSFails(uint256 signerPk, address next) internal returns (bool ok) {
        OneTimeSignerAccount.Operation memory o = OneTimeSignerAccount.Operation({
            target: address(witness),
            value: 0,
            data: abi.encodeCall(Witness.ping, ()),
            nextAuthorizedSigner: next,
            deadline: block.timestamp + 1 days
        });
        // La firma se calcula con el dominio de OTS en `a`; tras OP-auth, `hashOperation` ya no existe en `a`.
        bytes32 digest = _hashOpOffchain(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        vm.prank(relayer);
        (ok,) = A.call(abi.encodeCall(OneTimeSignerAccount.executeSignedAndRotate, (o, bytes.concat(r, s, bytes1(v)))));
    }

    /// Digest EIP-712 de OTS calculado fuera de la cuenta (igual que `hashOperation`, l. 446, y `domainSeparator`, l. 484–493).
    function _hashOpOffchain(OneTimeSignerAccount.Operation memory o) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                implementation.DOMAIN_TYPEHASH(),
                implementation.NAME_HASH(),
                implementation.VERSION_HASH(),
                block.chainid,
                A
            )
        );
        bytes32 structHash = implementation.operationStructHash(o);
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _rec(address nextAuth, address nextRec) internal view returns (OneTimeSignerAccount.RecoveryOperation memory) {
        return OneTimeSignerAccount.RecoveryOperation({
            nextAuthorizedSigner: nextAuth,
            nextRecoverySigner: nextRec,
            deadline: block.timestamp + 1 days
        });
    }

    function _send(OneTimeSignerAccount.Operation memory o, bytes memory sig) internal returns (bool success) {
        vm.prank(relayer);
        (success,) = acct().executeSignedAndRotate(o, sig);
    }
}
