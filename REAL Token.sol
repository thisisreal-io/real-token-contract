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
import {ReentrancyGuard} from "@openzeppelin/contracts@5.2.0/utils/ReentrancyGuard.sol";

contract Real_Estate_Alliance_League is ERC20, ERC20Burnable, Ownable, ReentrancyGuard {
    uint256 public constant MAX_SUPPLY = 100000000 * 10 ** 18;
    uint256 public constant PRE_MINTED_SUPPLY = 21000000 * 10 ** 18;
    uint256 public mintedSupply = 0;
    
    // Preminted token recipients (SAFE wallets)
    address public immutable address1; // Acquisitions
    address public immutable address2; // Org Corp Operations
    address public immutable address3; // Org Team Develop
    address public immutable address4; // Liquidity Pool Fund
    address public immutable address5; // Staking Fund
    address public immutable address6; // Founding Team & Contributors
    address public immutable address7; // Seed Investor — bbdc.io
    address public immutable address8; // Seed Investor — rix.us

    // Multisig infrastructure for minting (for remaining 79M tokens)
    address[5] public signers;
    uint256 public constant REQUIRED_SIGNATURES = 3; // 3 out of 5 signers must approve
    uint256 public constant PROPOSAL_EXPIRY = 14 days; // Proposals expire after 14 days
    uint256 public constant MINT_TIMELOCK = 30 days; // 30-day delay after 3 signatures before execution

    // Multisig proposal tracking
    mapping(bytes32 => mapping(address => bool)) public proposalSignatures; // Tracks which signers have signed each proposal
    mapping(bytes32 => uint256) public proposalSignatureCount; // Count of signatures for each proposal
    mapping(bytes32 => uint256) public proposalCreatedAt; // Timestamp when proposal was first created
    mapping(bytes32 => uint256) public proposalTimelockStart; // Timestamp when timelock started (after 3rd signature)
    mapping(bytes32 => bool) public mintProposalExecuted; // Tracks if mint proposal has been executed

    // Events
    event MintProposalCreated(bytes32 indexed proposalId, address indexed to, uint256 amount, bytes32 nonce);
    event MintProposalSigned(bytes32 indexed proposalId, address indexed signer);
    event MintTimelockStarted(bytes32 indexed proposalId, uint256 timelockStart);
    event TokensMinted(bytes32 indexed proposalId, address indexed to, uint256 amount);

    modifier onlySigner() {
        require(isSigner(msg.sender), "REAL: Not a signer");
        _;
    }

    constructor(address initialOwner)
        ERC20("Real Estate Alliance League", "REAL")
        Ownable(initialOwner)
    {
        // Set preminted token recipients (SAFE wallets)
        address1 = 0xa8b320A9f5ADA069b35cab9dC5901d167Dd155D6;  // Acquisitions
        address2 = 0x505c90447b06Af58FB7F745FcF29298393deA073;  // Org Corp Operations
        address3 = 0xa28903344a0C602A772F3E4FAEff9343474ad947;  // Org Team Develop
        address4 = 0xd9Dbdded9e5d4Ef7dbBDD06CE488F30f7B144300;  // Liquidity Pool Fund
        address5 = 0x6B5dbA8ba898f5D313A7ae379d31a3B133D77525;  // Staking Fund
        address6 = 0xD059F10963222AA62579e625fe35e945A6bca08c;  // Founding Team & Contributors
        address7 = 0x1967Fc0975E5482f009239C2253F38Ff49DbBDa7;  // Seed Investor — bbdc.io
        address8 = 0x2e960Dbd898bE6F0838736042b20B9d4f5cc6A60;  // Seed Investor — rix.us

        // Mint preminted tokens (21M tokens - no multisig needed)
        _mint(address1, 14200000 * 10 ** 18);
        _mint(address2, 1000000 * 10 ** 18);
        _mint(address3, 1000000 * 10 ** 18);
        _mint(address4, 2000000 * 10 ** 18);
        _mint(address5, 900000 * 10 ** 18);
        _mint(address6, 900000 * 10 ** 18);
        _mint(address7, 500000 * 10 ** 18);
        _mint(address8, 500000 * 10 ** 18);
        mintedSupply = PRE_MINTED_SUPPLY;

        // Set multisig signers for minting remaining 79M tokens
        signers[0] = 0x4106E21F155383DfB947b44e2A846405Cd7837A6; // Contract Creator Wallet
        signers[1] = 0x2438d494751cFeB9551342be64D3F7C645975067; // Acquisitions
        signers[2] = 0xeCCb924aFec718a2cB0a4546D6569c9E4F825177; // Org Team Development
        signers[3] = 0xBc3B0Bdead411d8034b6DAC49e2e666dA8779D16; // Org Corp Operations
        signers[4] = 0x6C62EE2e74F5B80b83652E5aA4d6Cd4D8F99A583; // Liquidity Pool
    }

    // Helper function to check if address is one of the 5 signers
    function isSigner(address _address) public view returns (bool) {
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == _address) {
                return true;
            }
        }
        return false;
    }

    // Generate unique proposal ID from recipient, amount, and nonce
    function getProposalId(address _to, uint256 _amount, bytes32 _nonce) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_to, _amount, _nonce));
    }

    // Check if proposal has required signatures (3 out of 5)
    function hasRequiredSignatures(bytes32 _proposalId) public view returns (bool) {
        return proposalSignatureCount[_proposalId] >= REQUIRED_SIGNATURES;
    }

    // Check if proposal has expired (14 days after creation)
    function isProposalExpired(bytes32 _proposalId) public view returns (bool) {
        if (proposalCreatedAt[_proposalId] == 0) {
            return false;
        }
        return block.timestamp > proposalCreatedAt[_proposalId] + PROPOSAL_EXPIRY;
    }

    // Check if 30-day timelock has passed since 3rd signature
    function isTimelockPassed(bytes32 _proposalId) public view returns (bool) {
        if (proposalTimelockStart[_proposalId] == 0) {
            return false;
        }
        return block.timestamp >= proposalTimelockStart[_proposalId] + MINT_TIMELOCK;
    }

    /**
     * @dev Propose and sign a mint operation using multisig with 30-day timelock
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint
     * @param nonce Unique nonce to prevent replay attacks
     * @notice This function requires 3 out of 5 signers to approve and a 30-day timelock delay
     */
    function mint(address to, uint256 amount, bytes32 nonce) external onlySigner nonReentrant {
        require(amount > 0, "REAL: Amount must be greater than zero");
        require(mintedSupply + amount <= MAX_SUPPLY, "REAL: Exceeds max supply");
        require(to != address(0), "REAL: Cannot mint to zero address");

        bytes32 proposalId = getProposalId(to, amount, nonce);

        // Check if proposal has expired
        if (proposalCreatedAt[proposalId] > 0) {
            require(!isProposalExpired(proposalId), "REAL: Proposal expired");
        }

        // Record signature if signer hasn't signed this proposal yet
        if (!proposalSignatures[proposalId][msg.sender]) {
            proposalSignatures[proposalId][msg.sender] = true;
            proposalSignatureCount[proposalId]++;
            
            if (proposalCreatedAt[proposalId] == 0) {
                proposalCreatedAt[proposalId] = block.timestamp;
                emit MintProposalCreated(proposalId, to, amount, nonce);
            }
            
            emit MintProposalSigned(proposalId, msg.sender);
            
            // Start timelock when required signatures (3) are reached
            if (hasRequiredSignatures(proposalId) && proposalTimelockStart[proposalId] == 0) {
                proposalTimelockStart[proposalId] = block.timestamp;
                emit MintTimelockStarted(proposalId, block.timestamp);
            }
        }

        // Check if proposal has required signatures
        if (!hasRequiredSignatures(proposalId)) {
            return;
        }

        // Check if timelock has passed
        if (!isTimelockPassed(proposalId)) {
            return;
        }

        // Execute mint if not already executed
        if (!mintProposalExecuted[proposalId]) {
            // Mark as executed before minting (CEI pattern)
            mintProposalExecuted[proposalId] = true;
            
            // Update state before external call
            mintedSupply += amount;
            
            // Mint tokens
            _mint(to, amount);
            
            emit TokensMinted(proposalId, to, amount);
        }
    }
}
