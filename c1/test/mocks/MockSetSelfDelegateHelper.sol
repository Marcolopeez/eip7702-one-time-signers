// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Stand-in for the raw-bytecode SETSELFDELEGATE helper (`5f35ac5f5260205ff3`) in Foundry, whose EVM
///         (revm) does not know opcode 0xac. Under DELEGATECALL it emits an event in the caller's context
///         with the delegate it received and returns a fixed result (1, or 0 for FI-3). It cannot change code:
///         tests emulate the effect with `vm.etch`. The real opcode is tested in Besu (AFIRMACIONES #90-#97).
contract MockSetSelfDelegateHelper {
    uint256 public immutable RESULT;

    event SetSelfDelegateCalled(address indexed context, address indexed delegate);

    constructor(uint256 result) {
        RESULT = result;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        address delegate = address(uint160(uint256(bytes32(input[0:32]))));
        emit SetSelfDelegateCalled(address(this), delegate);
        return abi.encode(RESULT);
    }
}
