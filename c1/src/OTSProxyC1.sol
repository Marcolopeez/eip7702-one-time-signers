// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

/// @title OTSProxyC1
/// @notice Proxy `P` of configuration C1 (D-22, D-26). The account is retired to `0xef0101 || P`; P runs in the
///         account context and delegates to the implementation in the account's ERC-1967 slot.
/// @dev No admin and no upgrade function: the slot is written only by the implementation
///      (`OneTimeSignerAccountC1._retire` and `redelegate`). Reverts if the slot is empty.
contract OTSProxyC1 is Proxy {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    error ImplementationNotSet();

    function _implementation() internal view override returns (address impl) {
        impl = StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value;
        if (impl == address(0)) revert ImplementationNotSet();
    }

    receive() external payable {
        _fallback();
    }
}
