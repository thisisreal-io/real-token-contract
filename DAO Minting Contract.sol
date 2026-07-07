// SPDX-License-Identifier: MIT

// Real Estate Alliance League, Illinois, USA
// DAO Mint Protocol — Governance & Token Release
// https://ThisIsREAL.io    /    email: support@thisisreal.io
// Controls release of 79,000,000 non-circulating REAL tokens via on-chain governance.
// Only active, circulating token holders control emissions — not the organization.

pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable@5.1.0/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable@5.1.0/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@5.1.0/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts@5.1.0/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@5.1.0/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts@5.1.0/utils/cryptography/MerkleProof.sol";

interface ICirculatingSupplyOracle {
    function getCirculatingSupply() external view returns (uint256);
    function isVotingExcluded(address _wallet) external view returns (bool);
}

contract DAOMintProtocol is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────

    uint256 public constant MAX_UNLOCK_PER_PROPOSAL = 1_000_000 * 1e18;
    uint256 public constant TIMELOCK_DURATION = 30 days;
    uint256 public constant COOLDOWN_DURATION = 90 days;
    uint256 public constant MAX_VOTING_PERIOD = 30 days;
    uint256 public constant TOKENS_PER_VOTE = 1_000 * 1e18;
    uint256 public constant QUORUM_BPS = 1500; // 15%
    uint256 public constant APPROVAL_BPS = 5100; // 51%
    uint256 public constant REQUIRED_SIGNATURES = 3;
    uint256 public constant TOTAL_SIGNERS = 5;
    uint256 public constant MIN_VOTERS = 10; // Minimum unique voters required (10 for testing, increase to 1000 for production)
    uint256 public constant MAX_VOTE_POWER_BPS = 500; // 5% max voting power per user (relative to circulating supply in vote units)

    // ─────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────

    IERC20 public realToken;
    ICirculatingSupplyOracle public supplyOracle;
    address public deployer;
    address[5] public authorizedWallets;

    // Proposals
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // Cooldown: tracks when the last proposal was approved
    uint256 public lastApprovalTimestamp;

    // System-wide pause (requires 3-of-5)
    bool public systemPaused;

    // Multisig action tracking for pause/unpause
    mapping(bytes32 => mapping(address => bool)) public actionSignatures;
    mapping(bytes32 => uint256) public actionSignatureCount;
    mapping(bytes32 => bool) public actionExecuted;

    // Per-proposal pause
    mapping(uint256 => bool) public proposalPaused;

    // ─────────────────────────────────────────────────────────────────────
    // Structs & Enums
    // ─────────────────────────────────────────────────────────────────────

    enum ProposalStatus {
        Pending,    // Created but voting not started
        Active,     // Voting in progress
        Passed,     // Quorum + approval met, in timelock
        Failed,     // Quorum or approval not met
        Executed,   // Tokens released
        Cancelled   // Cancelled by proposer before voting starts
    }

    struct Proposal {
        address proposer;
        address recipient;
        uint256 amount;
        bytes32 merkleRoot;
        uint256 circulatingSupplySnapshot;
        uint256 votingStart;
        uint256 votingEnd;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 voterCount;
        bool executed;
        bool cancelled;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address recipient,
        uint256 amount,
        bytes32 merkleRoot,
        uint256 votingStart,
        uint256 votingEnd,
        uint256 circulatingSupplySnapshot
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 votingPower
    );
    event ProposalExecuted(
        uint256 indexed proposalId,
        address indexed recipient,
        uint256 amount
    );
    event ProposalCancelled(uint256 indexed proposalId);
    event SystemPaused(bytes32 indexed actionId, address indexed triggeredBy);
    event SystemUnpaused(bytes32 indexed actionId, address indexed triggeredBy);
    event ProposalPausedEvent(uint256 indexed proposalId, bytes32 indexed actionId);
    event ProposalUnpausedEvent(uint256 indexed proposalId, bytes32 indexed actionId);
    event ActionSigned(bytes32 indexed actionId, address indexed signer, uint256 signatureCount);
    event AuthorizedWalletUpdated(uint256 indexed index, address oldWallet, address newWallet);
    event SupplyOracleUpdated(address oldOracle, address newOracle);

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyDeployer() {
        require(msg.sender == deployer, "DAO: only deployer");
        _;
    }

    modifier onlyAuthorized() {
        require(_isAuthorized(msg.sender), "DAO: not authorized wallet");
        _;
    }

    modifier whenSystemNotPaused() {
        require(!systemPaused, "DAO: system is paused");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Initializer (replaces constructor for upgradeable pattern)
    // ─────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _realToken,
        address _supplyOracle,
        address[5] memory _authorizedWallets
    ) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(_realToken != address(0), "DAO: invalid token address");
        require(_supplyOracle != address(0), "DAO: invalid oracle address");

        realToken = IERC20(_realToken);
        supplyOracle = ICirculatingSupplyOracle(_supplyOracle);
        deployer = msg.sender;
        authorizedWallets = _authorizedWallets;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Proposal Creation (Restricted to 5 Authorized Wallets)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a new governance proposal to release tokens from the DAO vault.
     * @param _recipient Wallet that receives tokens if proposal passes
     * @param _amount Amount of REAL tokens requested (max 1,000,000)
     * @param _merkleRoot Merkle root of eligible voters (address, votingPower) pairs.
     *        Computed off-chain: only wallets holding REAL for 30+ days at snapshot.
     *        MUST exclude vesting/vNFT holders, the DAO wallet, and all SAFE/Corp team
     *        wallets — see the oracle's isVotingExcluded() and VestingFactory.deployedContracts.
     * @param _votingStart Unix timestamp when voting begins
     * @param _votingEnd Unix timestamp when voting ends (must be < 30 days from start)
     */
    function createProposal(
        address _recipient,
        uint256 _amount,
        bytes32 _merkleRoot,
        uint256 _votingStart,
        uint256 _votingEnd
    ) external onlyAuthorized whenSystemNotPaused returns (uint256) {
        require(_recipient != address(0), "DAO: invalid recipient");
        require(_amount > 0 && _amount <= MAX_UNLOCK_PER_PROPOSAL, "DAO: amount exceeds max 1M");
        require(_amount <= realToken.balanceOf(address(this)), "DAO: insufficient vault balance");
        require(_merkleRoot != bytes32(0), "DAO: invalid merkle root");
        require(_votingStart >= block.timestamp, "DAO: voting start must be in future");
        require(_votingEnd > _votingStart, "DAO: end must be after start");
        require(_votingEnd - _votingStart <= MAX_VOTING_PERIOD, "DAO: voting period exceeds 30 days");

        // Cooldown enforcement: 90 days must pass since last approval
        if (lastApprovalTimestamp > 0) {
            require(
                block.timestamp >= lastApprovalTimestamp + COOLDOWN_DURATION,
                "DAO: 90-day cooldown not elapsed"
            );
        }

        uint256 proposalId = proposalCount++;
        uint256 circulatingSnapshot = supplyOracle.getCirculatingSupply();

        proposals[proposalId] = Proposal({
            proposer: msg.sender,
            recipient: _recipient,
            amount: _amount,
            merkleRoot: _merkleRoot,
            circulatingSupplySnapshot: circulatingSnapshot,
            votingStart: _votingStart,
            votingEnd: _votingEnd,
            yesVotes: 0,
            noVotes: 0,
            voterCount: 0,
            executed: false,
            cancelled: false
        });

        emit ProposalCreated(
            proposalId,
            msg.sender,
            _recipient,
            _amount,
            _merkleRoot,
            _votingStart,
            _votingEnd,
            circulatingSnapshot
        );

        return proposalId;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Voting (Merkle Proof Verified)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Cast a vote on an active proposal.
     * @param _proposalId ID of the proposal to vote on
     * @param _support true = YES, false = NO
     * @param _votingPower The voter's power (number of votes), proven by Merkle proof.
     *        Computed off-chain as: (eligible REAL balance) / 1000
     * @param _merkleProof Proof that (msg.sender, _votingPower) is in the proposal's Merkle tree
     */
    function castVote(
        uint256 _proposalId,
        bool _support,
        uint256 _votingPower,
        bytes32[] calldata _merkleProof
    ) external whenSystemNotPaused nonReentrant {
        Proposal storage proposal = proposals[_proposalId];

        require(!proposal.cancelled, "DAO: proposal cancelled");
        require(!proposalPaused[_proposalId], "DAO: proposal is paused");
        require(block.timestamp >= proposal.votingStart, "DAO: voting not started");
        require(block.timestamp <= proposal.votingEnd, "DAO: voting ended");
        require(!hasVoted[_proposalId][msg.sender], "DAO: already voted");
        require(_votingPower > 0, "DAO: zero voting power");

        // On-chain guard (defense in depth): SAFE/Corp (vote-excluded) wallets and the DAO
        // wallet are barred from voting, even if a faulty Merkle root were to include them.
        require(!supplyOracle.isVotingExcluded(msg.sender), "DAO: wallet excluded from voting");

        // Verify Merkle proof: leaf = keccak256(abi.encodePacked(voter, votingPower))
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, _votingPower));
        require(
            MerkleProof.verify(_merkleProof, proposal.merkleRoot, leaf),
            "DAO: invalid merkle proof"
        );

        // Cap voting power at 5% of circulating supply (in vote units)
        uint256 maxPower = (proposal.circulatingSupplySnapshot * MAX_VOTE_POWER_BPS) /
            (10000 * TOKENS_PER_VOTE);
        uint256 effectivePower = _votingPower > maxPower ? maxPower : _votingPower;

        hasVoted[_proposalId][msg.sender] = true;
        proposal.voterCount++;

        if (_support) {
            proposal.yesVotes += effectivePower;
        } else {
            proposal.noVotes += effectivePower;
        }

        emit VoteCast(_proposalId, msg.sender, _support, effectivePower);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Proposal Execution (After Timelock)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Execute a passed proposal after the 30-day timelock.
     *         Anyone can call this (permissionless execution of passed proposals).
     */
    function executeProposal(uint256 _proposalId) external whenSystemNotPaused nonReentrant {
        Proposal storage proposal = proposals[_proposalId];

        require(!proposal.executed, "DAO: already executed");
        require(!proposal.cancelled, "DAO: proposal cancelled");
        require(!proposalPaused[_proposalId], "DAO: proposal is paused");
        require(block.timestamp > proposal.votingEnd, "DAO: voting not ended");

        // Verify minimum unique voters participated
        require(proposal.voterCount >= MIN_VOTERS, "DAO: minimum voter count not met");

        // Verify quorum: total votes >= 15% of circulating supply (in vote units)
        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
        uint256 quorumThreshold = (proposal.circulatingSupplySnapshot * QUORUM_BPS) /
            (10000 * TOKENS_PER_VOTE);
        require(totalVotes >= quorumThreshold, "DAO: quorum not reached");

        // Verify approval: YES votes >= 51% of total votes cast
        require(
            proposal.yesVotes * 10000 >= totalVotes * APPROVAL_BPS,
            "DAO: approval threshold not met"
        );

        // Verify 30-day timelock has passed since voting ended
        require(
            block.timestamp >= proposal.votingEnd + TIMELOCK_DURATION,
            "DAO: 30-day timelock not elapsed"
        );

        // Verify vault has sufficient balance
        require(
            realToken.balanceOf(address(this)) >= proposal.amount,
            "DAO: insufficient vault balance"
        );

        // Effects
        proposal.executed = true;
        lastApprovalTimestamp = proposal.votingEnd;

        // Interaction: transfer tokens to recipient
        realToken.safeTransfer(proposal.recipient, proposal.amount);

        emit ProposalExecuted(_proposalId, proposal.recipient, proposal.amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Proposal Cancellation
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Cancel a proposal. Only the proposer can cancel, and only before voting starts.
     */
    function cancelProposal(uint256 _proposalId) external {
        Proposal storage proposal = proposals[_proposalId];

        require(msg.sender == proposal.proposer, "DAO: only proposer can cancel");
        require(!proposal.cancelled, "DAO: already cancelled");
        require(!proposal.executed, "DAO: already executed");
        require(block.timestamp < proposal.votingStart, "DAO: voting already started");

        proposal.cancelled = true;

        emit ProposalCancelled(_proposalId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Emergency Pause (3-of-5 Multisig)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Sign to pause the entire DAO system. Requires 3 of 5 authorized wallets.
     * @param _nonce Unique identifier for this pause action (prevents replay)
     */
    function signPauseSystem(bytes32 _nonce) external onlyAuthorized {
        bytes32 actionId = keccak256(abi.encodePacked("PAUSE_SYSTEM", _nonce));
        require(!actionExecuted[actionId], "DAO: action already executed");

        if (!actionSignatures[actionId][msg.sender]) {
            actionSignatures[actionId][msg.sender] = true;
            actionSignatureCount[actionId]++;
            emit ActionSigned(actionId, msg.sender, actionSignatureCount[actionId]);
        }

        if (actionSignatureCount[actionId] >= REQUIRED_SIGNATURES && !systemPaused) {
            systemPaused = true;
            actionExecuted[actionId] = true;
            emit SystemPaused(actionId, msg.sender);
        }
    }

    /**
     * @notice Sign to unpause the entire DAO system. Requires 3 of 5 authorized wallets.
     */
    function signUnpauseSystem(bytes32 _nonce) external onlyAuthorized {
        bytes32 actionId = keccak256(abi.encodePacked("UNPAUSE_SYSTEM", _nonce));
        require(!actionExecuted[actionId], "DAO: action already executed");

        if (!actionSignatures[actionId][msg.sender]) {
            actionSignatures[actionId][msg.sender] = true;
            actionSignatureCount[actionId]++;
            emit ActionSigned(actionId, msg.sender, actionSignatureCount[actionId]);
        }

        if (actionSignatureCount[actionId] >= REQUIRED_SIGNATURES && systemPaused) {
            systemPaused = false;
            actionExecuted[actionId] = true;
            emit SystemUnpaused(actionId, msg.sender);
        }
    }

    /**
     * @notice Sign to pause a specific proposal. Requires 3 of 5 authorized wallets.
     */
    function signPauseProposal(uint256 _proposalId, bytes32 _nonce) external onlyAuthorized {
        require(_proposalId < proposalCount, "DAO: invalid proposal");
        bytes32 actionId = keccak256(abi.encodePacked("PAUSE_PROPOSAL", _proposalId, _nonce));
        require(!actionExecuted[actionId], "DAO: action already executed");

        if (!actionSignatures[actionId][msg.sender]) {
            actionSignatures[actionId][msg.sender] = true;
            actionSignatureCount[actionId]++;
            emit ActionSigned(actionId, msg.sender, actionSignatureCount[actionId]);
        }

        if (actionSignatureCount[actionId] >= REQUIRED_SIGNATURES && !proposalPaused[_proposalId]) {
            proposalPaused[_proposalId] = true;
            actionExecuted[actionId] = true;
            emit ProposalPausedEvent(_proposalId, actionId);
        }
    }

    /**
     * @notice Sign to unpause a specific proposal. Requires 3 of 5 authorized wallets.
     */
    function signUnpauseProposal(uint256 _proposalId, bytes32 _nonce) external onlyAuthorized {
        require(_proposalId < proposalCount, "DAO: invalid proposal");
        bytes32 actionId = keccak256(abi.encodePacked("UNPAUSE_PROPOSAL", _proposalId, _nonce));
        require(!actionExecuted[actionId], "DAO: action already executed");

        if (!actionSignatures[actionId][msg.sender]) {
            actionSignatures[actionId][msg.sender] = true;
            actionSignatureCount[actionId]++;
            emit ActionSigned(actionId, msg.sender, actionSignatureCount[actionId]);
        }

        if (actionSignatureCount[actionId] >= REQUIRED_SIGNATURES && proposalPaused[_proposalId]) {
            proposalPaused[_proposalId] = false;
            actionExecuted[actionId] = true;
            emit ProposalUnpausedEvent(_proposalId, actionId);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin Functions (Deployer Only)
    // ─────────────────────────────────────────────────────────────────────

    function updateSupplyOracle(address _newOracle) external onlyDeployer {
        require(_newOracle != address(0), "DAO: zero address");

        address oldOracle = address(supplyOracle);
        supplyOracle = ICirculatingSupplyOracle(_newOracle);

        emit SupplyOracleUpdated(oldOracle, _newOracle);
    }

    function updateAuthorizedWallet(uint256 _index, address _newWallet) external onlyDeployer {
        require(_index < TOTAL_SIGNERS, "DAO: invalid index");
        require(_newWallet != address(0), "DAO: zero address");

        address oldWallet = authorizedWallets[_index];
        authorizedWallets[_index] = _newWallet;

        emit AuthorizedWalletUpdated(_index, oldWallet, _newWallet);
    }

    // ─────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────

    function getCirculatingSupply() public view returns (uint256) {
        return supplyOracle.getCirculatingSupply();
    }

    function getProposalStatus(uint256 _proposalId) public view returns (ProposalStatus) {
        require(_proposalId < proposalCount, "DAO: invalid proposal");
        Proposal storage proposal = proposals[_proposalId];

        if (proposal.cancelled) return ProposalStatus.Cancelled;
        if (proposal.executed) return ProposalStatus.Executed;
        if (block.timestamp < proposal.votingStart) return ProposalStatus.Pending;
        if (block.timestamp <= proposal.votingEnd) return ProposalStatus.Active;

        // Voting has ended — check if passed
        if (proposal.voterCount < MIN_VOTERS) return ProposalStatus.Failed;

        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
        uint256 quorumThreshold = (proposal.circulatingSupplySnapshot * QUORUM_BPS) /
            (10000 * TOKENS_PER_VOTE);

        bool quorumMet = totalVotes >= quorumThreshold;
        bool approvalMet = totalVotes > 0 &&
            (proposal.yesVotes * 10000 >= totalVotes * APPROVAL_BPS);

        if (quorumMet && approvalMet) return ProposalStatus.Passed;
        return ProposalStatus.Failed;
    }

    function getProposalDetails(uint256 _proposalId) external view returns (Proposal memory) {
        require(_proposalId < proposalCount, "DAO: invalid proposal");
        return proposals[_proposalId];
    }

    function getQuorumThreshold(uint256 _proposalId) external view returns (uint256) {
        require(_proposalId < proposalCount, "DAO: invalid proposal");
        return (proposals[_proposalId].circulatingSupplySnapshot * QUORUM_BPS) /
            (10000 * TOKENS_PER_VOTE);
    }

    function getVaultBalance() external view returns (uint256) {
        return realToken.balanceOf(address(this));
    }

    function getTimeUntilExecution(uint256 _proposalId) external view returns (uint256) {
        require(_proposalId < proposalCount, "DAO: invalid proposal");
        Proposal storage proposal = proposals[_proposalId];
        uint256 executableAt = proposal.votingEnd + TIMELOCK_DURATION;
        if (block.timestamp >= executableAt) return 0;
        return executableAt - block.timestamp;
    }

    function getCooldownRemaining() external view returns (uint256) {
        if (lastApprovalTimestamp == 0) return 0;
        uint256 cooldownEnd = lastApprovalTimestamp + COOLDOWN_DURATION;
        if (block.timestamp >= cooldownEnd) return 0;
        return cooldownEnd - block.timestamp;
    }

    function isAuthorizedWallet(address _wallet) public view returns (bool) {
        return _isAuthorized(_wallet);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal Functions
    // ─────────────────────────────────────────────────────────────────────

    function _isAuthorized(address _wallet) internal view returns (bool) {
        for (uint256 i = 0; i < TOTAL_SIGNERS; i++) {
            if (authorizedWallets[i] == _wallet) return true;
        }
        return false;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyDeployer {}
}
