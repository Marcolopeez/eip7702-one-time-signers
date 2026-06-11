// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Simple target contract used to test calls performed by the delegated EOA.
contract ExecutionTarget {
    uint256 public number;
    address public lastSender;
    uint256 public lastValue;

    event NumberSet(address indexed sender, uint256 number, uint256 value);

    function setNumber(uint256 newNumber) external payable returns (uint256 returnValue) {
        number = newNumber;
        lastSender = msg.sender;
        lastValue = msg.value;

        emit NumberSet(msg.sender, newNumber, msg.value);

        return newNumber + 1;
    }

    function alwaysRevert() external pure {
        revert("TARGET_REVERT");
    }
}
