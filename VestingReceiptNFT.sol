// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./Vesting.sol";

contract VestingReceiptNFT is ERC721, Ownable {
    using Strings for uint256;
    using Strings for address;

    uint256 private _tokenIdCounter = 1; // Start from 1 to avoid tokenId 0 ambiguity
    mapping(uint256 => address) public vestingContract; // NFT tokenId => Vesting contract address
    mapping(address => uint256) public vestingToTokenId; // Vesting contract => NFT tokenId
    /// @dev Per-token metadata URI (e.g. ipfs://CID). One-time set via setTokenURI. REA-03.
    mapping(uint256 => string) private _tokenURIs;

    event VestingReceiptMinted(
        uint256 indexed tokenId,
        address indexed vestingContract,
        address indexed owner
    );
    event TokenURISet(uint256 indexed tokenId, string uri);

    constructor(address _initialOwner) ERC721("REAL Vesting Receipt", "REALVR") Ownable(_initialOwner) {}

    /**
     * @dev Mint NFT receipt for a vesting contract
     * @param _to Address to mint NFT to
     * @param _vestingContract Address of the vesting contract
     */
    function mint(address _to, address _vestingContract) external onlyOwner returns (uint256) {
        require(_vestingContract != address(0), "Invalid vesting contract");
        require(vestingToTokenId[_vestingContract] == 0, "NFT already minted for this vesting");

        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;

        vestingContract[tokenId] = _vestingContract;
        vestingToTokenId[_vestingContract] = tokenId;

        _safeMint(_to, tokenId);

        emit VestingReceiptMinted(tokenId, _vestingContract, _to);

        return tokenId;
    }

    /**
     * @dev Set metadata URI for a token (e.g. ipfs://CID). One-time only; immutable after set. Option B / REA-03.
     * @param _tokenId NFT token ID
     * @param _uri Content-addressed URI (e.g. ipfs://... or ar://...)
     */
    function setTokenURI(uint256 _tokenId, string calldata _uri) external onlyOwner {
        require(_exists(_tokenId), "Token does not exist");
        require(bytes(_tokenURIs[_tokenId]).length == 0, "Token URI already set");
        require(bytes(_uri).length > 0, "URI cannot be empty");
        _tokenURIs[_tokenId] = _uri;
        emit TokenURISet(_tokenId, _uri);
    }

    function getVestingInfo(uint256 _tokenId) external view returns (
        address vestingAddress,
        uint256 vestingStartDate,
        uint256 initialVestingAmount,
        uint256 currentVestingBalance,
        uint256 claimableAmount,
        uint256 nextReleaseDate,
        uint256 nextReleaseAmount,
        uint256 vestingEndDate,
        string memory releaseRatio
    ) {
        require(_exists(_tokenId), "Token does not exist");
        address vestingAddr = vestingContract[_tokenId];
        require(vestingAddr != address(0), "Vesting contract not found");

        Vesting vesting = Vesting(vestingAddr);

        vestingStartDate = vesting.startTime();
        initialVestingAmount = vesting.lockedFund();
        currentVestingBalance = vesting.getCurrentVestingBalance();
        claimableAmount = vesting.getClaimableAmount();
        
        (nextReleaseDate, nextReleaseAmount) = vesting.getNextReleaseInfo();
        vestingEndDate = vesting.getVestingEndDate();
        releaseRatio = vesting.getReleaseRatio();

        return (
            vestingAddr,
            vestingStartDate,
            initialVestingAmount,
            currentVestingBalance,
            claimableAmount,
            nextReleaseDate,
            nextReleaseAmount,
            vestingEndDate,
            releaseRatio
        );
    }

    /**
     * @dev Token URI for NFT metadata. Option B: per-token content-addressed URI (e.g. ipfs://). REA-03.
     * Returns empty until setTokenURI is called for this token.
     */
    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        require(_exists(_tokenId), "Token does not exist");
        return _tokenURIs[_tokenId];
    }

    /**
     * @dev Check if token exists
     */
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }
}

