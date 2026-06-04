// SPDX-License-Identifier: MIT

// Real Estate Alliance League, Illinois, USA
// Circulating Supply Oracle — Shared supply calculation for REAL ecosystem
// https://ThisIsREAL.io    /    email: support@thisisreal.io
// Used by: DAO Mint Protocol, Staking Contract (future), and other ecosystem contracts.
//
// Supply model:
//   Circulating Supply = totalSupply() - vNFT (vesting) locked - DAO wallet balance
//   Burns reduce totalSupply() automatically, so burned tokens are already excluded.
//   (Circulating = Total - vNFT - DAO vault - Burn)
//
//   Excluded from CIRCULATING SUPPLY (subtracted):
//     1. vNFT vesting — AUTOMATIC & GAS-SAFE (O(1)) via VestingFactory.totalLocked.
//        The factory increments it when a user vests and decrements it on every release
//        (Vesting.unlockFund -> VestingFactory.notifyRelease), so newly vested tokens drop
//        out of circulation and released tokens flow back in with no admin action.
//     2. DAO wallet — a SINGLE address (the DAO mint vault) holding tokens that are released
//        only if DAO voting reaches the required threshold. Its live balance is subtracted.
//     3. Burn — automatic (totalSupply already reflects burns).
//
//   Excluded from VOTING only (these tokens STILL count as circulating):
//     SAFE wallets and Corp / team wallets — tracked in voteExcludedWallets.
//     The DAO wallet is also barred from voting.

pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable@5.1.0/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable@5.1.0/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts@5.1.0/token/ERC20/IERC20.sol";

interface IVestingFactory {
    function totalLocked() external view returns (uint256);
    function getTotalDeployedContracts() external view returns (uint256);
}

contract CirculatingSupplyOracle is Initializable, UUPSUpgradeable {

    // ─────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────

    IERC20 public realToken;
    address public deployer;

    // Vesting factory — its deployed vesting contracts hold all locked (vNFT) tokens.
    // Its live `totalLocked` counter is subtracted from circulating supply automatically.
    IVestingFactory public vestingFactory;

    // DAO wallet (single address): the DAO mint vault. Holds tokens that are released only
    // when DAO voting passes. Its live balance is subtracted from circulating supply AND
    // it is barred from voting.
    address public daoWallet;

    // Vote-excluded wallets (SAFE wallets and Corp / team wallets).
    // Counted as CIRCULATING, but barred from voting.
    address[] public voteExcludedWallets;
    mapping(address => bool) public isVoteExcluded;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event VestingFactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event DaoWalletUpdated(address indexed oldWallet, address indexed newWallet);
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
     * @notice Initialize the oracle.
     * @param _realToken Address of the REAL ERC-20 token
     * @param _vestingFactory Address of the VestingFactory (may be address(0); set later via setVestingFactory)
     * @param _daoWallet The DAO mint vault address (may be address(0); set later via setDaoWallet).
     *        Subtracted from circulating supply and barred from voting.
     * @param _initialVoteExcludedWallets SAFE / Corp / team wallets
     *        (counted as circulating, but barred from voting)
     */
    function initialize(
        address _realToken,
        address _vestingFactory,
        address _daoWallet,
        address[] memory _initialVoteExcludedWallets
    ) external initializer {
        require(_realToken != address(0), "Oracle: invalid token address");

        realToken = IERC20(_realToken);
        vestingFactory = IVestingFactory(_vestingFactory);
        daoWallet = _daoWallet;
        deployer = msg.sender;

        for (uint256 i = 0; i < _initialVoteExcludedWallets.length; i++) {
            address wallet = _initialVoteExcludedWallets[i];
            if (wallet != address(0) && !isVoteExcluded[wallet]) {
                isVoteExcluded[wallet] = true;
                voteExcludedWallets.push(wallet);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Core Function: Circulating Supply Calculation
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Circulating supply = totalSupply minus vNFT vesting locked balance minus the
     *         DAO wallet balance. Vesting is handled automatically via the VestingFactory's
     *         O(1) totalLocked counter. The DAO vault balance is subtracted live. SAFE / Corp
     *         (vote-excluded) wallets are NOT subtracted — their tokens are circulating.
     *         Burns already reduce totalSupply, so burned tokens are excluded automatically.
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
     *         True for SAFE / Corp (vote-excluded) wallets and the DAO wallet.
     *         Used by the DAO as an on-chain guard, and by the backend when building Merkle trees.
     *         (Vesting-holder voting exclusion is enforced off-chain in the Merkle tree.)
     */
    function isVotingExcluded(address _wallet) external view returns (bool) {
        if (_wallet == address(0)) return false;
        return isVoteExcluded[_wallet] || _wallet == daoWallet;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin Functions (Deployer Only) — Configuration
    // ─────────────────────────────────────────────────────────────────────

    function setVestingFactory(address _vestingFactory) external onlyDeployer {
        address old = address(vestingFactory);
        vestingFactory = IVestingFactory(_vestingFactory);
        emit VestingFactoryUpdated(old, _vestingFactory);
    }

    function setDaoWallet(address _daoWallet) external onlyDeployer {
        address old = daoWallet;
        daoWallet = _daoWallet;
        emit DaoWalletUpdated(old, _daoWallet);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin Functions (Deployer Only) — Vote-Excluded List (SAFE / Corp)
    // ─────────────────────────────────────────────────────────────────────

    function addVoteExcludedWallet(address _wallet) external onlyDeployer {
        require(_wallet != address(0), "Oracle: zero address");
        require(!isVoteExcluded[_wallet], "Oracle: already vote-excluded");

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

    function getVoteExcludedWallets() external view returns (address[] memory) {
        return voteExcludedWallets;
    }

    function getVoteExcludedWalletCount() external view returns (uint256) {
        return voteExcludedWallets.length;
    }

    function getTotalSupply() external view returns (uint256) {
        return realToken.totalSupply();
    }

    /// @notice Total currently-locked vesting balance (the factory's live totalLocked counter).
    function getVestingLockedBalance() external view returns (uint256) {
        return _vestingLockedBalance();
    }

    /// @notice Live balance held by the DAO wallet (subtracted from circulating supply).
    function getDaoWalletBalance() external view returns (uint256) {
        return _daoWalletBalance();
    }

    /// @notice Total non-circulating balance = vesting locked + DAO wallet balance.
    function getNonCirculatingBalance() external view returns (uint256) {
        return _nonCirculatingBalance();
    }

    /// @notice Number of vesting contracts the oracle is tracking via the factory.
    function getVestingContractCount() external view returns (uint256) {
        if (address(vestingFactory) == address(0)) return 0;
        return vestingFactory.getTotalDeployedContracts();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────

    function _nonCirculatingBalance() internal view returns (uint256) {
        return _vestingLockedBalance() + _daoWalletBalance();
    }

    function _vestingLockedBalance() internal view returns (uint256) {
        if (address(vestingFactory) == address(0)) {
            return 0;
        }
        // O(1): read the factory's live locked counter (incremented on vest, decremented on release).
        return vestingFactory.totalLocked();
    }

    function _daoWalletBalance() internal view returns (uint256) {
        if (daoWallet == address(0)) {
            return 0;
        }
        return realToken.balanceOf(daoWallet);
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
