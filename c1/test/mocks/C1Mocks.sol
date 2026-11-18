// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Target that records who called it.
contract Witness {
    address public lastCaller;
    uint256 public calls;

    function ping() external returns (uint256) {
        lastCaller = msg.sender;
        return ++calls;
    }
}

/// @notice Contract with code but without `proxiableUUID()`.
contract NotAnImplementation {
    uint256 public x;
}

/// @notice Declares a UUID that is not the ERC-1967 implementation slot.
contract WrongUUID {
    function proxiableUUID() external pure returns (bytes32) {
        return keccak256("not the slot");
    }
}

/// @notice `proxiableUUID()` that never returns: it must not make the redelegation run out of gas.
contract GasBurner {
    function proxiableUUID() external view returns (bytes32 r) {
        while (gasleft() > 100) {
            r = keccak256(abi.encode(r));
        }
    }
}
