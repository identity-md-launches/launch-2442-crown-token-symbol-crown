// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CrownHook} from "../src/CrownHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Offline CREATE2 salt search; this script never broadcasts or deploys anything.
contract MineSalt {
    error InvalidConfiguration();
    error SaltNotFound();

    function run(address factory, IPoolManager manager, address token, uint256 start, uint256 count)
        public
        pure
        returns (bytes32 salt, address predicted)
    {
        if (factory == address(0) || address(manager) == address(0) || token == address(0) || count == 0) {
            revert InvalidConfiguration();
        }
        bytes32 hash = keccak256(abi.encodePacked(type(CrownHook).creationCode, abi.encode(manager, token)));
        for (uint256 i; i < count; ++i) {
            salt = bytes32(start + i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, hash)))));
            if (HookFlags.matches(predicted, HookFlags.CROWN)) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
