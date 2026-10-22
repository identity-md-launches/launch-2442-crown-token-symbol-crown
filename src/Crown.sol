// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply launch token. Its deployer receives the entire supply once.
contract Crown is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Crown", "CROWN") {
        _mint(msg.sender, SUPPLY);
    }
}
