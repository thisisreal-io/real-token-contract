// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {ERC20Burnable} from "@openzeppelin/contracts@5.1.0/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20} from "@openzeppelin/contracts@5.1.0/token/ERC20/ERC20.sol";

/// Sepolia/local fixture only. This is not the deployed REAL token or supply oracle.
contract GOVMINTTestREAL is ERC20, ERC20Burnable {
    address public immutable owner;
    address public blockedRecipient;
    function setBlockedRecipient(address recipient) external {require(msg.sender==owner);blockedRecipient=recipient;}
    function _update(address from,address to,uint256 value) internal override {
        require(to==address(0) || to!=blockedRecipient,"fixture transfer failure");
        super._update(from,to,value);
    }
    constructor() ERC20("GOV MINT Sepolia Test REAL", "govtREAL") {
        require(block.chainid==11155111 || block.chainid==31337,"test chain only");
        owner=msg.sender;
        _mint(msg.sender,100_000_000 ether);
    }
}
contract GOVMINTTestOracle {
    ERC20 public immutable token;
    address public immutable owner;
    address public dao;
    bool public failing;
    function setFailing(bool value) external {require(msg.sender==owner);failing=value;}
    mapping(address=>bool) public excluded;
    constructor(address realToken) {
        require(block.chainid==11155111 || block.chainid==31337,"test chain only");
        token=ERC20(realToken);owner=msg.sender;
    }
    function setDao(address wallet) external {require(msg.sender==owner);dao=wallet;}
    function setExcluded(address wallet,bool value) external {require(msg.sender==owner);excluded[wallet]=value;}
    function getCirculatingSupply() external view returns(uint256) {
        require(!failing,"fixture oracle failure");
        return token.totalSupply()-(dao==address(0)?0:token.balanceOf(dao));
    }
    function isVotingExcluded(address wallet) external view returns(bool) {require(!failing,"fixture oracle failure");return excluded[wallet]||wallet==dao;}
}
