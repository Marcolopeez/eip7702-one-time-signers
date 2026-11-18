// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";

/// @title OneTimeSignerAccountC1
/// @notice OTS for configuration C1 (EIP-7702 + one-time signers + EIP-7851, experimental).
/// @dev Derived from `src/OneTimeSignerAccount.sol` at commit 92c4a69 (sha256 of `src/` 802db87f...). Changes:
///      - Retirement of the original ECDSA key `h` (EIP-7851, Draft): `initializeAndRetire` (V1) and `retire`
///        (V2) DELEGATECALL a raw-bytecode helper that executes SETSELFDELEGATE(PROXY) in the account context,
///        leaving `0xef0101 || PROXY`. The helper and the proxy are fixed at deployment (immutables).
///      - The account then runs through `OTSProxyC1`, which delegates to the implementation stored in the
///        ERC-1967 slot of the account's storage. `_retire` writes that slot with this implementation.
///      - Management keys (`μ`, called recovery keys in OTS) recover the account and redelegate it by writing
///        the slot (`redelegate`). Every recovery that counts revokes all other management keys (management
///        epochs). A redelegation consumes the signing key and names a successor, but revokes nothing.
///      - A redelegation requires an ERC-1822-compatible implementation. If it cannot be applied (incompatible
///        implementation or expired message), it does not revert: the key is consumed, the slot is unchanged
///        and the named successor is installed.
///      - The EIP-712 domain name is "OneTimeSignerAccountC1", so OTS signatures are not valid here.
///      Under EIP-7702 delegation (directly or through the proxy), `address(this)` is the EOA and storage is
///      the EOA's storage.
contract OneTimeSignerAccountC1 is IERC1822Proxiable {
    using ECDSA for bytes32;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Operation authorized by the current one-time key through its signer address.
    struct Operation {
        address target;
        uint256 value;
        bytes data;
        address nextAuthorizedSigner;
        uint256 deadline;
    }

    /// @notice Recovery authorized by an active management key.
    struct RecoveryOperation {
        address nextAuthorizedSigner;
        address nextManagementSigner;
        uint256 deadline;
    }

    /// @notice Redelegation (implementation change) authorized by an active management key.
    struct Redelegation {
        address newImplementation;
        address nextManagementSigner;
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
    error MustNotBeCalledThroughDelegation();
    error Unauthorized(address caller, address expectedAuthorizedSigner);
    error UnauthorizedInitializer(address caller, address expectedAuthorizedSigner);
    error UnauthorizedRetirement(address caller);
    error SignerAlreadyConsumedOrReserved(address reusedSigner);
    error InvalidNewManagementSigner();
    error ManagementSignerNotActive(address managementSigner);
    error AccountIsPaused();
    error InvalidDeployment();
    error AlreadyRetired();
    error NotRetired();
    error RetirementFailed();
    error IncompatibleImplementation(address implementation);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Initialized(address indexed account, address indexed currentAuthorizedSigner);
    event AuthorizedSignerRotated(
        address indexed account, address indexed previousAuthorizedSigner, address indexed nextAuthorizedSigner
    );
    event ManagementSignerRegistered(address indexed account, address indexed managementSigner);
    event ManagementSignerConsumed(address indexed account, address indexed managementSigner);
    event ManagementSignerRotated(
        address indexed account, address indexed previousManagementSigner, address indexed nextManagementSigner
    );
    /// @notice A recovery revoked every other management key (D-35).
    event ManagementEpochAdvanced(address indexed account, uint256 newEpoch);
    event AccountPaused(
        address indexed account, address indexed exposedAuthorizedSigner, address attemptedNextAuthorizedSigner, bytes reason
    );
    event AccountUnpaused(address indexed account, address indexed managementSigner, address indexed nextAuthorizedSigner);
    event RecoveryOperationFailed(
        address indexed account, address indexed managementSigner, address attemptedNextAuthorizedSigner, bytes reason
    );
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
    /// @notice The original ECDSA key was retired: the account code is now `0xef0101 || proxy`.
    event EcdsaRetired(address indexed account, address indexed proxy, address indexed implementation);
    event Redelegated(
        address indexed account,
        address indexed managementSigner,
        address previousImplementation,
        address indexed newImplementation
    );
    event RedelegationFailed(
        address indexed account, address indexed managementSigner, address attemptedImplementation, bytes reason
    );

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant OPERATION_TYPEHASH = keccak256(
        "Operation(address target,uint256 value,bytes32 dataHash,address nextAuthorizedSigner,uint256 deadline)"
    );
    bytes32 public constant RECOVERY_OPERATION_TYPEHASH =
        keccak256("RecoveryOperation(address nextAuthorizedSigner,address nextManagementSigner,uint256 deadline)");
    bytes32 public constant REDELEGATION_TYPEHASH =
        keccak256("Redelegation(address newImplementation,address nextManagementSigner,uint256 deadline)");
    bytes32 public constant NAME_HASH = keccak256("OneTimeSignerAccountC1");
    bytes32 public constant VERSION_HASH = keccak256("1");

    /// @notice ERC-1967 implementation slot (`keccak256("eip1967.proxy.implementation") - 1`), in the account storage.
    bytes32 public constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Gas forwarded to `proxiableUUID()` of a candidate implementation, so that a hostile candidate
    ///      cannot make the whole redelegation run out of gas (which would undo the key consumption).
    uint256 internal constant PROXIABLE_CHECK_GAS = 30_000;

    // -------------------------------------------------------------------------
    // Immutable implementation context
    // -------------------------------------------------------------------------

    address private immutable IMPLEMENTATION_ADDR = address(this);
    /// @notice Proxy the account is retired to (`0xef0101 || PROXY`).
    address public immutable PROXY;
    /// @notice Raw-bytecode helper that executes SETSELFDELEGATE (0xac) on DELEGATECALL.
    address public immutable SET_SELF_DELEGATE_HELPER;

    // -------------------------------------------------------------------------
    // Delegated account storage (sequential slots, as in OTS; the ERC-1967 slot is apart)
    // -------------------------------------------------------------------------

    bool public isInitialized;
    bool public isPaused;
    address public currentAuthorizedSigner;
    mapping(address => bool) public isConsumedOrReservedSigner;
    /// @notice Current management epoch. Keys of previous epochs are revoked.
    uint256 public managementEpoch;
    mapping(uint256 => mapping(address => bool)) private _activeManagementSigner;

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    constructor(address proxy, address setSelfDelegateHelper) {
        if (proxy == address(0) || setSelfDelegateHelper == address(0)) revert InvalidDeployment();
        assert(IMPLEMENTATION_SLOT == bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));
        PROXY = proxy;
        SET_SELF_DELEGATE_HELPER = setSelfDelegateHelper;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyDelegatedAccount() {
        if (address(this) == IMPLEMENTATION_ADDR) revert MustBeCalledThroughDelegation();
        _;
    }

    modifier onlyInitialized() {
        if (!isInitialized) revert NotInitialized();
        _;
    }

    modifier onlyUnpausedAccount() {
        if (isPaused) revert AccountIsPaused();
        _;
    }

    modifier onlyCurrentAuthorizedSigner() {
        if (msg.sender != currentAuthorizedSigner) revert Unauthorized(msg.sender, currentAuthorizedSigner);
        _;
    }

    modifier onlyActiveManagementSigner() {
        if (!isActiveManagementSigner(msg.sender)) revert ManagementSignerNotActive(msg.sender);
        _;
    }

    receive() external payable onlyDelegatedAccount {}

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Whether `signer` is an active management key in the current epoch.
    function isActiveManagementSigner(address signer) public view returns (bool) {
        return _activeManagementSigner[managementEpoch][signer];
    }

    /// @notice Implementation the proxy delegates to (zero before retirement).
    function implementation() public view returns (address) {
        return StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value;
    }

    /// @notice ERC-1822: declares this contract a valid implementation for the account proxy.
    /// @dev Reverts when executed through delegation, as in OpenZeppelin's UUPS.
    function proxiableUUID() external view returns (bytes32) {
        if (address(this) != IMPLEMENTATION_ADDR) revert MustNotBeCalledThroughDelegation();
        return IMPLEMENTATION_SLOT;
    }

    // -------------------------------------------------------------------------
    // Initialization and retirement
    // -------------------------------------------------------------------------

    /// @notice V2, first transaction: as OTS `initialize`, without retirement.
    function initialize(address firstAuthorizedSigner, address[] calldata initialManagementSigners)
        external
        onlyDelegatedAccount
    {
        _initialize(firstAuthorizedSigner, initialManagementSigners);
    }

    /// @notice V1: initializes and retires `h` in the same transaction (ESPECIFICACION §2.2; D-26).
    /// @dev Reverts if SETSELFDELEGATE does not return 1, so a failed retirement leaves nothing initialized.
    function initializeAndRetire(address firstAuthorizedSigner, address[] calldata initialManagementSigners)
        external
        onlyDelegatedAccount
    {
        _initialize(firstAuthorizedSigner, initialManagementSigners);
        _retire();
    }

    /// @notice V2, second transaction: retires `h`. Only a call from the account itself (`h`, T2a, or an
    ///         operation with `target = account`, T2b). The destination is fixed (D-26) and it works once.
    function retire() external onlyDelegatedAccount onlyInitialized {
        if (msg.sender != address(this)) revert UnauthorizedRetirement(msg.sender);
        _retire();
    }

    // -------------------------------------------------------------------------
    // Direct signer rotation
    // -------------------------------------------------------------------------

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

    /// @notice Recovery by a direct call from an active management key.
    function rotateAuthorizedSignerThroughRecovery(address nextAuthorizedSigner, address nextManagementSigner)
        external
        onlyDelegatedAccount
        onlyInitialized
        onlyActiveManagementSigner
        returns (bool success, bytes memory result)
    {
        address managementSigner = msg.sender;
        _consumeManagementSigner(managementSigner);
        return _recoverAuthorizedSigner(managementSigner, nextAuthorizedSigner, nextManagementSigner);
    }

    // -------------------------------------------------------------------------
    // Signed execution (unchanged from OTS)
    // -------------------------------------------------------------------------

    function executeSignedAndRotate(Operation calldata operation, bytes calldata signature)
        external
        onlyDelegatedAccount
        onlyInitialized
        onlyUnpausedAccount
        returns (bool success, bytes memory result)
    {
        address consumedAuthorizedSigner = currentAuthorizedSigner;
        address recovered = hashOperation(operation).recover(signature);
        if (recovered != consumedAuthorizedSigner) revert InvalidSignature(recovered, consumedAuthorizedSigner);

        (bool rotationSucceeded, bytes memory rotationError) =
            _rotateAuthorizedSignerOrPause(operation.nextAuthorizedSigner);
        if (!rotationSucceeded) {
            emit SignedOperationExecuted(
                address(this), consumedAuthorizedSigner, operation.target, operation.value, operation.data,
                operation.nextAuthorizedSigner, false, rotationError
            );
            return (false, rotationError);
        }

        result = _operationValidation(operation);
        if (result.length != 0) {
            emit SignedOperationExecuted(
                address(this), consumedAuthorizedSigner, operation.target, operation.value, operation.data,
                operation.nextAuthorizedSigner, false, result
            );
            return (false, result);
        }

        (success, result) = operation.target.call{value: operation.value}(operation.data);
        emit SignedOperationExecuted(
            address(this), consumedAuthorizedSigner, operation.target, operation.value, operation.data,
            operation.nextAuthorizedSigner, success, result
        );
    }

    // -------------------------------------------------------------------------
    // Management: signed recovery and redelegation
    // -------------------------------------------------------------------------

    /// @notice Recovery signed by an active management key. A recovery that installs the new authorized
    ///         signer revokes every other management key (D-35).
    function signedRecovery(RecoveryOperation calldata recoveryOperation, bytes calldata signature)
        external
        onlyDelegatedAccount
        onlyInitialized
        returns (bool success, bytes memory result)
    {
        address recovered = hashRecoveryOperation(recoveryOperation).recover(signature);
        if (!isActiveManagementSigner(recovered)) revert ManagementSignerNotActive(recovered);
        _consumeManagementSigner(recovered);

        if (block.timestamp > recoveryOperation.deadline) {
            result = abi.encodeWithSelector(ExpiredOperation.selector, recoveryOperation.deadline);
            emit RecoveryOperationFailed(address(this), recovered, recoveryOperation.nextAuthorizedSigner, result);
            return (false, result);
        }

        return _recoverAuthorizedSigner(
            recovered, recoveryOperation.nextAuthorizedSigner, recoveryOperation.nextManagementSigner
        );
    }

    /// @notice Changes the implementation in the ERC-1967 slot. Only after retirement and only with a
    ///         signature of an active management key (D-22, D-23, D-48). The operational signer cannot do it.
    /// @dev Once the signature is verified the key is consumed and the named successor is installed; if the
    ///      redelegation cannot be applied, it returns `(false, reason)` without reverting (D-49).
    function redelegate(Redelegation calldata redelegation, bytes calldata signature)
        external
        onlyDelegatedAccount
        onlyInitialized
        returns (bool success, bytes memory result)
    {
        address previousImplementation = implementation();
        if (previousImplementation == address(0)) revert NotRetired();

        address recovered = hashRedelegation(redelegation).recover(signature);
        if (!isActiveManagementSigner(recovered)) revert ManagementSignerNotActive(recovered);
        _consumeManagementSigner(recovered);

        bytes memory successorError = _installManagementSuccessor(recovered, redelegation.nextManagementSigner);

        if (block.timestamp > redelegation.deadline) {
            result = abi.encodeWithSelector(ExpiredOperation.selector, redelegation.deadline);
            emit RedelegationFailed(address(this), recovered, redelegation.newImplementation, result);
            return (false, result);
        }

        result = _validateImplementation(redelegation.newImplementation);
        if (result.length != 0) {
            emit RedelegationFailed(address(this), recovered, redelegation.newImplementation, result);
            return (false, result);
        }

        StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value = redelegation.newImplementation;
        emit Redelegated(address(this), recovered, previousImplementation, redelegation.newImplementation);

        if (successorError.length != 0) return (false, successorError);
        return (true, bytes(""));
    }

    // -------------------------------------------------------------------------
    // EIP-712 hashing
    // -------------------------------------------------------------------------

    function hashOperation(Operation memory operation) public view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator(), operationStructHash(operation));
    }

    function hashRecoveryOperation(RecoveryOperation memory recoveryOperation) public view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator(), recoveryOperationStructHash(recoveryOperation));
    }

    function hashRedelegation(Redelegation memory redelegation) public view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator(), redelegationStructHash(redelegation));
    }

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

    function recoveryOperationStructHash(RecoveryOperation memory recoveryOperation) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                RECOVERY_OPERATION_TYPEHASH,
                recoveryOperation.nextAuthorizedSigner,
                recoveryOperation.nextManagementSigner,
                recoveryOperation.deadline
            )
        );
    }

    function redelegationStructHash(Redelegation memory redelegation) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                REDELEGATION_TYPEHASH,
                redelegation.newImplementation,
                redelegation.nextManagementSigner,
                redelegation.deadline
            )
        );
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _initialize(address firstAuthorizedSigner, address[] calldata initialManagementSigners) internal {
        if (isInitialized) revert AlreadyInitialized();
        if (msg.sender != address(this)) revert UnauthorizedInitializer(msg.sender, address(this));
        if (firstAuthorizedSigner == address(0)) revert InvalidNextAuthorizedSigner();

        isInitialized = true;
        isConsumedOrReservedSigner[address(this)] = true;
        isConsumedOrReservedSigner[firstAuthorizedSigner] = true;
        currentAuthorizedSigner = firstAuthorizedSigner;

        uint256 epoch = managementEpoch;
        for (uint16 i; i < initialManagementSigners.length; ++i) {
            address m = initialManagementSigners[i];
            if (m == address(0) || isConsumedOrReservedSigner[m]) revert InvalidNewManagementSigner();
            isConsumedOrReservedSigner[m] = true;
            _activeManagementSigner[epoch][m] = true;
            emit ManagementSignerRegistered(address(this), m);
        }

        emit Initialized(address(this), firstAuthorizedSigner);
    }

    /// @dev Writes the slot and executes SETSELFDELEGATE(PROXY) through the helper, in the account context.
    function _retire() internal {
        if (implementation() != address(0)) revert AlreadyRetired();
        StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value = IMPLEMENTATION_ADDR;

        (bool ok, bytes memory ret) = SET_SELF_DELEGATE_HELPER.delegatecall(abi.encode(PROXY));
        if (!ok || ret.length != 32 || abi.decode(ret, (uint256)) != 1) revert RetirementFailed();

        emit EcdsaRetired(address(this), PROXY, IMPLEMENTATION_ADDR);
    }

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

    /// @dev As OTS, plus D-35: once the new authorized signer is installed, the epoch advances (revoking every
    ///      other management key) and only the named successor is registered in the new epoch.
    function _recoverAuthorizedSigner(address managementSigner, address nextAuthorizedSigner, address nextManagementSigner)
        internal
        returns (bool success, bytes memory result)
    {
        result = _validateNewAuthorizedSigner(nextAuthorizedSigner);
        if (result.length != 0) {
            emit RecoveryOperationFailed(address(this), managementSigner, nextAuthorizedSigner, result);
            return (false, result);
        }

        isConsumedOrReservedSigner[nextAuthorizedSigner] = true;
        currentAuthorizedSigner = nextAuthorizedSigner;
        if (isPaused) isPaused = false;
        emit AccountUnpaused(address(this), managementSigner, nextAuthorizedSigner);

        uint256 newEpoch = managementEpoch + 1;
        managementEpoch = newEpoch;
        emit ManagementEpochAdvanced(address(this), newEpoch);

        result = _installManagementSuccessor(managementSigner, nextManagementSigner);
        if (result.length != 0) return (false, result);
        return (true, bytes(""));
    }

    function _consumeManagementSigner(address managementSigner) internal {
        _activeManagementSigner[managementEpoch][managementSigner] = false;
        emit ManagementSignerConsumed(address(this), managementSigner);
    }

    /// @dev Registers `nextManagementSigner` in the current epoch. Returns encoded error data if invalid.
    function _installManagementSuccessor(address previousManagementSigner, address nextManagementSigner)
        internal
        returns (bytes memory)
    {
        bytes memory err = _validateNewManagementSigner(nextManagementSigner);
        if (err.length != 0) return err;
        isConsumedOrReservedSigner[nextManagementSigner] = true;
        _activeManagementSigner[managementEpoch][nextManagementSigner] = true;
        emit ManagementSignerRotated(address(this), previousManagementSigner, nextManagementSigner);
        return bytes("");
    }

    function _validateNewAuthorizedSigner(address nextAuthorizedSigner) internal view returns (bytes memory) {
        if (nextAuthorizedSigner == address(0)) return abi.encodeWithSelector(InvalidNextAuthorizedSigner.selector);
        if (isConsumedOrReservedSigner[nextAuthorizedSigner]) {
            return abi.encodeWithSelector(SignerAlreadyConsumedOrReserved.selector, nextAuthorizedSigner);
        }
        return bytes("");
    }

    function _validateNewManagementSigner(address nextManagementSigner) internal view returns (bytes memory) {
        if (nextManagementSigner == address(0)) return abi.encodeWithSelector(InvalidNewManagementSigner.selector);
        if (isConsumedOrReservedSigner[nextManagementSigner] || isActiveManagementSigner(nextManagementSigner)) {
            return abi.encodeWithSelector(SignerAlreadyConsumedOrReserved.selector, nextManagementSigner);
        }
        return bytes("");
    }

    /// @dev ERC-1822 check (D-49) with a gas cap; never reverts.
    function _validateImplementation(address candidate) internal view returns (bytes memory) {
        if (candidate.code.length == 0) {
            return abi.encodeWithSelector(IncompatibleImplementation.selector, candidate);
        }
        (bool ok, bytes memory ret) = candidate.staticcall{gas: PROXIABLE_CHECK_GAS}(
            abi.encodeWithSelector(IERC1822Proxiable.proxiableUUID.selector)
        );
        if (!ok || ret.length != 32 || abi.decode(ret, (bytes32)) != IMPLEMENTATION_SLOT) {
            return abi.encodeWithSelector(IncompatibleImplementation.selector, candidate);
        }
        return bytes("");
    }

    function _operationValidation(Operation calldata operation) internal view returns (bytes memory) {
        if (operation.target == address(0)) return abi.encodeWithSelector(InvalidTarget.selector);
        if (block.timestamp > operation.deadline) {
            return abi.encodeWithSelector(ExpiredOperation.selector, operation.deadline);
        }
        return bytes("");
    }
}
