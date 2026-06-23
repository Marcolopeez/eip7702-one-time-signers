// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "lib/openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title EphemeralKeyAccount
/// @notice Minimal EIP-7702 account implementation controlled by rotating ephemeral ECDSA keys.
/// @dev This contract is designed to be executed as delegated code from an EOA under EIP-7702.
///      In that mode, `address(this)` is the EOA address and all storage writes are applied to the
///      EOA's storage, not to the implementation contract's storage.
///
///      Terminology used by this implementation:
///      - The contract stores signer addresses, not raw ECDSA keys.
///      - Each signer address is expected to correspond to a fresh one-time ECDSA keypair managed off-chain.
///      - Comments may refer to "keys" when describing the threat model, because the security property is
///        about key exposure and key consumption after a valid ECDSA signature has been observed.
///
///      Current security model:
///      - The delegated EOA is initialized once with its first authorized ephemeral key, represented
///        on-chain by `currentAuthorizedSigner`.
///      - A signed operation must be authorized by the current `currentAuthorizedSigner`.
///      - The current key is consumed and the signer is rotated before the external call is executed.
///      - Target call failures are returned as `(success = false, result)` and do not revert the
///        account transaction, so the key rotation persists.
///      - If the next authorized signer is invalid after a valid authorization has been observed,
///        the account is paused instead of reverting. While paused, only recovery flows can rotate
///        the account to a fresh key and unpause it.
///
///      Important limitation:
///      This contract cannot protect against compromise of the EIP-7702 authority key that controls the
///      account's delegation at protocol level. If that key can be recovered from a set-code authorization,
///      an attacker may be able to replace or clear the delegation outside this contract's control.
///      Thats why we need ECDSA-key deactivation after EIP-7702 delegation.
contract EphemeralKeyAccount {
    using ECDSA for bytes32;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Operation authorized by the current ephemeral key through its signer address.
    /// @param target Contract or account called by the delegated EOA.
    /// @param value ETH value sent from the delegated EOA.
    /// @param data Calldata sent to `target`.
    /// @param nextAuthorizedSigner Signer address for the next one-time ephemeral key.
    /// @param deadline Last timestamp at which the operation is valid.
    struct Operation {
        address target;
        uint256 value;
        bytes data;
        address nextAuthorizedSigner;
        uint256 deadline;
    }

    /// @notice Recovery operation authorized by an active one-time recovery key through its signer address.
    /// @param nextAuthorizedSigner Signer address for the fresh authorized key installed by recovery.
    /// @param nextRecoverySigner Signer address for the fresh one-time recovery key installed by recovery.
    /// @param deadline Last timestamp at which the recovery operation is valid.
    struct RecoveryOperation {
        address nextAuthorizedSigner;
        address nextRecoverySigner;
        uint256 deadline;
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error AlreadyInitialized();
    error NotInitialized();
    error InvalidNextAuthorizedSigner();
    error InvalidTarget();
    error ExpiredOperation(uint256 deadline);
    error InvalidSignature(address recovered, address expectedAuthorizedSigner);
    error MustBeCalledThroughDelegation();
    error Unauthorized(address caller, address expectedAuthorizedSigner);
    error UnauthorizedInitializer(address caller, address expectedAuthorizedSigner);
    error SignerAlreadyConsumedOrReserved(address reusedAuthorizedSigner);
    error InvalidNewRecoverySigner();
    error RecoverySignerNotActive(address recoverySigner);
    error AccountIsPaused();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a delegated EOA is initialized with its first authorized key.
    event Initialized(address indexed account, address indexed currentAuthorizedSigner);

    /// @notice Emitted whenever control moves from one ephemeral key to the next one.
    event AuthorizedSignerRotated(
        address indexed account,
        address indexed previousAuthorizedSigner,
        address indexed nextAuthorizedSigner
    );

    /// @notice Emitted when a recovery key is registered through its signer address and reserved for one-time use.
    event RecoverySignerRegistered(address indexed account, address indexed recoverySigner);

    /// @notice Emitted when a one-time recovery key is consumed and its signer address is deactivated.
    event RecoverySignerConsumed(address indexed account, address indexed recoverySigner);

    /// @notice Emitted when recovery replaces a consumed recovery key with a fresh one.
    event RecoverySignerRotated(
        address indexed account,
        address indexed previousRecoverySigner,
        address indexed nextRecoverySigner
    );

    /// @notice Emitted when a valid authorization has exposed the current key but rotation cannot proceed.
    event AccountPaused(
        address indexed account,
        address indexed exposedAuthorizedSigner,
        address attemptedNextAuthorizedSigner,
        bytes reason
    );

    /// @notice Emitted when a recovery key successfully restores the account to a fresh authorized key.
    event AccountUnpaused(
        address indexed account,
        address indexed recoverySigner,
        address indexed nextAuthorizedSigner
    );

    /// @notice Emitted when a recovery key is consumed but the requested recovery could not be applied.
    event RecoveryOperationFailed(
        address indexed account,
        address indexed recoverySigner,
        address attemptedNextAuthorizedSigner,
        bytes reason
    );

    /// @notice Emitted after a signed operation has consumed its key and attempted execution.
    /// @dev `success = false` means the target call reverted, validation failed, or rotation paused the account,
    ///      but the account transaction did not revert.
    event SignedOperationExecuted(
        address indexed account,
        address indexed signer,
        address indexed target,
        uint256 value,
        bytes data,
        address nextAuthorizedSigner,
        bool success,
        bytes result
    );

    // -------------------------------------------------------------------------
    // EIP-712 constants
    // -------------------------------------------------------------------------

    /// @dev EIP-712 domain type hash used by `domainSeparator`.
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev EIP-712 type hash for operations authorized by the current ephemeral key's signer address.
    bytes32 public constant OPERATION_TYPEHASH =
        keccak256("Operation(address target,uint256 value,bytes32 dataHash,address nextAuthorizedSigner,uint256 deadline)");

    /// @dev EIP-712 type hash for recovery operations authorized by an active recovery key's signer address.
    bytes32 public constant RECOVERY_OPERATION_TYPEHASH =
        keccak256("RecoveryOperation(address nextAuthorizedSigner,address nextRecoverySigner,uint256 deadline)");

    /// @dev Pre-hashed EIP-712 domain name.
    bytes32 public constant NAME_HASH = keccak256("EphemeralKeyAccount");

    /// @dev Pre-hashed EIP-712 domain version.
    bytes32 public constant VERSION_HASH = keccak256("1");

    // -------------------------------------------------------------------------
    // Immutable implementation context
    // -------------------------------------------------------------------------

    /// @dev Address of the implementation contract itself.
    ///      During EIP-7702 delegated execution, `address(this)` is the EOA, not this value.
    address private immutable IMPLEMENTATION_ADDR = address(this);

    // -------------------------------------------------------------------------
    // Delegated account storage
    // -------------------------------------------------------------------------

    /// @notice Whether the delegated account storage has been initialized.
    bool public isInitialized;

    /// @notice Whether normal authorized-key execution is blocked until recovery succeeds.
    bool public isPaused;

    /// @notice Signer address of the current one-time ephemeral ECDSA key.
    address public currentAuthorizedSigner;

    /// @notice Signer addresses whose underlying keys have been consumed or reserved and must never be authorized again.
    mapping(address => bool) public isConsumedOrReservedSigner;

    /// @notice Recovery key signer addresses that can rotate the account to a fresh authorized key.
    mapping(address => bool) public isActiveRecoverySigner;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Prevents direct use of the implementation contract storage.
    modifier onlyDelegatedAccount() {
        if (address(this) == IMPLEMENTATION_ADDR) revert MustBeCalledThroughDelegation();
        _;
    }

    /// @dev Requires the delegated account storage to have been initialized.
    modifier onlyInitialized() {
        if (!isInitialized) revert NotInitialized();
        _;
    }

    /// @dev Blocks normal authorized-key flows while the account is awaiting recovery.
    modifier onlyUnpausedAccount() {
        if (isPaused) revert AccountIsPaused();
        _;
    }

    /// @dev Requires a direct call from the signer address of the currently authorized key.
    modifier onlyCurrentAuthorizedSigner() {
        if (msg.sender != currentAuthorizedSigner) {
            revert Unauthorized(msg.sender, currentAuthorizedSigner);
        }
        _;
    }

    /// @dev Requires a direct call from a recovery key signer address that has not been consumed yet.
    modifier onlyActiveRecoverySigner() {
        if (!isActiveRecoverySigner[msg.sender]) {
            revert RecoverySignerNotActive(msg.sender);
        }
        _;
    }

    // -------------------------------------------------------------------------
    // ETH reception
    // -------------------------------------------------------------------------

    /// @notice Allows the delegated EOA to receive ETH while using this implementation.
    /// @dev Receiving ETH is intentionally allowed even while paused because it does not consume
    ///      an ephemeral key authorization or execute arbitrary account-controlled logic.
    receive() external payable onlyDelegatedAccount {}

    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------

    /// @notice Initializes the delegated EOA with its first ephemeral key and recovery key signers.
    /// @dev Must be called through the delegated EOA. A self-call during the EIP-7702 setup transaction
    ///      can satisfy the `msg.sender == address(this)` check.
    /// @param firstAuthorizedSigner Signer address of the first ephemeral key allowed to authorize this account.
    /// @param initialRecoverySigners Signer addresses for one-time recovery keys that can restore a fresh key.
    function initialize(address firstAuthorizedSigner, address[] calldata initialRecoverySigners) 
        external 
        onlyDelegatedAccount 
    {
        if (isInitialized) revert AlreadyInitialized();
        if (msg.sender != address(this)) revert UnauthorizedInitializer(msg.sender, address(this));
        if (firstAuthorizedSigner == address(0)) revert InvalidNextAuthorizedSigner();

        isInitialized = true;
        isConsumedOrReservedSigner[address(this)] = true;

        isConsumedOrReservedSigner[firstAuthorizedSigner] = true;
        currentAuthorizedSigner = firstAuthorizedSigner;

        for (uint16 i; i < initialRecoverySigners.length; ++i) {
            if (initialRecoverySigners[i] == address(0) || isConsumedOrReservedSigner[initialRecoverySigners[i]]) {
                revert InvalidNewRecoverySigner();
            }

            isConsumedOrReservedSigner[initialRecoverySigners[i]] = true;
            isActiveRecoverySigner[initialRecoverySigners[i]] = true;

            emit RecoverySignerRegistered(address(this), initialRecoverySigners[i]);
        }

        emit Initialized(address(this), firstAuthorizedSigner);
    }

    // -------------------------------------------------------------------------
    // Direct signer rotation
    // -------------------------------------------------------------------------

    /// @notice Rotates the current ephemeral key when called directly by its authorized signer address.
    /// @dev If `nextAuthorizedSigner` is invalid, the current key has still been exposed by the transaction
    ///      signature, so the account is paused instead of reverting.
    /// @param nextAuthorizedSigner Signer address for the key that becomes valid after this call.
    /// @dev Kept as a direct key-rotation path so wallets can rotate without executing a target call.
    function rotateAuthorizedSigner(address nextAuthorizedSigner)
        external
        onlyDelegatedAccount
        onlyInitialized
        onlyUnpausedAccount
        onlyCurrentAuthorizedSigner
        returns (bool success, bytes memory result)
    {
        return _rotateAuthorizedSignerOrPause(nextAuthorizedSigner);
    }

    /// @notice Rotates the current ephemeral key and renews recovery when called directly by a recovery key signer.
    /// @dev The recovery key is consumed before validating either replacement signer because the recovery signer's
    ///      transaction signature is observable once this function is called. On success, the account is unpaused.
    /// @param nextAuthorizedSigner Signer address for the key that becomes valid after this call.
    /// @param nextRecoverySigner Signer address for the recovery key that replaces the consumed recovery key.
    function rotateAuthorizedSignerThroughRecovery(address nextAuthorizedSigner, address nextRecoverySigner)
        external
        onlyDelegatedAccount
        onlyInitialized
        onlyActiveRecoverySigner
        returns (bool success, bytes memory result)
    {
        address recoverySigner = msg.sender;
        // Once a valid recovery signature is observed, this recovery key is burned.
        isActiveRecoverySigner[recoverySigner] = false;
        emit RecoverySignerConsumed(address(this), recoverySigner);
        return _recoverAuthorizedSigner(recoverySigner, nextAuthorizedSigner, nextRecoverySigner);
    }

    // -------------------------------------------------------------------------
    // Signed execution
    // -------------------------------------------------------------------------

    /// @notice Executes an operation authorized by the current ephemeral key and rotates to the next key.
    /// @dev The signature is verified first. If it was produced by `currentAuthorizedSigner`, the underlying
    ///      ephemeral key is consumed immediately by rotating to `operation.nextAuthorizedSigner`.
    ///
    ///      After a valid authorized signature has been observed, this function must not revert because
    ///      of an invalid next key signer, an invalid target, an expired operation, or a target revert. Those
    ///      failures are returned as `(success = false, result = encodedErrorOrRevertData)` so the
    ///      key-consumption or pause property remains persisted.
    ///
    /// @param operation Operation authorized by the current ephemeral key.
    /// @param signature EIP-712 signature over `operation`, produced by the current ephemeral key.
    /// @return success Whether the target call succeeded.
    /// @return result Return data or revert data from the target call.
    function executeSignedAndRotate(Operation calldata operation, bytes calldata signature)
        external
        onlyDelegatedAccount
        onlyInitialized
        onlyUnpausedAccount
        returns (bool success, bytes memory result)
    {
        address consumedAuthorizedSigner = currentAuthorizedSigner;
        address recovered = hashOperation(operation).recover(signature);

        if (recovered != consumedAuthorizedSigner) {
            revert InvalidSignature(recovered, consumedAuthorizedSigner);
        }

        // Consume the ephemeral key before validating the executable part of the operation.
        // Once a valid authorized signature is observed, the current key must be considered exposed.
        (bool rotationSucceeded, bytes memory rotationError) = _rotateAuthorizedSignerOrPause(operation.nextAuthorizedSigner);

        if (!rotationSucceeded) {
            emit SignedOperationExecuted(
                address(this),
                consumedAuthorizedSigner,
                operation.target,
                operation.value,
                operation.data,
                operation.nextAuthorizedSigner,
                false,
                rotationError
            );

            return (false, rotationError);
        }

        result = _operationValidation(operation);
        if (result.length != 0) {
            emit SignedOperationExecuted(
                address(this),
                consumedAuthorizedSigner,
                operation.target,
                operation.value,
                operation.data,
                operation.nextAuthorizedSigner,
                false,
                result
            );

            return (false, result);
        }

        // Never revert solely because the target reverted. Doing so would roll back the rotation.
        (success, result) = operation.target.call{value: operation.value}(operation.data);

        emit SignedOperationExecuted(
            address(this),
            consumedAuthorizedSigner,
            operation.target,
            operation.value,
            operation.data,
            operation.nextAuthorizedSigner,
            success,
            result
        );
    }

    /// @notice Rotates the account through an EIP-712 signature produced by an active recovery key.
    /// @dev The recovery key is consumed as soon as its valid signature is observed, even if the recovery
    ///      operation is expired or requests an invalid next key signer.
    function signedRecovery(RecoveryOperation calldata recoveryOperation, bytes calldata signature)
        external
        onlyDelegatedAccount
        onlyInitialized
        returns (bool success, bytes memory result)
    {
        address recovered = hashRecoveryOperation(recoveryOperation).recover(signature);

        if (!isActiveRecoverySigner[recovered]) {
            revert RecoverySignerNotActive(recovered);
        }

        // Once a valid recovery signature is observed, this recovery key is burned.
        isActiveRecoverySigner[recovered] = false;
        emit RecoverySignerConsumed(address(this), recovered);

        if (block.timestamp > recoveryOperation.deadline) {
            result = abi.encodeWithSelector(ExpiredOperation.selector, recoveryOperation.deadline);

            emit RecoveryOperationFailed(
                address(this),
                recovered,
                recoveryOperation.nextAuthorizedSigner,
                result
            );

            return (false, result);
        }

        return _recoverAuthorizedSigner(
            recovered,
            recoveryOperation.nextAuthorizedSigner,
            recoveryOperation.nextRecoverySigner
        );
    }

    // -------------------------------------------------------------------------
    // EIP-712 hashing
    // -------------------------------------------------------------------------

    /// @notice Computes the EIP-712 digest signed by the current ephemeral key.
    /// @dev When called through a delegated EOA, the verifying contract is the EOA address.
    function hashOperation(Operation memory operation) public view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator(), operationStructHash(operation));
    }

    /// @notice Computes the EIP-712 digest signed by an active recovery key.
    /// @dev Uses the delegated EOA as the verifying contract when executed through EIP-7702.
    function hashRecoveryOperation(RecoveryOperation memory recoveryOperation) public view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator(), recoveryOperationStructHash(recoveryOperation));
    }

    /// @notice Computes the EIP-712 struct hash for an operation.
    function operationStructHash(Operation memory operation) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                OPERATION_TYPEHASH,
                operation.target,
                operation.value,
                keccak256(operation.data),
                operation.nextAuthorizedSigner,
                operation.deadline
            )
        );
    }

    /// @notice Computes the EIP-712 struct hash for a recovery operation.
    function recoveryOperationStructHash(RecoveryOperation memory recoveryOperation) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                RECOVERY_OPERATION_TYPEHASH,
                recoveryOperation.nextAuthorizedSigner,
                recoveryOperation.nextRecoverySigner,
                recoveryOperation.deadline
            )
        );
    }

    /// @notice Computes the EIP-712 domain separator for the current execution context.
    /// @dev Under EIP-7702 delegation, `address(this)` is the delegated EOA.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                NAME_HASH,
                VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Normal authorized-key rotation path. Invalid next key signers pause instead of reverting because
    ///      the current authorized key has already been exposed by a valid signature or transaction.
    function _rotateAuthorizedSignerOrPause(address nextAuthorizedSigner)
        internal
        returns (bool success, bytes memory result)
    {
        result = _validateNewAuthorizedSigner(nextAuthorizedSigner);
        if (result.length != 0) {
            isPaused = true;
            emit AccountPaused(address(this), currentAuthorizedSigner, nextAuthorizedSigner, result);
            return (false, result);
        }

        address previousAuthorizedSigner = currentAuthorizedSigner;
        isConsumedOrReservedSigner[nextAuthorizedSigner] = true;
        currentAuthorizedSigner = nextAuthorizedSigner;

        emit AuthorizedSignerRotated(address(this), previousAuthorizedSigner, nextAuthorizedSigner);
        return (true, bytes(""));
    }

    /// @dev Recovery path. Invalid next key signers do not revert, because the recovery key has already been
    ///      exposed and consumed. A successful recovery atomically installs both a fresh authorized signer and
    ///      a fresh recovery signer, then unpauses the account. If `nextAuthorizedSigner` is correct but
    ///      `nextRecoverySigner` is not, `currentAuthorizedSigner` is rotated and the account is unpaused.
    function _recoverAuthorizedSigner(
        address recoverySigner,
        address nextAuthorizedSigner,
        address nextRecoverySigner
    )
        internal
        returns (bool success, bytes memory result)
    {
        result = _validateNewAuthorizedSigner(nextAuthorizedSigner);
        if (result.length != 0) {
            emit RecoveryOperationFailed(address(this), recoverySigner, nextAuthorizedSigner, result);
            return (false, result);
        }

        isConsumedOrReservedSigner[nextAuthorizedSigner] = true;
        currentAuthorizedSigner = nextAuthorizedSigner;

        if (isPaused) isPaused = false;
        emit AccountUnpaused(address(this), recoverySigner, nextAuthorizedSigner);

        result = _validateNewRecoverySigner(nextRecoverySigner);
        if (result.length != 0) return (false, result);

        isConsumedOrReservedSigner[nextRecoverySigner] = true;
        isActiveRecoverySigner[nextRecoverySigner] = true;

        emit RecoverySignerRotated(address(this), recoverySigner, nextRecoverySigner);

        return (true, bytes(""));
    }

    /// @dev Returns encoded custom-error data if `nextAuthorizedSigner` cannot become the new key signer.
    function _validateNewAuthorizedSigner(address nextAuthorizedSigner) internal view returns (bytes memory) {
        if (nextAuthorizedSigner == address(0)) {
            return abi.encodeWithSelector(InvalidNextAuthorizedSigner.selector);
        }

        if (isConsumedOrReservedSigner[nextAuthorizedSigner]) {
            return abi.encodeWithSelector(SignerAlreadyConsumedOrReserved.selector, nextAuthorizedSigner);
        }

        return bytes("");
    }

    /// @dev Returns encoded custom-error data if `nextRecoverySigner` cannot become the new recovery signer.
    function _validateNewRecoverySigner(
        address nextRecoverySigner
    )
        internal
        view
        returns (bytes memory)
    {
        if (nextRecoverySigner == address(0)) {
            return abi.encodeWithSelector(InvalidNewRecoverySigner.selector);
        }
        if (isConsumedOrReservedSigner[nextRecoverySigner] || isActiveRecoverySigner[nextRecoverySigner]) {
            return abi.encodeWithSelector(SignerAlreadyConsumedOrReserved.selector, nextRecoverySigner);
        }

        return bytes("");
    }

    /// @dev Returns encoded custom-error data for operation-level failures that must not revert.
    ///
    ///      At this point, the signature has already been verified and the ephemeral key has already
    ///      been rotated. Returning encoded error data instead of reverting preserves the key-consumption
    ///      property required by the quantum-threat model: once a valid signature is observed, the
    ///      corresponding ECDSA key material should be considered exposed.
    function _operationValidation(Operation calldata operation) internal view returns (bytes memory) {
        if (operation.target == address(0)) {
            return abi.encodeWithSelector(InvalidTarget.selector);
        }

        if (block.timestamp > operation.deadline) {
            return abi.encodeWithSelector(ExpiredOperation.selector, operation.deadline);
        }

        return bytes("");
    }
}