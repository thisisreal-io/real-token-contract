// SPDX-License-Identifier: MIT

// Real Estate Alliance League, Illinois, USA
// GOV MINT v2 — DEVELOPMENT DRAFT; see GOV_MINT_V2.md
// Derived from DAO Minting Contract.sol; original file is preserved.
// Merkle eligibility and final production policy are NOT finalized.
// https://ThisIsREAL.io    /    email: support@thisisreal.io
// Controls release of 79,000,000 non-circulating REAL tokens via on-chain governance.
// Only active, circulating token holders control emissions — not the organization.

pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable@5.1.0/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable@5.1.0/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts@5.1.0/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@5.1.0/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts@5.1.0/utils/cryptography/MerkleProof.sol";

interface IGovMintSupplyOracleV2 {
    function getCirculatingSupply() external view returns (uint256);
    function isVotingExcluded(address _wallet) external view returns (bool);
}

contract GOVMINTv2 is Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────

    uint256 public constant MAX_UNLOCK_PER_PROPOSAL = 1_000_000 * 1e18;
    uint256 public constant TIMELOCK_DURATION = 30 days;
    uint256 public constant COOLDOWN_DURATION = 90 days;
    uint256 public constant VOTING_PERIOD = 30 days;
    uint256 public constant HOLDING_PERIOD = 30 days; // Eligibility verification still pending.
    uint256 public constant TOKENS_PER_VOTE = 1_000 * 1e18;
    uint256 public constant QUORUM_BPS = 1500; // 15%
    uint256 public constant APPROVAL_BPS = 5100; // 51%
    uint256 public constant REQUIRED_SIGNATURES = 3;
    uint256 public constant TOTAL_SIGNERS = 5;
    uint256 public constant MIN_VOTERS = 10; // Inherited test value: 10 distinct addresses. Production minimum requires approval.
    uint256 public constant MAX_VOTE_POWER_BPS = 500; // Inherited draft: 5% max voting power per address (relative to circulating supply in vote units)

    // ─────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────

    IERC20 public realToken;
    IGovMintSupplyOracleV2 public supplyOracle;
    address public deployer;
    address[5] public authorizedWallets;

    // Every wallet replacement invalidates proposals and approvals from older groups.
    // Historical corporate signer wallets never acquire public voting power on removal.
    mapping(address => bool) public corporateWallet;
    uint256 public systemPauseRevision;
    mapping(uint256 => uint256) public proposalPauseRevision;
    uint256 public signerEpoch;
    uint256 public replacementCount;
    uint256 public totalReleased;
    uint256 public constant MAX_TOTAL_RELEASE = 79_000_000 ether;
    mapping(uint256 => uint256) public proposalEpoch;
    mapping(uint256 => uint256) public proposalApprovalCount;
    mapping(uint256 => mapping(address => bool)) public proposalApprovedBy;
    mapping(uint256 => WalletReplacement) public walletReplacements;
    mapping(uint256 => mapping(address => bool)) public replacementApprovedBy;
    struct WalletReplacement {
        uint256 index;
        address oldWallet;
        address newWallet;
        uint256 epoch;
        uint256 approvals;
        bool executed;
    }
    event WalletReplacementRequested(uint256 indexed id, address indexed oldWallet, address indexed newWallet, uint256 epoch);
    event WalletReplacementApproved(uint256 indexed id, address indexed signer, uint256 approvals);
    event VotingOpened(uint256 indexed id, uint256 start, uint256 end);
    event ProposalApproved(uint256 indexed id, address indexed signer, uint256 approvals);
    // Proposals
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // Cooldown: actual timestamp of the most recent successful token release
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
        AwaitingApproval, // Needs three distinct current authorized wallets
        Passed,     // Quorum + approval met, in timelock
        Failed,     // Quorum or approval not met
        Executed,   // Tokens released
        Cancelled,   // Cancelled by proposer or obsolete signer group
        Paused       // System or proposal paused; deadlines still use wall-clock time
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

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyAuthorized() {
        require(_isAuthorized(msg.sender), "DAO: not authorized wallet");
        _;
    }

    modifier whenSystemNotPaused() {
        require(!systemPaused, "DAO: system is paused");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // One-time initializer for a fixed ERC1967 proxy; v2 exposes no upgrade path
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
        __ReentrancyGuard_init();

        require(_realToken.code.length > 0, "DAO: invalid token contract");
        require(_supplyOracle.code.length > 0, "DAO: invalid oracle contract");

        realToken = IERC20(_realToken);
        supplyOracle = IGovMintSupplyOracleV2(_supplyOracle);
        deployer = msg.sender;
        for (uint256 i; i < TOTAL_SIGNERS; ++i) {
            require(_authorizedWallets[i] != address(0) && _authorizedWallets[i] != address(this), "DAO: invalid signer");
            for (uint256 j; j < i; ++j) {
                require(_authorizedWallets[i] != _authorizedWallets[j], "DAO: duplicate signer");
            }
        }
        authorizedWallets = _authorizedWallets;
        for (uint256 i; i < TOTAL_SIGNERS; ++i) corporateWallet[_authorizedWallets[i]] = true;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Proposal Creation (Restricted to 5 Authorized Wallets)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a new governance proposal to release tokens from the DAO vault.
     * @param _recipient Wallet that receives tokens if proposal passes
     * @param _amount Amount of REAL tokens requested (max 1,000,000)
     * @param _merkleRoot Merkle root of eligible voters (address, votingPower) pairs.
     *        DRAFT: computed off-chain. Membership is not proof of token ownership.
     *        Final snapshot, holding-period and vesting-exclusion mechanics are unresolved.
     *        Corporate signers are excluded locally; other exclusions depend on the oracle.
     */
    function createProposal(
        address _recipient,
        uint256 _amount,
        bytes32 _merkleRoot
    ) external onlyAuthorized whenSystemNotPaused returns (uint256) {
        require(_recipient != address(0), "DAO: invalid recipient");
        require(_amount > 0 && _amount <= MAX_UNLOCK_PER_PROPOSAL, "DAO: amount exceeds max 1M");
        require(_amount <= realToken.balanceOf(address(this)), "DAO: insufficient vault balance");
        require(_merkleRoot != bytes32(0), "DAO: invalid merkle root");
        uint256 proposalId = proposalCount++;
        uint256 circulatingSnapshot = supplyOracle.getCirculatingSupply();
        require(circulatingSnapshot >= TOKENS_PER_VOTE, "DAO: invalid supply snapshot");
        require(circulatingSnapshot <= realToken.totalSupply(), "DAO: supply exceeds token total");
        require(_amount <= MAX_TOTAL_RELEASE - totalReleased, "DAO: reserve limit");
        proposalEpoch[proposalId] = signerEpoch;
        proposalApprovedBy[proposalId][msg.sender] = true;
        proposalApprovalCount[proposalId] = 1;

        proposals[proposalId] = Proposal({
            proposer: msg.sender,
            recipient: _recipient,
            amount: _amount,
            merkleRoot: _merkleRoot,
            circulatingSupplySnapshot: circulatingSnapshot,
            votingStart: 0,
            votingEnd: 0,
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
            0,
            0,
            circulatingSnapshot
        );

        emit ProposalApproved(proposalId, msg.sender, 1);
        return proposalId;
    }

    /// The requester's approval counts once; two other current wallets must approve.
    /// All proposal fields, including the Merkle root, are fixed before approvals.
    function approveProposal(uint256 id) external onlyAuthorized whenSystemNotPaused {
        _requireCurrentProposal(id);
        Proposal storage proposal = proposals[id];
        require(!proposal.cancelled, "DAO: proposal cancelled");
        require(proposalApprovalCount[id] < REQUIRED_SIGNATURES, "DAO: internal approval complete");
        require(!proposalApprovedBy[id][msg.sender], "DAO: duplicate approval");
        proposalApprovedBy[id][msg.sender] = true;
        emit ProposalApproved(id, msg.sender, ++proposalApprovalCount[id]);
        if (proposalApprovalCount[id] == REQUIRED_SIGNATURES) {
            proposal.votingStart = block.timestamp;
            proposal.votingEnd = block.timestamp + VOTING_PERIOD;
            emit VotingOpened(id, proposal.votingStart, proposal.votingEnd);
        }
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
        _requireCurrentProposal(_proposalId);
        require(proposalApprovalCount[_proposalId] >= REQUIRED_SIGNATURES, "DAO: internal approval missing");
        require(!corporateWallet[msg.sender], "DAO: corporate wallet cannot vote");
        require(msg.sender != address(this), "DAO: vault cannot vote");
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

        require(effectivePower > 0, "DAO: zero effective voting power");
        hasVoted[_proposalId][msg.sender] = true;
        proposal.voterCount++;
        require(proposal.yesVotes + proposal.noVotes + effectivePower <= proposal.circulatingSupplySnapshot / TOKENS_PER_VOTE,
            "DAO: votes exceed circulating snapshot");

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
        _requireCurrentProposal(_proposalId);
        require(proposalApprovalCount[_proposalId] >= REQUIRED_SIGNATURES, "DAO: internal approval missing");
        require(lastApprovalTimestamp == 0 || block.timestamp >= lastApprovalTimestamp + COOLDOWN_DURATION, "DAO: 90-day release cooldown");
        Proposal storage proposal = proposals[_proposalId];

        require(!proposal.executed, "DAO: already executed");
        require(!proposal.cancelled, "DAO: proposal cancelled");
        require(!proposalPaused[_proposalId], "DAO: proposal is paused");
        require(block.timestamp > proposal.votingEnd, "DAO: voting not ended");

        // Verify minimum unique voters participated
        require(proposal.voterCount >= MIN_VOTERS, "DAO: minimum voter count not met");

        // Verify quorum: total votes >= 15% of circulating supply (in vote units)
        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
        uint256 quorumThreshold = _quorumThreshold(proposal.circulatingSupplySnapshot);
        require(totalVotes > 0 && totalVotes >= quorumThreshold, "DAO: quorum not reached");

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
        require(proposal.amount <= MAX_TOTAL_RELEASE - totalReleased, "DAO: reserve limit");
        lastApprovalTimestamp = block.timestamp; // Actual transfer time; never move backwards.
        totalReleased += proposal.amount;

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
        _requireCurrentProposal(_proposalId);
        Proposal storage proposal = proposals[_proposalId];

        require(msg.sender == proposal.proposer, "DAO: only proposer can cancel");
        require(!proposal.cancelled, "DAO: already cancelled");
        require(!proposal.executed, "DAO: already executed");
        require(proposalApprovalCount[_proposalId] < REQUIRED_SIGNATURES, "DAO: voting already started");

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
        require(!systemPaused, "DAO: already paused");
        bytes32 actionId = keccak256(abi.encodePacked("PAUSE_SYSTEM", signerEpoch, systemPauseRevision, _nonce));
        require(!actionExecuted[actionId], "DAO: action already executed");

        if (!actionSignatures[actionId][msg.sender]) {
            actionSignatures[actionId][msg.sender] = true;
            actionSignatureCount[actionId]++;
            emit ActionSigned(actionId, msg.sender, actionSignatureCount[actionId]);
        }

        if (actionSignatureCount[actionId] >= REQUIRED_SIGNATURES && !systemPaused) {
            systemPaused = true;
            ++systemPauseRevision;
            actionExecuted[actionId] = true;
            emit SystemPaused(actionId, msg.sender);
        }
    }

    /**
     * @notice Sign to unpause the entire DAO system. Requires 3 of 5 authorized wallets.
     */
    function signUnpauseSystem(bytes32 _nonce) external onlyAuthorized {
        require(systemPaused, "DAO: not paused");
        bytes32 actionId = keccak256(abi.encodePacked("UNPAUSE_SYSTEM", signerEpoch, systemPauseRevision, _nonce));
        require(!actionExecuted[actionId], "DAO: action already executed");

        if (!actionSignatures[actionId][msg.sender]) {
            actionSignatures[actionId][msg.sender] = true;
            actionSignatureCount[actionId]++;
            emit ActionSigned(actionId, msg.sender, actionSignatureCount[actionId]);
        }

        if (actionSignatureCount[actionId] >= REQUIRED_SIGNATURES && systemPaused) {
            systemPaused = false;
            ++systemPauseRevision;
            actionExecuted[actionId] = true;
            emit SystemUnpaused(actionId, msg.sender);
        }
    }

    /**
     * @notice Sign to pause a specific proposal. Requires 3 of 5 authorized wallets.
     */
    function signPauseProposal(uint256 _proposalId, bytes32 _nonce) external onlyAuthorized {
        require(!proposalPaused[_proposalId], "DAO: already paused");
        _requireCurrentProposal(_proposalId);
        require(!proposals[_proposalId].cancelled && !proposals[_proposalId].executed, "DAO: closed proposal");
        bytes32 actionId = keccak256(abi.encodePacked("PAUSE_PROPOSAL", signerEpoch, _proposalId, proposalPauseRevision[_proposalId], _nonce));
        require(!actionExecuted[actionId], "DAO: action already executed");

        if (!actionSignatures[actionId][msg.sender]) {
            actionSignatures[actionId][msg.sender] = true;
            actionSignatureCount[actionId]++;
            emit ActionSigned(actionId, msg.sender, actionSignatureCount[actionId]);
        }

        if (actionSignatureCount[actionId] >= REQUIRED_SIGNATURES && !proposalPaused[_proposalId]) {
            proposalPaused[_proposalId] = true;
            ++proposalPauseRevision[_proposalId];
            actionExecuted[actionId] = true;
            emit ProposalPausedEvent(_proposalId, actionId);
        }
    }

    /**
     * @notice Sign to unpause a specific proposal. Requires 3 of 5 authorized wallets.
     */
    function signUnpauseProposal(uint256 _proposalId, bytes32 _nonce) external onlyAuthorized {
        require(proposalPaused[_proposalId], "DAO: not paused");
        _requireCurrentProposal(_proposalId);
        require(!proposals[_proposalId].cancelled && !proposals[_proposalId].executed, "DAO: closed proposal");
        bytes32 actionId = keccak256(abi.encodePacked("UNPAUSE_PROPOSAL", signerEpoch, _proposalId, proposalPauseRevision[_proposalId], _nonce));
        require(!actionExecuted[actionId], "DAO: action already executed");

        if (!actionSignatures[actionId][msg.sender]) {
            actionSignatures[actionId][msg.sender] = true;
            actionSignatureCount[actionId]++;
            emit ActionSigned(actionId, msg.sender, actionSignatureCount[actionId]);
        }

        if (actionSignatureCount[actionId] >= REQUIRED_SIGNATURES && proposalPaused[_proposalId]) {
            proposalPaused[_proposalId] = false;
            ++proposalPauseRevision[_proposalId];
            actionExecuted[actionId] = true;
            emit ProposalUnpausedEvent(_proposalId, actionId);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Wallet recovery (3 of 5 current authorized wallets)
    // ─────────────────────────────────────────────────────────────────────

    /// No unilateral wallet updates, oracle changes or deployer upgrades in v2.
    /// Replacement is atomic: exactly five distinct nonzero wallets remain.
    function requestWalletReplacement(uint256 index, address replacement)
        external onlyAuthorized returns (uint256 id)
    {
        require(index < TOTAL_SIGNERS, "DAO: invalid index");
        require(replacement != address(0) && replacement != address(this), "DAO: invalid replacement");
        require(!_isAuthorized(replacement), "DAO: replacement already authorized");
        id = replacementCount++;
        address oldWallet = authorizedWallets[index];
        walletReplacements[id] = WalletReplacement(index, oldWallet, replacement, signerEpoch, 1, false);
        replacementApprovedBy[id][msg.sender] = true;
        emit WalletReplacementRequested(id, oldWallet, replacement, signerEpoch);
        emit WalletReplacementApproved(id, msg.sender, 1);
    }

    /// The nominee cannot approve: only the current five wallets are authorized.
    /// Recovery remains available during emergency pauses.
    function approveWalletReplacement(uint256 id) external onlyAuthorized {
        require(id < replacementCount, "DAO: invalid replacement request");
        WalletReplacement storage request = walletReplacements[id];
        require(!request.executed && request.epoch == signerEpoch, "DAO: stale replacement request");
        require(!replacementApprovedBy[id][msg.sender], "DAO: duplicate approval");
        require(authorizedWallets[request.index] == request.oldWallet, "DAO: signer changed");
        require(!_isAuthorized(request.newWallet), "DAO: replacement already authorized");
        replacementApprovedBy[id][msg.sender] = true;
        emit WalletReplacementApproved(id, msg.sender, ++request.approvals);
        if (request.approvals == REQUIRED_SIGNATURES) {
            request.executed = true;
            authorizedWallets[request.index] = request.newWallet;
            corporateWallet[request.newWallet] = true;
            ++signerEpoch;
            emit AuthorizedWalletUpdated(request.index, request.oldWallet, request.newWallet);
        }
    }

    function _requireCurrentProposal(uint256 id) internal view {
        require(id < proposalCount, "DAO: invalid proposal");
        require(proposalEpoch[id] == signerEpoch, "DAO: proposal belongs to previous signer group");
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

        if (proposal.executed) return ProposalStatus.Executed;
        if (proposalEpoch[_proposalId] != signerEpoch || proposal.cancelled) return ProposalStatus.Cancelled;
        if (proposalApprovalCount[_proposalId] < REQUIRED_SIGNATURES) {
            return ProposalStatus.AwaitingApproval;
        }
        if (systemPaused || proposalPaused[_proposalId]) return ProposalStatus.Paused;
        if (block.timestamp < proposal.votingStart) return ProposalStatus.Pending;
        if (block.timestamp <= proposal.votingEnd) return ProposalStatus.Active;

        // Voting has ended — check if passed
        if (proposal.voterCount < MIN_VOTERS) return ProposalStatus.Failed;

        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
        uint256 quorumThreshold = _quorumThreshold(proposal.circulatingSupplySnapshot);

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
        return _quorumThreshold(proposals[_proposalId].circulatingSupplySnapshot);
    }

    function getVaultBalance() external view returns (uint256) {
        return realToken.balanceOf(address(this));
    }

    function getTimeUntilExecution(uint256 _proposalId) external view returns (uint256) {
        require(_proposalId < proposalCount, "DAO: invalid proposal");
        Proposal storage proposal = proposals[_proposalId];
        require(proposalApprovalCount[_proposalId] >= REQUIRED_SIGNATURES, "DAO: voting schedule not set");
        uint256 executableAt = proposal.votingEnd + TIMELOCK_DURATION;
        if (lastApprovalTimestamp > 0 && lastApprovalTimestamp + COOLDOWN_DURATION > executableAt) {
            executableAt = lastApprovalTimestamp + COOLDOWN_DURATION;
        }
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

    // Round participation UP: integer votes must cover the whole stated fraction.
    function _quorumThreshold(uint256 supply) internal pure returns (uint256) {
        uint256 denominator = 10000 * TOKENS_PER_VOTE;
        return (supply * QUORUM_BPS + denominator - 1) / denominator;
    }

    function _isAuthorized(address _wallet) internal view returns (bool) {
        for (uint256 i = 0; i < TOTAL_SIGNERS; i++) {
            if (authorizedWallets[i] == _wallet) return true;
        }
        return false;
    }

    // No upgrade entry point or implementation authorization exists in v2.
}
