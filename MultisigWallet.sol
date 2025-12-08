// SPDX-License-Identifier: MIT

// Real Estate Alliance League, Illinois, USA
// Multisig Wallet Contract for REAL Token Storage
// https://ThisIsREAL.io    /    support@thisisreal.io

pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MultisigWallet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address[5] public signers;
    uint256 public constant REQUIRED_SIGNATURES = 3;
    uint256 public constant PROPOSAL_EXPIRY = 14 days;
    uint256 public constant TIMELOCK_DURATION = 7 days;
    address public immutable depositAddress;

    modifier onlySigner() {
        require(isSigner(msg.sender), "Not a signer");
        _;
    }

    mapping(bytes32 => mapping(address => bool)) public proposalSignatures;
    mapping(bytes32 => uint256) public proposalSignatureCount;
    mapping(bytes32 => uint256) public proposalCreatedAt;
    mapping(bytes32 => uint256) public proposalTimelockStart;
    mapping(bytes32 => bool) public executed;

    event ProposalCreated(bytes32 indexed proposalId, address indexed token, uint256 amount, bytes32 nonce);
    event ProposalSigned(bytes32 indexed proposalId, address indexed signer);
    event TimelockStarted(bytes32 indexed proposalId, uint256 timelockStart);
    event WithdrawalExecuted(bytes32 indexed proposalId, address indexed token, uint256 amount);

    constructor(address[5] memory _signers, address _depositAddress) {
        require(_depositAddress != address(0), "Invalid deposit address");
        for (uint256 i = 0; i < 5; i++) {
            require(_signers[i] != address(0), "Invalid signer");
            for (uint256 j = i + 1; j < 5; j++) {
                require(_signers[i] != _signers[j], "Duplicate signer");
            }
            signers[i] = _signers[i];
        }
        depositAddress = _depositAddress;
    }

    receive() external payable {}

    function isSigner(address _address) public view returns (bool) {
        for (uint256 i = 0; i < 5; i++) {
            if (signers[i] == _address) return true;
        }
        return false;
    }

    function getProposalId(address _token, uint256 _amount, bytes32 _nonce) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_token, _amount, _nonce));
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

    function isTimelockPassed(bytes32 _proposalId) public view returns (bool) {
        if (proposalTimelockStart[_proposalId] == 0) {
            return false;
        }
        return block.timestamp >= proposalTimelockStart[_proposalId] + TIMELOCK_DURATION;
    }

    function getProposalInfo(bytes32 _proposalId) external view returns (
        uint256 signatureCount,
        uint256 createdAt,
        uint256 timelockStart,
        bool isExecuted,
        bool hasRequiredSigs,
        bool timelockPassed,
        bool expired
    ) {
        return (
            proposalSignatureCount[_proposalId],
            proposalCreatedAt[_proposalId],
            proposalTimelockStart[_proposalId],
            executed[_proposalId],
            hasRequiredSignatures(_proposalId),
            isTimelockPassed(_proposalId),
            isProposalExpired(_proposalId)
        );
    }

    function signProposal(address _token, uint256 _amount, bytes32 _nonce) public onlySigner {
        require(_amount > 0, "Amount must be greater than zero");
        bytes32 proposalId = getProposalId(_token, _amount, _nonce);

        // Check if proposal has expired
        if (proposalCreatedAt[proposalId] > 0) {
            require(!isProposalExpired(proposalId), "Proposal expired");
        }

        // Record signature if signer hasn't signed yet
        require(!proposalSignatures[proposalId][msg.sender], "Already signed");
        proposalSignatures[proposalId][msg.sender] = true;
        proposalSignatureCount[proposalId]++;
        
        if (proposalCreatedAt[proposalId] == 0) {
            proposalCreatedAt[proposalId] = block.timestamp;
            emit ProposalCreated(proposalId, _token, _amount, _nonce);
        }
        
        emit ProposalSigned(proposalId, msg.sender);
        
        // Start timelock when required signatures are reached
        if (proposalSignatureCount[proposalId] == REQUIRED_SIGNATURES && proposalTimelockStart[proposalId] == 0) {
            proposalTimelockStart[proposalId] = block.timestamp;
            emit TimelockStarted(proposalId, block.timestamp);
        }
    }

    function executeWithdrawal(address _token, uint256 _amount, bytes32 _nonce) public onlySigner nonReentrant {
        require(_amount > 0, "Amount must be greater than zero");
        bytes32 proposalId = getProposalId(_token, _amount, _nonce);

        // Check if proposal is ready to execute
        require(!executed[proposalId], "Already executed");
        require(proposalSignatureCount[proposalId] >= REQUIRED_SIGNATURES, "Not enough signatures");
        require(proposalTimelockStart[proposalId] > 0, "Timelock not started");
        require(block.timestamp >= proposalTimelockStart[proposalId] + TIMELOCK_DURATION, "Timelock not passed");
        require(!isProposalExpired(proposalId), "Proposal expired");

        executed[proposalId] = true;

        if (_token == address(0)) {
            require(address(this).balance >= _amount, "Insufficient balance");
            (bool success, ) = payable(depositAddress).call{value: _amount}("");
            require(success, "Transfer failed");
        } else {
            IERC20(_token).safeTransfer(depositAddress, _amount);
        }

        emit WithdrawalExecuted(proposalId, _token, _amount);
    }

    // Convenience function that signs and executes if ready (for backwards compatibility)
    function withdraw(address _token, uint256 _amount, bytes32 _nonce) external onlySigner nonReentrant {
        bytes32 proposalId = getProposalId(_token, _amount, _nonce);
        
        // First, try to sign if not already signed
        if (!proposalSignatures[proposalId][msg.sender]) {
            signProposal(_token, _amount, _nonce);
        }
        
        // Then, try to execute if conditions are met
        if (!executed[proposalId] && 
            proposalSignatureCount[proposalId] >= REQUIRED_SIGNATURES && 
            proposalTimelockStart[proposalId] > 0 &&
            block.timestamp >= proposalTimelockStart[proposalId] + TIMELOCK_DURATION &&
            !isProposalExpired(proposalId)) {
            executeWithdrawal(_token, _amount, _nonce);
        }
    }
}
