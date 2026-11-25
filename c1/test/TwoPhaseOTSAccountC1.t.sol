// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {TwoPhaseOTSAccountC1 as TP} from "../src/TwoPhaseOTSAccountC1.sol";
import {OneTimeSignerAccountC1 as OTSC1} from "../src/OneTimeSignerAccountC1.sol";
import {OTSProxyC1} from "../src/OTSProxyC1.sol";
import {MockSetSelfDelegateHelper} from "./mocks/MockSetSelfDelegateHelper.sol";
import {Witness} from "./mocks/C1Mocks.sol";
import {RevertingWrapper, LargeTarget, BandProbe, Drainer} from "./mocks/TwoPhaseMocks.sol";

/// @notice CR3: C1⁺ (d⁺, two-phase authorization) in Foundry, one test per oracle T01-T16 of
///         `experimentos/CR/ORACULOS.md` (= CR-ESPECIFICACION §9). As in H3, revm does not execute 0xac nor
///         0xef0101: the helper is a mock and the retired state is emulated with `0xef0100 || P`.
///         Delivery rule under On-spend (#264): the adversary receives sk(k) at E, i.e. when the test builds
///         ("broadcasts") the holder's execution; from then on the test lets the adversary sign with sk(k) and
///         act first in the same block. Under Classical the adversary only gets pk(k) from E.
///         The tests compute ℓ, δ and γ themselves (CR-ESPECIFICACION §2.3), not with the contract's helpers.
contract TwoPhaseOTSAccountC1Test is Test {
    uint256 internal constant H_PK = 0xA11CE;
    uint256 internal constant H2_PK = 0xA11CE2; // a second account, in OTS-C1, for comparisons
    uint256 internal constant S1_PK = 0xB0B;
    uint256 internal constant S2_PK = 0xCAFE;
    uint256 internal constant S3_PK = 0xD00D;
    uint256 internal constant M1_PK = 0xAABB;
    uint256 internal constant M2_PK = 0xCCDD;
    uint256 internal constant M3_PK = 0xDDCC;
    uint256 internal constant ATTACKER_PK = 0xBAD;
    uint256 internal constant RELAYER_PK = 0x1234;

    bytes32 internal constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address payable internal A;
    address payable internal B;
    address internal S1;
    address internal S2;
    address internal S3;
    address internal M1;
    address internal M2;
    address internal M3;
    address internal attacker;
    address internal relayer;
    address internal attNextS; // successor the adversary wants to install
    address internal attNextM;

    OTSProxyC1 internal proxy;
    MockSetSelfDelegateHelper internal helper;
    TP internal dPlus;
    TP internal dPlus2;
    OTSC1 internal c1;
    Witness internal witness;

    function setUp() public {
        A = payable(vm.addr(H_PK));
        B = payable(vm.addr(H2_PK));
        S1 = vm.addr(S1_PK);
        S2 = vm.addr(S2_PK);
        S3 = vm.addr(S3_PK);
        M1 = vm.addr(M1_PK);
        M2 = vm.addr(M2_PK);
        M3 = vm.addr(M3_PK);
        attacker = vm.addr(ATTACKER_PK);
        relayer = vm.addr(RELAYER_PK);
        attNextS = vm.addr(0xA77A);
        attNextM = vm.addr(0xA77B);

        proxy = new OTSProxyC1();
        helper = new MockSetSelfDelegateHelper(1);
        dPlus = new TP(address(proxy), address(helper));
        dPlus2 = new TP(address(proxy), address(helper));
        c1 = new OTSC1(address(proxy), address(helper));
        witness = new Witness();
        vm.deal(A, 10 ether);
        vm.deal(B, 10 ether);
    }

    // ================================================================== helpers

    struct Commitment {
        bytes32 loc;
        bytes32 delta;
        bytes32 gamma;
    }

    function _acct() internal view returns (TP) {
        return TP(A);
    }

    function _management() internal view returns (address[] memory m) {
        m = new address[](2);
        m[0] = M1;
        m[1] = M2;
    }

    /// V1 with d = d⁺ (activation in the migration, D-162), then the retired state emulated.
    function _v1() internal {
        vm.signAndAttachDelegation(address(dPlus), H_PK);
        vm.prank(A);
        TP(A).initializeAndRetire(S1, _management());
        vm.etch(A, abi.encodePacked(hex"ef0100", address(proxy)));
    }

    /// The same account structure in OTS-C1 at B, for comparisons in the same tool.
    function _v1c1() internal {
        vm.signAndAttachDelegation(address(c1), H2_PK);
        vm.prank(B);
        OTSC1(B).initializeAndRetire(S1, _management());
        vm.etch(B, abi.encodePacked(hex"ef0100", address(proxy)));
    }

    function _slot(address a) internal view returns (address) {
        return address(uint160(uint256(vm.load(a, SLOT))));
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// pk(k): 64-byte uncompressed secp256k1 public key.
    function _pub(uint256 sk) internal returns (bytes memory) {
        Vm.Wallet memory w = vm.createWallet(sk);
        return abi.encodePacked(w.publicKeyX, w.publicKeyY);
    }

    // Independent computation of the hashes of CR-ESPECIFICACION §2.3: H_tag(x) = keccak256(keccak256(tag) ‖ x).
    function _loc(uint256 chainId, address account, bytes memory pk) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256("OTS-2P/loc"), chainId, account, pk));
    }

    function _dig(bytes32 digest, bytes32 r) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256("OTS-2P/dig"), digest, r));
    }

    function _com(uint256 chainId, address account, bytes memory pk, bytes32 delta) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256("OTS-2P/com"), chainId, account, pk, delta));
    }

    function _cm(uint256 sk, bytes32 digest, bytes32 r) internal returns (Commitment memory c) {
        return _cmFor(block.chainid, A, sk, digest, r);
    }

    function _cmFor(uint256 chainId, address account, uint256 sk, bytes32 digest, bytes32 r)
        internal
        returns (Commitment memory c)
    {
        bytes memory pk = _pub(sk);
        c.loc = _loc(chainId, account, pk);
        c.delta = _dig(digest, r);
        c.gamma = _com(chainId, account, pk, c.delta);
    }

    function _commit(Commitment memory c, address from) internal returns (uint256 position) {
        vm.prank(from);
        return _acct().commit(c.loc, c.delta, c.gamma);
    }

    function _skip(Commitment memory c) internal pure returns (TP.SkippedEntry memory) {
        return TP.SkippedEntry({delta: c.delta, gamma: c.gamma});
    }

    function _none() internal pure returns (TP.SkippedEntry[] memory) {
        return new TP.SkippedEntry[](0);
    }

    function _one(TP.SkippedEntry memory e) internal pure returns (TP.SkippedEntry[] memory s) {
        s = new TP.SkippedEntry[](1);
        s[0] = e;
    }

    /// Simulated finality F of the last commitment (two epochs).
    function _finality() internal {
        vm.roll(block.number + 64);
        vm.warp(block.timestamp + 64 * 12);
    }

    function _salt(string memory label) internal pure returns (bytes32) {
        return keccak256(bytes(label));
    }

    function _op(address target, bytes memory data, address next) internal view returns (TP.Operation memory) {
        return TP.Operation({target: target, value: 0, data: data, nextAuthorizedSigner: next, deadline: block.timestamp + 1 days});
    }

    function _ping(address next) internal view returns (TP.Operation memory) {
        return _op(address(witness), abi.encodeCall(Witness.ping, ()), next);
    }

    function _exec(TP.Operation memory op, uint256 sk, bytes32 r, TP.SkippedEntry[] memory skipped, address from)
        internal
        returns (bool ok, bytes memory res)
    {
        bytes memory sig = _sig(sk, _acct().hashOperation(op));
        bytes memory pk = _pub(sk);
        vm.prank(from);
        return _acct().executeSignedAndRotate(op, sig, pk, r, skipped);
    }

    function _execCd(TP.Operation memory op, uint256 sk, bytes32 r, TP.SkippedEntry[] memory skipped)
        internal
        returns (bytes memory)
    {
        return abi.encodeCall(
            TP.executeSignedAndRotate, (op, _sig(sk, _acct().hashOperation(op)), _pub(sk), r, skipped)
        );
    }

    function _rec(address nextS, address nextM) internal view returns (TP.RecoveryOperation memory) {
        return TP.RecoveryOperation({nextAuthorizedSigner: nextS, nextManagementSigner: nextM, deadline: block.timestamp + 1 days});
    }

    function _recover(TP.RecoveryOperation memory m, uint256 sk, bytes32 r, TP.SkippedEntry[] memory skipped, address from)
        internal
        returns (bool ok, bytes memory res)
    {
        bytes memory sig = _sig(sk, _acct().hashRecoveryOperation(m));
        bytes memory pk = _pub(sk);
        vm.prank(from);
        return _acct().signedRecovery(m, sig, pk, r, skipped);
    }

    function _redel(address impl, address nextM) internal view returns (TP.Redelegation memory) {
        return TP.Redelegation({newImplementation: impl, nextManagementSigner: nextM, deadline: block.timestamp + 1 days});
    }

    function _redelegate(TP.Redelegation memory m, uint256 sk, bytes32 r, TP.SkippedEntry[] memory skipped, address from)
        internal
        returns (bool ok, bytes memory res)
    {
        bytes memory sig = _sig(sk, _acct().hashRedelegation(m));
        bytes memory pk = _pub(sk);
        vm.prank(from);
        return _acct().redelegate(m, sig, pk, r, skipped);
    }

    function _notFirstValid(bytes32 loc, uint256 p) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(TP.NotFirstValid.selector, loc, p);
    }

    /// Holder's normal path up to F: commit (from the relayer) and simulated finality. Returns the commitment.
    function _holderCommitsOp(TP.Operation memory op, bytes32 r) internal returns (Commitment memory c) {
        c = _cm(S1_PK, _acct().hashOperation(op), r);
        _commit(c, relayer);
        _finality();
    }

    // ================================================================== T01-T16

    /// T01. Normal path: commit, F, execute -> rotates to s_{i+1}, the call has effect.
    function test_T01_normalPath_rotatesAndCalls() public {
        _v1();
        TP.Operation memory op = _ping(S2);
        bytes32 r = _salt("T01");
        Commitment memory c = _cm(S1_PK, _acct().hashOperation(op), r);

        vm.expectEmit(true, false, false, true, A);
        emit TP.Committed(c.loc, c.delta, c.gamma, 0);
        assertEq(_commit(c, relayer), 0);
        assertEq(_acct().entryCount(c.loc), 1);
        _finality();

        (bool ok,) = _exec(op, S1_PK, r, _none(), relayer);
        assertTrue(ok, "operation applied");
        assertEq(_acct().currentAuthorizedSigner(), S2, "rotated to s_{i+1}");
        assertEq(witness.calls(), 1);
        assertEq(witness.lastCaller(), A, "call from the account");
        assertTrue(_acct().isConsumedOrReservedSigner(S2));
        assertEq(_acct().firstEntry(c.loc), bytes32(0), "entry deleted on consumption (D-167)");
    }

    /// T02. Execution without a commitment reverts NoCommitment; nothing changes.
    function test_T02_noCommitment_reverts() public {
        _v1();
        TP.Operation memory op = _ping(S2);
        bytes32 r = _salt("T02");
        bytes32 loc = _loc(block.chainid, A, _pub(S1_PK));
        bytes memory sig = _sig(S1_PK, _acct().hashOperation(op));
        bytes memory pk = _pub(S1_PK);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(TP.NoCommitment.selector, loc));
        _acct().executeSignedAndRotate(op, sig, pk, r, _none());
        assertEq(_acct().currentAuthorizedSigner(), S1);
        assertFalse(_acct().isPaused());
        assertEq(witness.calls(), 0);
    }

    /// T03. On-spend in the same block: after E the adversary (with sk) commits m' and executes before the holder.
    function test_T03_onSpendSameBlock_adversaryRevertsHolderExecutes() public {
        _v1();
        TP.Operation memory op = _ping(S2);
        bytes32 r = _salt("T03");
        Commitment memory c = _holderCommitsOp(op, r);
        uint256 blockOfE = block.number;
        // E: the holder broadcasts (op, σ, pk(s_1), r). The adversary now has sk(s_1) and acts first.
        TP.Operation memory evil = _op(address(witness), abi.encodeCall(Witness.ping, ()), attNextS);
        bytes32 rEvil = _salt("T03-evil");
        Commitment memory ce = _cm(S1_PK, _acct().hashOperation(evil), rEvil);
        assertEq(ce.loc, c.loc, "same locator: same key");
        assertEq(_commit(ce, attacker), 1, "the adversary's entry is behind the holder's");

        bytes memory sigEvil = _sig(S1_PK, _acct().hashOperation(evil));
        bytes memory pk = _pub(S1_PK);
        // (i) without skipping: position 0 is the holder's entry
        vm.prank(attacker);
        vm.expectRevert(_notFirstValid(c.loc, 0));
        _acct().executeSignedAndRotate(evil, sigEvil, pk, rEvil, _none());
        // (ii) asking to skip the holder's entry, which is valid
        vm.prank(attacker);
        vm.expectRevert(_notFirstValid(c.loc, 0));
        _acct().executeSignedAndRotate(evil, sigEvil, pk, rEvil, _one(_skip(c)));
        // (iii) with a valid entry under the locator of a key of its own, and σ' from sk(s_1): the locator must be
        // the current signer's (found by a mutant of the pk check, see experimentos/CR/resultados)
        bytes memory pkAtt = _pub(ATTACKER_PK);
        Commitment memory own = _cm(ATTACKER_PK, _acct().hashOperation(evil), rEvil);
        _commit(own, attacker);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TP.PublicKeyMismatch.selector, attacker, S1));
        _acct().executeSignedAndRotate(evil, sigEvil, pkAtt, rEvil, _none());

        assertEq(block.number, blockOfE, "same block");
        (bool ok,) = _exec(op, S1_PK, r, _none(), relayer);
        assertTrue(ok);
        assertEq(_acct().currentAuthorizedSigner(), S2, "the holder's successor, not the adversary's");
        assertEq(witness.calls(), 1);
    }

    /// T04. Garbage before the holder's entry: correct skip list succeeds; incomplete or wrong list reverts.
    function test_T04_garbageBefore_skippedWithCorrectList() public {
        _v1();
        TP.Operation memory op = _ping(S2);
        bytes32 r = _salt("T04");
        Commitment memory c = _cm(S1_PK, _acct().hashOperation(op), r);
        uint256 n = 5;
        TP.SkippedEntry[] memory garbage = new TP.SkippedEntry[](n);
        // the adversary sees ℓ in the mempool and orders garbage first (random pairs and a bit flip of γ)
        for (uint256 i; i < n; ++i) {
            garbage[i] = TP.SkippedEntry({delta: keccak256(abi.encode("g", i)), gamma: keccak256(abi.encode("h", i))});
            if (i == n - 1) garbage[i] = TP.SkippedEntry({delta: c.delta, gamma: c.gamma ^ bytes32(uint256(1))});
            vm.prank(attacker);
            _acct().commit(c.loc, garbage[i].delta, garbage[i].gamma);
        }
        assertEq(_commit(c, relayer), n, "holder's entry at position n");
        _finality();

        // incomplete list (n - 1): the entry at position n - 1 is garbage, not the holder's
        TP.SkippedEntry[] memory incomplete = new TP.SkippedEntry[](n - 1);
        for (uint256 i; i < n - 1; ++i) incomplete[i] = garbage[i];
        bytes memory sig = _sig(S1_PK, _acct().hashOperation(op));
        bytes memory pk = _pub(S1_PK);
        vm.expectRevert(_notFirstValid(c.loc, n - 1));
        _acct().executeSignedAndRotate(op, sig, pk, r, incomplete);
        // wrong list: one pair that is not the preimage of its entry
        TP.SkippedEntry[] memory wrong = new TP.SkippedEntry[](n);
        for (uint256 i; i < n; ++i) wrong[i] = garbage[i];
        wrong[2] = TP.SkippedEntry({delta: garbage[2].delta, gamma: bytes32(uint256(0xbeef))}); // a new struct: no alias
        vm.expectRevert(abi.encodeWithSelector(TP.SkippedEntryMismatch.selector, c.loc, 2));
        _acct().executeSignedAndRotate(op, sig, pk, r, wrong);
        // a list one too long: there is no entry after the holder's
        TP.SkippedEntry[] memory tooLong = new TP.SkippedEntry[](n + 1);
        for (uint256 i; i < n; ++i) tooLong[i] = garbage[i];
        tooLong[n] = _skip(c);
        vm.expectRevert(abi.encodeWithSelector(TP.NoCommitment.selector, c.loc));
        _acct().executeSignedAndRotate(op, sig, pk, r, tooLong);

        assertEq(_acct().currentAuthorizedSigner(), S1, "nothing consumed by the failed attempts (R8)");
        (bool ok,) = _exec(op, S1_PK, r, garbage, relayer);
        assertTrue(ok);
        assertEq(_acct().currentAuthorizedSigner(), S2);
        assertEq(witness.calls(), 1);
    }

    /// T05. An exact copy of the holder's entry in front: the holder's m executes.
    function test_T05_exactCopyInFront_holderExecutes() public {
        _v1();
        TP.Operation memory op = _ping(S2);
        bytes32 r = _salt("T05");
        Commitment memory c = _cm(S1_PK, _acct().hashOperation(op), r);
        assertEq(_commit(c, attacker), 0, "the copy is first");
        assertEq(_commit(c, relayer), 1);
        _finality();
        (bool ok,) = _exec(op, S1_PK, r, _none(), relayer);
        assertTrue(ok);
        assertEq(_acct().currentAuthorizedSigner(), S2);
        assertEq(witness.calls(), 1);
    }

    /// T06. Censorship and no Δ: the adversary commits after E, rolls 10^6 blocks and executes m' -> reverts.
    function test_T06_censorshipNoDelta_adversaryReverts() public {
        _v1();
        TP.Operation memory op = _ping(S2);
        bytes32 r = _salt("T06");
        Commitment memory c = _holderCommitsOp(op, r);
        // E: the holder's execution is broadcast but censored (not included). The adversary has sk(s_1).
        TP.Operation memory evil = _op(address(witness), abi.encodeCall(Witness.ping, ()), attNextS);
        evil.deadline = type(uint256).max;
        bytes32 rEvil = _salt("T06-evil");
        _commit(_cm(S1_PK, _acct().hashOperation(evil), rEvil), attacker);
        vm.roll(block.number + 1_000_000);

        bytes memory sigEvil = _sig(S1_PK, _acct().hashOperation(evil));
        bytes memory pk = _pub(S1_PK);
        vm.prank(attacker);
        vm.expectRevert(_notFirstValid(c.loc, 0));
        _acct().executeSignedAndRotate(evil, sigEvil, pk, rEvil, _none());
        // added check: the holder's execution, once included, executes m
        (bool ok,) = _exec(op, S1_PK, r, _none(), relayer);
        assertTrue(ok);
        assertEq(_acct().currentAuthorizedSigner(), S2);
    }

    /// T07a. Reorganization with W3 broken, On-spend: EXPECTED ADVERSARY SUCCESS (documents why W3).
    function test_T07a_reorgW3Broken_onSpend_EXPECTED_adversarySucceeds() public {
        _v1();
        TP.Operation memory op = _ping(S2);
        bytes32 r = _salt("T07a");
        uint256 snap = vm.snapshotState();
        // the holder commits and executes before F (W3 broken): E, the adversary gets sk(s_1)
        Commitment memory c = _cm(S1_PK, _acct().hashOperation(op), r);
        _commit(c, relayer);
        (bool ok,) = _exec(op, S1_PK, r, _none(), relayer);
        assertTrue(ok);
        // reorganization before F removes both transactions
        vm.revertToState(snap);
        assertEq(_acct().currentAuthorizedSigner(), S1);
        assertEq(_acct().entryCount(c.loc), 0);
        // the adversary commits first in the new branch and executes m' with σ' = sig of sk(s_1)
        TP.Operation memory evil = _op(address(witness), abi.encodeCall(Witness.ping, ()), attNextS);
        bytes32 rEvil = _salt("T07a-evil");
        assertEq(_commit(_cm(S1_PK, _acct().hashOperation(evil), rEvil), attacker), 0);
        (bool okEvil,) = _exec(evil, S1_PK, rEvil, _none(), attacker);
        assertTrue(okEvil, "EXPECTED: the adversary's message executes");
        assertEq(_acct().currentAuthorizedSigner(), attNextS, "EXPECTED: the adversary names the successor");
    }

    /// T07b. Same reorganization under Classical (the adversary has pk(s_1), not sk): reverts by σ.
    function test_T07b_reorgW3Broken_classical_revertsBySignature() public {
        _v1();
        TP.Operation memory op = _ping(S2);
        bytes32 r = _salt("T07b");
        uint256 snap = vm.snapshotState();
        _commit(_cm(S1_PK, _acct().hashOperation(op), r), relayer);
        (bool ok,) = _exec(op, S1_PK, r, _none(), relayer);
        assertTrue(ok);
        vm.revertToState(snap);
        // the adversary saw pk(s_1) at E; it commits first a valid entry for m' and signs with its own key
        bytes memory pk = _pub(S1_PK);
        TP.Operation memory evil = _op(address(witness), abi.encodeCall(Witness.ping, ()), attNextS);
        bytes32 rEvil = _salt("T07b-evil");
        Commitment memory ce = _cm(S1_PK, _acct().hashOperation(evil), rEvil);
        assertEq(_commit(ce, attacker), 0);
        bytes memory sigByAttacker = _sig(ATTACKER_PK, _acct().hashOperation(evil));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TP.InvalidSignature.selector, attacker, S1));
        _acct().executeSignedAndRotate(evil, sigByAttacker, pk, rEvil, _none());
        assertEq(_acct().currentAuthorizedSigner(), S1, "no capture");

        // Observation (not part of the oracle): the adversary's valid entry is now first under ℓ, so the holder
        // can no longer execute with s_1 (liveness of s_1 lost, safety kept); a two-phase recovery replaces it.
        _commit(_cm(S1_PK, _acct().hashOperation(op), r), relayer);
        _finality();
        bytes memory sig = _sig(S1_PK, _acct().hashOperation(op));
        vm.expectRevert(_notFirstValid(ce.loc, 0));
        _acct().executeSignedAndRotate(op, sig, pk, r, _none());
        vm.expectRevert(_notFirstValid(ce.loc, 0));
        _acct().executeSignedAndRotate(op, sig, pk, r, _one(_skip(ce)));
        TP.RecoveryOperation memory rec = _rec(S3, M3);
        bytes32 rr = _salt("T07b-rec");
        _commit(_cm(M1_PK, _acct().hashRecoveryOperation(rec), rr), relayer);
        _finality();
        (bool okRec,) = _recover(rec, M1_PK, rr, _none(), relayer);
        assertTrue(okRec, "a two-phase recovery replaces the blocked signer");
        assertEq(_acct().currentAuthorizedSigner(), S3);
    }

    /// T07b (complement for the management paths, added after a mutant of the σ check survived): the same
    ///      reorganization under Classical with a recovery; the adversary has pk(μ_1), not sk -> reverts by σ.
    function test_T07b_mgmt_reorgW3Broken_classical_revertsBySignature() public {
        _v1();
        TP.RecoveryOperation memory rec = _rec(S3, M3);
        bytes32 r = _salt("T07b-mgmt");
        uint256 snap = vm.snapshotState();
        _commit(_cm(M1_PK, _acct().hashRecoveryOperation(rec), r), relayer);
        (bool ok,) = _recover(rec, M1_PK, r, _none(), relayer);
        assertTrue(ok);
        vm.revertToState(snap);
        TP.RecoveryOperation memory evil = _rec(attNextS, attNextM);
        bytes32 rEvil = _salt("T07b-mgmt-evil");
        uint256 snap2 = vm.snapshotState();
        _commit(_cm(M1_PK, _acct().hashRecoveryOperation(evil), rEvil), attacker);
        bytes memory pk = _pub(M1_PK);
        bytes memory sigByAttacker = _sig(ATTACKER_PK, _acct().hashRecoveryOperation(evil));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TP.InvalidSignature.selector, attacker, M1));
        _acct().signedRecovery(evil, sigByAttacker, pk, rEvil, _none());
        // and the code change with the same key (another branch, so that its entry is the first under ℓ)
        vm.revertToState(snap2);
        TP.Redelegation memory evilRed = _redel(address(dPlus2), attNextM);
        _commit(_cm(M1_PK, _acct().hashRedelegation(evilRed), rEvil), attacker);
        bytes memory sigRed = _sig(ATTACKER_PK, _acct().hashRedelegation(evilRed));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TP.InvalidSignature.selector, attacker, M1));
        _acct().redelegate(evilRed, sigRed, pk, rEvil, _none());
        assertEq(_acct().currentAuthorizedSigner(), S1, "no capture");
        assertTrue(_acct().isActiveManagementSigner(M1));
        assertEq(_slot(A), address(dPlus));

        // Observation (not part of the oracle): μ_1 is now blocked (the adversary's valid entry is first under its
        // ℓ), so the holder must use another active μ; with a single μ, management would be lost.
        _muBlockedThenAnotherMuRecovers(rec, r);
    }

    function _muBlockedThenAnotherMuRecovers(TP.RecoveryOperation memory rec, bytes32 r) internal {
        bytes memory pk = _pub(M1_PK);
        _commit(_cm(M1_PK, _acct().hashRecoveryOperation(rec), r), relayer);
        _finality();
        bytes memory sigRec = _sig(M1_PK, _acct().hashRecoveryOperation(rec));
        vm.expectRevert(_notFirstValid(_loc(block.chainid, A, pk), 0));
        _acct().signedRecovery(rec, sigRec, pk, r, _none());
        TP.RecoveryOperation memory rec2 = _rec(S3, M3);
        bytes32 r2 = _salt("T07b-mgmt-M2");
        _commit(_cm(M2_PK, _acct().hashRecoveryOperation(rec2), r2), relayer);
        _finality();
        (bool ok2,) = _recover(rec2, M2_PK, r2, _none(), relayer);
        assertTrue(ok2, "another active mu recovers");
        assertFalse(_acct().isActiveManagementSigner(M1), "the blocked mu_1 is revoked by the recovery (D-35)");
    }

    /// T08. Execution after the deadline: rotates without effect; the entry keeps blocking the adversary's m'.
    function test_T08_afterDeadline_rotatesWithoutEffect_entryStillBlocks() public {
        _v1();
        TP.Operation memory op = _ping(S2);
        op.deadline = block.timestamp + 1 hours;
        bytes32 r = _salt("T08");
        Commitment memory c = _holderCommitsOp(op, r);
        vm.warp(op.deadline + 1);
        // E after the deadline: the adversary (On-spend) commits m' and executes first
        TP.Operation memory evil = _op(address(witness), abi.encodeCall(Witness.ping, ()), attNextS);
        bytes32 rEvil = _salt("T08-evil");
        _commit(_cm(S1_PK, _acct().hashOperation(evil), rEvil), attacker);
        bytes memory sigEvil = _sig(S1_PK, _acct().hashOperation(evil));
        bytes memory pk = _pub(S1_PK);
        vm.prank(attacker);
        vm.expectRevert(_notFirstValid(c.loc, 0));
        _acct().executeSignedAndRotate(evil, sigEvil, pk, rEvil, _none());

        (bool ok, bytes memory res) = _exec(op, S1_PK, r, _none(), relayer);
        assertFalse(ok);
        assertEq(res, abi.encodeWithSelector(TP.ExpiredOperation.selector, op.deadline));
        assertEq(_acct().currentAuthorizedSigner(), S2, "rotated without effect");
        assertEq(witness.calls(), 0, "no call");
    }

    /// T09. A wrapper that reverts (#26): everything is undone, the entry stays, m executes later, m' reverts.
    function test_T09_revertingWrapper_entryStays() public {
        _v1();
        TP.Operation memory op = _ping(S2);
        bytes32 r = _salt("T09");
        Commitment memory c = _holderCommitsOp(op, r);
        RevertingWrapper wrapper = new RevertingWrapper();
        bytes memory cd = _execCd(op, S1_PK, r, _none());
        vm.expectRevert(abi.encodeWithSelector(RevertingWrapper.WrapperReverted.selector, true));
        wrapper.forwardAndRevert(A, cd); // E: the adversary gets sk(s_1)
        assertEq(_acct().currentAuthorizedSigner(), S1, "rotation undone");
        assertEq(_acct().entryCount(c.loc), 1, "the entry stays");
        assertEq(witness.calls(), 0);

        TP.Operation memory evil = _op(address(witness), abi.encodeCall(Witness.ping, ()), attNextS);
        bytes32 rEvil = _salt("T09-evil");
        _commit(_cm(S1_PK, _acct().hashOperation(evil), rEvil), attacker);
        bytes memory sigEvil = _sig(S1_PK, _acct().hashOperation(evil));
        bytes memory pk = _pub(S1_PK);
        vm.prank(attacker);
        vm.expectRevert(_notFirstValid(c.loc, 0));
        _acct().executeSignedAndRotate(evil, sigEvil, pk, rEvil, _none());

        (bool ok,) = _exec(op, S1_PK, r, _none(), relayer);
        assertTrue(ok);
        assertEq(_acct().currentAuthorizedSigner(), S2);
    }

    /// T10. Gas band (#64): authority consumed without effect, as in C1.
    function test_T10_gasBand_consumedWithoutEffect_asC1() public {
        _v1();
        _v1c1();
        LargeTarget tA = new LargeTarget();
        LargeTarget tB = new LargeTarget();
        BandProbe probe = new BandProbe();

        TP.Operation memory op = _op(address(tA), abi.encodeCall(LargeTarget.write200, ()), S2);
        bytes32 r = _salt("T10");
        _holderCommitsOp(op, r);
        bytes memory cdPlus = _execCd(op, S1_PK, r, _none());

        OTSC1.Operation memory opC1 = OTSC1.Operation({
            target: address(tB), value: 0, data: abi.encodeCall(LargeTarget.write200, ()), nextAuthorizedSigner: S2,
            deadline: block.timestamp + 1 days
        });
        bytes memory cdC1 =
            abi.encodeCall(OTSC1.executeSignedAndRotate, (opC1, _sig(S1_PK, OTSC1(B).hashOperation(opC1))));

        uint256[4] memory nPlus = _sweep(probe, A, cdPlus, address(tA));
        uint256[4] memory nC1 = _sweep(probe, B, cdC1, address(tB));
        emit log_named_uint("d+  reverted", nPlus[0]);
        emit log_named_uint("d+  applied", nPlus[1]);
        emit log_named_uint("d+  consumed_without_effect", nPlus[2]);
        emit log_named_uint("C1  reverted", nC1[0]);
        emit log_named_uint("C1  applied", nC1[1]);
        emit log_named_uint("C1  consumed_without_effect", nC1[2]);
        assertGt(nPlus[2], 0, "d+: band exists");
        assertGt(nC1[2], 0, "C1: band exists");
        assertGt(nPlus[1], 0);
        assertEq(nPlus[3], 0);
        assertEq(nC1[3], 0);
    }

    function _sweep(BandProbe probe, address account, bytes memory cd, address target)
        internal
        returns (uint256[4] memory n)
    {
        for (uint256 g = 100_000; g <= 6_000_000; g += 50_000) {
            try probe.tryAt(account, cd, g, target, S2) {}
            catch Error(string memory o) {
                n[uint8(bytes(o)[0]) - 48]++;
            }
        }
    }

    /// T11. signedRecovery in two phases under On-spend: the adversary does not install its μ; D-35 unchanged.
    function test_T11_signedRecovery_onSpend_adversaryCannotInstall() public {
        _v1();
        TP.RecoveryOperation memory rec = _rec(S3, M3);
        bytes32 r = _salt("T11");
        Commitment memory c = _cm(M1_PK, _acct().hashRecoveryOperation(rec), r);
        _commit(c, relayer);
        _finality();
        // E: the adversary gets sk(μ_1) and acts first
        TP.RecoveryOperation memory evil = _rec(attNextS, attNextM);
        bytes32 rEvil = _salt("T11-evil");
        _commit(_cm(M1_PK, _acct().hashRecoveryOperation(evil), rEvil), attacker);
        bytes memory sigEvil = _sig(M1_PK, _acct().hashRecoveryOperation(evil));
        bytes memory pk = _pub(M1_PK);
        vm.prank(attacker);
        vm.expectRevert(_notFirstValid(c.loc, 0));
        _acct().signedRecovery(evil, sigEvil, pk, rEvil, _none());
        vm.prank(attacker);
        vm.expectRevert(_notFirstValid(c.loc, 0));
        _acct().signedRecovery(evil, sigEvil, pk, rEvil, _one(_skip(c)));
        // (iii) a key of its own, with its own valid entry and its own signature: not an active management key
        Commitment memory own = _cm(ATTACKER_PK, _acct().hashRecoveryOperation(evil), rEvil);
        _commit(own, attacker);
        bytes memory pkAtt = _pub(ATTACKER_PK);
        bytes memory sigAtt = _sig(ATTACKER_PK, _acct().hashRecoveryOperation(evil));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TP.ManagementSignerNotActive.selector, attacker));
        _acct().signedRecovery(evil, sigAtt, pkAtt, rEvil, _none());

        (bool ok,) = _recover(rec, M1_PK, r, _none(), relayer);
        assertTrue(ok);
        assertEq(_acct().currentAuthorizedSigner(), S3);
        assertEq(_acct().managementEpoch(), 1, "epoch advanced (D-35)");
        assertFalse(_acct().isActiveManagementSigner(M1), "consumed");
        assertFalse(_acct().isActiveManagementSigner(M2), "revoked (D-35)");
        assertTrue(_acct().isActiveManagementSigner(M3), "holder's successor");
        assertFalse(_acct().isActiveManagementSigner(attNextM), "adversary's mu not installed");
    }

    /// T12. redelegate in two phases under On-spend: the slot changes only to the holder's m.
    function test_T12_redelegate_onSpend_slotOnlyToHolders() public {
        _v1();
        TP evilImpl = new TP(address(proxy), address(helper));
        TP.Redelegation memory red = _redel(address(dPlus2), M3);
        bytes32 r = _salt("T12");
        Commitment memory c = _cm(M1_PK, _acct().hashRedelegation(red), r);
        _commit(c, relayer);
        _finality();
        TP.Redelegation memory evil = _redel(address(evilImpl), attNextM);
        bytes32 rEvil = _salt("T12-evil");
        _commit(_cm(M1_PK, _acct().hashRedelegation(evil), rEvil), attacker);
        bytes memory sigEvil = _sig(M1_PK, _acct().hashRedelegation(evil));
        bytes memory pk = _pub(M1_PK);
        vm.prank(attacker);
        vm.expectRevert(_notFirstValid(c.loc, 0));
        _acct().redelegate(evil, sigEvil, pk, rEvil, _none());
        assertEq(_slot(A), address(dPlus));

        (bool ok,) = _redelegate(red, M1_PK, r, _none(), relayer);
        assertTrue(ok);
        assertEq(_slot(A), address(dPlus2), "slot = the holder's implementation");
        assertTrue(_acct().isActiveManagementSigner(M3));
        assertFalse(_acct().isActiveManagementSigner(attNextM));
        assertTrue(_acct().isActiveManagementSigner(M2), "a redelegation revokes nothing (D-35)");
    }

    /// T13. The removed one-step paths revert (selector absent in d⁺).
    function test_T13_removedPaths_revert() public {
        _v1();
        vm.prank(S1);
        (bool ok1,) = A.call(abi.encodeCall(OTSC1.rotateAuthorizedSigner, (attNextS)));
        assertFalse(ok1, "rotateAuthorizedSigner absent");
        vm.prank(M1);
        (bool ok2,) = A.call(abi.encodeCall(OTSC1.rotateAuthorizedSignerThroughRecovery, (attNextS, attNextM)));
        assertFalse(ok2, "rotateAuthorizedSignerThroughRecovery absent");
        assertEq(_acct().currentAuthorizedSigner(), S1);
        assertTrue(_acct().isActiveManagementSigner(M1));
        assertFalse(_acct().isActiveManagementSigner(attNextM));

        // added check: the one-step selectors of the three signed paths of OTS-C1 are absent too, even with a
        // signature over d⁺'s own digest
        OTSC1.Operation memory o = OTSC1.Operation({
            target: address(witness), value: 0, data: abi.encodeCall(Witness.ping, ()), nextAuthorizedSigner: S2,
            deadline: block.timestamp + 1 days
        });
        bytes memory sigO = _sig(S1_PK, _acct().hashOperation(_ping(S2)));
        (bool ok3,) = A.call(abi.encodeCall(OTSC1.executeSignedAndRotate, (o, sigO)));
        OTSC1.RecoveryOperation memory ro = OTSC1.RecoveryOperation(S3, M3, block.timestamp + 1 days);
        (bool ok4,) = A.call(abi.encodeCall(OTSC1.signedRecovery, (ro, _sig(M1_PK, _acct().hashRecoveryOperation(_rec(S3, M3))))));
        OTSC1.Redelegation memory rd = OTSC1.Redelegation(address(dPlus2), M3, block.timestamp + 1 days);
        (bool ok5,) = A.call(abi.encodeCall(OTSC1.redelegate, (rd, _sig(M1_PK, _acct().hashRedelegation(_redel(address(dPlus2), M3))))));
        assertFalse(ok3 || ok4 || ok5, "no one-step signed path");
        assertEq(_acct().currentAuthorizedSigner(), S1);
        assertEq(_slot(A), address(dPlus));
        assertEq(witness.calls(), 0);
    }

    /// T14. Domain separation: a commitment made for another chain or another account is invalid.
    function test_T14_domainSeparation() public {
        _v1();
        TP.Operation memory op = _ping(S2);
        bytes32 r = _salt("T14");
        bytes32 digest = _acct().hashOperation(op);
        bytes memory pk = _pub(S1_PK);
        Commitment memory good = _cm(S1_PK, digest, r);
        // the contract's helpers agree with the independent computation (§2.3)
        assertEq(_acct().locatorOf(pk), good.loc);
        assertEq(_acct().blindedDigestOf(digest, r), good.delta);
        assertEq(_acct().commitmentOf(pk, good.delta), good.gamma);

        // (a) ℓ, δ, γ for another chain and for another account, sent to a: different ℓ -> NoCommitment
        Commitment memory otherChain = _cmFor(block.chainid + 1, A, S1_PK, digest, r);
        Commitment memory otherAccount = _cmFor(block.chainid, B, S1_PK, digest, r);
        assertTrue(otherChain.loc != good.loc && otherAccount.loc != good.loc);
        _commit(otherChain, relayer);
        _commit(otherAccount, relayer);
        bytes memory sig = _sig(S1_PK, digest);
        vm.expectRevert(abi.encodeWithSelector(TP.NoCommitment.selector, good.loc));
        _acct().executeSignedAndRotate(op, sig, pk, r, _none());

        // (b) entries under the right ℓ with γ of another chain and of another account: invalid
        Commitment memory b1 = Commitment(good.loc, good.delta, otherChain.gamma);
        Commitment memory b2 = Commitment(good.loc, good.delta, otherAccount.gamma);
        assertTrue(b1.gamma != good.gamma && b2.gamma != good.gamma);
        _commit(b1, attacker);
        _commit(b2, attacker);
        vm.expectRevert(_notFirstValid(good.loc, 0));
        _acct().executeSignedAndRotate(op, sig, pk, r, _none());
        TP.SkippedEntry[] memory two = new TP.SkippedEntry[](2);
        two[0] = _skip(b1);
        two[1] = _skip(b2);
        vm.expectRevert(abi.encodeWithSelector(TP.NoCommitment.selector, good.loc));
        _acct().executeSignedAndRotate(op, sig, pk, r, two);
        // both can be skipped as invalid once the holder commits
        _commit(good, relayer);
        _finality();
        (bool ok,) = _exec(op, S1_PK, r, two, relayer);
        assertTrue(ok);
        assertEq(_acct().currentAuthorizedSigner(), S2);
    }

    /// T15. Activation by redelegate(d⁺) from d (OTS-C1): compatible (ERC-1822); the OTS-C1 storage is kept.
    function test_T15_activationFromC1_keepsStorage() public {
        assertEq(dPlus.proxiableUUID(), SLOT, "d+ is ERC-1822");
        vm.signAndAttachDelegation(address(c1), H_PK);
        vm.prank(A);
        OTSC1(A).initializeAndRetire(S1, _management());
        vm.etch(A, abi.encodePacked(hex"ef0100", address(proxy)));
        // some OTS-C1 state: one operation (s_1 -> s_2)
        OTSC1.Operation memory o = OTSC1.Operation({
            target: address(witness), value: 0, data: abi.encodeCall(Witness.ping, ()), nextAuthorizedSigner: S2,
            deadline: block.timestamp + 1 days
        });
        vm.prank(relayer);
        OTSC1(A).executeSignedAndRotate(o, _sig(S1_PK, OTSC1(A).hashOperation(o)));
        // one-step redelegation to d⁺ (the last one-step path, D-162)
        OTSC1.Redelegation memory rd = OTSC1.Redelegation(address(dPlus), M3, block.timestamp + 1 days);
        vm.prank(relayer);
        (bool okR,) = OTSC1(A).redelegate(rd, _sig(M1_PK, OTSC1(A).hashRedelegation(rd)));
        assertTrue(okR, "redelegation to d+ applied");
        assertEq(_slot(A), address(dPlus));

        assertTrue(_acct().isInitialized());
        assertFalse(_acct().isPaused());
        assertEq(_acct().currentAuthorizedSigner(), S2);
        assertTrue(_acct().isConsumedOrReservedSigner(S1));
        assertTrue(_acct().isConsumedOrReservedSigner(S2));
        assertEq(_acct().managementEpoch(), 0);
        assertFalse(_acct().isActiveManagementSigner(M1));
        assertTrue(_acct().isActiveManagementSigner(M2));
        assertTrue(_acct().isActiveManagementSigner(M3));
        assertEq(_acct().implementation(), address(dPlus));

        // a two-phase operation works with s_2
        TP.Operation memory op = _ping(S3);
        bytes32 r = _salt("T15");
        _commit(_cm(S2_PK, _acct().hashOperation(op), r), relayer);
        _finality();
        (bool ok,) = _exec(op, S2_PK, r, _none(), relayer);
        assertTrue(ok);
        assertEq(_acct().currentAuthorizedSigner(), S3);
        assertEq(witness.calls(), 2);
    }

    /// T16. Control C0⁺ (no retirement): the adversary with h redelegates; d⁺ does not protect.
    ///      EXPECTED FAILURE: the test passes when the adversary succeeds.
    function test_T16_C0plus_noRetirement_EXPECTED_adversaryWithHRedelegates() public {
        vm.signAndAttachDelegation(address(dPlus), H_PK);
        vm.prank(A);
        TP(A).initialize(S1, _management()); // V2 without retire(): `h` stays live
        assertEq(_slot(A), address(0));
        // On-spend: h was exposed by the 7702 tuple; the adversary signs a tuple to its own contract
        Drainer drainer = new Drainer();
        vm.signAndAttachDelegation(address(drainer), H_PK);
        Drainer(A).drain(payable(attacker));
        assertEq(attacker.balance, 10 ether, "EXPECTED: the adversary drains the account");
        assertEq(A.balance, 0);
    }

    // ================================================================== gas (CR3, step 4)
    // Call gas measured with `gasleft` around the call and with `vm.lastCallGas`, after `vm.cool` on every
    // account touched, so that each measured call starts cold as a transaction would (except that the tx target
    // is warm in a real transaction and the base 21 000 and calldata are not included). Run with -vv.

    function _coolAll(address account, address impl, address target) internal {
        vm.cool(account);
        vm.cool(address(proxy));
        vm.cool(impl);
        vm.cool(target);
        vm.cool(relayer);
    }

    function _logGas(string memory label, uint256 delta) internal {
        Vm.Gas memory g = vm.lastCallGas();
        emit log_named_uint(string.concat(label, " gasleft_delta"), delta);
        emit log_named_uint(string.concat(label, " lastCallGas.gasTotalUsed"), g.gasTotalUsed);
        emit log_named_uint(string.concat(label, " lastCallGas.gasRefunded"), uint256(int256(g.gasRefunded)));
    }

    /// Gas of T01 (both phases) and of the same operation in OTS-C1, in the same tool.
    function test_GAS_T01_normalPath_vsC1() public {
        _v1();
        _v1c1();
        Witness wB = new Witness();
        // pre-ping both targets once, so that the measured call writes non-zero slots (as #158 after the first)
        TP.Operation memory warm = _ping(S2);
        bytes32 r0 = _salt("GAS-warm");
        _holderCommitsOp(warm, r0);
        _exec(warm, S1_PK, r0, _none(), relayer);
        OTSC1.Operation memory warmB = OTSC1.Operation(address(wB), 0, abi.encodeCall(Witness.ping, ()), S2, block.timestamp + 1 days);
        vm.prank(relayer);
        OTSC1(B).executeSignedAndRotate(warmB, _sig(S1_PK, OTSC1(B).hashOperation(warmB)));

        // d⁺: commit
        TP.Operation memory op = _ping(S3);
        bytes32 r = _salt("GAS-T01");
        Commitment memory c = _cm(S2_PK, _acct().hashOperation(op), r);
        _coolAll(A, address(dPlus), address(witness));
        vm.prank(relayer);
        uint256 g0 = gasleft();
        _acct().commit(c.loc, c.delta, c.gamma);
        _logGas("d+ commit", g0 - gasleft());
        _finality();
        // d⁺: execute
        bytes memory sig = _sig(S2_PK, _acct().hashOperation(op));
        bytes memory pk = _pub(S2_PK);
        TP.SkippedEntry[] memory none = _none();
        _coolAll(A, address(dPlus), address(witness));
        vm.prank(relayer);
        g0 = gasleft();
        _acct().executeSignedAndRotate(op, sig, pk, r, none);
        _logGas("d+ execute", g0 - gasleft());
        assertEq(_acct().currentAuthorizedSigner(), S3);

        // OTS-C1: the same operation in one step
        OTSC1.Operation memory opB = OTSC1.Operation(address(wB), 0, abi.encodeCall(Witness.ping, ()), S3, block.timestamp + 1 days);
        bytes memory sigB = _sig(S2_PK, OTSC1(B).hashOperation(opB));
        _coolAll(B, address(c1), address(wB));
        vm.prank(relayer);
        g0 = gasleft();
        OTSC1(B).executeSignedAndRotate(opB, sigB);
        _logGas("C1 execute", g0 - gasleft());
        assertEq(OTSC1(B).currentAuthorizedSigner(), S3);
    }

    /// Gas of T04: the execution with N = 0, 1, 5 and 10 garbage entries skipped, and the cost of a later entry.
    function test_GAS_T04_perSkippedEntry() public {
        _v1();
        TP.Operation memory op = _ping(S2);
        bytes32 r = _salt("GAS-T04");
        Commitment memory c = _cm(S1_PK, _acct().hashOperation(op), r);
        bytes memory sig = _sig(S1_PK, _acct().hashOperation(op));
        bytes memory pk = _pub(S1_PK);
        uint256[4] memory ns = [uint256(0), 1, 5, 10];
        for (uint256 k; k < 4; ++k) {
            uint256 snap = vm.snapshotState();
            uint256 n = ns[k];
            TP.SkippedEntry[] memory garbage = new TP.SkippedEntry[](n);
            for (uint256 i; i < n; ++i) {
                garbage[i] = TP.SkippedEntry({delta: keccak256(abi.encode("g", i)), gamma: keccak256(abi.encode("h", i))});
                _coolAll(A, address(dPlus), address(witness));
                vm.prank(attacker);
                uint256 gc = gasleft();
                _acct().commit(c.loc, garbage[i].delta, garbage[i].gamma);
                if (n == 10 && (i == 0 || i == 1 || i == 9)) {
                    _logGas(string.concat("garbage commit #", vm.toString(i)), gc - gasleft());
                }
            }
            _commit(c, relayer);
            _finality();
            _coolAll(A, address(dPlus), address(witness));
            vm.prank(relayer);
            uint256 g0 = gasleft();
            _acct().executeSignedAndRotate(op, sig, pk, r, garbage);
            _logGas(string.concat("d+ execute skipping N=", vm.toString(n)), g0 - gasleft());
            assertEq(_acct().currentAuthorizedSigner(), S2);
            vm.revertToState(snap);
        }
    }

    /// Gas of the recovery and of the code change in two phases, and of the same messages in OTS-C1.
    function test_GAS_recoveryAndRedelegation_vsC1() public {
        _v1();
        _v1c1();
        uint256 snapA = vm.snapshotState();

        // d⁺ recovery
        TP.RecoveryOperation memory rec = _rec(S3, M3);
        bytes32 r = _salt("GAS-rec");
        Commitment memory c = _cm(M1_PK, _acct().hashRecoveryOperation(rec), r);
        _coolAll(A, address(dPlus), address(0));
        vm.prank(relayer);
        uint256 g0 = gasleft();
        _acct().commit(c.loc, c.delta, c.gamma);
        _logGas("d+ recovery commit", g0 - gasleft());
        _finality();
        bytes memory sig = _sig(M1_PK, _acct().hashRecoveryOperation(rec));
        bytes memory pk = _pub(M1_PK);
        TP.SkippedEntry[] memory none = _none();
        _coolAll(A, address(dPlus), address(0));
        vm.prank(relayer);
        g0 = gasleft();
        (bool ok,) = _acct().signedRecovery(rec, sig, pk, r, none);
        _logGas("d+ recovery execute", g0 - gasleft());
        assertTrue(ok);
        vm.revertToState(snapA);

        // d⁺ code change
        TP.Redelegation memory red = _redel(address(dPlus2), M3);
        r = _salt("GAS-redel");
        c = _cm(M1_PK, _acct().hashRedelegation(red), r);
        _coolAll(A, address(dPlus), address(dPlus2));
        vm.prank(relayer);
        g0 = gasleft();
        _acct().commit(c.loc, c.delta, c.gamma);
        _logGas("d+ redelegation commit", g0 - gasleft());
        _finality();
        sig = _sig(M1_PK, _acct().hashRedelegation(red));
        _coolAll(A, address(dPlus), address(dPlus2));
        vm.prank(relayer);
        g0 = gasleft();
        (ok,) = _acct().redelegate(red, sig, pk, r, none);
        _logGas("d+ redelegation execute", g0 - gasleft());
        assertTrue(ok);
        assertEq(_slot(A), address(dPlus2));

        // OTS-C1 recovery and code change (one step each), at B
        OTSC1.RecoveryOperation memory recB = OTSC1.RecoveryOperation(S3, M3, block.timestamp + 1 days);
        bytes memory sigRecB = _sig(M1_PK, OTSC1(B).hashRecoveryOperation(recB));
        uint256 snapB = vm.snapshotState();
        _coolAll(B, address(c1), address(0));
        vm.prank(relayer);
        g0 = gasleft();
        (ok,) = OTSC1(B).signedRecovery(recB, sigRecB);
        _logGas("C1 recovery", g0 - gasleft());
        assertTrue(ok);
        vm.revertToState(snapB);
        OTSC1 c1b = new OTSC1(address(proxy), address(helper));
        OTSC1.Redelegation memory redB = OTSC1.Redelegation(address(c1b), M3, block.timestamp + 1 days);
        bytes memory sigRedB = _sig(M1_PK, OTSC1(B).hashRedelegation(redB));
        _coolAll(B, address(c1), address(c1b));
        vm.prank(relayer);
        g0 = gasleft();
        (ok,) = OTSC1(B).redelegate(redB, sigRedB);
        _logGas("C1 redelegation", g0 - gasleft());
        assertTrue(ok);
    }
}
