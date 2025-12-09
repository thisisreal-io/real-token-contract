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
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract FreeREAL is Ownable, ReentrancyGuard, Pausable {
    uint256 public hardcap;
    uint256 public totalClaimed;
    uint256 public claimableAmt;
    IERC20 public real;

    mapping(address => bool) public userClaimed;

    // Signature verification for claims
    address public signerAddress;
    mapping(address => uint256) public nonces;

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

    constructor() Ownable(msg.sender) {
        // REAL token mainnet address
        real = IERC20(0x325Aa344761c19F7ab6dc45A95f01d6907A30DCA);
        
        // Claimable amount: 1 REAL token (1 * 10^18 wei)
        claimableAmt = 1 ether;
        
        // Hardcap: 5000 REAL tokens (5000 * 10^18 wei)
        hardcap = 5000 ether;
        
        // Deposit Address: Org Corp Operations
        mainDepositWallet = 0xBc3B0Bdead411d8034b6DAC49e2e666dA8779D16;
        
        // Signer Address: Contract Creator Wallet (for signature verification)
        signerAddress = 0x4106E21F155383DfB947b44e2A846405Cd7837A6;
        
        // Multisig signers (5 addresses)
        signers[0] = 0x4106E21F155383DfB947b44e2A846405Cd7837A6; // Contract Creator Wallet
        signers[1] = 0x2438d494751cFeB9551342be64D3F7C645975067; // Acquisitions
        signers[2] = 0xeCCb924aFec718a2cB0a4546D6569c9E4F825177; // Org Team Development
        signers[3] = 0xBc3B0Bdead411d8034b6DAC49e2e666dA8779D16; // Org Corp Operations
        signers[4] = 0x6C62EE2e74F5B80b83652E5aA4d6Cd4D8F99A583; // Liquidity Pool
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

    /**
     * @dev Reconstructs the message hash that the backend signed
     * @param _user Address of the user claiming
     * @param _amount Amount to claim (claimableAmt)
     * @param _nonce Nonce for this claim
     * @return Message hash that should be signed by backend
     */
    function _getMessageHash(
        address _user,
        uint256 _amount,
        uint256 _nonce
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    keccak256(
                        abi.encodePacked(_user, _amount, _nonce, address(this))
                    )
                )
            );
    }

    /**
     * @dev Verifies that the signature was created by the backend signer
     * @param _messageHash The message hash that was signed
     * @param _signature The signature to verify
     * @return True if signature is valid, false otherwise
     */
    function _verifySignature(
        bytes32 _messageHash,
        bytes memory _signature
    ) internal view returns (bool) {
        address recoveredSigner = ECDSA.recover(_messageHash, _signature);
        return recoveredSigner == signerAddress;
    }

    function claimREAL(bytes memory signature, uint256 nonce) external whenNotPaused nonReentrant {
        require(!userClaimed[msg.sender], "Free tokens already claimed");
        require(nonce == nonces[msg.sender], "FreeREAL: Invalid nonce");
        require(claimableAmt > 0, "Set claimable amount");
        require(
            real.balanceOf(address(this)) >= claimableAmt,
            "Contract have less REAL balance"
        );
        require(totalClaimed + claimableAmt <= hardcap, "Claim exceeds hard cap");

        // Reconstruct the message hash that backend signed
        bytes32 messageHash = _getMessageHash(msg.sender, claimableAmt, nonce);
        
        // Verify the signature
        require(_verifySignature(messageHash, signature), "FreeREAL: Invalid signature");

        // Increment nonce for next claim (prevents replay attacks)
        nonces[msg.sender]++;

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
