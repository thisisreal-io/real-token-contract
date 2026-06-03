// SPDX-License-Identifier: MIT

// Real Estate Alliance League, Illinois, USA
// Circulating Supply Oracle — Shared supply calculation for REAL ecosystem
// https://ThisIsREAL.io    /    email: support@thisisreal.io
// Used by: DAO Mint Protocol, Staking Contract (future), and other ecosystem contracts.
//
// Supply model:
//   Circulating Supply = totalSupply() - non-circulating (vesting / vNFT) balances
//   Burns reduce totalSupply() automatically, so burned tokens are already excluded.
//   (Matches the tokenomics formula: Circulating = Total - vNFT - Burn)
//
//   Two distinct wallet categories are tracked:
//     1. Non-circulating wallets (vesting / vNFT, locked reserves):
//        - SUBTRACTED from circulating supply.
//        - Also barred from voting.
//     2. Vote-excluded wallets (SAFE / organization wallets):
//        - COUNTED as circulating (these tokens can be sold at any time).
//        - Barred from voting only.
//
//   Note: full vesting-holder vote exclusion is built off-chain in the DAO Merkle tree
//   (the backend reads these lists plus VestingFactory.deployedContracts). The on-chain
//   non-circulating list is intentionally bounded/deployer-managed to keep
//   getCirculatingSupply() gas-safe (it is called on-chain by the DAO).

pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable@5.1.0/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable@5.1.0/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts@5.1.0/token/ERC20/IERC20.sol";

contract CirculatingSupplyOracle is Initializable, UUPSUpgradeable {

    // ─────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────

    IERC20 public realToken;
    address public deployer;

    // Non-circulating wallets (vesting / vNFT, locked reserves).
    // Subtracted from circulating supply AND barred from voting.
    address[] public nonCirculatingWallets;
    mapping(address => bool) public isNonCirculating;

    // Vote-excluded wallets (SAFE / organization wallets).
    // Counted as circulating, but barred from voting.
    address[] public voteExcludedWallets;
    mapping(address => bool) public isVoteExcluded;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event NonCirculatingWalletAdded(address indexed wallet);
    event NonCirculatingWalletRemoved(address indexed wallet);
    event VoteExcludedWalletAdded(address indexed wallet);
    event VoteExcludedWalletRemoved(address indexed wallet);

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyDeployer() {
        require(msg.sender == deployer, "Oracle: only deployer");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the oracle with the REAL token and the two wallet lists.
     * @param _realToken Address of the REAL ERC-20 token
     * @param _initialNonCirculatingWallets Vesting / vNFT / locked reserve wallets
     *        (subtracted from circulating supply, and barred from voting)
     * @param _initialVoteExcludedWallets SAFE / organization wallets
     *        (counted as circulating, but barred from voting)
     */
    function initialize(
        address _realToken,
        address[] memory _initialNonCirculatingWallets,
        address[] memory _initialVoteExcludedWallets
    ) external initializer {
        require(_realToken != address(0), "Oracle: invalid token address");

        realToken = IERC20(_realToken);
        deployer = msg.sender;

        for (uint256 i = 0; i < _initialNonCirculatingWallets.length; i++) {
            address wallet = _initialNonCirculatingWallets[i];
            if (wallet != address(0) && !isNonCirculating[wallet] && !isVoteExcluded[wallet]) {
                isNonCirculating[wallet] = true;
                nonCirculatingWallets.push(wallet);
            }
        }

        for (uint256 i = 0; i < _initialVoteExcludedWallets.length; i++) {
            address wallet = _initialVoteExcludedWallets[i];
            if (wallet != address(0) && !isVoteExcluded[wallet] && !isNonCirculating[wallet]) {
                isVoteExcluded[wallet] = true;
                voteExcludedWallets.push(wallet);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Core Function: Circulating Supply Calculation
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Circulating supply = totalSupply minus all non-circulating (vesting/vNFT)
     *         balances. SAFE / vote-excluded wallets are NOT subtracted — their tokens
     *         are considered circulating (sellable at any time). Burns already reduce
     *         totalSupply, so burned tokens are excluded automatically.
     * @return Circulating supply in token wei (18 decimals)
     */
    function getCirculatingSupply() external view returns (uint256) {
        uint256 totalSupply = realToken.totalSupply();
        uint256 nonCirculating = _nonCirculatingBalance();

        if (nonCirculating >= totalSupply) {
            return 0;
        }
        return totalSupply - nonCirculating;
    }

    /**
     * @notice Get the voting power for a given token balance.
     * @param _balance Raw REAL token balance (in wei, 18 decimals)
     * @return Number of votes (1 vote per 1,000 REAL)
     */
    function getVotingPower(uint256 _balance) external pure returns (uint256) {
        return _balance / (1_000 * 1e18);
    }

    /**
     * @notice Whether a wallet is barred from voting on DAO proposals.
     *         True for both non-circulating (vesting/vNFT) and vote-excluded (SAFE) wallets.
     *         Used by the DAO as an on-chain guard, and by the backend when building Merkle trees.
     */
    function isVotingExcluded(address _wallet) external view returns (bool) {
        return isNonCirculating[_wallet] || isVoteExcluded[_wallet];
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin Functions (Deployer Only) — Non-Circulating List
    // ─────────────────────────────────────────────────────────────────────

    function addNonCirculatingWallet(address _wallet) external onlyDeployer {
        require(_wallet != address(0), "Oracle: zero address");
        require(!isNonCirculating[_wallet], "Oracle: already non-circulating");
        require(!isVoteExcluded[_wallet], "Oracle: already vote-excluded");

        isNonCirculating[_wallet] = true;
        nonCirculatingWallets.push(_wallet);

        emit NonCirculatingWalletAdded(_wallet);
    }

    function removeNonCirculatingWallet(address _wallet) external onlyDeployer {
        require(isNonCirculating[_wallet], "Oracle: not non-circulating");

        isNonCirculating[_wallet] = false;
        _removeFromList(nonCirculatingWallets, _wallet);

        emit NonCirculatingWalletRemoved(_wallet);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin Functions (Deployer Only) — Vote-Excluded List
    // ─────────────────────────────────────────────────────────────────────

    function addVoteExcludedWallet(address _wallet) external onlyDeployer {
        require(_wallet != address(0), "Oracle: zero address");
        require(!isVoteExcluded[_wallet], "Oracle: already vote-excluded");
        require(!isNonCirculating[_wallet], "Oracle: already non-circulating");

        isVoteExcluded[_wallet] = true;
        voteExcludedWallets.push(_wallet);

        emit VoteExcludedWalletAdded(_wallet);
    }

    function removeVoteExcludedWallet(address _wallet) external onlyDeployer {
        require(isVoteExcluded[_wallet], "Oracle: not vote-excluded");

        isVoteExcluded[_wallet] = false;
        _removeFromList(voteExcludedWallets, _wallet);

        emit VoteExcludedWalletRemoved(_wallet);
    }

    // ─────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────

    function getNonCirculatingWallets() external view returns (address[] memory) {
        return nonCirculatingWallets;
    }

    function getNonCirculatingWalletCount() external view returns (uint256) {
        return nonCirculatingWallets.length;
    }

    function getVoteExcludedWallets() external view returns (address[] memory) {
        return voteExcludedWallets;
    }

    function getVoteExcludedWalletCount() external view returns (uint256) {
        return voteExcludedWallets.length;
    }

    function getTotalSupply() external view returns (uint256) {
        return realToken.totalSupply();
    }

    function getNonCirculatingBalance() external view returns (uint256) {
        return _nonCirculatingBalance();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────

    function _nonCirculatingBalance() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < nonCirculatingWallets.length; i++) {
            total += realToken.balanceOf(nonCirculatingWallets[i]);
        }
        return total;
    }

    function _removeFromList(address[] storage list, address _wallet) internal {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == _wallet) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyDeployer {}
}
