// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.5.0
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @custom:security-contact contact@thisisreal.io
contract TestREAL is ERC20, ERC20Burnable {
    constructor(address recipient) ERC20("Test REAL", "tREAL") {
        _mint(recipient, 21000000 * 10 ** decimals());
    }
}
