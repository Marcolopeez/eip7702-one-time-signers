// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

import {OneTimeSignerAccount} from "../src/OneTimeSignerAccount.sol";
import {ExecutionTarget} from "./mocks/ExecutionTarget.sol";

/// @notice Tests for the minimal EIP-7702 rotating-signer account.
/// @dev These tests intentionally use Foundry's EIP-7702 cheatcode support. The account address `A1`
///      starts as a plain EOA, then receives EIP-7702 delegation code pointing to `implementation`.
contract OneTimeSignerAccountTest is Test {
    using ECDSA for bytes32;

    // -------------------------------------------------------------------------
    // Test signers
    // -------------------------------------------------------------------------

    uint256 internal constant A1_PK = 0xA11CE;
    uint256 internal constant A2_PK = 0xB0B;
    uint256 internal constant A3_PK = 0xCAFE;
    uint256 internal constant A4_PK = 0xD00D;
    uint256 internal constant R1_PK = 0xAABB;
    uint256 internal constant R2_PK = 0xCCDD;
    uint256 internal constant R3_PK = 0xDDCC;
    uint256 internal constant R4_PK = 0xEEFF;
    uint256 internal constant RELAYER_PK = 0x1234;
    uint256 internal constant ATTACKER_PK = 0xBAD;
    uint256 internal constant OTHER_ACCOUNT_PK = 0xA55A;

    // -------------------------------------------------------------------------
    // Test accounts
    // -------------------------------------------------------------------------

    address payable internal A1;
    address payable internal otherAccount;

    address internal A2;
    address internal A3;
    address internal A4;
    address internal R1;
    address internal R2;
    address internal R3;
    address internal R4;
    address internal relayer;
    address internal attacker;

    OneTimeSignerAccount internal implementation;
    ExecutionTarget internal target;

    event RecoverySignerConsumed(address indexed account, address indexed recoverySigner);
    event RecoverySignerRotated(
        address indexed account,
        address indexed previousRecoverySigner,
        address indexed nextRecoverySigner
    );
    event AccountUnpaused(
        address indexed account,
        address indexed recoverySigner,
        address indexed nextAuthorizedSigner
    );
    event AccountRecovered(
        address indexed account,
        address indexed recoverySigner,
        address indexed previousAuthorizedSigner,
        address nextAuthorizedSigner
    );

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        A1 = payable(vm.addr(A1_PK));
        A2 = vm.addr(A2_PK);
        A3 = vm.addr(A3_PK);
        A4 = vm.addr(A4_PK);
        R1 = vm.addr(R1_PK);
        R2 = vm.addr(R2_PK);
        R3 = vm.addr(R3_PK);
        R4 = vm.addr(R4_PK);
        relayer = vm.addr(RELAYER_PK);
        attacker = vm.addr(ATTACKER_PK);
        otherAccount = payable(vm.addr(OTHER_ACCOUNT_PK));

        implementation = new OneTimeSignerAccount();
        target = new ExecutionTarget();

        vm.label(A1, "A1 - delegated EOA");
        vm.label(A2, "A2 - first one-time signer");
        vm.label(A3, "A3 - second one-time signer");
        vm.label(A4, "A4 - third one-time signer");
        vm.label(R1, "R1 - recovery signer");
        vm.label(R2, "R2 - recovery signer");
        vm.label(R3, "R3 - renewed recovery signer");
        vm.label(R4, "R4 - second renewed recovery signer");
        vm.label(relayer, "Relayer");
        vm.label(attacker, "Attacker");
        vm.label(otherAccount, "Other delegated EOA");
        vm.label(address(implementation), "OneTimeSignerAccount implementation");
        vm.label(address(target), "ExecutionTarget");
    }

    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------

    function test_initialize_setsFirstAuthorizedSignerAndRecoverySignersInDelegatedAccountStorage() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        assertEq(A1.code, _expectedDelegationCode(), "A1 should contain EIP-7702 delegation code");
        assertTrue(_account(A1).isInitialized(), "A1 delegated storage should be initialized");
        assertFalse(_account(A1).isPaused(), "account should start unpaused");
        assertEq(_account(A1).currentAuthorizedSigner(), A2, "A2 should be the first authorized signer");

        assertTrue(_account(A1).isConsumedOrReservedSigner(A1), "delegated account address should be reserved");
        assertTrue(_account(A1).isConsumedOrReservedSigner(A2), "first authorized signer should be reserved");
        assertTrue(_account(A1).isConsumedOrReservedSigner(R1), "R1 should be reserved");
        assertTrue(_account(A1).isConsumedOrReservedSigner(R2), "R2 should be reserved");
        assertTrue(_account(A1).isActiveRecoverySigner(R1), "R1 should be active");
        assertTrue(_account(A1).isActiveRecoverySigner(R2), "R2 should be active");

        assertFalse(implementation.isInitialized(), "implementation storage should remain uninitialized");
        assertFalse(implementation.isPaused(), "implementation storage should remain unpaused");
        assertEq(implementation.currentAuthorizedSigner(), address(0), "implementation should not store A2");
    }

    function test_initialize_revertsWhenCalledOnImplementation() public {
        address[] memory recoverySigners = new address[](0);

        vm.expectRevert(OneTimeSignerAccount.MustBeCalledThroughDelegation.selector);
        implementation.initialize(A2, recoverySigners);
    }

    function test_initialize_revertsWithZeroAuthorizedSigner() public {
        _delegate(A1_PK);

        vm.prank(A1);
        vm.expectRevert(OneTimeSignerAccount.InvalidNextAuthorizedSigner.selector);
        _account(A1).initialize(address(0), _defaultRecoverySigners());
    }

    function test_initialize_revertsWhenCallerIsNotDelegatedAccount() public {
        _delegate(A1_PK);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                OneTimeSignerAccount.UnauthorizedInitializer.selector,
                attacker,
                A1
            )
        );
        _account(A1).initialize(attacker, _defaultRecoverySigners());
    }

    function test_initialize_revertsWhenCalledTwice() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        vm.prank(A1);
        vm.expectRevert(OneTimeSignerAccount.AlreadyInitialized.selector);
        _account(A1).initialize(vm.addr(0xD00D), _defaultRecoverySigners());
    }

    function test_initialize_revertsWithZeroRecoverySigner() public {
        address[] memory recoverySigners = new address[](1);
        recoverySigners[0] = address(0);

        _delegate(A1_PK);

        vm.prank(A1);
        vm.expectRevert(OneTimeSignerAccount.InvalidNewRecoverySigner.selector);
        _account(A1).initialize(A2, recoverySigners);
    }

    function test_initialize_revertsWhenRecoverySignerEqualsFirstAuthorizedSigner() public {
        address[] memory recoverySigners = new address[](1);
        recoverySigners[0] = A2;

        _delegate(A1_PK);

        vm.prank(A1);
        vm.expectRevert(OneTimeSignerAccount.InvalidNewRecoverySigner.selector);
        _account(A1).initialize(A2, recoverySigners);
    }

    function test_initialize_revertsWithDuplicatedRecoverySigner() public {
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = R1;
        recoverySigners[1] = R1;

        _delegate(A1_PK);

        vm.prank(A1);
        vm.expectRevert(OneTimeSignerAccount.InvalidNewRecoverySigner.selector);
        _account(A1).initialize(A2, recoverySigners);
    }

    // -------------------------------------------------------------------------
    // Direct signer rotation
    // -------------------------------------------------------------------------

    function test_rotateAuthorizedSigner_revertsWhenCallerIsDelegatedAccountItself() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        vm.prank(A1);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.Unauthorized.selector, A1, A2));
        _account(A1).rotateAuthorizedSigner(A3);

        assertEq(_account(A1).currentAuthorizedSigner(), A2, "authorized signer should remain A2");
        assertFalse(_account(A1).isPaused(), "account should remain unpaused");
    }

    function test_rotateAuthorizedSigner_allowsCurrentAuthorizedSignerToRotate() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        vm.prank(A2);
        (bool success, bytes memory result) = _account(A1).rotateAuthorizedSigner(A3);

        assertTrue(success, "rotation should succeed");
        assertEq(result.length, 0, "successful rotation should return empty result");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "authorized signer should rotate to A3");
        assertTrue(_account(A1).isConsumedOrReservedSigner(A3), "A3 should be marked as used/reserved");
        assertFalse(_account(A1).isPaused(), "account should remain unpaused");
    }

    function test_rotateAuthorizedSigner_burnsPreviousSigner() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        vm.prank(A2);
        _account(A1).rotateAuthorizedSigner(A3);

        vm.prank(A2);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.Unauthorized.selector, A2, A3));
        _account(A1).rotateAuthorizedSigner(A4);

        assertEq(_account(A1).currentAuthorizedSigner(), A3, "authorized signer should remain A3");
    }

    function test_rotateAuthorizedSigner_allowsNewAuthorizedSignerToContinueChain() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        vm.prank(A2);
        _account(A1).rotateAuthorizedSigner(A3);

        vm.prank(A3);
        _account(A1).rotateAuthorizedSigner(A4);

        assertEq(_account(A1).currentAuthorizedSigner(), A4, "authorized signer should rotate to A4");
    }

    function test_rotateAuthorizedSigner_pausesWithZeroNextAuthorizedSigner() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        vm.prank(A2);
        (bool success, bytes memory result) = _account(A1).rotateAuthorizedSigner(address(0));

        assertFalse(success, "invalid rotation should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.InvalidNextAuthorizedSigner.selector));
        assertTrue(_account(A1).isPaused(), "account should be paused after exposing A2");
        assertEq(_account(A1).currentAuthorizedSigner(), A2, "authorized signer remains A2 because there is no safe next signer");
    }

    function test_rotateAuthorizedSigner_pausesWhenReusingDelegatedAccountAddress() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        vm.prank(A2);
        (bool success, bytes memory result) = _account(A1).rotateAuthorizedSigner(A1);

        assertFalse(success, "invalid rotation should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.SignerAlreadyConsumedOrReserved.selector, A1));
        assertTrue(_account(A1).isPaused(), "account should be paused");
        assertEq(_account(A1).currentAuthorizedSigner(), A2, "authorized signer should remain A2");
    }

    function test_rotateAuthorizedSigner_pausesWhenReusingPreviousAuthorizedSigner() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        vm.prank(A2);
        _account(A1).rotateAuthorizedSigner(A3);

        vm.prank(A3);
        (bool success, bytes memory result) = _account(A1).rotateAuthorizedSigner(A2);

        assertFalse(success, "invalid rotation should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.SignerAlreadyConsumedOrReserved.selector, A2));
        assertTrue(_account(A1).isPaused(), "account should be paused after exposing A3");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "authorized signer should remain A3");
    }

    function test_rotateAuthorizedSigner_pausesWhenReusingCurrentAuthorizedSigner() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        vm.prank(A2);
        (bool success, bytes memory result) = _account(A1).rotateAuthorizedSigner(A2);

        assertFalse(success, "invalid rotation should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.SignerAlreadyConsumedOrReserved.selector, A2));
        assertTrue(_account(A1).isPaused(), "account should be paused after exposing A2");
        assertEq(_account(A1).currentAuthorizedSigner(), A2, "authorized signer should remain A2");
    }

    // -------------------------------------------------------------------------
    // Signed execution: happy paths
    // -------------------------------------------------------------------------

    function test_executeSignedAndRotate_allowsRelayerToSubmitOperationSignedByA2() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        OneTimeSignerAccount.Operation memory operation = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.setNumber, (42)),
            nextAuthorizedSigner_: A3
        });

        bytes memory signature = _signOperation(A1, A2_PK, operation);

        vm.prank(relayer);
        (bool success, bytes memory result) = _account(A1).executeSignedAndRotate(operation, signature);

        assertTrue(success, "target call should succeed");
        assertEq(abi.decode(result, (uint256)), 43, "return data should be forwarded");

        assertEq(target.number(), 42, "target number should be updated");
        assertEq(target.lastSender(), A1, "target should see A1 as msg.sender");
        assertEq(target.lastValue(), 0, "no ETH should be sent");

        assertEq(_account(A1).currentAuthorizedSigner(), A3, "authorized signer should rotate to A3");
        assertFalse(_account(A1).isPaused(), "account should remain unpaused");
    }

    function test_executeSignedAndRotate_canSendEthFromDelegatedAccount() public {
        _delegateAndInitialize(A1, A1_PK, A2);
        vm.deal(A1, 1 ether);

        OneTimeSignerAccount.Operation memory operation = _operation({
            target_: address(target),
            value_: 0.25 ether,
            data_: abi.encodeCall(ExecutionTarget.setNumber, (42)),
            nextAuthorizedSigner_: A3
        });

        bytes memory signature = _signOperation(A1, A2_PK, operation);

        vm.prank(relayer);
        (bool success,) = _account(A1).executeSignedAndRotate(operation, signature);

        assertTrue(success, "target call should succeed");
        assertEq(address(target).balance, 0.25 ether, "target should receive ETH");
        assertEq(A1.balance, 0.75 ether, "A1 balance should decrease");
        assertEq(target.lastSender(), A1, "target should see A1 as msg.sender");
        assertEq(target.lastValue(), 0.25 ether, "target should receive msg.value");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "authorized signer should rotate to A3");
    }

    function test_executeSignedAndRotate_allowsNewKeyToContinueChain() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        OneTimeSignerAccount.Operation memory firstOperation = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.setNumber, (42)),
            nextAuthorizedSigner_: A3
        });

        bytes memory firstSignature = _signOperation(A1, A2_PK, firstOperation);

        vm.prank(relayer);
        (bool firstSuccess,) = _account(A1).executeSignedAndRotate(firstOperation, firstSignature);

        assertTrue(firstSuccess, "first target call should succeed");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "control should pass to A3");

        OneTimeSignerAccount.Operation memory secondOperation = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.setNumber, (100)),
            nextAuthorizedSigner_: A4
        });

        bytes memory secondSignature = _signOperation(A1, A3_PK, secondOperation);

        vm.prank(relayer);
        (bool secondSuccess,) = _account(A1).executeSignedAndRotate(secondOperation, secondSignature);

        assertTrue(secondSuccess, "second target call should succeed");
        assertEq(target.number(), 100, "target number should be updated by A3");
        assertEq(target.lastSender(), A1, "target should still see A1 as msg.sender");
        assertEq(_account(A1).currentAuthorizedSigner(), A4, "authorized signer should rotate to A4");
    }

    // -------------------------------------------------------------------------
    // Signed execution: one-time-signer security property
    // -------------------------------------------------------------------------

    function test_executeSignedAndRotate_rotatesEvenWhenTargetReverts() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        OneTimeSignerAccount.Operation memory operation = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.alwaysRevert, ()),
            nextAuthorizedSigner_: A3
        });

        bytes memory signature = _signOperation(A1, A2_PK, operation);

        vm.prank(relayer);
        (bool success, bytes memory result) = _account(A1).executeSignedAndRotate(operation, signature);

        assertFalse(success, "target call should fail");
        assertGt(result.length, 0, "revert data should be returned");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "A3 should become authorized even if execution fails");
        assertFalse(_account(A1).isPaused(), "target revert should not pause the account");
        assertEq(target.number(), 0, "target state should remain unchanged");
    }

    function test_executeSignedAndRotate_burnsA2SignatureAfterFailedExecution() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        OneTimeSignerAccount.Operation memory operation = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.alwaysRevert, ()),
            nextAuthorizedSigner_: A3
        });

        bytes memory signature = _signOperation(A1, A2_PK, operation);

        vm.prank(relayer);
        (bool success,) = _account(A1).executeSignedAndRotate(operation, signature);

        assertFalse(success, "target call should fail");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "control should pass to A3");

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, A2, A3));
        _account(A1).executeSignedAndRotate(operation, signature);
    }

    function test_executeSignedAndRotate_burnsA2SignatureAfterSuccessfulExecution() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        OneTimeSignerAccount.Operation memory operation = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.setNumber, (42)),
            nextAuthorizedSigner_: A3
        });

        bytes memory signature = _signOperation(A1, A2_PK, operation);

        vm.prank(relayer);
        (bool success,) = _account(A1).executeSignedAndRotate(operation, signature);

        assertTrue(success, "target call should succeed");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "control should pass to A3");

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, A2, A3));
        _account(A1).executeSignedAndRotate(operation, signature);
    }

    // -------------------------------------------------------------------------
    // Signed execution: invalid operations
    // -------------------------------------------------------------------------

    function test_executeSignedAndRotate_revertsWithInvalidSigner() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        OneTimeSignerAccount.Operation memory operation = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.setNumber, (42)),
            nextAuthorizedSigner_: A3
        });

        bytes memory signature = _signOperation(A1, ATTACKER_PK, operation);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, attacker, A2));
        _account(A1).executeSignedAndRotate(operation, signature);

        assertEq(_account(A1).currentAuthorizedSigner(), A2, "authorized signer should remain A2");
        assertFalse(_account(A1).isPaused(), "invalid signer should not pause the account");
        assertEq(target.number(), 0, "target should not be called");
    }

    function test_executeSignedAndRotate_pausesWhenNextAuthorizedSignerIsZero() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        OneTimeSignerAccount.Operation memory operation = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.setNumber, (42)),
            nextAuthorizedSigner_: address(0)
        });

        bytes memory signature = _signOperation(A1, A2_PK, operation);

        vm.prank(relayer);
        (bool success, bytes memory result) = _account(A1).executeSignedAndRotate(operation, signature);

        assertFalse(success, "invalid rotation should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.InvalidNextAuthorizedSigner.selector));
        assertTrue(_account(A1).isPaused(), "account should pause because A2 was exposed");
        assertEq(_account(A1).currentAuthorizedSigner(), A2, "authorized signer remains A2 without a safe next signer");
        assertEq(target.number(), 0, "target should not be called");
    }

    function test_executeSignedAndRotate_pausesWhenReusingAuthorizedSigner() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        OneTimeSignerAccount.Operation memory op1 = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.setNumber, (1)),
            nextAuthorizedSigner_: A3
        });

        bytes memory sig1 = _signOperation(A1, A2_PK, op1);

        vm.prank(relayer);
        (bool firstSuccess,) = _account(A1).executeSignedAndRotate(op1, sig1);
        assertTrue(firstSuccess, "first operation should succeed");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "control should pass to A3");

        OneTimeSignerAccount.Operation memory op2 = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.setNumber, (2)),
            nextAuthorizedSigner_: A2
        });

        bytes memory sig2 = _signOperation(A1, A3_PK, op2);

        vm.prank(relayer);
        (bool secondSuccess, bytes memory result) = _account(A1).executeSignedAndRotate(op2, sig2);

        assertFalse(secondSuccess, "reused next signer should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.SignerAlreadyConsumedOrReserved.selector, A2));
        assertTrue(_account(A1).isPaused(), "account should pause because A3 was exposed");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "authorized signer should remain A3");
        assertEq(target.number(), 1, "second operation should not be executed");
    }

    function test_executeSignedAndRotate_rotatesAndReturnsFailureWhenOperationExpired() public {
        _delegateAndInitialize(A1, A1_PK, A2);
        vm.warp(1_000_000);

        OneTimeSignerAccount.Operation memory operation = OneTimeSignerAccount.Operation({
            target: address(target),
            value: 0,
            data: abi.encodeCall(ExecutionTarget.setNumber, (42)),
            nextAuthorizedSigner: A3,
            deadline: block.timestamp - 1
        });

        bytes memory signature = _signOperation(A1, A2_PK, operation);

        vm.prank(relayer);
        (bool success, bytes memory result) = _account(A1).executeSignedAndRotate(operation, signature);

        assertFalse(success, "expired operation should be reported as failed");
        assertEq(
            result,
            abi.encodeWithSelector(OneTimeSignerAccount.ExpiredOperation.selector, operation.deadline),
            "result should contain the encoded ExpiredOperation error"
        );

        assertEq(_account(A1).currentAuthorizedSigner(), A3, "authorized signer should rotate even if operation is expired");
        assertFalse(_account(A1).isPaused(), "expired executable part should not pause after successful rotation");
        assertEq(target.number(), 0, "target should not be called");
    }

    function test_executeSignedAndRotate_rotatesAndReturnsFailureWithZeroTarget() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        OneTimeSignerAccount.Operation memory operation = _operation({
            target_: address(0),
            value_: 0,
            data_: "",
            nextAuthorizedSigner_: A3
        });

        bytes memory signature = _signOperation(A1, A2_PK, operation);

        vm.prank(relayer);
        (bool success, bytes memory result) = _account(A1).executeSignedAndRotate(operation, signature);

        assertFalse(success, "zero target operation should be reported as failed");
        assertEq(
            result,
            abi.encodeWithSelector(OneTimeSignerAccount.InvalidTarget.selector),
            "result should contain the encoded InvalidTarget error"
        );

        assertEq(_account(A1).currentAuthorizedSigner(), A3, "authorized signer should rotate even if target is zero");
        assertFalse(_account(A1).isPaused(), "invalid target should not pause after successful rotation");
        assertEq(target.number(), 0, "target should not be called");
    }

    function test_executeSignedAndRotate_rejectsSignatureBoundToAnotherDelegatedAccount() public {
        _delegateAndInitialize(A1, A1_PK, A2);
        _delegateAndInitialize(otherAccount, OTHER_ACCOUNT_PK, A2);

        OneTimeSignerAccount.Operation memory operation = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.setNumber, (42)),
            nextAuthorizedSigner_: A3
        });

        // Same operation and same signer, but the digest is bound to `otherAccount` as verifyingContract.
        bytes memory signatureForOtherAccount = _signOperation(otherAccount, A2_PK, operation);

        address recoveredAgainstA1 = _account(A1).hashOperation(operation).recover(signatureForOtherAccount);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(OneTimeSignerAccount.InvalidSignature.selector, recoveredAgainstA1, A2)
        );
        _account(A1).executeSignedAndRotate(operation, signatureForOtherAccount);

        assertEq(_account(A1).currentAuthorizedSigner(), A2, "A1 authorized signer should remain A2");
        assertEq(_account(otherAccount).currentAuthorizedSigner(), A2, "other account authorized signer should remain A2");
        assertEq(target.number(), 0, "target should not be called");
    }

    // -------------------------------------------------------------------------
    // Paused-state restrictions
    // -------------------------------------------------------------------------

    function test_pausedAccount_revertsNormalSignedExecution() public {
        _pauseAccountWithSignedInvalidNextSigner();

        OneTimeSignerAccount.Operation memory operation = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.setNumber, (42)),
            nextAuthorizedSigner_: A3
        });

        bytes memory signature = _signOperation(A1, A2_PK, operation);

        vm.prank(relayer);
        vm.expectRevert(OneTimeSignerAccount.AccountIsPaused.selector);
        _account(A1).executeSignedAndRotate(operation, signature);

        assertEq(target.number(), 0, "target should not be called while paused");
    }

    function test_pausedAccount_revertsDirectAuthorizedRotation() public {
        _pauseAccountWithSignedInvalidNextSigner();

        vm.prank(A2);
        vm.expectRevert(OneTimeSignerAccount.AccountIsPaused.selector);
        _account(A1).rotateAuthorizedSigner(A3);
    }

    function test_pausedAccount_canStillReceiveEth() public {
        _pauseAccountWithSignedInvalidNextSigner();

        vm.deal(relayer, 1 ether);

        vm.prank(relayer);
        (bool sent,) = A1.call{value: 0.25 ether}("");

        assertTrue(sent, "paused delegated account should still receive ETH");
        assertEq(A1.balance, 0.25 ether, "account balance should increase");
        assertTrue(_account(A1).isPaused(), "receiving ETH should not unpause the account");
    }

    // -------------------------------------------------------------------------
    // Direct recovery
    // -------------------------------------------------------------------------

    function test_rotateAuthorizedSignerThroughRecovery_unpausesPausedAccountAndRotatesRecoverySigner() public {
        _pauseAccountWithSignedInvalidNextSigner();

        vm.expectEmit(true, true, false, true, A1);
        emit RecoverySignerConsumed(A1, R1);
        vm.expectEmit(true, true, true, true, A1);
        emit AccountUnpaused(A1, R1, A3);
        vm.expectEmit(true, true, true, true, A1);
        emit RecoverySignerRotated(A1, R1, R3);

        vm.prank(R1);
        (bool success, bytes memory result) = _account(A1).rotateAuthorizedSignerThroughRecovery(A3, R3);

        assertTrue(success, "recovery rotation should succeed");
        assertEq(result.length, 0, "successful recovery should return empty result");
        assertFalse(_account(A1).isPaused(), "account should be unpaused");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "A3 should become authorized signer");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed");
        assertTrue(_account(A1).isConsumedOrReservedSigner(R1), "R1 should remain reserved after consumption");
        assertTrue(_account(A1).isActiveRecoverySigner(R2), "R2 should remain active");
        assertTrue(_account(A1).isActiveRecoverySigner(R3), "R3 should become active recovery signer");
        assertTrue(_account(A1).isConsumedOrReservedSigner(A3), "A3 should be marked used");
        assertTrue(_account(A1).isConsumedOrReservedSigner(R3), "R3 should be marked used/reserved");
    }

    function test_rotateAuthorizedSignerThroughRecovery_canRotateEvenWhenNotPaused() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        vm.prank(R1);
        (bool success,) = _account(A1).rotateAuthorizedSignerThroughRecovery(A3, R3);

        assertTrue(success, "direct recovery rotation should succeed");
        assertFalse(_account(A1).isPaused(), "account should remain unpaused");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "A3 should become authorized signer");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed");
    }

    function test_rotateAuthorizedSignerThroughRecovery_revertsWhenCallerIsNotActiveRecoverySigner() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.RecoverySignerNotActive.selector, attacker));
        _account(A1).rotateAuthorizedSignerThroughRecovery(A3, R3);
    }

    function test_rotateAuthorizedSignerThroughRecovery_consumesRecoverySignerEvenWhenNextSignerIsInvalid() public {
        _pauseAccountWithSignedInvalidNextSigner();

        vm.prank(R1);
        (bool success, bytes memory result) = _account(A1).rotateAuthorizedSignerThroughRecovery(address(0), R3);

        assertFalse(success, "invalid recovery rotation should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.InvalidNextAuthorizedSigner.selector));
        assertTrue(_account(A1).isPaused(), "account should remain paused");
        assertEq(_account(A1).currentAuthorizedSigner(), A2, "authorized signer should remain A2");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed even on invalid next signer");
    }

    function test_rotateAuthorizedSignerThroughRecovery_cannotReuseConsumedRecoverySigner() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        vm.prank(R1);
        _account(A1).rotateAuthorizedSignerThroughRecovery(A3, R3);

        vm.prank(R1);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.RecoverySignerNotActive.selector, R1));
        _account(A1).rotateAuthorizedSignerThroughRecovery(A4, R4);

        assertEq(_account(A1).currentAuthorizedSigner(), A3, "old recovery signer should not recover control");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should remain inactive");
        assertTrue(_account(A1).isActiveRecoverySigner(R3), "R3 should remain the renewed recovery signer");
    }

    function test_rotateAuthorizedSignerThroughRecovery_consumesRecoverySignerWhenNextRecoverySignerIsZero() public {
        _pauseAccountWithSignedInvalidNextSigner();

        vm.prank(R1);
        (bool success, bytes memory result) = _account(A1).rotateAuthorizedSignerThroughRecovery(A3, address(0));

        assertFalse(success, "zero next recovery signer should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.InvalidNewRecoverySigner.selector));
        assertFalse(_account(A1).isPaused(), "account should be unpaused");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "authorized signer should rotate");
        assertTrue(_account(A1).isConsumedOrReservedSigner(A3), "A3 should be reserved after failed recovery");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed");
        assertFalse(_account(A1).isActiveRecoverySigner(address(0)), "zero address must not become active recovery signer");
    }

    function test_rotateAuthorizedSignerThroughRecovery_rejectsUsedNextRecoverySignerAndConsumesRecoverySigner() public {
        _pauseAccountWithSignedInvalidNextSigner();

        vm.prank(R1);
        (bool success, bytes memory result) = _account(A1).rotateAuthorizedSignerThroughRecovery(A3, R2);

        assertFalse(success, "used next recovery signer should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.SignerAlreadyConsumedOrReserved.selector, R2));
        assertFalse(_account(A1).isPaused(), "account should be unpaused");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "authorized signer should rotate");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed");
        assertTrue(_account(A1).isActiveRecoverySigner(R2), "R2 should remain active but not be re-registered");
    }

    function test_rotateAuthorizedSignerThroughRecovery_rejectsSameAuthorizedAndRecoverySignerAndConsumesRecoverySigner() public {
        _pauseAccountWithSignedInvalidNextSigner();

        vm.prank(R1);
        (bool success, bytes memory result) = _account(A1).rotateAuthorizedSignerThroughRecovery(A3, A3);

        assertFalse(success, "same authorized and recovery signer should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.SignerAlreadyConsumedOrReserved.selector, A3));
        assertFalse(_account(A1).isPaused(), "account should be unpaused");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "authorized signer should rotate");
        assertTrue(_account(A1).isConsumedOrReservedSigner(A3), "A3 should be reserved after failed recovery");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed");
        assertFalse(_account(A1).isActiveRecoverySigner(A3), "A3 should not become a recovery signer");
    }

    function test_rotateAuthorizedSignerThroughRecovery_newRecoverySignerCanRecoverAgain() public {
        _pauseAccountWithSignedInvalidNextSigner();

        vm.prank(R1);
        (bool firstSuccess,) = _account(A1).rotateAuthorizedSignerThroughRecovery(A3, R3);

        assertTrue(firstSuccess, "first recovery should succeed");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "first recovery should install A3");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed");
        assertTrue(_account(A1).isActiveRecoverySigner(R3), "R3 should become active");

        vm.prank(R3);
        (bool secondSuccess, bytes memory secondResult) = _account(A1).rotateAuthorizedSignerThroughRecovery(A4, R4);

        assertTrue(secondSuccess, "new recovery signer should be able to recover again");
        assertEq(secondResult.length, 0, "successful second recovery should return empty result");
        assertFalse(_account(A1).isPaused(), "account should remain unpaused");
        assertEq(_account(A1).currentAuthorizedSigner(), A4, "second recovery should install A4");
        assertFalse(_account(A1).isActiveRecoverySigner(R3), "R3 should be consumed by the second recovery");
        assertTrue(_account(A1).isActiveRecoverySigner(R4), "R4 should become the renewed recovery signer");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should remain inactive");
    }

    // -------------------------------------------------------------------------
    // Signed recovery
    // -------------------------------------------------------------------------

    function test_signedRecovery_unpausesPausedAccountAndRotatesRecoverySigner() public {
        _pauseAccountWithSignedInvalidNextSigner();

        OneTimeSignerAccount.RecoveryOperation memory recoveryOperation = _recoveryOperation(A3, R3);
        bytes memory signature = _signRecoveryOperation(A1, R1_PK, recoveryOperation);

        vm.prank(relayer);
        (bool success, bytes memory result) = _account(A1).signedRecovery(recoveryOperation, signature);

        assertTrue(success, "signed recovery should succeed");
        assertEq(result.length, 0, "successful recovery should return empty result");
        assertFalse(_account(A1).isPaused(), "account should be unpaused");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "A3 should become authorized signer");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed");
        assertTrue(_account(A1).isConsumedOrReservedSigner(R1), "R1 should remain reserved after consumption");
        assertTrue(_account(A1).isActiveRecoverySigner(R2), "R2 should remain active");
        assertTrue(_account(A1).isActiveRecoverySigner(R3), "R3 should become active recovery signer");
        assertTrue(_account(A1).isConsumedOrReservedSigner(A3), "A3 should be marked used");
        assertTrue(_account(A1).isConsumedOrReservedSigner(R3), "R3 should be marked used/reserved");
    }

    function test_signedRecovery_canRotateEvenWhenNotPaused() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        OneTimeSignerAccount.RecoveryOperation memory recoveryOperation = _recoveryOperation(A3);
        bytes memory signature = _signRecoveryOperation(A1, R1_PK, recoveryOperation);

        vm.prank(relayer);
        (bool success,) = _account(A1).signedRecovery(recoveryOperation, signature);

        assertTrue(success, "signed recovery should succeed");
        assertFalse(_account(A1).isPaused(), "account should remain unpaused");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "A3 should become authorized signer");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed");
    }

    function test_signedRecovery_revertsWhenSignatureIsNotFromActiveRecoverySigner() public {
        _delegateAndInitialize(A1, A1_PK, A2);

        OneTimeSignerAccount.RecoveryOperation memory recoveryOperation = _recoveryOperation(A3);
        bytes memory signature = _signRecoveryOperation(A1, ATTACKER_PK, recoveryOperation);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.RecoverySignerNotActive.selector, attacker));
        _account(A1).signedRecovery(recoveryOperation, signature);

        assertEq(_account(A1).currentAuthorizedSigner(), A2, "authorized signer should remain A2");
        assertTrue(_account(A1).isActiveRecoverySigner(R1), "R1 should remain active");
    }

    function test_signedRecovery_consumesRecoverySignerWhenOperationExpired() public {
        _pauseAccountWithSignedInvalidNextSigner();
        vm.warp(1_000_000);

        OneTimeSignerAccount.RecoveryOperation memory recoveryOperation = OneTimeSignerAccount.RecoveryOperation({
            nextAuthorizedSigner: A3,
            nextRecoverySigner: R3,
            deadline: block.timestamp - 1
        });

        bytes memory signature = _signRecoveryOperation(A1, R1_PK, recoveryOperation);

        vm.prank(relayer);
        (bool success, bytes memory result) = _account(A1).signedRecovery(recoveryOperation, signature);

        assertFalse(success, "expired recovery should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.ExpiredOperation.selector, recoveryOperation.deadline));
        assertTrue(_account(A1).isPaused(), "account should remain paused");
        assertEq(_account(A1).currentAuthorizedSigner(), A2, "authorized signer should remain A2");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed after exposing its signature");
        assertFalse(_account(A1).isActiveRecoverySigner(R3), "R3 should not be registered for expired recovery");
    }

    function test_signedRecovery_consumesRecoverySignerEvenWhenNextSignerIsInvalid() public {
        _pauseAccountWithSignedInvalidNextSigner();

        OneTimeSignerAccount.RecoveryOperation memory recoveryOperation = _recoveryOperation(address(0));
        bytes memory signature = _signRecoveryOperation(A1, R1_PK, recoveryOperation);

        vm.prank(relayer);
        (bool success, bytes memory result) = _account(A1).signedRecovery(recoveryOperation, signature);

        assertFalse(success, "invalid recovery should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.InvalidNextAuthorizedSigner.selector));
        assertTrue(_account(A1).isPaused(), "account should remain paused");
        assertEq(_account(A1).currentAuthorizedSigner(), A2, "authorized signer should remain A2");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed after exposing its signature");
        assertFalse(_account(A1).isActiveRecoverySigner(R3), "R3 should not be registered when authorized signer is invalid");
    }

    function test_signedRecovery_consumesRecoverySignerWhenNextRecoverySignerIsZero() public {
        _pauseAccountWithSignedInvalidNextSigner();

        OneTimeSignerAccount.RecoveryOperation memory recoveryOperation = _recoveryOperation(A3, address(0));
        bytes memory signature = _signRecoveryOperation(A1, R1_PK, recoveryOperation);

        vm.prank(relayer);
        (bool success, bytes memory result) = _account(A1).signedRecovery(recoveryOperation, signature);

        assertFalse(success, "zero next recovery signer should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.InvalidNewRecoverySigner.selector));
        assertFalse(_account(A1).isPaused(), "account should be unpaused");
        assertEq(_account(A1).currentAuthorizedSigner(), A3, "authorized signer should rotate");
        assertTrue(_account(A1).isConsumedOrReservedSigner(A3), "A3 should be reserved after failed recovery");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed after exposing its signature");
        assertFalse(_account(A1).isActiveRecoverySigner(address(0)), "zero address must not become active recovery signer");
    }

    function test_signedRecovery_rejectsUsedNextAuthorizedSignerAndConsumesRecoverySigner() public {
        _pauseAccountWithSignedInvalidNextSigner();

        OneTimeSignerAccount.RecoveryOperation memory recoveryOperation = _recoveryOperation(A2, R3);
        bytes memory signature = _signRecoveryOperation(A1, R1_PK, recoveryOperation);

        vm.prank(relayer);
        (bool success, bytes memory result) = _account(A1).signedRecovery(recoveryOperation, signature);

        assertFalse(success, "used next authorized signer should be reported as failed");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.SignerAlreadyConsumedOrReserved.selector, A2));
        assertTrue(_account(A1).isPaused(), "account should remain paused");
        assertEq(_account(A1).currentAuthorizedSigner(), A2, "authorized signer should not rotate");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should be consumed after exposing its signature");
        assertFalse(_account(A1).isActiveRecoverySigner(R3), "R3 should not be registered after failed recovery");
    }

    function test_signedRecovery_replayFailsBecauseRecoverySignerWasConsumed() public {
        _pauseAccountWithSignedInvalidNextSigner();

        OneTimeSignerAccount.RecoveryOperation memory recoveryOperation = _recoveryOperation(A3, R3);
        bytes memory signature = _signRecoveryOperation(A1, R1_PK, recoveryOperation);

        vm.prank(relayer);
        (bool success,) = _account(A1).signedRecovery(recoveryOperation, signature);
        assertTrue(success, "first signed recovery should succeed");

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(OneTimeSignerAccount.RecoverySignerNotActive.selector, R1));
        _account(A1).signedRecovery(recoveryOperation, signature);

        assertEq(_account(A1).currentAuthorizedSigner(), A3, "replay should not modify authorized signer");
        assertFalse(_account(A1).isActiveRecoverySigner(R1), "R1 should remain inactive");
        assertTrue(_account(A1).isActiveRecoverySigner(R3), "R3 should remain active recovery signer");
    }

    function test_signedRecovery_rejectsSignatureBoundToAnotherDelegatedAccount() public {
        _delegateAndInitialize(A1, A1_PK, A2);
        _delegateAndInitialize(otherAccount, OTHER_ACCOUNT_PK, A2);

        OneTimeSignerAccount.RecoveryOperation memory recoveryOperation = _recoveryOperation(A3);
        bytes memory signatureForOtherAccount = _signRecoveryOperation(otherAccount, R1_PK, recoveryOperation);

        address recoveredAgainstA1 = _account(A1).hashRecoveryOperation(recoveryOperation).recover(signatureForOtherAccount);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(OneTimeSignerAccount.RecoverySignerNotActive.selector, recoveredAgainstA1)
        );
        _account(A1).signedRecovery(recoveryOperation, signatureForOtherAccount);

        assertEq(_account(A1).currentAuthorizedSigner(), A2, "A1 authorized signer should remain A2");
        assertEq(_account(otherAccount).currentAuthorizedSigner(), A2, "other account authorized signer should remain A2");
        assertTrue(_account(A1).isActiveRecoverySigner(R1), "A1 R1 should remain active");
        assertTrue(_account(otherAccount).isActiveRecoverySigner(R1), "other account R1 should remain active");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _delegate(uint256 accountPrivateKey) internal {
        vm.signAndAttachDelegation(address(implementation), accountPrivateKey);
    }

    function _delegateAndInitialize(
        address payable accountAddress,
        uint256 accountPrivateKey,
        address firstAuthorizedSigner
    )
        internal
    {
        _delegateAndInitialize(accountAddress, accountPrivateKey, firstAuthorizedSigner, _defaultRecoverySigners());
    }

    function _delegateAndInitialize(
        address payable accountAddress,
        uint256 accountPrivateKey,
        address firstAuthorizedSigner,
        address[] memory recoverySigners
    )
        internal
    {
        assertEq(accountAddress.code.length, 0, "account should start as a plain EOA");

        _delegate(accountPrivateKey);

        vm.prank(accountAddress);
        _account(accountAddress).initialize(firstAuthorizedSigner, recoverySigners);
    }

    function _pauseAccountWithSignedInvalidNextSigner() internal {
        _delegateAndInitialize(A1, A1_PK, A2);

        OneTimeSignerAccount.Operation memory operation = _operation({
            target_: address(target),
            value_: 0,
            data_: abi.encodeCall(ExecutionTarget.setNumber, (42)),
            nextAuthorizedSigner_: address(0)
        });

        bytes memory signature = _signOperation(A1, A2_PK, operation);

        vm.prank(relayer);
        (bool success, bytes memory result) = _account(A1).executeSignedAndRotate(operation, signature);

        assertFalse(success, "pause helper should fail the rotation");
        assertEq(result, abi.encodeWithSelector(OneTimeSignerAccount.InvalidNextAuthorizedSigner.selector));
        assertTrue(_account(A1).isPaused(), "pause helper should leave account paused");
        assertEq(_account(A1).currentAuthorizedSigner(), A2, "pause helper should leave authorized signer unchanged");
    }

    function _signOperation(
        address payable accountAddress,
        uint256 signerPrivateKey,
        OneTimeSignerAccount.Operation memory operation
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _account(accountAddress).hashOperation(operation);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);

        return bytes.concat(r, s, bytes1(v));
    }

    function _signRecoveryOperation(
        address payable accountAddress,
        uint256 signerPrivateKey,
        OneTimeSignerAccount.RecoveryOperation memory recoveryOperation
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _account(accountAddress).hashRecoveryOperation(recoveryOperation);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);

        return bytes.concat(r, s, bytes1(v));
    }

    function _operation(
        address target_,
        uint256 value_,
        bytes memory data_,
        address nextAuthorizedSigner_
    )
        internal
        view
        returns (OneTimeSignerAccount.Operation memory)
    {
        return OneTimeSignerAccount.Operation({
            target: target_,
            value: value_,
            data: data_,
            nextAuthorizedSigner: nextAuthorizedSigner_,
            deadline: block.timestamp + 1 days
        });
    }

    function _recoveryOperation(address nextAuthorizedSigner)
        internal
        view
        returns (OneTimeSignerAccount.RecoveryOperation memory)
    {
        return _recoveryOperation(nextAuthorizedSigner, R3);
    }

    function _recoveryOperation(address nextAuthorizedSigner, address nextRecoverySigner)
        internal
        view
        returns (OneTimeSignerAccount.RecoveryOperation memory)
    {
        return OneTimeSignerAccount.RecoveryOperation({
            nextAuthorizedSigner: nextAuthorizedSigner,
            nextRecoverySigner: nextRecoverySigner,
            deadline: block.timestamp + 1 days
        });
    }

    function _defaultRecoverySigners() internal view returns (address[] memory recoverySigners) {
        recoverySigners = new address[](2);
        recoverySigners[0] = R1;
        recoverySigners[1] = R2;
    }

    function _account(address payable accountAddress) internal pure returns (OneTimeSignerAccount) {
        return OneTimeSignerAccount(accountAddress);
    }

    function _expectedDelegationCode() internal view returns (bytes memory) {
        return bytes.concat(hex"ef0100", bytes20(address(implementation)));
    }
}
