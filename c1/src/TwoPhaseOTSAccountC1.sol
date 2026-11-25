// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";

/// @title TwoPhaseOTSAccountC1 (d⁺, configuration C1⁺)
/// @notice OTS-C1 with two-phase authorization (commit, then execute) on every signed path.
/// @dev Modified copy of `OneTimeSignerAccountC1.sol` at `ots` 3edcbd25 (its functions are not `virtual`, and the
///      evaluated code must not change: D-156). Specification: `revisiones/CR-ESPECIFICACION.md` of the paper
///      (§2-§3; decisions D-160 to D-162 and D-167). Changes with respect to OTS-C1:
///      - The secret of each one-time key k (an operational signer `s_i` or a management key `μ_j`) is its
///        uncompressed public key pk(k) (64 bytes), which OTS-C1 already hides behind the address it stores.
///      - Commit phase (`commit`): anyone appends keccak256(δ ‖ γ) to the list L[ℓ], where
///          ℓ = H_loc(chainId ‖ a ‖ pk(k)),  δ = H_dig(eip712(m) ‖ r),  γ = H_com(chainId ‖ a ‖ pk(k) ‖ δ),
///        and H_tag(x) = keccak256(keccak256(tag) ‖ x) with the tags "OTS-2P/loc", "OTS-2P/com", "OTS-2P/dig".
///      - Execute phase: `executeSignedAndRotate`, `signedRecovery` and `redelegate` take the same signed message
///        as OTS-C1 plus pk(k), the salt r and the entries to skip; they require that the first valid entry under
///        ℓ commits to the executed message, and then run the OTS-C1 logic unchanged (rotation, management rule
///        D-52, ERC-1822 check D-49).
///      - Removed (R6): `rotateAuthorizedSigner` and `rotateAuthorizedSignerThroughRecovery` (one-step paths).
///      - The commitment entry at position 0 is deleted when the execution consumes k (D-167); a consumed key
///        never becomes current or active again (#122), so the deletion opens nothing.
///      - Own EIP-712 domain name, "TwoPhaseOTSAccountC1": OTS and OTS-C1 signatures are not valid here.
///      - Storage: the OTS-C1 variables in the same order, and the two-phase variables appended at the end
///        (§2.1), so that `redelegate(d⁺)` from OTS-C1 keeps the account state (T15).
///      Rules (CR-ESPECIFICACION §2.5): R1 first valid entry wins, no minimum age; R2 invalid entries are skipped;
///      R3 rotation or consumption in the execute phase; R4 no expiry frees ℓ; R5 a list, not a slot; R6 no
///      one-step path; R7 the commitment hides m (salted δ); R8 every check before any write.
contract TwoPhaseOTSAccountC1 is IERC1822Proxiable {
    using ECDSA for bytes32;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Operation authorized by the current one-time key (same type as OTS-C1).
    struct Operation {
        address target;
        uint256 value;
        bytes data;
        address nextAuthorizedSigner;
        uint256 deadline;
    }

    /// @notice Recovery authorized by an active management key (same type as OTS-C1).
    struct RecoveryOperation {
        address nextAuthorizedSigner;
        address nextManagementSigner;
        uint256 deadline;
    }

    /// @notice Redelegation authorized by an active management key (same type as OTS-C1).
    struct Redelegation {
        address newImplementation;
        address nextManagementSigner;
        uint256 deadline;
    }

    /// @notice Preimage (δ_j, γ_j) of an entry that the execution skips (read from the `Committed` events).
    struct SkippedEntry {
        bytes32 delta;
        bytes32 gamma;
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
    // Two-phase authorization
    /// @notice The public key is not 64 bytes (uncompressed secp256k1, without the 0x04 prefix).
    error InvalidPublicKey();
    /// @notice The address of the public key is not the current authorized signer.
    error PublicKeyMismatch(address keyAddress, address expectedAuthorizedSigner);
    /// @notice There is no entry under `locator` at the requested position.
    error NoCommitment(bytes32 locator);
    /// @notice R1: the entry at `position` is not the executed message's, or a skipped entry is valid.
    error NotFirstValid(bytes32 locator, uint256 position);
    /// @notice R2: the given (δ_j, γ_j) is not the preimage of the stored entry at `position`.
    error SkippedEntryMismatch(bytes32 locator, uint256 position);

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
    /// @notice Commit phase: an entry keccak256(δ ‖ γ) was appended to L[ℓ] at `position` (R5).
    event Committed(bytes32 indexed locator, bytes32 delta, bytes32 gamma, uint256 position);

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
    bytes32 public constant NAME_HASH = keccak256("TwoPhaseOTSAccountC1");
    bytes32 public constant VERSION_HASH = keccak256("1");

    /// @notice Domain tags of the three hashes (CR-ESPECIFICACION §2.3): H_tag(x) = keccak256(TAG ‖ x).
    bytes32 public constant TAG_LOC = keccak256("OTS-2P/loc");
    bytes32 public constant TAG_COM = keccak256("OTS-2P/com");
    bytes32 public constant TAG_DIG = keccak256("OTS-2P/dig");

    /// @notice ERC-1967 implementation slot (`keccak256("eip1967.proxy.implementation") - 1`), in the account storage.
    bytes32 public constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Gas forwarded to `proxiableUUID()` of a candidate implementation (as OTS-C1).
    uint256 internal constant PROXIABLE_CHECK_GAS = 30_000;

    // -------------------------------------------------------------------------
    // Immutable implementation context
    // -------------------------------------------------------------------------

    address private immutable IMPLEMENTATION_ADDR = address(this);
    address public immutable PROXY;
    address public immutable SET_SELF_DELEGATE_HELPER;

    // -------------------------------------------------------------------------
    // Delegated account storage. The first six variables are those of OTS-C1, in the same order (T15).
    // -------------------------------------------------------------------------

    bool public isInitialized;
    bool public isPaused;
    address public currentAuthorizedSigner;
    mapping(address => bool) public isConsumedOrReservedSigner;
    uint256 public managementEpoch;
    mapping(uint256 => mapping(address => bool)) private _activeManagementSigner;

    // Two-phase authorization (appended, §2.1). L[ℓ] = [firstEntry[ℓ]] ++ laterEntries[ℓ], in inclusion order.
    /// @notice Entry at position 0 of L[ℓ]: keccak256(δ ‖ γ). Deleted when the execution consumes k (D-167).
    mapping(bytes32 => bytes32) public firstEntry;
    /// @notice Entries at positions 1, 2, ... of L[ℓ] (R5: no bound on pending entries).
    mapping(bytes32 => bytes32[]) public laterEntries;

    // -------------------------------------------------------------------------
    // Construction and modifiers
    // -------------------------------------------------------------------------

    constructor(address proxy, address setSelfDelegateHelper) {
        if (proxy == address(0) || setSelfDelegateHelper == address(0)) revert InvalidDeployment();
        assert(IMPLEMENTATION_SLOT == bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));
        PROXY = proxy;
        SET_SELF_DELEGATE_HELPER = setSelfDelegateHelper;
    }

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

    receive() external payable onlyDelegatedAccount {}

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function isActiveManagementSigner(address signer) public view returns (bool) {
        return _activeManagementSigner[managementEpoch][signer];
    }

    function implementation() public view returns (address) {
        return StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value;
    }

    /// @notice ERC-1822: declares this contract a valid implementation for the account proxy (D-49, T15).
    function proxiableUUID() external view returns (bytes32) {
        if (address(this) != IMPLEMENTATION_ADDR) revert MustNotBeCalledThroughDelegation();
        return IMPLEMENTATION_SLOT;
    }

    /// @notice Number of entries in L[ℓ] (0 once the entry at position 0 was deleted on consumption).
    function entryCount(bytes32 locator) public view returns (uint256) {
        if (firstEntry[locator] == bytes32(0)) return 0;
        return 1 + laterEntries[locator].length;
    }

    /// @notice ℓ = H_loc(chainId ‖ a ‖ pk(k)), for wallets. The execution recomputes it from pk.
    function locatorOf(bytes calldata publicKey) external view returns (bytes32) {
        if (publicKey.length != 64) revert InvalidPublicKey();
        return _locator(publicKey);
    }

    /// @notice δ = H_dig(eip712(m) ‖ r) (R7).
    function blindedDigestOf(bytes32 digest, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(TAG_DIG, digest, salt));
    }

    /// @notice γ = H_com(chainId ‖ a ‖ pk(k) ‖ δ).
    function commitmentOf(bytes calldata publicKey, bytes32 delta) external view returns (bytes32) {
        if (publicKey.length != 64) revert InvalidPublicKey();
        return _commitment(publicKey, delta);
    }

    // -------------------------------------------------------------------------
    // Initialization and retirement (unchanged from OTS-C1)
    // -------------------------------------------------------------------------

    /// @notice V2, first transaction: initializes without retirement (C0⁺ if `h` is never retired, T16).
    function initialize(address firstAuthorizedSigner, address[] calldata initialManagementSigners)
        external
        onlyDelegatedAccount
    {
        _initialize(firstAuthorizedSigner, initialManagementSigners);
    }

    /// @notice V1 with d = d⁺: activation of C1⁺ in the migration (D-162).
    function initializeAndRetire(address firstAuthorizedSigner, address[] calldata initialManagementSigners)
        external
        onlyDelegatedAccount
    {
        _initialize(firstAuthorizedSigner, initialManagementSigners);
        _retire();
    }

    /// @notice V2, second transaction: retires `h` (only from the account itself, once).
    function retire() external onlyDelegatedAccount onlyInitialized {
        if (msg.sender != address(this)) revert UnauthorizedRetirement(msg.sender);
        _retire();
    }

    // -------------------------------------------------------------------------
    // Commit phase
    // -------------------------------------------------------------------------

    /// @notice Appends keccak256(δ ‖ γ) to L[ℓ]. Anyone may call it (A3): it checks nothing, never overwrites and
    ///         never deletes (R5). It carries no signature, because signing would expose pk(k), and no m (R7).
    /// @dev Only the delegation context is checked, so that a commitment is never written to the
    ///      implementation's own storage.
    function commit(bytes32 locator, bytes32 delta, bytes32 gamma)
        external
        onlyDelegatedAccount
        returns (uint256 position)
    {
        bytes32 entry = keccak256(abi.encodePacked(delta, gamma));
        if (firstEntry[locator] == bytes32(0)) {
            firstEntry[locator] = entry;
        } else {
            laterEntries[locator].push(entry);
            position = laterEntries[locator].length;
        }
        emit Committed(locator, delta, gamma, position);
    }

    // -------------------------------------------------------------------------
    // Execute phase: the three signed paths of OTS-C1 (D-162). The one-step paths are removed (R6).
    // -------------------------------------------------------------------------

    /// @notice Operation in two phases. Checks, in order and before any write (R8): pk is the current signer;
    ///         the first valid entry under ℓ commits to this operation (R1, R2); σ is the current signer's.
    ///         Then, as OTS-C1: rotation or pause (R3), deadline and call. An expired operation still rotates
    ///         without effect, and the entry does not expire (R4).
    function executeSignedAndRotate(
        Operation calldata operation,
        bytes calldata signature,
        bytes calldata publicKey,
        bytes32 salt,
        SkippedEntry[] calldata skipped
    ) external onlyDelegatedAccount onlyInitialized onlyUnpausedAccount returns (bool success, bytes memory result) {
        (address consumedAuthorizedSigner, bytes32 locator) =
            _checkOperation(operation, signature, publicKey, salt, skipped);
        return _operationAfterChecks(consumedAuthorizedSigner, locator, operation);
    }

    /// @notice Recovery in two phases. Checks before any write (R8): pk is an active management key; the first
    ///         valid entry under ℓ commits to this recovery (R1, R2); σ is pk's. Then the management rule of
    ///         OTS-C1 (D-52) and the epoch revocation (D-35), unchanged: μ_j is consumed in this call (R3).
    function signedRecovery(
        RecoveryOperation calldata recoveryOperation,
        bytes calldata signature,
        bytes calldata publicKey,
        bytes32 salt,
        SkippedEntry[] calldata skipped
    ) external onlyDelegatedAccount onlyInitialized returns (bool success, bytes memory result) {
        bytes32 digest = hashRecoveryOperation(recoveryOperation);
        (address managementSigner, bytes32 locator) = _checkManagement(digest, signature, publicKey, salt, skipped);
        return _recoveryAfterChecks(managementSigner, locator, recoveryOperation);
    }

    /// @notice Code change in two phases. Checks before any write (R8) as `signedRecovery`; then the management
    ///         rule (D-52) and the ERC-1822 check (D-49) of OTS-C1, unchanged. The slot changes only to the
    ///         implementation of the message committed first for μ_j (R1).
    function redelegate(
        Redelegation calldata redelegation,
        bytes calldata signature,
        bytes calldata publicKey,
        bytes32 salt,
        SkippedEntry[] calldata skipped
    ) external onlyDelegatedAccount onlyInitialized returns (bool success, bytes memory result) {
        bytes32 digest = hashRedelegation(redelegation);
        (address managementSigner, bytes32 locator) = _checkManagement(digest, signature, publicKey, salt, skipped);
        return _redelegationAfterChecks(managementSigner, locator, redelegation);
    }

    // -------------------------------------------------------------------------
    // Effects of the three signed paths, run only after every check passed (R8). Split from the external
    // functions only to keep the stack shallow; the logic is that of OTS-C1 (rotation, D-52, D-35, D-49).
    // -------------------------------------------------------------------------

    function _operationAfterChecks(address consumedAuthorizedSigner, bytes32 locator, Operation calldata operation)
        internal
        returns (bool success, bytes memory result)
    {
        delete firstEntry[locator]; // D-167: k is consumed (or the account paused) below

        (bool rotationSucceeded, bytes memory rotationError) =
            _rotateAuthorizedSignerOrPause(operation.nextAuthorizedSigner); // R3
        if (!rotationSucceeded) {
            emit SignedOperationExecuted(
                address(this), consumedAuthorizedSigner, operation.target, operation.value, operation.data,
                operation.nextAuthorizedSigner, false, rotationError
            );
            return (false, rotationError);
        }

        result = _operationValidation(operation); // R4: an expired operation rotates without effect
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

    function _recoveryAfterChecks(
        address managementSigner,
        bytes32 locator,
        RecoveryOperation calldata recoveryOperation
    ) internal returns (bool success, bytes memory result) {
        delete firstEntry[locator]; // D-167
        _consumeManagementSigner(managementSigner); // R3

        bytes memory actionError;
        if (block.timestamp > recoveryOperation.deadline) {
            actionError = abi.encodeWithSelector(ExpiredOperation.selector, recoveryOperation.deadline);
        }
        return _applyRecovery(
            managementSigner, recoveryOperation.nextAuthorizedSigner, recoveryOperation.nextManagementSigner, actionError
        );
    }

    function _redelegationAfterChecks(address managementSigner, bytes32 locator, Redelegation calldata redelegation)
        internal
        returns (bool success, bytes memory result)
    {
        delete firstEntry[locator]; // D-167
        _consumeManagementSigner(managementSigner); // R3

        address previousImplementation = implementation();
        bytes memory actionError;
        if (previousImplementation == address(0)) {
            actionError = abi.encodeWithSelector(NotRetired.selector);
        } else if (block.timestamp > redelegation.deadline) {
            actionError = abi.encodeWithSelector(ExpiredOperation.selector, redelegation.deadline);
        } else {
            actionError = _validateImplementation(redelegation.newImplementation);
        }
        bytes memory successorError = _validateNewManagementSigner(redelegation.nextManagementSigner);

        if (successorError.length == 0) {
            _registerManagementSuccessor(managementSigner, redelegation.nextManagementSigner);
        }

        if (actionError.length == 0 && successorError.length == 0) {
            StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value = redelegation.newImplementation;
            emit Redelegated(address(this), managementSigner, previousImplementation, redelegation.newImplementation);
            return (true, bytes(""));
        }

        result = actionError.length != 0 ? actionError : successorError;
        emit RedelegationFailed(address(this), managementSigner, redelegation.newImplementation, result);
        return (false, result);
    }

    // -------------------------------------------------------------------------
    // EIP-712 hashing (same types as OTS-C1, own domain)
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
    // Two-phase internals (view only: no write happens before every check has passed, R8)
    // -------------------------------------------------------------------------

    /// @dev Address of a 64-byte uncompressed secp256k1 public key.
    function _keyAddress(bytes calldata publicKey) internal pure returns (address) {
        if (publicKey.length != 64) revert InvalidPublicKey();
        return address(uint160(uint256(keccak256(publicKey))));
    }

    function _locator(bytes calldata publicKey) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(TAG_LOC, block.chainid, address(this), publicKey));
    }

    function _commitment(bytes calldata publicKey, bytes32 delta) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(TAG_COM, block.chainid, address(this), publicKey, delta));
    }

    /// @dev Entry at `position` of L[ℓ], or zero if there is none (an entry is a keccak256 output, never zero).
    ///      Position 0 reads one slot only, so the normal path does not read the length of `laterEntries`.
    function _entryAt(bytes32 locator, uint256 position) internal view returns (bytes32) {
        if (position == 0) return firstEntry[locator];
        bytes32[] storage later = laterEntries[locator];
        return position - 1 < later.length ? later[position - 1] : bytes32(0);
    }

    /// @dev R1 and R2. The caller lists, in order, the preimages of the entries before the executed one. Each
    ///      listed entry must match its stored hash and be invalid for pk (γ_j ≠ H_com(… pk ‖ δ_j)): a valid
    ///      entry cannot be skipped, whatever message it commits to. The entry right after them must be
    ///      keccak256(δ ‖ γ) of the executed message. No minimum age (R1) and no expiry (R4) is checked.
    function _checkFirstValidEntry(
        bytes calldata publicKey,
        bytes32 digest,
        bytes32 salt,
        SkippedEntry[] calldata skipped
    ) internal view returns (bytes32 locator) {
        locator = _locator(publicKey);
        uint256 position = skipped.length;
        bytes32 stored = _entryAt(locator, position);
        if (stored == bytes32(0)) revert NoCommitment(locator);
        for (uint256 j; j < position; ++j) {
            bytes32 dj = skipped[j].delta;
            bytes32 gj = skipped[j].gamma;
            if (keccak256(abi.encodePacked(dj, gj)) != _entryAt(locator, j)) revert SkippedEntryMismatch(locator, j);
            if (gj == _commitment(publicKey, dj)) revert NotFirstValid(locator, j);
        }
        bytes32 delta = blindedDigestOf(digest, salt);
        bytes32 entry = keccak256(abi.encodePacked(delta, _commitment(publicKey, delta)));
        if (stored != entry) revert NotFirstValid(locator, position);
    }

    /// @dev Checks of the operational path, before any write (R8): pk is the current signer, the first valid
    ///      entry commits to the operation, and σ is the current signer's.
    function _checkOperation(
        Operation calldata operation,
        bytes calldata signature,
        bytes calldata publicKey,
        bytes32 salt,
        SkippedEntry[] calldata skipped
    ) internal view returns (address signer, bytes32 locator) {
        signer = currentAuthorizedSigner;
        address keyAddress = _keyAddress(publicKey);
        if (keyAddress != signer) revert PublicKeyMismatch(keyAddress, signer);
        bytes32 digest = hashOperation(operation);
        locator = _checkFirstValidEntry(publicKey, digest, salt, skipped);
        address recovered = digest.recover(signature);
        if (recovered != signer) revert InvalidSignature(recovered, signer);
    }

    /// @dev Checks of the two management paths, before any write (R8): pk is an active management key, the
    ///      first valid entry commits to `digest`, and σ is pk's.
    function _checkManagement(
        bytes32 digest,
        bytes calldata signature,
        bytes calldata publicKey,
        bytes32 salt,
        SkippedEntry[] calldata skipped
    ) internal view returns (address managementSigner, bytes32 locator) {
        managementSigner = _keyAddress(publicKey);
        if (!isActiveManagementSigner(managementSigner)) revert ManagementSignerNotActive(managementSigner);
        locator = _checkFirstValidEntry(publicKey, digest, salt, skipped);
        address recovered = digest.recover(signature);
        if (recovered != managementSigner) revert InvalidSignature(recovered, managementSigner);
    }

    // -------------------------------------------------------------------------
    // Internal helpers (unchanged from OTS-C1)
    // -------------------------------------------------------------------------

    function _initialize(address firstAuthorizedSigner, address[] calldata initialManagementSigners) internal {
        if (isInitialized) revert AlreadyInitialized();
        if (msg.sender != address(this)) revert UnauthorizedInitializer(msg.sender, address(this));
        if (firstAuthorizedSigner == address(0)) revert InvalidNextAuthorizedSigner();
        if (initialManagementSigners.length == 0) revert InvalidNewManagementSigner(); // D-55

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

    function _applyRecovery(
        address managementSigner,
        address nextAuthorizedSigner,
        address nextManagementSigner,
        bytes memory actionError
    ) internal returns (bool success, bytes memory result) {
        if (actionError.length == 0) actionError = _validateNewAuthorizedSigner(nextAuthorizedSigner);
        bytes memory successorError = _validateNewManagementSigner(nextManagementSigner);
        if (successorError.length == 0 && nextManagementSigner == nextAuthorizedSigner) {
            successorError = abi.encodeWithSelector(SignerAlreadyConsumedOrReserved.selector, nextManagementSigner);
        }

        if (actionError.length == 0 && successorError.length == 0) {
            isConsumedOrReservedSigner[nextAuthorizedSigner] = true;
            currentAuthorizedSigner = nextAuthorizedSigner;
            if (isPaused) isPaused = false;
            emit AccountUnpaused(address(this), managementSigner, nextAuthorizedSigner);

            uint256 newEpoch = managementEpoch + 1;
            managementEpoch = newEpoch;
            emit ManagementEpochAdvanced(address(this), newEpoch);

            _registerManagementSuccessor(managementSigner, nextManagementSigner);
            return (true, bytes(""));
        }

        if (successorError.length == 0) _registerManagementSuccessor(managementSigner, nextManagementSigner);
        result = actionError.length != 0 ? actionError : successorError;
        emit RecoveryOperationFailed(address(this), managementSigner, nextAuthorizedSigner, result);
        return (false, result);
    }

    function _consumeManagementSigner(address managementSigner) internal {
        _activeManagementSigner[managementEpoch][managementSigner] = false;
        emit ManagementSignerConsumed(address(this), managementSigner);
    }

    function _registerManagementSuccessor(address previousManagementSigner, address nextManagementSigner) internal {
        isConsumedOrReservedSigner[nextManagementSigner] = true;
        _activeManagementSigner[managementEpoch][nextManagementSigner] = true;
        emit ManagementSignerRotated(address(this), previousManagementSigner, nextManagementSigner);
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
