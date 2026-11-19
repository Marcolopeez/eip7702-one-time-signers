// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {OneTimeSignerAccountC1, OneTimeSignerAccountC1 as OTSC1} from "../src/OneTimeSignerAccountC1.sol";
import {OTSProxyC1} from "../src/OTSProxyC1.sol";
import {MockSetSelfDelegateHelper} from "./mocks/MockSetSelfDelegateHelper.sol";
import {Witness, NotAnImplementation, WrongUUID, GasBurner} from "./mocks/C1Mocks.sol";

/// @notice H3 (besu/PLAN.md §10): logic of OTS-C1 in Foundry. revm does not execute 0xac nor 0xef0101, so:
///         - SETSELFDELEGATE is a mock helper that records the call and returns 1 (or 0);
///         - the retired state `0xef0101 || P` is emulated with `vm.etch(a, 0xef0100 || P)`: Besu executes both
///           prefixes identically (#90-#92). What only `0xef0101` adds (ECDSA of `h` rejected, authorizations
///           skipped) is tested in Besu (H2, #94-#97), not here.
contract OneTimeSignerAccountC1Test is Test {
    uint256 internal constant H_PK = 0xA11CE;
    uint256 internal constant S1_PK = 0xB0B;
    uint256 internal constant S2_PK = 0xCAFE;
    uint256 internal constant S3_PK = 0xD00D;
    uint256 internal constant M1_PK = 0xAABB;
    uint256 internal constant M2_PK = 0xCCDD;
    uint256 internal constant M3_PK = 0xDDCC;
    uint256 internal constant M4_PK = 0xEEFF;
    uint256 internal constant ATTACKER_PK = 0xBAD;
    uint256 internal constant RELAYER_PK = 0x1234;

    bytes32 internal constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address payable internal A;
    address internal S1;
    address internal S2;
    address internal S3;
    address internal M1;
    address internal M2;
    address internal M3;
    address internal M4;
    address internal attacker;
    address internal relayer;

    OTSProxyC1 internal proxy;
    MockSetSelfDelegateHelper internal helper;
    MockSetSelfDelegateHelper internal helperReturnsZero;
    OTSC1 internal impl;
    OTSC1 internal implWithFailingHelper;
    OTSC1 internal impl2;
    Witness internal witness;

    event SetSelfDelegateCalled(address indexed context, address indexed delegate);

    function setUp() public {
        A = payable(vm.addr(H_PK));
        S1 = vm.addr(S1_PK);
        S2 = vm.addr(S2_PK);
        S3 = vm.addr(S3_PK);
        M1 = vm.addr(M1_PK);
        M2 = vm.addr(M2_PK);
        M3 = vm.addr(M3_PK);
        M4 = vm.addr(M4_PK);
        attacker = vm.addr(ATTACKER_PK);
        relayer = vm.addr(RELAYER_PK);

        proxy = new OTSProxyC1();
        helper = new MockSetSelfDelegateHelper(1);
        helperReturnsZero = new MockSetSelfDelegateHelper(0);
        impl = new OTSC1(address(proxy), address(helper));
        implWithFailingHelper = new OTSC1(address(proxy), address(helperReturnsZero));
        impl2 = new OTSC1(address(proxy), address(helper));
        witness = new Witness();
        vm.deal(A, 10 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _acct() internal view returns (OTSC1) {
        return OTSC1(A);
    }

    function _management() internal view returns (address[] memory m) {
        m = new address[](2);
        m[0] = M1;
        m[1] = M2;
    }

    /// V1 (ESPECIFICACION §2.2): tipo 4 de h hacia `d` + initializeAndRetire, desde a.
    function _v1(OTSC1 d) internal {
        vm.signAndAttachDelegation(address(d), H_PK);
        vm.prank(A);
        OTSC1(A).initializeAndRetire(S1, _management());
    }

    /// V2, T1: migración del TFM (initialize, sin retirar).
    function _v2Migrate() internal {
        vm.signAndAttachDelegation(address(impl), H_PK);
        vm.prank(A);
        OTSC1(A).initialize(S1, _management());
    }

    /// Emula `ind(a) = 0xef0101 || P` (ver la nota del contrato).
    function _emulateRetired() internal {
        vm.etch(A, abi.encodePacked(hex"ef0100", address(proxy)));
    }

    function _slot() internal view returns (address) {
        return address(uint160(uint256(vm.load(A, SLOT))));
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _op(address target, bytes memory data, address next) internal view returns (OTSC1.Operation memory) {
        return OTSC1.Operation({target: target, value: 0, data: data, nextAuthorizedSigner: next, deadline: block.timestamp + 1 hours});
    }

    function _exec(OTSC1.Operation memory op, uint256 pk) internal returns (bool ok, bytes memory res) {
        bytes memory sig = _sig(pk, _acct().hashOperation(op));
        vm.prank(relayer);
        return _acct().executeSignedAndRotate(op, sig);
    }

    function _redel(address newImpl, address nextM) internal view returns (OTSC1.Redelegation memory) {
        return OTSC1.Redelegation({newImplementation: newImpl, nextManagementSigner: nextM, deadline: block.timestamp + 1 hours});
    }

    function _redelegate(OTSC1.Redelegation memory r, uint256 pk) internal returns (bool ok, bytes memory res) {
        bytes memory sig = _sig(pk, _acct().hashRedelegation(r));
        vm.prank(relayer);
        return _acct().redelegate(r, sig);
    }

    function _recover(address nextAuth, address nextM, uint256 pk) internal returns (bool ok, bytes memory res) {
        OTSC1.RecoveryOperation memory r = OTSC1.RecoveryOperation({
            nextAuthorizedSigner: nextAuth, nextManagementSigner: nextM, deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _sig(pk, _acct().hashRecoveryOperation(r));
        vm.prank(relayer);
        return _acct().signedRecovery(r, sig);
    }

    function _activeCount(address[] memory ms) internal view returns (uint256 n) {
        for (uint256 i; i < ms.length; ++i) {
            if (_acct().isActiveManagementSigner(ms[i])) ++n;
        }
    }

    // ------------------------------------------------------------------ V1 and V2 (D-26)

    function test_V1_initializeAndRetire_setsStateAndCallsHelperWithProxy() public {
        vm.expectEmit(true, true, false, false, A);
        emit SetSelfDelegateCalled(A, address(proxy));
        _v1(impl);

        assertTrue(_acct().isInitialized());
        assertEq(_acct().currentAuthorizedSigner(), S1);
        assertTrue(_acct().isActiveManagementSigner(M1));
        assertTrue(_acct().isActiveManagementSigner(M2));
        assertEq(_slot(), address(impl), "slot = d");
        assertEq(_acct().implementation(), address(impl));
        assertEq(_acct().managementEpoch(), 0);
    }

    function test_V1_revertsIfSetSelfDelegateReturnsZero() public {
        vm.signAndAttachDelegation(address(implWithFailingHelper), H_PK);
        vm.prank(A);
        vm.expectRevert(OTSC1.RetirementFailed.selector);
        OTSC1(A).initializeAndRetire(S1, _management());

        assertEq(vm.load(A, bytes32(0)), bytes32(0), "nothing initialized");
        assertEq(_slot(), address(0), "slot empty");
    }

    function test_V1_onlyTheAccountCanInitialize() public {
        vm.signAndAttachDelegation(address(impl), H_PK);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OTSC1.UnauthorizedInitializer.selector, attacker, A));
        OTSC1(A).initializeAndRetire(S1, _management());
    }

    function test_V2_retireBySelf_onceOnly() public {
        _v2Migrate();
        assertEq(_slot(), address(0));

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(OTSC1.UnauthorizedRetirement.selector, relayer));
        _acct().retire();

        vm.expectEmit(true, true, false, false, A);
        emit SetSelfDelegateCalled(A, address(proxy));
        vm.prank(A);
        _acct().retire();
        assertEq(_slot(), address(impl));

        vm.prank(A);
        vm.expectRevert(OTSC1.AlreadyRetired.selector);
        _acct().retire();
    }

    function test_V2_retireThroughOperation_T2b() public {
        _v2Migrate();
        (bool ok,) = _exec(_op(A, abi.encodeCall(OTSC1.retire, ()), S2), S1_PK);
        assertTrue(ok, "T2b: the operation retires the account");
        assertEq(_slot(), address(impl));
        assertEq(_acct().currentAuthorizedSigner(), S2);
    }

    // ------------------------------------------------------------------ after retirement

    function test_afterRetirement_operationsRunThroughTheProxy() public {
        _v1(impl);
        _emulateRetired();
        (bool ok,) = _exec(_op(address(witness), abi.encodeCall(Witness.ping, ()), S2), S1_PK);
        assertTrue(ok);
        assertEq(witness.lastCaller(), A);
        assertEq(_acct().currentAuthorizedSigner(), S2);
    }

    function test_afterRetirement_helperIsUnreachable() public {
        _v1(impl);
        _emulateRetired();

        vm.prank(A);
        vm.expectRevert(OTSC1.AlreadyRetired.selector);
        _acct().retire();

        vm.prank(A);
        vm.expectRevert(OTSC1.AlreadyInitialized.selector);
        _acct().initializeAndRetire(S3, new address[](0));

        // through an operation with target = a: the operation runs, the inner call fails, nothing changes
        vm.recordLogs();
        (bool ok,) = _exec(_op(A, abi.encodeCall(OTSC1.retire, ()), S2), S1_PK);
        assertFalse(ok);
        assertEq(_slot(), address(impl));
        assertEq(vm.getRecordedLogs().length, 2, "rotation + SignedOperationExecuted; no helper call");
    }

    function test_operationalSignerCannotRedelegate() public {
        _v1(impl);
        _emulateRetired();
        // the operational signer signs a redelegation to the attacker's choice and sends it as an operation
        OTSC1.Redelegation memory r = _redel(address(impl2), S3);
        bytes memory sigByS1 = _sig(S1_PK, _acct().hashRedelegation(r));
        (bool ok, bytes memory res) = _exec(_op(A, abi.encodeCall(OTSC1.redelegate, (r, sigByS1)), S2), S1_PK);
        assertFalse(ok);
        assertEq(res, abi.encodeWithSelector(OTSC1.ManagementSignerNotActive.selector, S1));
        assertEq(_slot(), address(impl), "slot unchanged");
    }

    // ------------------------------------------------------------------ redelegation (D-22, D-23, D-48, D-49)

    function test_redelegate_byManagementKey() public {
        _v1(impl);
        _emulateRetired();
        (bool ok,) = _redelegate(_redel(address(impl2), M3), M1_PK);
        assertTrue(ok);
        assertEq(_slot(), address(impl2));
        assertFalse(_acct().isActiveManagementSigner(M1), "consumed");
        assertTrue(_acct().isActiveManagementSigner(M3), "successor");
        assertTrue(_acct().isActiveManagementSigner(M2), "redelegation revokes nothing (D-35)");
        assertEq(_acct().managementEpoch(), 0);

        // the account keeps working with the new implementation
        (bool ok2,) = _exec(_op(address(witness), abi.encodeCall(Witness.ping, ()), S2), S1_PK);
        assertTrue(ok2);
    }

    function _assertIncompatible(address candidate) internal {
        _v1(impl);
        _emulateRetired();
        (bool ok, bytes memory res) = _redelegate(_redel(candidate, M3), M1_PK);
        assertFalse(ok);
        assertEq(res, abi.encodeWithSelector(OTSC1.IncompatibleImplementation.selector, candidate));
        assertEq(_slot(), address(impl), "slot unchanged");
        assertFalse(_acct().isActiveManagementSigner(M1), "key consumed (D-49 ii)");
        assertTrue(_acct().isActiveManagementSigner(M3), "successor installed (D-49 ii)");
    }

    function test_redelegate_incompatible_noCode() public {
        _assertIncompatible(address(0xdead));
    }

    function test_redelegate_incompatible_noProxiableUUID() public {
        _assertIncompatible(address(new NotAnImplementation()));
    }

    function test_redelegate_incompatible_wrongUUID() public {
        _assertIncompatible(address(new WrongUUID()));
    }

    function test_redelegate_incompatible_gasBurner() public {
        _assertIncompatible(address(new GasBurner()));
    }

    function test_redelegate_incompatible_theProxyItself() public {
        _assertIncompatible(address(proxy));
    }

    function test_redelegate_expired_consumesKeyAndInstallsSuccessor() public {
        _v1(impl);
        _emulateRetired();
        OTSC1.Redelegation memory r = _redel(address(impl2), M3);
        bytes memory sig = _sig(M1_PK, _acct().hashRedelegation(r));
        vm.warp(r.deadline + 1);
        vm.prank(relayer);
        (bool ok, bytes memory res) = _acct().redelegate(r, sig);
        assertFalse(ok);
        assertEq(res, abi.encodeWithSelector(OTSC1.ExpiredOperation.selector, r.deadline));
        assertEq(_slot(), address(impl));
        assertFalse(_acct().isActiveManagementSigner(M1));
        assertTrue(_acct().isActiveManagementSigner(M3));
    }

    /// D-52 (c): an invalid successor means the code change does not apply (it applied in 6508e6eb, D-50).
    function test_redelegate_invalidSuccessor_notApplied() public {
        _v1(impl);
        _emulateRetired();
        vm.recordLogs();
        (bool ok, bytes memory res) = _redelegate(_redel(address(impl2), S1), M1_PK);
        assertFalse(ok);
        assertEq(res, abi.encodeWithSelector(OTSC1.SignerAlreadyConsumedOrReserved.selector, S1));
        assertEq(_slot(), address(impl), "redelegation not applied (I3)");
        assertFalse(_acct().isActiveManagementSigner(M1));
        assertTrue(_acct().isActiveManagementSigner(M2));
        assertEq(_countTopic(vm.getRecordedLogs(), OTSC1.Redelegated.selector), 0, "no Redelegated event");
    }

    /// D-52 (f1): before retirement a redelegation no longer reverts before the signature; it consumes the key,
    /// installs the successor and fails with NotRetired. The same signature is useless afterwards.
    function test_redelegate_beforeRetirement_consumesAndFails() public {
        _v2Migrate();
        OTSC1.Redelegation memory r = _redel(address(impl2), M3);
        bytes memory sig = _sig(M1_PK, _acct().hashRedelegation(r));
        vm.prank(relayer);
        (bool ok, bytes memory res) = _acct().redelegate(r, sig);
        assertFalse(ok);
        assertEq(res, abi.encodeWithSelector(OTSC1.NotRetired.selector));
        assertFalse(_acct().isActiveManagementSigner(M1), "consumed");
        assertTrue(_acct().isActiveManagementSigner(M3), "successor installed");
        assertEq(_slot(), address(0));

        vm.prank(A);
        _acct().retire();
        vm.expectRevert(abi.encodeWithSelector(OTSC1.ManagementSignerNotActive.selector, M1));
        _acct().redelegate(r, sig);
    }

    function test_redelegate_attackerOrConsumedKey_reverts() public {
        _v1(impl);
        _emulateRetired();
        OTSC1.Redelegation memory r = _redel(address(impl2), M3);
        bytes memory sigAtt = _sig(ATTACKER_PK, _acct().hashRedelegation(r));
        vm.expectRevert(abi.encodeWithSelector(OTSC1.ManagementSignerNotActive.selector, attacker));
        _acct().redelegate(r, sigAtt);

        _redelegate(r, M1_PK);
        OTSC1.Redelegation memory r2 = _redel(address(impl), M4);
        bytes memory sigAgain = _sig(M1_PK, _acct().hashRedelegation(r2));
        vm.expectRevert(abi.encodeWithSelector(OTSC1.ManagementSignerNotActive.selector, M1));
        _acct().redelegate(r2, sigAgain);
    }

    // ------------------------------------------------------------------ recovery revokes the others (D-35)

    function test_recovery_revokesEveryOtherManagementKey() public {
        _v1(impl);
        _emulateRetired();
        (bool ok,) = _recover(S3, M3, M1_PK);
        assertTrue(ok);
        assertEq(_acct().currentAuthorizedSigner(), S3);
        assertEq(_acct().managementEpoch(), 1);
        assertFalse(_acct().isActiveManagementSigner(M2), "other key revoked");
        assertTrue(_acct().isActiveManagementSigner(M3));
        address[] memory all = new address[](3);
        all[0] = M1;
        all[1] = M2;
        all[2] = M3;
        assertEq(_activeCount(all), 1, "invariant: one active management key after a recovery that counts");

        // the revoked key (e.g. captured by the attacker earlier, #66) can no longer redelegate
        OTSC1.Redelegation memory r = _redel(address(impl2), M4);
        bytes memory sig = _sig(M2_PK, _acct().hashRedelegation(r));
        vm.expectRevert(abi.encodeWithSelector(OTSC1.ManagementSignerNotActive.selector, M2));
        _acct().redelegate(r, sig);
    }

    function test_recovery_failedDoesNotRevoke() public {
        _v1(impl);
        _emulateRetired();
        (bool ok, bytes memory res) = _recover(S1, M3, M1_PK); // S1 is already consumed/reserved
        assertFalse(ok);
        assertEq(res, abi.encodeWithSelector(OTSC1.SignerAlreadyConsumedOrReserved.selector, S1));
        assertEq(_acct().managementEpoch(), 0);
        assertFalse(_acct().isActiveManagementSigner(M1));
        assertTrue(_acct().isActiveManagementSigner(M2));
        // D-52 (b): the valid successor is installed although the recovery does not apply (I2, I3)
        assertTrue(_acct().isActiveManagementSigner(M3), "successor installed");
        assertEq(_acct().currentAuthorizedSigner(), S1);
        assertEq(_activeCount(_all()), 2);
    }

    // ------------------------------------------------------------------ management rule (D-52 to D-55)

    function _all() internal view returns (address[] memory m) {
        m = new address[](4);
        m[0] = M1;
        m[1] = M2;
        m[2] = M3;
        m[3] = M4;
    }

    function _one(address x) internal pure returns (address[] memory m) {
        m = new address[](1);
        m[0] = x;
    }

    function _two(address x, address y) internal pure returns (address[] memory m) {
        m = new address[](2);
        m[0] = x;
        m[1] = y;
    }

    function _none() internal pure returns (address[] memory m) {
        m = new address[](0);
    }

    function _assertState(
        address signer,
        bool paused,
        uint256 epoch,
        address slot,
        address[] memory active,
        address[] memory inactive
    ) internal view {
        assertEq(_acct().currentAuthorizedSigner(), signer, "signer");
        assertEq(_acct().isPaused(), paused, "pause");
        assertEq(_acct().managementEpoch(), epoch, "epoch");
        assertEq(_slot(), slot, "slot");
        for (uint256 i; i < active.length; ++i) {
            assertTrue(_acct().isActiveManagementSigner(active[i]), "expected active");
        }
        for (uint256 i; i < inactive.length; ++i) {
            assertFalse(_acct().isActiveManagementSigner(inactive[i]), "expected inactive");
        }
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) ++n;
        }
    }

    function _recoverAt(address nextAuth, address nextM, uint256 pk, uint256 deadline)
        internal
        returns (bool ok, bytes memory res)
    {
        OTSC1.RecoveryOperation memory r =
            OTSC1.RecoveryOperation({nextAuthorizedSigner: nextAuth, nextManagementSigner: nextM, deadline: deadline});
        bytes memory sig = _sig(pk, _acct().hashRecoveryOperation(r));
        vm.prank(relayer);
        return _acct().signedRecovery(r, sig);
    }

    /// P-1 (#109): a valid signer with an invalid successor applies nothing (D-52 A, I3).
    function test_recovery_invalidSuccessor_appliesNothing() public {
        _v1(impl);
        _emulateRetired();
        address[3] memory bad = [M2, address(0), S3];
        bytes[3] memory err = [
            abi.encodeWithSelector(OTSC1.SignerAlreadyConsumedOrReserved.selector, M2),
            abi.encodeWithSelector(OTSC1.InvalidNewManagementSigner.selector),
            abi.encodeWithSelector(OTSC1.SignerAlreadyConsumedOrReserved.selector, S3)
        ];
        for (uint256 k; k < 3; ++k) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory res) = _recover(S3, bad[k], M1_PK);
            assertFalse(ok);
            assertEq(res, err[k]);
            _assertState(S1, false, 0, address(impl), _one(M2), _one(M1));
            assertEq(_activeCount(_all()), 1);
            assertFalse(_acct().isConsumedOrReservedSigner(S3), "the operational signer is not burnt");
            vm.revertToState(snap);
        }
    }

    function test_directRecovery_invalidSuccessor_appliesNothing() public {
        _v1(impl);
        _emulateRetired();
        address[3] memory bad = [M2, address(0), S3];
        for (uint256 k; k < 3; ++k) {
            uint256 snap = vm.snapshotState();
            vm.prank(M1);
            (bool ok,) = _acct().rotateAuthorizedSignerThroughRecovery(S3, bad[k]);
            assertFalse(ok);
            _assertState(S1, false, 0, address(impl), _one(M2), _one(M1));
            assertEq(_activeCount(_all()), 1);
            vm.revertToState(snap);
        }
    }

    function test_recovery_expired_installsSuccessor() public {
        _v1(impl);
        _emulateRetired();
        uint256 dl = block.timestamp + 1 hours;
        vm.warp(dl + 1);
        (bool ok, bytes memory res) = _recoverAt(S3, M3, M1_PK, dl);
        assertFalse(ok);
        assertEq(res, abi.encodeWithSelector(OTSC1.ExpiredOperation.selector, dl));
        _assertState(S1, false, 0, address(impl), _two(M2, M3), _one(M1));
    }

    function test_recovery_expiredAndInvalidSuccessor_returnsExpired() public {
        _v1(impl);
        _emulateRetired();
        uint256 dl = block.timestamp + 1 hours;
        vm.warp(dl + 1);
        (bool ok, bytes memory res) = _recoverAt(S3, address(0), M1_PK, dl);
        assertFalse(ok);
        assertEq(res, abi.encodeWithSelector(OTSC1.ExpiredOperation.selector, dl), "action error first");
        _assertState(S1, false, 0, address(impl), _one(M2), _one(M1));
        assertEq(_activeCount(_all()), 1, "no successor registered");
    }

    function test_lastMu_invalidSigner_keepsChain() public {
        _v1(impl);
        _emulateRetired();
        (bool ok,) = _recover(S3, M3, M1_PK);
        assertTrue(ok);
        (ok,) = _recover(S1, M4, M3_PK);
        assertFalse(ok);
        _assertState(S3, false, 1, address(impl), _one(M4), _two(M3, M2));
        assertEq(_activeCount(_all()), 1);
    }

    function test_lastMu_expired_keepsChain() public {
        _v1(impl);
        _emulateRetired();
        _recover(S3, M3, M1_PK);
        uint256 dl = block.timestamp + 1 hours;
        vm.warp(dl + 1);
        (bool ok,) = _recoverAt(S2, M4, M3_PK, dl);
        assertFalse(ok);
        _assertState(S3, false, 1, address(impl), _one(M4), _one(M3));
        assertEq(_activeCount(_all()), 1);
    }

    /// Declared limit (D-54, #112): the last key names an invalid successor.
    function test_lastMu_redelegationInvalidSuccessor_notApplied() public {
        _v1(impl);
        _emulateRetired();
        _recover(S3, M3, M1_PK);
        (bool ok,) = _redelegate(_redel(address(impl2), S1), M3_PK);
        assertFalse(ok);
        _assertState(S3, false, 1, address(impl), _none(), _all());
        assertEq(_activeCount(_all()), 0, "declared limit (D-54)");
    }

    function test_lastMu_invalidSuccessor_losesChain_declaredLimit() public {
        _v1(impl);
        _emulateRetired();
        _recover(S3, M3, M1_PK);
        (bool ok, bytes memory res) = _recover(S2, M3, M3_PK);
        assertFalse(ok);
        assertEq(res, abi.encodeWithSelector(OTSC1.SignerAlreadyConsumedOrReserved.selector, M3));
        _assertState(S3, false, 1, address(impl), _none(), _all());
        assertEq(_activeCount(_all()), 0, "declared limit (D-54)");
    }

    /// Inverse of DIS_08: paused and with its last key, a failed recovery keeps the chain, so the account
    /// is not bricked.
    function test_paused_lastMu_invalidSigner_notBricked() public {
        _v1(impl);
        _emulateRetired();
        _recover(S3, M3, M1_PK);
        (bool ok,) = _exec(_op(address(witness), "", S1), S3_PK); // consumed successor -> pause
        assertFalse(ok);
        assertTrue(_acct().isPaused());
        (ok,) = _recover(S1, M4, M3_PK);
        assertFalse(ok);
        _assertState(S3, true, 1, address(impl), _one(M4), _one(M3));
        address m5 = vm.addr(0xF00D);
        (ok,) = _recover(S2, m5, M4_PK);
        assertTrue(ok, "the chain survived");
        _assertState(S2, false, 2, address(impl), _one(m5), _all());
    }

    function test_recovery_events() public {
        _v1(impl);
        _emulateRetired();
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        _recover(S3, M2, M1_PK); // P-1: not applied
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countTopic(logs, OTSC1.AccountUnpaused.selector), 0);
        assertEq(_countTopic(logs, OTSC1.ManagementEpochAdvanced.selector), 0);
        assertEq(_countTopic(logs, OTSC1.RecoveryOperationFailed.selector), 1);
        assertEq(_countTopic(logs, OTSC1.ManagementSignerConsumed.selector), 1);
        assertEq(_countTopic(logs, OTSC1.ManagementSignerRotated.selector), 0);
        vm.revertToState(snap);
        vm.recordLogs();
        _recover(S3, M3, M1_PK); // applied
        logs = vm.getRecordedLogs();
        assertEq(_countTopic(logs, OTSC1.AccountUnpaused.selector), 1);
        assertEq(_countTopic(logs, OTSC1.ManagementEpochAdvanced.selector), 1);
        assertEq(_countTopic(logs, OTSC1.RecoveryOperationFailed.selector), 0);
        assertEq(_countTopic(logs, OTSC1.ManagementSignerRotated.selector), 1);
    }

    /// D-55: at least one management key at initialization.
    function test_initialize_requiresManagementKey() public {
        address[] memory empty = new address[](0);
        vm.signAndAttachDelegation(address(impl), H_PK);
        vm.prank(A);
        vm.expectRevert(OTSC1.InvalidNewManagementSigner.selector);
        OTSC1(A).initializeAndRetire(S1, empty);

        vm.signAndAttachDelegation(address(impl), H_PK);
        vm.prank(A);
        vm.expectRevert(OTSC1.InvalidNewManagementSigner.selector);
        OTSC1(A).initialize(S1, empty);
    }

    /// Recovery 2x2x2 (expired, signer valid, successor valid) and redelegation 2x2x2 (expired, implementation
    /// compatible, successor valid). Checks the return value, its error priority and I1-I3 (D-53) in every cell.
    function test_managementRule_matrix() public {
        _v1(impl);
        _emulateRetired();
        NotAnImplementation bad = new NotAnImplementation();
        for (uint256 c; c < 8; ++c) {
            bool expired = c & 1 != 0;
            bool goodSigner = c & 2 != 0;
            bool goodSucc = c & 4 != 0;
            uint256 snap = vm.snapshotState();
            uint256 dl = block.timestamp + 1 hours;
            if (expired) vm.warp(dl + 1);
            uint256 before = _activeCount(_all());
            (bool ok, bytes memory res) = _recoverAt(goodSigner ? S3 : S1, goodSucc ? M3 : M2, M1_PK, dl);
            bool applies = !expired && goodSigner && goodSucc;
            assertEq(ok, applies, "recovery applies iff all valid");
            if (applies) {
                assertEq(_activeCount(_all()), 1, "I1");
                _assertState(S3, false, 1, address(impl), _one(M3), _two(M1, M2));
            } else {
                _assertState(S1, false, 0, address(impl), _none(), _one(M1)); // I3
                if (expired) assertEq(bytes4(res), OTSC1.ExpiredOperation.selector);
                else if (!goodSigner) assertEq(bytes4(res), OTSC1.SignerAlreadyConsumedOrReserved.selector);
                if (goodSucc) {
                    assertTrue(_acct().isActiveManagementSigner(M3));
                    assertEq(_activeCount(_all()), before, "I2: consumes one, registers one");
                } else {
                    assertEq(_activeCount(_all()), before - 1);
                }
            }
            vm.revertToState(snap);
        }
        for (uint256 c; c < 8; ++c) {
            bool expired = c & 1 != 0;
            bool goodImpl = c & 2 != 0;
            bool goodSucc = c & 4 != 0;
            uint256 snap = vm.snapshotState();
            OTSC1.Redelegation memory r = OTSC1.Redelegation({
                newImplementation: goodImpl ? address(impl2) : address(bad),
                nextManagementSigner: goodSucc ? M3 : M2,
                deadline: block.timestamp + 1 hours
            });
            bytes memory sig = _sig(M1_PK, _acct().hashRedelegation(r));
            if (expired) vm.warp(r.deadline + 1);
            uint256 before = _activeCount(_all());
            vm.prank(relayer);
            (bool ok, bytes memory res) = _acct().redelegate(r, sig);
            bool applies = !expired && goodImpl && goodSucc;
            assertEq(ok, applies, "redelegation applies iff all valid");
            assertEq(_slot(), applies ? address(impl2) : address(impl), "I3");
            assertEq(_acct().managementEpoch(), 0, "redelegation never advances the epoch");
            assertFalse(_acct().isActiveManagementSigner(M1));
            if (!applies) {
                if (expired) assertEq(bytes4(res), OTSC1.ExpiredOperation.selector);
                else if (!goodImpl) assertEq(bytes4(res), OTSC1.IncompatibleImplementation.selector);
                else assertEq(bytes4(res), OTSC1.SignerAlreadyConsumedOrReserved.selector);
            }
            assertEq(_activeCount(_all()), goodSucc ? before : before - 1, "I2");
            vm.revertToState(snap);
        }
    }

    /// Port of DIS_14: no gas band in which a compatible redelegation consumes the key without applying.
    function test_redelegate_noGasBand() public {
        _v1(impl);
        _emulateRetired();
        GasProbe probe = new GasProbe();
        OTSC1.Redelegation memory r = _redel(address(impl2), M3);
        bytes memory sig = _sig(M1_PK, _acct().hashRedelegation(r));
        bytes memory cd = abi.encodeCall(OTSC1.redelegate, (r, sig));
        uint256[4] memory n;
        for (uint256 g = 20_000; g <= 120_000; g += 10) {
            try probe.tryAt(A, cd, g, M1, address(impl2)) {}
            catch Error(string memory o) {
                n[uint8(bytes(o)[0]) - 48]++;
            }
        }
        emit log_named_uint("reverted", n[0]);
        emit log_named_uint("applied", n[1]);
        emit log_named_uint("consumed_without_effect", n[2]);
        assertGt(n[1], 0);
        assertEq(n[2], 0);
        assertEq(n[3], 0);
    }

    // ------------------------------------------------------------------ ERC-1822, proxy and deployment

    function test_proxiableUUID_onlyOnTheImplementation() public {
        assertEq(impl.proxiableUUID(), SLOT);
        _v1(impl);
        _emulateRetired();
        vm.expectRevert(OTSC1.MustNotBeCalledThroughDelegation.selector);
        _acct().proxiableUUID();
    }

    function test_proxy_revertsWithoutImplementation() public {
        address b = makeAddr("b");
        vm.etch(b, abi.encodePacked(hex"ef0100", address(proxy)));
        vm.expectRevert(OTSProxyC1.ImplementationNotSet.selector);
        OTSC1(payable(b)).isInitialized();
    }

    function test_implementationCannotBeUsedDirectly() public {
        vm.expectRevert(OTSC1.MustBeCalledThroughDelegation.selector);
        impl.initialize(S1, _management());
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(OTSC1.InvalidDeployment.selector);
        new OTSC1(address(0), address(helper));
        vm.expectRevert(OTSC1.InvalidDeployment.selector);
        new OTSC1(address(proxy), address(0));
    }

    function test_domainIsNotOTS() public view {
        assertTrue(impl.NAME_HASH() != keccak256("OneTimeSignerAccount"));
    }

    function test_receivesEthThroughTheProxy() public {
        _v1(impl);
        _emulateRetired();
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        (bool ok,) = A.call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(A.balance, 11 ether);
    }
}

/// @notice Calls with a given gas, classifies the outcome and reverts so that no state is kept (DIS_14).
contract GasProbe {
    function tryAt(address a, bytes calldata cd, uint256 g, address m, address newImpl) external {
        (bool ok,) = a.call{gas: g}(cd);
        uint256 outcome;
        if (!ok) outcome = 0;
        else if (OneTimeSignerAccountC1(payable(a)).implementation() == newImpl) outcome = 1;
        else if (!OneTimeSignerAccountC1(payable(a)).isActiveManagementSigner(m)) outcome = 2;
        else outcome = 3;
        revert(string(abi.encodePacked(bytes1(uint8(48 + outcome)))));
    }
}
