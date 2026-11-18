// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SignatureChecker} from "lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {SignatureVerification} from "./vendor/permit2-cc56ad0f/SignatureVerification.sol";
import {OneTimeSignerAccount} from "../../../src/OneTimeSignerAccount.sol";

/// Fixtures de los experimentos X1-C0 a X5 (18-11-2026). Solo para tests; no forman parte de ots/src.

/// @notice Contrato testigo para OP-tx: registra quién llamó y el origen de la transacción.
contract Witness {
    address public lastSender;
    address public lastOrigin;
    uint256 public calls;

    function ping() external {
        lastSender = msg.sender;
        lastOrigin = tx.origin;
        calls++;
    }
}

/// @notice Código del atacante para OP-auth (destino de una autorización 7702 firmada con `h`).
contract AdversaryCode {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    receive() external payable {}

    /// Ejecuta cualquier llamada desde la cuenta delegada (msg.sender del target = la cuenta).
    function exec(address target, uint256 value, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "ADV_ONLY_OWNER");
        (bool ok, bytes memory res) = target.call{value: value}(data);
        require(ok, "ADV_CALL_FAILED");
        return res;
    }
}

/// @notice X4-1: saldo por dirección; `withdrawTo` usa `msg.sender`.
contract SenderVault {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdrawTo(address payable to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "SEND_FAILED");
    }
}

/// @notice X4-1: `Ownable` de OZ 5.6.1 con `owner = a`.
contract OwnedBox is Ownable {
    uint256 public value;

    constructor(address owner_) Ownable(owner_) {}

    function setValue(uint256 v) external onlyOwner {
        value = v;
    }
}

/// @notice X4-2: patrón `msg.sender == tx.origin` y registro por `tx.origin` (Huang et al., §3.3).
contract OriginGated {
    mapping(address => uint256) public claims;

    function claim() external {
        require(msg.sender == tx.origin, "ONLY_EOA");
        claims[tx.origin] += 1;
    }
}

/// @notice X4-3: `ERC20Permit` de OZ 5.6.1 (`ECDSA.recover`, no mira el código del titular).
contract PermitToken is ERC20Permit {
    constructor() ERC20("Permit Token", "PTK") ERC20Permit("Permit Token") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice X4-4: verificadores condicionados al código del firmante.
/// - `actPermit2`: patrón de Permit2 `cc56ad0f` (`SignatureVerification.verify`, l. 26–44).
/// - `actOZ`: `SignatureChecker.isValidSignatureNow` de OZ 5.6.1 (l. 32–39).
contract SigGate {
    mapping(address => uint256) public actsPermit2;
    mapping(address => uint256) public actsOZ;

    function actPermit2(address signer, bytes32 hash, bytes calldata signature) external {
        SignatureVerification.verify(signature, hash, signer);
        actsPermit2[signer] += 1;
    }

    function actOZ(address signer, bytes32 hash, bytes calldata signature) external {
        require(SignatureChecker.isValidSignatureNow(signer, hash, signature), "OZ_INVALID_SIGNATURE");
        actsOZ[signer] += 1;
    }
}

/// @notice X4-4, variante ingenua (solo para mostrar el conflicto con O, ESPECIFICACION §3, nota A):
/// ERC-1271 que acepta una firma del firmante vigente. `isValidSignature` es `view`: no rota.
contract OTS1271Naive is OneTimeSignerAccount {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && rec == currentAuthorizedSigner && !isPaused) return 0x1626ba7e;
        return 0xffffffff;
    }
}

/// @notice X4-4, control (2): ERC-1271 por hash aprobado en cadena (patrón de mensajes firmados en cadena).
/// El hash se aprueba con una operación de OTS (`target = a`, `data = approveHash(h)`), que consume y rota el
/// firmante vigente; `isValidSignature` solo lee storage y no usa ninguna clave. Storage en un slot fijo para no
/// colisionar con el de OTS.
contract OTS1271ApprovedHash is OneTimeSignerAccount {
    // keccak256("paper-pq-eoa.experiments.ots1271.approved") - 1
    bytes32 private constant APPROVED_SLOT = bytes32(uint256(keccak256("paper-pq-eoa.experiments.ots1271.approved")) - 1);

    event HashApproved(bytes32 indexed hash);

    function _approved() private pure returns (mapping(bytes32 => bool) storage m) {
        bytes32 slot = APPROVED_SLOT;
        assembly {
            m.slot := slot
        }
    }

    function approveHash(bytes32 hash) external {
        require(msg.sender == address(this), "ONLY_SELF");
        _approved()[hash] = true;
        emit HashApproved(hash);
    }

    function isApprovedHash(bytes32 hash) external view returns (bool) {
        return _approved()[hash];
    }

    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return _approved()[hash] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice X2: target que escribe `n` slots nuevos (gas conocido) para el barrido de gas.
contract StorageTarget {
    mapping(uint256 => uint256) public slots;
    uint256 public writes;

    function write(uint256 n) external {
        uint256 base = writes;
        for (uint256 i; i < n; ++i) {
            slots[base + i] = 1;
        }
        writes = base + n;
    }
}

/// @notice Target que siempre revierte.
contract RevertingTarget {
    error TargetReverted();

    function fail() external pure {
        revert TargetReverted();
    }
}
