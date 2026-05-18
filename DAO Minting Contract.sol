// SPDX-License-Identifier: MIT

// Real Estate Alliance League, Illinois, USA
// DAO Mint Protocol — Governance & Token Release
// https://ThisIsREAL.io    /    email: support@thisisreal.io
// Controls release of 79,000,000 non-circulating REAL tokens via on-chain governance.
// Only active, circulating token holders control emissions — not the organization.

pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

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

    // ─────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────

    IERC20 public realToken;
    address public deployer;
    address[5] public authorizedWallets;

    // Excluded wallets for circulating supply calculation
    address[] public excludedWalletList;
    mapping(address => bool) public isExcludedWallet;

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
    event ExcludedWalletAdded(address indexed wallet);
    event ExcludedWalletRemoved(address indexed wallet);
    event ActionSigned(bytes32 indexed actionId, address indexed signer, uint256 signatureCount);
    event AuthorizedWalletUpdated(uint256 indexed index, address oldWallet, address newWallet);

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
        address[5] memory _authorizedWallets,
        address[] memory _initialExcludedWallets
    ) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(_realToken != address(0), "DAO: invalid token address");

        realToken = IERC20(_realToken);
        deployer = msg.sender;
        authorizedWallets = _authorizedWallets;

        for (uint256 i = 0; i < _initialExcludedWallets.length; i++) {
            address wallet = _initialExcludedWallets[i];
            if (wallet != address(0) && !isExcludedWallet[wallet]) {
                isExcludedWallet[wallet] = true;
                excludedWalletList.push(wallet);
            }
        }
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
        uint256 circulatingSnapshot = getCirculatingSupply();

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

        // Verify Merkle proof: leaf = keccak256(abi.encodePacked(voter, votingPower))
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, _votingPower));
        require(
            MerkleProof.verify(_merkleProof, proposal.merkleRoot, leaf),
            "DAO: invalid merkle proof"
        );

        hasVoted[_proposalId][msg.sender] = true;

        if (_support) {
            proposal.yesVotes += _votingPower;
        } else {
            proposal.noVotes += _votingPower;
        }

        emit VoteCast(_proposalId, msg.sender, _support, _votingPower);
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
    // Circulating Supply Calculation
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Calculate circulating supply by subtracting excluded wallets from total supply.
     *         Excluded wallets include: this contract (DAO vault), vesting wallets,
     *         sale contract, free contract, organization wallets, burn address.
     */
    function getCirculatingSupply() public view returns (uint256) {
        uint256 totalSupply = realToken.totalSupply();
        uint256 excludedBalance = 0;

        for (uint256 i = 0; i < excludedWalletList.length; i++) {
            excludedBalance += realToken.balanceOf(excludedWalletList[i]);
        }

        // Also exclude tokens held by this contract (the DAO vault itself)
        excludedBalance += realToken.balanceOf(address(this));

        if (excludedBalance >= totalSupply) {
            return 0;
        }
        return totalSupply - excludedBalance;
    }

    /**
     * @notice Get the voting power for a given token balance.
     * @param _balance Raw REAL token balance (in wei, 18 decimals)
     * @return Number of votes (1 vote per 1,000 REAL)
     */
    function getVotingPower(uint256 _balance) public pure returns (uint256) {
        return _balance / TOKENS_PER_VOTE;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin Functions (Deployer Only)
    // ─────────────────────────────────────────────────────────────────────

    function addExcludedWallet(address _wallet) external onlyDeployer {
        require(_wallet != address(0), "DAO: zero address");
        require(!isExcludedWallet[_wallet], "DAO: already excluded");

        isExcludedWallet[_wallet] = true;
        excludedWalletList.push(_wallet);

        emit ExcludedWalletAdded(_wallet);
    }

    function removeExcludedWallet(address _wallet) external onlyDeployer {
        require(isExcludedWallet[_wallet], "DAO: not excluded");

        isExcludedWallet[_wallet] = false;

        // Remove from array (swap and pop)
        for (uint256 i = 0; i < excludedWalletList.length; i++) {
            if (excludedWalletList[i] == _wallet) {
                excludedWalletList[i] = excludedWalletList[excludedWalletList.length - 1];
                excludedWalletList.pop();
                break;
            }
        }

        emit ExcludedWalletRemoved(_wallet);
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

    function getProposalStatus(uint256 _proposalId) public view returns (ProposalStatus) {
        require(_proposalId < proposalCount, "DAO: invalid proposal");
        Proposal storage proposal = proposals[_proposalId];

        if (proposal.cancelled) return ProposalStatus.Cancelled;
        if (proposal.executed) return ProposalStatus.Executed;
        if (block.timestamp < proposal.votingStart) return ProposalStatus.Pending;
        if (block.timestamp <= proposal.votingEnd) return ProposalStatus.Active;

        // Voting has ended — check if passed
        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
        uint256 quorumThreshold = (proposal.circulatingSupplySnapshot * QUORUM_BPS) /
            (10000 * TOKENS_PER_VOTE);

        bool quorumMet = totalVotes >= quorumThreshold;
        bool approvalMet = totalVotes > 0 &&
            (proposal.yesVotes * 10000 >= totalVotes * APPROVAL_BPS);

        if (quorumMet && approvalMet) return ProposalStatus.Passed;
        return ProposalStatus.Failed;
    }

    function getProposalDetails(uint256 _proposalId)
        external
        view
        returns (
            address proposer,
            address recipient,
            uint256 amount,
            bytes32 merkleRoot,
            uint256 circulatingSupplySnapshot,
            uint256 votingStart,
            uint256 votingEnd,
            uint256 yesVotes,
            uint256 noVotes,
            ProposalStatus status
        )
    {
        require(_proposalId < proposalCount, "DAO: invalid proposal");
        Proposal storage p = proposals[_proposalId];
        return (
            p.proposer,
            p.recipient,
            p.amount,
            p.merkleRoot,
            p.circulatingSupplySnapshot,
            p.votingStart,
            p.votingEnd,
            p.yesVotes,
            p.noVotes,
            getProposalStatus(_proposalId)
        );
    }

    function getQuorumThreshold(uint256 _proposalId) external view returns (uint256) {
        require(_proposalId < proposalCount, "DAO: invalid proposal");
        return (proposals[_proposalId].circulatingSupplySnapshot * QUORUM_BPS) /
            (10000 * TOKENS_PER_VOTE);
    }

    function getVaultBalance() external view returns (uint256) {
        return realToken.balanceOf(address(this));
    }

    function getExcludedWallets() external view returns (address[] memory) {
        return excludedWalletList;
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
