// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable@5.1.0/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable@5.1.0/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable@5.1.0/access/Ownable2StepUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts@5.1.0/token/ERC20/IERC20.sol";

interface IVestingFactorySupply {
    function realToken() external view returns (address);
    function totalLocked() external view returns (uint256);
    function getTotalDeployedContracts() external view returns (uint256);
}

interface IRealV2Pair is IERC20 {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice Read-only supply accounting for REAL. This oracle never holds tokens.
/// @dev Deploy a NEW ERC1967Proxy, atomically initializing it with the intended owner.
///      This version has a new storage layout and is not a drop-in upgrade for the old Sepolia proxy.
contract CirculatingSupplyOracle is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    uint256 public constant MAX_SUPPLY = 100_000_000 ether;
    uint256 public constant MAX_VESTING_FACTORIES = 32;

    IERC20 public realToken;
    uint256 public issuedSupplyBaseline;
    IVestingFactorySupply public vestingFactory; // First factory, retained as a compatibility getter.
    IVestingFactorySupply[] private _additionalFactories;
    mapping(address => bool) public isVestingFactory;
    address public daoWallet;
    address public lpBurnAddress;
    IRealV2Pair public ethLpPair;
    IRealV2Pair public usdcLpPair;
    address public ethQuoteToken;
    address public usdcQuoteToken;
    address[] public voteExcludedWallets;
    mapping(address => bool) public isVoteExcluded;

    error InvalidAddress();
    error InvalidIssuedSupply();
    error SupplyIncreasedAfterBaseline();
    error InvalidSupplyAccounting(uint256 totalSupply, uint256 nonCirculating);
    error InvalidFactory();
    error FactoryAlreadyRegistered();
    error FactoryLimitReached();
    error FactoryAlreadySet();
    error InvalidPair();
    error RenounceDisabled();

    event VestingFactoryAdded(address indexed factory);
    event DaoWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event LpBurnAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event EthLpPairUpdated(address indexed pair, address indexed quoteToken);
    event UsdcLpPairUpdated(address indexed pair, address indexed quoteToken);
    event VoteExcludedWalletAdded(address indexed wallet);
    event VoteExcludedWalletRemoved(address indexed wallet);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param initialOwner Address that controls oracle settings and UUPS upgrades (prefer a Safe).
    /// @param tokenAddress REAL token on this chain.
    /// @param totalIssuedEver Cumulative REAL minted before this deployment, including burned REAL.
    ///        Mainnet: 100 million REAL; on Sepolia supply may be different. This assumes no later mint.
    /// @param firstFactory Zero until a verified REAL VestingFactory has been deployed.
    /// @param initialDaoWallet Zero until the DAO vault exists; Safe wallets are circulating.
    /// @param initialLpBurnAddress Zero until the intended LP burn address is confirmed.
    /// @param initialVoteExcludedWallets Wallets excluded from voting, but still circulating.
    function initialize(
        address initialOwner,
        address tokenAddress,
        uint256 totalIssuedEver,
        address firstFactory,
        address initialDaoWallet,
        address initialLpBurnAddress,
        address[] calldata initialVoteExcludedWallets
    ) external initializer {
        if (initialOwner == address(0) || tokenAddress.code.length == 0) revert InvalidAddress();
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();

        realToken = IERC20(tokenAddress);
        uint256 liveSupply = realToken.totalSupply();
        if (totalIssuedEver < liveSupply || totalIssuedEver > MAX_SUPPLY) revert InvalidIssuedSupply();
        issuedSupplyBaseline = totalIssuedEver;
        daoWallet = initialDaoWallet;
        lpBurnAddress = initialLpBurnAddress;
        if (firstFactory != address(0)) _addFactory(firstFactory);
        for (uint256 i; i < initialVoteExcludedWallets.length; ++i) {
            address wallet = initialVoteExcludedWallets[i];
            if (wallet != address(0) && !isVoteExcluded[wallet]) {
                isVoteExcluded[wallet] = true;
                voteExcludedWallets.push(wallet);
                emit VoteExcludedWalletAdded(wallet);
            }
        }
    }

    // ERC-20 destruction reduces totalSupply already; this getter is for separate reporting.
    // It does not count transfers to an inaccessible address. It assumes no mint after baseline.
    function getBurnedSupply() external view returns (uint256) {
        uint256 liveSupply = realToken.totalSupply();
        if (liveSupply > issuedSupplyBaseline) revert SupplyIncreasedAfterBaseline();
        return issuedSupplyBaseline - liveSupply;
    }

    function getMaxSupply() external pure returns (uint256) { return MAX_SUPPLY; }
    function getTotalSupply() external view returns (uint256) { return realToken.totalSupply(); }

    function getCirculatingSupply() external view returns (uint256) {
        uint256 total = realToken.totalSupply();
        uint256 nonCirculating = _vestingLockedBalance() + _daoWalletBalance();
        if (nonCirculating > total) revert InvalidSupplyAccounting(total, nonCirculating);
        return total - nonCirculating;
    }

    function getVestingLockedBalance() external view returns (uint256) { return _vestingLockedBalance(); }
    function getDaoWalletBalance() external view returns (uint256) { return _daoWalletBalance(); }
    function getNonCirculatingBalance() external view returns (uint256) {
        return _vestingLockedBalance() + _daoWalletBalance();
    }

    function getVestingContractCount() external view returns (uint256 count) {
        if (address(vestingFactory) != address(0)) count += vestingFactory.getTotalDeployedContracts();
        for (uint256 i; i < _additionalFactories.length; ++i) {
            count += _additionalFactories[i].getTotalDeployedContracts();
        }
    }

    function getVestingFactories() external view returns (address[] memory factories) {
        uint256 first = address(vestingFactory) == address(0) ? 0 : 1;
        factories = new address[](first + _additionalFactories.length);
        if (first == 1) factories[0] = address(vestingFactory);
        for (uint256 i; i < _additionalFactories.length; ++i) {
            factories[first + i] = address(_additionalFactories[i]);
        }
    }

    /// @dev Kept for existing integrations. It may only set an initially unset factory.
    function setVestingFactory(address factory) external onlyOwner {
        if (address(vestingFactory) != address(0)) revert FactoryAlreadySet();
        _addFactory(factory);
    }

    function addVestingFactory(address factory) external onlyOwner { _addFactory(factory); }

    function setDaoWallet(address wallet) external onlyOwner {
        address old = daoWallet;
        daoWallet = wallet;
        emit DaoWalletUpdated(old, wallet);
    }

    function setLpBurnAddress(address burnAddress) external onlyOwner {
        if (burnAddress == address(0)) revert InvalidAddress();
        address old = lpBurnAddress;
        lpBurnAddress = burnAddress;
        emit LpBurnAddressUpdated(old, burnAddress);
    }

    /// @dev For Uniswap V2-style ERC-20 LP tokens. The pair must contain REAL and the stated quote token.
    ///      Address zero clears a pair before it exists. Neither pool changes REAL circulating supply.
    function setEthLpPair(address pair, address quoteToken) external onlyOwner {
        _checkPair(pair, quoteToken, address(usdcLpPair));
        ethLpPair = IRealV2Pair(pair);
        ethQuoteToken = quoteToken;
        emit EthLpPairUpdated(pair, quoteToken);
    }

    function setUsdcLpPair(address pair, address quoteToken) external onlyOwner {
        _checkPair(pair, quoteToken, address(ethLpPair));
        usdcLpPair = IRealV2Pair(pair);
        usdcQuoteToken = quoteToken;
        emit UsdcLpPairUpdated(pair, quoteToken);
    }

    function getEthLpBurned() external view returns (uint256) { return _lpBurned(ethLpPair); }
    function getUsdcLpBurned() external view returns (uint256) { return _lpBurned(usdcLpPair); }
    function getEthLpTotalSupply() external view returns (uint256) { return _lpTotal(ethLpPair); }
    function getUsdcLpTotalSupply() external view returns (uint256) { return _lpTotal(usdcLpPair); }

    // Voting exclusions do not remove Safe/corporate holdings from circulating supply.
    function getVotingPower(uint256 balance) external pure returns (uint256) { return balance / (1_000 ether); }
    function isVotingExcluded(address wallet) external view returns (bool) {
        if (wallet == address(0)) return false;
        return isVoteExcluded[wallet] || wallet == daoWallet;
    }
    function getVoteExcludedWallets() external view returns (address[] memory) { return voteExcludedWallets; }
    function getVoteExcludedWalletCount() external view returns (uint256) { return voteExcludedWallets.length; }

    function addVoteExcludedWallet(address wallet) external onlyOwner {
        if (wallet == address(0) || isVoteExcluded[wallet]) revert InvalidAddress();
        isVoteExcluded[wallet] = true;
        voteExcludedWallets.push(wallet);
        emit VoteExcludedWalletAdded(wallet);
    }

    function removeVoteExcludedWallet(address wallet) external onlyOwner {
        if (!isVoteExcluded[wallet]) revert InvalidAddress();
        isVoteExcluded[wallet] = false;
        for (uint256 i; i < voteExcludedWallets.length; ++i) {
            if (voteExcludedWallets[i] == wallet) {
                voteExcludedWallets[i] = voteExcludedWallets[voteExcludedWallets.length - 1];
                voteExcludedWallets.pop();
                break;
            }
        }
        emit VoteExcludedWalletRemoved(wallet);
    }

    /// @dev Compatibility for consumers of the earlier Sepolia oracle's deployer() getter.
    function deployer() external view returns (address) { return owner(); }

    /// @dev Losing admin control would prevent correcting future DAO/factory addresses.
    function renounceOwnership() public pure override { revert RenounceDisabled(); }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _addFactory(address factory) internal {
        if (factory.code.length == 0) revert InvalidFactory();
        if (isVestingFactory[factory]) revert FactoryAlreadyRegistered();
        if (getFactoryCount() >= MAX_VESTING_FACTORIES) revert FactoryLimitReached();
        IVestingFactorySupply candidate = IVestingFactorySupply(factory);
        if (candidate.realToken() != address(realToken)) revert InvalidFactory();
        // Validate the required interface before a factory can affect public supply reads.
        candidate.totalLocked();
        candidate.getTotalDeployedContracts();
        if (address(vestingFactory) == address(0)) vestingFactory = candidate;
        else _additionalFactories.push(candidate);
        isVestingFactory[factory] = true;
        emit VestingFactoryAdded(factory);
    }

    function getFactoryCount() public view returns (uint256) {
        return (address(vestingFactory) == address(0) ? 0 : 1) + _additionalFactories.length;
    }

    function _vestingLockedBalance() internal view returns (uint256 total) {
        if (address(vestingFactory) != address(0)) total += vestingFactory.totalLocked();
        for (uint256 i; i < _additionalFactories.length; ++i) {
            total += _additionalFactories[i].totalLocked();
        }
    }

    function _daoWalletBalance() internal view returns (uint256) {
        return daoWallet == address(0) ? 0 : realToken.balanceOf(daoWallet);
    }

    function _checkPair(address pair, address quote, address otherPair) internal view {
        if (pair == address(0)) {
            if (quote != address(0)) revert InvalidPair();
            return;
        }
        if (pair.code.length == 0 || quote == address(0) || quote == address(realToken) || pair == otherPair) {
            revert InvalidPair();
        }
        address a = IRealV2Pair(pair).token0();
        address b = IRealV2Pair(pair).token1();
        if (!((a == address(realToken) && b == quote) || (b == address(realToken) && a == quote))) {
            revert InvalidPair();
        }
        IRealV2Pair(pair).totalSupply();
    }

    function _lpBurned(IRealV2Pair pair) internal view returns (uint256) {
        if (address(pair) == address(0) || lpBurnAddress == address(0)) return 0;
        return pair.balanceOf(lpBurnAddress);
    }

    function _lpTotal(IRealV2Pair pair) internal view returns (uint256) {
        return address(pair) == address(0) ? 0 : pair.totalSupply();
    }
}
