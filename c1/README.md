# OTS-C1

Cuenta One-Time-Signer para la configuración **C1** del paper (EIP-7702 + OTS + EIP-7851 experimental en Besu).
Rama `research/c1` de este repositorio. Todo lo de C1 está en esta carpeta; fuera de ella la rama es `research/paper@92c4a69` sin cambios (`scripts/check-hygiene.sh`).

## Origen

`src/OneTimeSignerAccountC1.sol` parte de `../src/OneTimeSignerAccount.sol` en el commit `92c4a69` (sha256 `802db87f…`), que no se modifica. Cambios:

| Cambio | Motivo (decisiones del paper) |
|---|---|
| `initializeAndRetire` (V1) y `retire()` (V2): DELEGATECALL a un helper de bytecode crudo (`5f35ac5f5260205ff3`) que ejecuta `SETSELFDELEGATE(PROXY)` (opcode `0xac`) en el contexto de la cuenta y la deja en `0xef0101‖PROXY`. Revierten si el opcode no devuelve 1. `retire()` solo desde la propia cuenta y una sola vez | D-26, D-24 |
| `OTSProxyC1`: proxy sin administrador que delega en la implementación del slot ERC-1967 del storage de la cuenta | D-22 |
| *Management keys* (`μ`; *recovery keys* en OTS): recuperan y redelegan. `redelegate` escribe el slot con una firma EIP-712 `Redelegation(newImplementation, nextManagementSigner, deadline)` | D-22, D-23, D-29, D-48 |
| La redelegación exige una implementación ERC-1822 (`proxiableUUID()` = slot) | D-49 |
| **Regla de gestión** (recuperación firmada o directa y redelegación): con la firma válida de una `μ` activa, la `μ` se consume y la función ya no revierte; la sucesora se instala si es válida, se aplique o no la acción; la acción solo se aplica si el mensaje no ha caducado y todos sus campos, sucesora incluida, son válidos; si no, no cambia nada más y devuelve `(false, primer error)`. `NotRetired` es un fallo después del consumo. Tabla completa en ESPECIFICACION §2.4.1 del paper | D-52, D-53 |
| `initialize` e `initializeAndRetire` exigen al menos una `μ` | D-55 |
| Cada recuperación que se aplica revoca todas las demás `μ` («épocas» de gestión); la redelegación no revoca | D-34, D-35, D-53 |
| Dominio EIP-712 `"OneTimeSignerAccountC1"`: las firmas de OTS no valen aquí | — |

El camino operacional (`executeSignedAndRotate`) es el de OTS y no tiene DELEGATECALL. Después de la retirada, el helper ya no es alcanzable.

## Tests

`forge test` (desde esta carpeta; usa `../lib`): 39 tests, con los invariantes I1–I3 de D-53 y la matriz de la regla de gestión. Foundry (revm) no ejecuta `0xac` ni `0xef0101`: los tests usan un helper simulado y emulan el estado retirado con `0xef0100‖P`, que Besu ejecuta igual. Lo propio de `0xef0101` (rechazo de las firmas ECDSA de `h` y salto de autorizaciones) se prueba en Besu.

## Despliegue (devnet de C1)

Primero `OTSProxyC1`; después `OneTimeSignerAccountC1(proxy, helper)`, con el helper en la dirección fija del `alloc` de la devnet.

## C1⁺ (dos fases)

`src/TwoPhaseOTSAccountC1.sol` (d⁺) es una copia modificada de `OneTimeSignerAccountC1.sol` (`3edcbd25`) con **autorización en dos fases** en los tres caminos firmados (especificación: `revisiones/CR-ESPECIFICACION.md` del paper; D-160 a D-162 y D-167). Rama `research/c1-2p`. Los archivos de OTS-C1 no cambian (D-156).

| Cambio | Regla |
|---|---|
| `commit(ℓ, δ, γ)`: cualquiera añade keccak256(δ ‖ γ) a la lista L[ℓ], con ℓ = H_loc(chainId ‖ a ‖ pk(k)), δ = H_dig(eip712(m) ‖ r) y γ = H_com(chainId ‖ a ‖ pk(k) ‖ δ); H_tag(x) = keccak256(keccak256(tag) ‖ x) | R5, R7 |
| `executeSignedAndRotate`, `signedRecovery` y `redelegate` reciben además pk(k) (64 bytes), la sal r y las entradas saltadas; exigen que la primera entrada válida bajo ℓ case con el mensaje y que dirección(pk) sea la clave vigente o una `μ` activa; después, la lógica de OTS-C1 sin cambios | R1–R4, R8 |
| Sin `rotateAuthorizedSigner` ni `rotateAuthorizedSignerThroughRecovery` | R6 |
| La entrada de la posición 0 se borra al consumir la clave | D-167 |
| Dominio EIP-712 `"TwoPhaseOTSAccountC1"`; storage de OTS-C1 en el mismo orden y, al final, `firstEntry` y `laterEntries` | Compatibilidad con `redelegate(d⁺)` desde OTS-C1 |

**Tests:** `test/TwoPhaseOTSAccountC1.t.sol` (mocks en `test/mocks/TwoPhaseMocks.sol`): un test por oráculo T01–T16 de `experimentos/CR/ORACULOS.md` (T07a y T16 son de fallo esperado: el test pasa si el adversario gana), uno complementario y tres de gas (`--isolate -vv`). Resultados: `experimentos/CR/resultados/2026-11-25-3edcbd25.md`. El opcode se simula como en H3.
