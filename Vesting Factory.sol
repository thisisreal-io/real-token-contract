// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Vesting.sol";
import "./VestingReceiptNFT.sol";

contract VestingFactory is Ownable, ReentrancyGuard, Pausable {
    IERC20 public immutable realToken;
    VestingReceiptNFT public immutable vestingReceiptNFT;
    address[] public deployedContracts;
    uint256 public totalLocked;

    mapping(address => address[]) public contractsOwners;

    // Maximum memo length in bytes (256 bytes = ~256 ASCII characters)
    uint256 public constant MAX_MEMO_BYTES = 256;

    event DeployedContracts(
        address indexed _tokenAddress,
        address indexed _contractAddress,
        address indexed _deployerAddress,
        uint256 _vestingAmount,
        uint256 _nftTokenId
    );

    constructor(
        address _initialOwner,
        address _realToken,
        address _vestingReceiptNFT
    ) Ownable(_initialOwner) {
        require(_realToken != address(0), "REAL token address cannot be zero");
        require(_vestingReceiptNFT != address(0), "NFT contract address cannot be zero");
        realToken = IERC20(_realToken);
        vestingReceiptNFT = VestingReceiptNFT(_vestingReceiptNFT);
    }

    function deployVesting(
        uint256 _vestingAmount,
        uint8 _totalEvents,
        uint8 _vestingDuration,
        uint8 _firstUnlockMonth,
        string memory _vestingMemo
    ) public nonReentrant whenNotPaused {
        require(_vestingAmount > 0, "Vesting amount must be greater than zero");
        require(
            bytes(_vestingMemo).length <= MAX_MEMO_BYTES,
            "Vesting memo exceeds maximum length"
        );
        require(
            realToken.balanceOf(msg.sender) >= _vestingAmount,
            "Insufficient REAL token balance"
        );
        require(
            realToken.allowance(msg.sender, address(this)) >= _vestingAmount,
            "Insufficient token allowance"
        );

        Vesting deployedVesting = new Vesting(
            address(realToken),
            _vestingAmount,
            _totalEvents,
            _vestingDuration,
            _firstUnlockMonth,
            _vestingMemo,
            address(vestingReceiptNFT)
        );

        address _vestingAddress = address(deployedVesting);
        deployedContracts.push(_vestingAddress);
        contractsOwners[msg.sender].push(_vestingAddress);

        SafeERC20.safeTransferFrom(
            realToken,
            msg.sender,
            _vestingAddress,
            _vestingAmount
        );

        // Handle fee-on-transfer / deflationary tokens: measure actual received amount
        uint256 actualLocked = realToken.balanceOf(_vestingAddress);
        require(actualLocked > 0, "No tokens received by vesting");

        // Adjust vesting accounting to match actual received amount
        deployedVesting.adjustLockedFund(actualLocked);
        totalLocked += actualLocked;

        // Mint NFT receipt for the vesting contract
        uint256 nftTokenId = vestingReceiptNFT.mint(msg.sender, _vestingAddress);
        
        // Set NFT token ID in vesting contract
        deployedVesting.setNFTTokenId(nftTokenId);

        emit DeployedContracts(
            address(realToken),
            _vestingAddress,
            msg.sender,
            actualLocked,
            nftTokenId
        );
    }

    /**
     * @dev Set metadata URI for a vesting receipt NFT (REA-03). Callable only by the Factory's
     * initial owner (the address set as _initialOwner in the constructor). The owner signs
     * transactions off-chain with their wallet; use that wallet's private key in backend/test.
     */
    function setVestingReceiptTokenURI(uint256 _tokenId, string calldata _uri) external onlyOwner {
        vestingReceiptNFT.setTokenURI(_tokenId, _uri);
    }

    function pause() public whenNotPaused onlyOwner {
        _pause();
    }

    function unpause() public whenPaused onlyOwner {
        _unpause();
    }

    function getPaginatedDeployedAddresses(
        uint256 page,
        uint256 size
    ) public view returns (address[] memory _deployedAddresses) {
        uint256 ToSkip = page * size;
        uint256 count = 0;

        uint256 EndAt = deployedContracts.length > ToSkip + size
            ? ToSkip + size
            : deployedContracts.length;

        require(ToSkip < deployedContracts.length, "OVERFLOW_PAGE");
        require(EndAt > ToSkip, "OVERFLOW_PAGE");
        address[] memory result = new address[](EndAt - ToSkip);

        for (uint256 i = ToSkip; i < EndAt; i++) {
            result[count] = deployedContracts[
                (deployedContracts.length - 1) - i
            ];
            count++;
        }
        return result;
    }

    /**
     * @dev Get all vesting contracts for a specific user
     * @param _user Address of the user
     * @return Array of vesting contract addresses
     */
    function getUserVestingContracts(address _user) public view returns (address[] memory) {
        return contractsOwners[_user];
    }

    /**
     * @dev Get total number of deployed vesting contracts
     * @return Total count of deployed contracts
     */
    function getTotalDeployedContracts() public view returns (uint256) {
        return deployedContracts.length;
    }
}
