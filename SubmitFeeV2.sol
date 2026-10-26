// Real Estate Alliance League, Illinois, USA
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts@5.1.0/utils/ReentrancyGuard.sol";

interface IREALBurnableV2 {
    function burnFrom(address account, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @notice Optional on-chain one-REAL submission fee. Membership and claim
/// authority are enforced separately by the platform; Credits are off-chain.
/// @dev New deployment: this does not upgrade or change the legacy SubmitFee.
contract SubmitFeeV2 is ReentrancyGuard {
    IREALBurnableV2 public immutable REAL_TOKEN;
    uint256 public constant SUBMISSION_FEE = 1 * 10 ** 18;
    mapping(bytes32 => bool) public usedBackendIds;

    // Preserve all existing numeric codes. Append Company; never reorder.
    enum SubmissionType { Property, Forum, Poll, Company }

    event Submitted(
        address indexed submitter,
        SubmissionType indexed submissionType,
        bytes32 indexed backendId,
        string title
    );

    constructor(address realToken) {
        require(realToken != address(0), "SubmitFee: Token address cannot be zero");
        REAL_TOKEN = IREALBurnableV2(realToken);
    }

    /// @dev Burns exactly one REAL after allowance approval. Each backend ID
    /// can be consumed once on this deployment. Titles/events are public:
    /// the platform must never put applicant verification data in them.
    function submit(SubmissionType submissionType, string calldata title, bytes32 backendId)
        external nonReentrant
    {
        require(bytes(title).length > 0, "SubmitFee: Title cannot be empty");
        require(backendId != bytes32(0), "SubmitFee: Backend ID cannot be zero");
        require(!usedBackendIds[backendId], "SubmitFee: Backend ID already used");
        require(REAL_TOKEN.balanceOf(msg.sender) >= SUBMISSION_FEE, "SubmitFee: Insufficient REAL balance");
        require(REAL_TOKEN.allowance(msg.sender, address(this)) >= SUBMISSION_FEE, "SubmitFee: Insufficient allowance, approve this contract on REAL token first");
        usedBackendIds[backendId] = true;
        REAL_TOKEN.burnFrom(msg.sender, SUBMISSION_FEE);
        emit Submitted(msg.sender, submissionType, backendId, title);
    }
}
