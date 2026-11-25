// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Mocks for the C1⁺ tests (CR3). New file: the OTS-C1 mocks are not changed.

interface ICurrentSigner {
    function currentAuthorizedSigner() external view returns (address);
}

/// @notice Wrapper that forwards a call to the account and then reverts (#26, T09).
contract RevertingWrapper {
    error WrapperReverted(bool innerOk);

    function forwardAndRevert(address account, bytes calldata data) external {
        (bool ok,) = account.call(data);
        revert WrapperReverted(ok);
    }
}

/// @notice Target that writes 200 fresh slots (#64, T10).
contract LargeTarget {
    mapping(uint256 => uint256) internal s;
    uint256 public runs;

    function write200() external {
        for (uint256 i; i < 200; ++i) {
            s[i] = i + 1;
        }
        ++runs;
    }
}

/// @notice Calls the account with a given gas, classifies the outcome and reverts, so that nothing is kept (T10).
///         0 = the call reverted; 1 = applied (the target ran); 2 = authority consumed without effect (the call
///         returned, the signer rotated and the target did not run); 3 = other.
contract BandProbe {
    function tryAt(address account, bytes calldata cd, uint256 g, address target, address next) external {
        uint256 before = LargeTarget(target).runs();
        (bool ok,) = account.call{gas: g}(cd);
        uint256 outcome;
        if (!ok) outcome = 0;
        else if (LargeTarget(target).runs() > before) outcome = 1;
        else if (ICurrentSigner(account).currentAuthorizedSigner() == next) outcome = 2;
        else outcome = 3;
        revert(string(abi.encodePacked(bytes1(uint8(48 + outcome)))));
    }
}

/// @notice Contract the adversary delegates the account to with `h` when `h` is not retired (C0⁺, T16).
contract Drainer {
    function drain(address payable to) external {
        to.transfer(address(this).balance);
    }
}
