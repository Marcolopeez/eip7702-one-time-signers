// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {OneTimeSignerAccount} from "../../../src/OneTimeSignerAccount.sol";

/// @notice H1. Target que, armado, devuelve tantos bytes como su propio marco puede pagar en expansión de memoria.
/// @dev memcost(w) = 3w + w^2/512 (Yellow Paper). Elige el mayor w con memcost(w) <= gasleft() - margen.
///      `armed` lo controla quien opera el target (fixture: cualquiera).
contract ReturnBombTarget {
    bool public armed = true;
    uint256 public number;

    function setArmed(bool a) external {
        armed = a;
    }

    function setNumber(uint256 n) external returns (uint256) {
        number = n;
        if (armed) {
            uint256 g = gasleft();
            g = g > 10_000 ? g - 10_000 : 0;
            // w^2 + 1536 w - 512 g <= 0
            uint256 w = (Math.sqrt(1536 * 1536 + 2048 * g) - 1536) / 2;
            assembly {
                return(0, mul(w, 32))
            }
        }
        return n + 1;
    }
}

/// @notice H1, control. Target que consume todo el gas que recibe y no devuelve datos.
contract GasBurnerTarget {
    function burn() external pure {
        while (true) {}
    }
}

/// @notice H4. Contrato intermediario que envía la operación firmada y, opcionalmente, revierte después.
contract OperationForwarder {
    function forward(
        OneTimeSignerAccount account,
        OneTimeSignerAccount.Operation calldata operation,
        bytes calldata signature,
        bool revertAfter
    ) external returns (bool success, bytes memory result) {
        (success, result) = account.executeSignedAndRotate(operation, signature);
        if (revertAfter) revert("WRAPPER_REVERT");
    }

    function forwardRecovery(
        OneTimeSignerAccount account,
        OneTimeSignerAccount.RecoveryOperation calldata recoveryOperation,
        bytes calldata signature
    ) external returns (bool success, bytes memory result) {
        return account.signedRecovery(recoveryOperation, signature);
    }
}

/// @notice Target trivial para las operaciones legítimas de control.
contract PlainTarget {
    uint256 public number;
    address public lastSender;

    function setNumber(uint256 n) external returns (uint256) {
        number = n;
        lastSender = msg.sender;
        return n + 1;
    }
}
