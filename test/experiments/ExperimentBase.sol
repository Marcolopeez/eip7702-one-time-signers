// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "../../lib/forge-std/src/Test.sol";
import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

import {OneTimeSignerAccount} from "../../src/OneTimeSignerAccount.sol";

/// @notice Shared setup for the paper experiments (tarea 1, 17-11-2026).
/// @dev Same delegation path as the TFM tests: `vm.signAndAttachDelegation` + self-call `initialize`.
///      Does not modify `src/`.
abstract contract ExperimentBase is Test {
    using ECDSA for bytes32;

    uint256 internal constant H_PK = 0xA11CE; // original EOA key `h`
    uint256 internal constant S1_PK = 0xB0B; // first one-time signer
    uint256 internal constant S2_PK = 0xCAFE; // legitimate successor
    uint256 internal constant R1_PK = 0xAABB; // recovery signer
    uint256 internal constant R2_PK = 0xCCDD; // recovery signer
    uint256 internal constant R3_PK = 0xDDCC; // renewed recovery signer
    uint256 internal constant S3_PK = 0xD00D; // signer installed by recovery
    uint256 internal constant ATTACKER_PK = 0xBAD;
    uint256 internal constant RELAYER_PK = 0x1234;

    address payable internal A;
    address internal S1;
    address internal S2;
    address internal S3;
    address internal R1;
    address internal R2;
    address internal R3;
    address internal attacker;
    address internal relayer;

    OneTimeSignerAccount internal implementation;

    function setUp() public virtual {
        A = payable(vm.addr(H_PK));
        S1 = vm.addr(S1_PK);
        S2 = vm.addr(S2_PK);
        S3 = vm.addr(S3_PK);
        R1 = vm.addr(R1_PK);
        R2 = vm.addr(R2_PK);
        R3 = vm.addr(R3_PK);
        attacker = vm.addr(ATTACKER_PK);
        relayer = vm.addr(RELAYER_PK);

        implementation = new OneTimeSignerAccount();

        vm.signAndAttachDelegation(address(implementation), H_PK);
        address[] memory recovery = new address[](2);
        recovery[0] = R1;
        recovery[1] = R2;
        vm.prank(A);
        acct().initialize(S1, recovery);
    }

    function acct() internal view returns (OneTimeSignerAccount) {
        return OneTimeSignerAccount(A);
    }

    function op(address target, bytes memory data, address next)
        internal
        view
        returns (OneTimeSignerAccount.Operation memory)
    {
        return OneTimeSignerAccount.Operation({
            target: target,
            value: 0,
            data: data,
            nextAuthorizedSigner: next,
            deadline: block.timestamp + 1 days
        });
    }

    function sign(uint256 pk, OneTimeSignerAccount.Operation memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, acct().hashOperation(o));
        return bytes.concat(r, s, bytes1(v));
    }

    function signRecovery(uint256 pk, OneTimeSignerAccount.RecoveryOperation memory o)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, acct().hashRecoveryOperation(o));
        return bytes.concat(r, s, bytes1(v));
    }

    /// @dev Oráculo: la firma sigue siendo aceptable por el contrato (su firmante es el actual).
    function stillAcceptable(OneTimeSignerAccount.Operation memory o, bytes memory sig) internal view returns (bool) {
        return acct().hashOperation(o).recover(sig) == acct().currentAuthorizedSigner() && !acct().isPaused();
    }
}
