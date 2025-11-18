// Real Estate Alliance League, Illinois, USA
// ThisIsREAL.io    /    support@thisisreal.io 
// Real Estate Educational Platform with DAO
// Tokenomics Maximum Supply 100000000  /  Initial Circulating Supply is 21000000
// See Token Details at our website ThisIsREAL.io including token supply dispursement and vesting schedules.
// 
// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts@5.2.0/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts@5.2.0/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts@5.2.0/access/Ownable.sol";


contract Real_Estate_Alliance_League is ERC20, ERC20Burnable, Ownable {
    uint256 public constant MAX_SUPPLY = 100000000 * 10 ** 18;
    uint256 public constant PRE_MINTED_SUPPLY = 21000000 * 10 ** 18;
    uint256 public mintedSupply = 0;
    address public address1 = 0x2438d494751cFeB9551342be64D3F7C645975067 ;
    address public address2 = 0xBc3B0Bdead411d8034b6DAC49e2e666dA8779D16 ;
    address public address3 = 0xeCCb924aFec718a2cB0a4546D6569c9E4F825177 ;
    address public address4 = 0x6C62EE2e74F5B80b83652E5aA4d6Cd4D8F99A583 ;
    address public address5 = 0xa39Be9812b96A198C92B7723dBb6E1D561Eb94F4 ;
    address public address6 = 0xb51D0Acc151354184d990e2805254F593f35C6bA ;
    address public address7 = 0x9a16F6f70655E7551C331bAc08A7a0888A6e7c63 ;
    address public address8 = 0xBacF467A3cAd670E256C900FcE4A0DfA561e6B86 ;
    constructor(address initialOwner)
        ERC20("Real Estate Alliance League", "REAL")
        Ownable(initialOwner)
    {
        mint(address1, 14200000 * 10 ** 18);
        mint(address2, 1000000 * 10 ** 18);
        mint(address3, 1000000 * 10 ** 18);
	    mint(address4, 2000000 * 10 ** 18);
        mint(address5, 900000 * 10 ** 18);
        mint(address6, 900000 * 10 ** 18);
	    mint(address7, 500000 * 10 ** 18);
        mint(address8, 500000 * 10 ** 18);
        mintedSupply = PRE_MINTED_SUPPLY;
    }


    function mint(address to, uint256 amount) public onlyOwner {
    require(mintedSupply + amount <= MAX_SUPPLY, "Exceeds max supply");
    _mint(to, amount);
    mintedSupply += amount;
}
}
