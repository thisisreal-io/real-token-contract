// SPDX-License-Identifier: MIT

// Real Estate Alliance League, Illinois, USA
// Free Token Smart Contract: 5,000 REAL @ $0 each. 
// Promo is while supplyies last OR until end date.  Please see thisisreal.io for details including END DATE.
// REAL Token: 0x325Aa344761c19F7ab6dc45A95f01d6907A30DCA
// Requirements: Claim 1 REAL token per user wallet  /   Must be an existing Eth wallet with 1+ Eth transaction 
// Token Sale Page:    https://app.thisisreal.io/sale  
// https://ThisIsREAL.io    /    support@thisisreal.io 
// Real Estate Educational Platform with DAO
// Tokenomics Maximum Supply 100,000,000  /  Initial Circulating Supply is 21,000,000
// See Token Details at our website ThisIsREAL.io including token supply dispursement and vesting schedules.
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract FreeREAL is Ownable, ReentrancyGuard, Pausable {
    uint256 public HARDCAP;
    uint256 public totalClaimed;
    uint256 claimableAmt;
    IERC20 public real;

    mapping(address => bool) public userClaimed;

    event REALClaimed(
        address indexed _user,
        uint256 _amount,
        uint256 _timeStamp
    );

    event REALWithdrawn(uint256 _amount);

    constructor(
        address _real,
        uint256 _claimableAmt,
        uint256 _hardCAP
    ) Ownable(msg.sender) {
        real = IERC20(_real);
        claimableAmt = _claimableAmt;
        HARDCAP = _hardCAP;
    }

    function claimREAL() external whenNotPaused nonReentrant {
        require(!userClaimed[msg.sender], "Free tokens already claimed");

        require(
            real.balanceOf(address(this)) >= claimableAmt,
            "Contract have less REAL balance"
        );

        uint256 _amount = address(msg.sender).balance;
        require(_amount > 0, "No ETH balance!");

        require(claimableAmt > 0, "Set claimable amount");
        require(totalClaimed < HARDCAP, "Hardcap reached");

        totalClaimed += claimableAmt;
        userClaimed[msg.sender] = true;

        SafeERC20.safeTransfer(real, msg.sender, claimableAmt);

        emit REALClaimed(msg.sender, claimableAmt, block.timestamp);
    }

    function pause() public whenNotPaused onlyOwner {
        _pause();
    }

    function unpause() public whenPaused onlyOwner {
        _unpause();
    }

    // method `setHARDCAP`
    // @dev - for testing purpose only
    function setHARDCAP(uint256 hardcap) public onlyOwner {
        HARDCAP = hardcap;
    }

    function withdrawREAL(uint256 amount) external onlyOwner {
        require(
            real.balanceOf(address(this)) >= amount,
            "Not enough REAL in contract"
        );
        SafeERC20.safeTransfer(IERC20(address(real)), msg.sender, amount);

        emit REALWithdrawn(amount);
    }
}
