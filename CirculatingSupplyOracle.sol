// SPDX-License-Identifier: MIT

// Real Estate Alliance League, Illinois, USA
// Circulating Supply Oracle — Shared supply calculation for REAL ecosystem
// https://ThisIsREAL.io    /    email: support@thisisreal.io
// Used by: DAO Mint Protocol, Staking Contract (future), and other ecosystem contracts.
//
// Supply model:
//   Circulating Supply = totalSupply() - vesting (vNFT) locked balances - manual non-circulating balances
//   Burns reduce totalSupply() automatically, so burned tokens are already excluded.
//   (Matches the tokenomics formula: Circulating = Total - vNFT - Burn)
//
//   Vesting (vNFT) — AUTOMATIC & GAS-SAFE (O(1)):
//     The oracle reads the VestingFactory's live `totalLocked` counter in a single call.
//     The factory increments it when a user vests and decrements it on every release
//     (Vesting.unlockFund -> VestingFactory.notifyRelease). This means:
//       - When a user vests tokens, totalLocked rises, so those tokens become non-circulating
//         automatically.
//       - As vesting unlocks release tokens step-by-step, totalLocked falls, so the released
//         amount re-enters circulating supply automatically.
//     Because it is a single O(1) read, there is no unbounded loop and no gas/DoS concern.
//
//   Manual non-circulating wallets (optional):
//     For locked reserves that are NOT vesting contracts. Subtracted from circulating supply.
//
//   Vote-excluded wallets (SAFE / organization wallets):
//     Counted as circulating (sellable at any time), but barred from voting.

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
    // Their live balances are subtracted from circulating supply automatically.
    IVestingFactory public vestingFactory;

    // Manual non-circulating wallets (locked reserves that are NOT vesting contracts).
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

    event VestingFactoryUpdated(address indexed oldFactory, address indexed newFactory);
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
     * @notice Initialize the oracle.
     * @param _realToken Address of the REAL ERC-20 token
     * @param _vestingFactory Address of the VestingFactory (may be address(0); set later via setVestingFactory)
     * @param _initialNonCirculatingWallets Non-vesting locked reserve wallets
     *        (subtracted from circulating supply, and barred from voting)
     * @param _initialVoteExcludedWallets SAFE / organization wallets
     *        (counted as circulating, but barred from voting)
     */
    function initialize(
        address _realToken,
        address _vestingFactory,
        address[] memory _initialNonCirculatingWallets,
        address[] memory _initialVoteExcludedWallets
    ) external initializer {
        require(_realToken != address(0), "Oracle: invalid token address");

        realToken = IERC20(_realToken);
        vestingFactory = IVestingFactory(_vestingFactory);
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
     * @notice Circulating supply = totalSupply minus vesting (vNFT) locked balance and
     *         minus manual non-circulating balances. Vesting is handled automatically via the
     *         VestingFactory's O(1) totalLocked counter — newly vested tokens drop out of
     *         circulation and released tokens flow back in, with no admin action.
     *         SAFE / vote-excluded wallets are NOT subtracted (their tokens are circulating).
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
     *         True for both manual non-circulating and vote-excluded (SAFE) wallets.
     *         Used by the DAO as an on-chain guard, and by the backend when building Merkle trees.
     *         (Vesting-holder voting exclusion is enforced off-chain in the Merkle tree.)
     */
    function isVotingExcluded(address _wallet) external view returns (bool) {
        return isNonCirculating[_wallet] || isVoteExcluded[_wallet];
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin Functions (Deployer Only) — Vesting Factory
    // ─────────────────────────────────────────────────────────────────────

    function setVestingFactory(address _vestingFactory) external onlyDeployer {
        address old = address(vestingFactory);
        vestingFactory = IVestingFactory(_vestingFactory);
        emit VestingFactoryUpdated(old, _vestingFactory);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin Functions (Deployer Only) — Manual Non-Circulating List
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

    /// @notice Total currently-locked vesting balance (the factory's live totalLocked counter).
    function getVestingLockedBalance() external view returns (uint256) {
        return _vestingLockedBalance();
    }

    /// @notice Manual (non-vesting) non-circulating balance only.
    function getManualNonCirculatingBalance() external view returns (uint256) {
        return _manualNonCirculatingBalance();
    }

    /// @notice Total non-circulating balance = vesting locked + manual non-circulating.
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
        return _manualNonCirculatingBalance() + _vestingLockedBalance();
    }

    function _manualNonCirculatingBalance() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < nonCirculatingWallets.length; i++) {
            total += realToken.balanceOf(nonCirculatingWallets[i]);
        }
        return total;
    }

    function _vestingLockedBalance() internal view returns (uint256) {
        if (address(vestingFactory) == address(0)) {
            return 0;
        }
        // O(1): read the factory's live locked counter (incremented on vest, decremented on release).
        return vestingFactory.totalLocked();
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
