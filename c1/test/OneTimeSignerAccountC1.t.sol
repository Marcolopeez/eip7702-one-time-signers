// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {OneTimeSignerAccountC1 as OTSC1} from "../src/OneTimeSignerAccountC1.sol";
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

    function test_redelegate_invalidSuccessor_appliesAndReturnsFalse() public {
        _v1(impl);
        _emulateRetired();
        (bool ok, bytes memory res) = _redelegate(_redel(address(impl2), S1), M1_PK);
        assertFalse(ok);
        assertEq(res, abi.encodeWithSelector(OTSC1.SignerAlreadyConsumedOrReserved.selector, S1));
        assertEq(_slot(), address(impl2), "redelegation applied");
        assertFalse(_acct().isActiveManagementSigner(M1));
        assertTrue(_acct().isActiveManagementSigner(M2));
    }

    function test_redelegate_beforeRetirement_reverts() public {
        _v2Migrate();
        OTSC1.Redelegation memory r = _redel(address(impl2), M3);
        bytes memory sig = _sig(M1_PK, _acct().hashRedelegation(r));
        vm.expectRevert(OTSC1.NotRetired.selector);
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
