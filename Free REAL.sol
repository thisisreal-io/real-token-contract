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
    uint256 public hardcap;
    uint256 public totalClaimed;
    uint256 claimableAmt;
    IERC20 public real;

    mapping(address => bool) public userClaimed;

    // Multisig infrastructure
    address[5] public signers;
    uint256 public constant REQUIRED_SIGNATURES = 3;
    uint256 public constant PROPOSAL_EXPIRY = 14 days;
    address public mainDepositWallet;

    mapping(bytes32 => mapping(address => bool)) public proposalSignatures;
    mapping(bytes32 => uint256) public proposalSignatureCount;
    mapping(bytes32 => uint256) public proposalCreatedAt;

    struct WithdrawalQueue {
        uint256 amount;
        bool executed;
    }
    mapping(bytes32 => WithdrawalQueue) public withdrawalQueue;

    event REALClaimed(
        address indexed _user,
        uint256 _amount,
        uint256 _timeStamp
    );

    event REALWithdrawn(uint256 _amount);
    event WithdrawalQueued(bytes32 indexed proposalId, uint256 amount);
    event WithdrawalExecuted(bytes32 indexed proposalId, uint256 amount);
    event ProposalSigned(bytes32 indexed proposalId, address indexed signer);

    modifier onlySigner() {
        require(isSigner(msg.sender), "FreeREAL: Not a signer");
        _;
    }

    constructor(
        address _real,
        uint256 _claimableAmt,
        uint256 _hardCAP,
        address _mainDepositWallet,
        address[5] memory _signers
    ) Ownable(msg.sender) {
        real = IERC20(_real);
        claimableAmt = _claimableAmt;
        hardcap = _hardCAP;
        mainDepositWallet = _mainDepositWallet;
        
        require(_signers.length == 5, "FreeREAL: Must provide exactly 5 signers");
        for (uint256 i = 0; i < 5; i++) {
            require(_signers[i] != address(0), "FreeREAL: Signer cannot be zero address");
            signers[i] = _signers[i];
        }
    }

    function isSigner(address _address) public view returns (bool) {
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == _address) {
                return true;
            }
        }
        return false;
    }

    function getProposalId(uint256 _amount, bytes32 _nonce) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_amount, _nonce));
    }

    function hasRequiredSignatures(bytes32 _proposalId) public view returns (bool) {
        return proposalSignatureCount[_proposalId] >= REQUIRED_SIGNATURES;
    }

    function isProposalExpired(bytes32 _proposalId) public view returns (bool) {
        if (proposalCreatedAt[_proposalId] == 0) {
            return false;
        }
        return block.timestamp > proposalCreatedAt[_proposalId] + PROPOSAL_EXPIRY;
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
        require(totalClaimed + claimableAmt <= hardcap, "Claim exceeds hard cap");

        totalClaimed += claimableAmt;
        userClaimed[msg.sender] = true;

        SafeERC20.safeTransfer(real, msg.sender, claimableAmt);

        emit REALClaimed(msg.sender, claimableAmt, block.timestamp);
    }

    function pause() external whenNotPaused onlySigner {
        _pause();
    }

    function unpause() external whenPaused onlySigner {
        _unpause();
    }

    function withdrawREAL(uint256 amount, bytes32 nonce) external onlySigner {
        require(amount > 0, "FreeREAL: Withdraw amount must be greater than zero");
        require(
            real.balanceOf(address(this)) >= amount,
            "FreeREAL: Not enough REAL in contract"
        );
        bytes32 proposalId = getProposalId(amount, nonce);

        if (proposalCreatedAt[proposalId] > 0) {
            require(!isProposalExpired(proposalId), "FreeREAL: Proposal expired");
        }

        if (!proposalSignatures[proposalId][msg.sender]) {
            proposalSignatures[proposalId][msg.sender] = true;
            proposalSignatureCount[proposalId]++;
            if (proposalCreatedAt[proposalId] == 0) {
                proposalCreatedAt[proposalId] = block.timestamp;
            }
            emit ProposalSigned(proposalId, msg.sender);
        }
        if (!hasRequiredSignatures(proposalId)) {
            return;
        }
        if (!withdrawalQueue[proposalId].executed) {
            withdrawalQueue[proposalId] = WithdrawalQueue({
                amount: amount,
                executed: false
            });
            emit WithdrawalQueued(proposalId, amount);
            
            // Automatically transfer to main deposit wallet when queued
            SafeERC20.safeTransfer(IERC20(address(real)), mainDepositWallet, amount);
            withdrawalQueue[proposalId].executed = true;
            emit REALWithdrawn(amount);
            emit WithdrawalExecuted(proposalId, amount);
        }
    }
}
