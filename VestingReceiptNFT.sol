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

    event VestingReceiptMinted(
        uint256 indexed tokenId,
        address indexed vestingContract,
        address indexed owner
    );

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
     * @dev Generate token URI for NFT metadata
     * Note: For full metadata, backend should query getVestingInfo() and generate JSON
     */
    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        require(_exists(_tokenId), "Token does not exist");
        
        address vestingAddr = vestingContract[_tokenId];
        
        // Return a basic URI - frontend/backend should query getVestingInfo() for full details
        return string(abi.encodePacked(
            "https://thisisreal.io/api/vesting-receipt/",
            _tokenId.toString()
        ));
    }

    /**
     * @dev Check if token exists
     */
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }
}

