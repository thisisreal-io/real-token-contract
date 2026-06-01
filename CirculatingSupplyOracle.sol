// SPDX-License-Identifier: MIT

// Real Estate Alliance League, Illinois, USA
// Circulating Supply Oracle — Shared supply calculation for REAL ecosystem
// https://ThisIsREAL.io    /    email: support@thisisreal.io
// Used by: DAO Mint Protocol, Staking Contract (future), and other ecosystem contracts.

pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CirculatingSupplyOracle is Initializable, UUPSUpgradeable {

    // ─────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────

    IERC20 public realToken;
    address public deployer;

    address[] public excludedWalletList;
    mapping(address => bool) public isExcludedWallet;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event ExcludedWalletAdded(address indexed wallet);
    event ExcludedWalletRemoved(address indexed wallet);

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
     * @notice Initialize the oracle with the REAL token and initial excluded wallets.
     * @param _realToken Address of the REAL ERC-20 token
     * @param _initialExcludedWallets Wallets to exclude from circulating supply
     *        (vesting wallets, sale contract, free contract, org wallets, burn address, etc.)
     */
    function initialize(
        address _realToken,
        address[] memory _initialExcludedWallets
    ) external initializer {
        require(_realToken != address(0), "Oracle: invalid token address");

        realToken = IERC20(_realToken);
        deployer = msg.sender;

        for (uint256 i = 0; i < _initialExcludedWallets.length; i++) {
            address wallet = _initialExcludedWallets[i];
            if (wallet != address(0) && !isExcludedWallet[wallet]) {
                isExcludedWallet[wallet] = true;
                excludedWalletList.push(wallet);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Core Function: Circulating Supply Calculation
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Calculate circulating supply: totalSupply minus all excluded wallet balances.
     *         Excluded wallets include: DAO vault, vesting wallets, sale contract,
     *         free contract, organization wallets, burn address.
     * @return Circulating supply in token wei (18 decimals)
     */
    function getCirculatingSupply() external view returns (uint256) {
        uint256 totalSupply = realToken.totalSupply();
        uint256 excludedBalance = 0;

        for (uint256 i = 0; i < excludedWalletList.length; i++) {
            excludedBalance += realToken.balanceOf(excludedWalletList[i]);
        }

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
    function getVotingPower(uint256 _balance) external pure returns (uint256) {
        return _balance / (1_000 * 1e18);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin Functions (Deployer Only)
    // ─────────────────────────────────────────────────────────────────────

    function addExcludedWallet(address _wallet) external onlyDeployer {
        require(_wallet != address(0), "Oracle: zero address");
        require(!isExcludedWallet[_wallet], "Oracle: already excluded");

        isExcludedWallet[_wallet] = true;
        excludedWalletList.push(_wallet);

        emit ExcludedWalletAdded(_wallet);
    }

    function removeExcludedWallet(address _wallet) external onlyDeployer {
        require(isExcludedWallet[_wallet], "Oracle: not excluded");

        isExcludedWallet[_wallet] = false;

        for (uint256 i = 0; i < excludedWalletList.length; i++) {
            if (excludedWalletList[i] == _wallet) {
                excludedWalletList[i] = excludedWalletList[excludedWalletList.length - 1];
                excludedWalletList.pop();
                break;
            }
        }

        emit ExcludedWalletRemoved(_wallet);
    }

    // ─────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────

    function getExcludedWallets() external view returns (address[] memory) {
        return excludedWalletList;
    }

    function getExcludedWalletCount() external view returns (uint256) {
        return excludedWalletList.length;
    }

    function getTotalSupply() external view returns (uint256) {
        return realToken.totalSupply();
    }

    function getExcludedBalance() external view returns (uint256) {
        uint256 excluded = 0;
        for (uint256 i = 0; i < excludedWalletList.length; i++) {
            excluded += realToken.balanceOf(excludedWalletList[i]);
        }
        return excluded;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────

    function _authorizeUpgrade(address newImplementation) internal override onlyDeployer {}
}
