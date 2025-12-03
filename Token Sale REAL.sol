// SPDX-License-Identifier: MIT

// Real Estate Alliance League, Illinois, USA
// Token Sale Phase 1: 1,100,000 REAL available @ $5 each
// Token Sale Page:    https://app.thisisreal.io/sale
// https://ThisIsREAL.io    /    email: support@thisisreal.io
// Real Estate Educational Platform with DAO
// Tokenomics Maximum Supply 100,000,000  /  Initial Circulating Supply is 21,000,000
// See Token Details at our website ThisIsREAL.io including token supply dispursement and vesting schedules.

pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract TokenSaleREAL is ReentrancyGuard, Pausable {
    uint256 public hardcap;
    uint256 public totalBought;
    uint64 public icoDuration;
    uint64 public icoStartTime;

    AggregatorV3Interface internal priceFeed;
    AggregatorV3Interface internal daiUsdPriceFeed;
    AggregatorV3Interface internal usdtUsdPriceFeed;
    AggregatorV3Interface internal usdcUsdPriceFeed;

    uint256 public stableSlippageBps = 100; // 1% slippage allowed

    address[5] public signers;
    uint256 public constant REQUIRED_SIGNATURES = 3;
    uint256 public constant PROPOSAL_EXPIRY = 14 days;
    address public mainDepositWallet;

    mapping(bytes32 => mapping(address => bool)) public proposalSignatures;
    mapping(bytes32 => uint256) public proposalSignatureCount;
    mapping(bytes32 => uint256) public proposalCreatedAt;

    struct WithdrawalQueue {
        address token;
        uint256 amount;
        bool executed;
    }
    mapping(bytes32 => WithdrawalQueue) public withdrawalQueue;

    IERC20Metadata public immutable real;
    IERC20Metadata public immutable usdt;
    IERC20Metadata public immutable usdc;
    IERC20Metadata public immutable dai;

    mapping(uint32 => mapping(address => uint256)) public userBought;

    struct Stage {
        uint64 timeToStart;
        uint64 timeToEnd;
        uint256 totalRealBought;
        uint256 totalETHCollected;
        uint256 totalUSDTCollected;
        uint256 totalUSDCCollected;
        uint256 totalDAICollected;
        uint256 price;
    }

    struct UserBoughtData {
        uint32 stageID;
        uint256 amount;
    }

    Stage[] public stages;

    event ICOStarted(uint64 _icoStartTime, uint64 _icoEndTime, uint64 _icoDuration);
    event StageCreated(uint32 indexed _stageId, uint64 _timeToStart, uint64 _timeToEnd, uint256 _price);
    event StageUpdated(uint32 indexed _stageId, uint64 _timeToStart, uint64 _timeToEnd, uint256 _price);
    event REALPurchasedWithETH(address indexed _user, uint32 indexed _stage, uint256 _baseAmount, uint256 _quoteAmount);
    event REALPurchasedWithUSDT(address indexed _user, uint32 indexed _stage, uint256 _baseAmount, uint256 _quoteAmount);
    event REALPurchasedWithUSDC(address indexed _user, uint32 indexed _stage, uint256 _baseAmount, uint256 _quoteAmount);
    event REALPurchasedWithDAI(address indexed _user, uint32 indexed _stage, uint256 _baseAmount, uint256 _quoteAmount);
    event ETHWithdrawn(uint256 _amount);
    event USDTWithdrawn(uint256 _amount);
    event USDCWithdrawn(uint256 _amount);
    event DAIWithdrawn(uint256 _amount);
    event REALWithdrawn(uint256 _amount);
    event WithdrawalQueued(bytes32 indexed proposalId, address indexed token, uint256 amount);
    event WithdrawalExecuted(bytes32 indexed proposalId, address indexed token, uint256 amount);
    event ProposalSigned(bytes32 indexed proposalId, address indexed signer);
    event StableSlippageBpsSet(uint256 newBps, address indexed setter);

    // REAL 0x325Aa344761c19F7ab6dc45A95f01d6907A30DCA
    // USDT 0xdAC17F958D2ee523a2206206994597C13D831ec7
    // USDC 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    // DAI  0x6B175474E89094C44Da98b954EedeAC495271d0F

    receive() external payable {}
    fallback() external payable {}

    modifier validStage(uint32 _stageId) {
        require(_stageId < stages.length, "Presale: Invalid stage ID");
        _;
    }

    modifier onlySigner() {
        require(isSigner(msg.sender), "Presale: Not a signer");
        _;
    }

    function isSigner(address _address) public view returns (bool) {
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == _address) {
                return true;
            }
        }
        return false;
    }

    function getProposalId(address _token, uint256 _amount, bytes32 _nonce) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_token, _amount, _nonce));
    }

    function signProposal(bytes32 _proposalId) external onlySigner {
        require(!isProposalExpired(_proposalId), "Presale: Proposal expired");
        require(!proposalSignatures[_proposalId][msg.sender], "Presale: Already signed");
        proposalSignatures[_proposalId][msg.sender] = true;
        proposalSignatureCount[_proposalId]++;
        if (proposalCreatedAt[_proposalId] == 0) {
            proposalCreatedAt[_proposalId] = block.timestamp;
        }
        emit ProposalSigned(_proposalId, msg.sender);
    }

    function hasRequiredSignatures(bytes32 _proposalId) public view returns (bool) {
        return proposalSignatureCount[_proposalId] >= REQUIRED_SIGNATURES;
    }

    function isProposalExpired(bytes32 _proposalId) public view returns (bool) {
        if (proposalCreatedAt[_proposalId] == 0) {
            return false;
        }
        return block.timestamp > proposalCreatedAt[_proposalId] + PROPOSAL_EXPIRY;
    }

    constructor(
        address _real,
        address _usdt,
        address _usdc,
        address _dai,
        uint256 _hardcap,
        address _mainDepositWallet,
        address _ethUsdPriceFeed,
        address _daiUsdPriceFeed,
        address _usdtUsdPriceFeed,
        address _usdcUsdPriceFeed,
        address[5] memory _signers
    ) {
        priceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        daiUsdPriceFeed = AggregatorV3Interface(_daiUsdPriceFeed);
        usdtUsdPriceFeed = AggregatorV3Interface(_usdtUsdPriceFeed);
        usdcUsdPriceFeed = AggregatorV3Interface(_usdcUsdPriceFeed);

        real = IERC20Metadata(_real);
        usdt = IERC20Metadata(_usdt);
        usdc = IERC20Metadata(_usdc);
        dai = IERC20Metadata(_dai);
        hardcap = _hardcap;
        mainDepositWallet = _mainDepositWallet;

        require(_signers.length == 5, "Presale: Must provide exactly 5 signers");
        for (uint256 i = 0; i < 5; i++) {
            require(_signers[i] != address(0), "Presale: Signer cannot be zero address");
            signers[i] = _signers[i];
        }
    }

    function getOraclePrice(AggregatorV3Interface _oracle) internal view returns (uint256, uint256) {
        (, int256 price, , uint256 updatedAt, ) = _oracle.latestRoundData();
        require(price > 0, "Oracle: invalid price");
        uint256 feedDecimals = _oracle.decimals();
        uint256 base = 10 ** (18 - feedDecimals);
        return (uint256(price) * base, updatedAt);
    }

    function validateStableOracleNearOne(AggregatorV3Interface _oracle) internal view returns (uint256, uint256) {
        (uint256 price, uint256 _updatedAt) = getOraclePrice(_oracle);
        uint256 deviation = (stableSlippageBps * 1e18) / 10000;
        uint256 lower = 1e18 - deviation;
        uint256 upper = 1e18 + deviation;
        require(price >= lower && price <= upper, "Stablecoin: depegged");
        require(block.timestamp - _updatedAt < 2 hours, "Stablecoin: price stale");
        return (price, _updatedAt);
    }

    function startICO(uint64 _icoDuration) external onlySigner {
        require(_icoDuration > 0, "ICO duration cannot be zero");
        icoDuration = _icoDuration;
        icoStartTime = uint64(block.timestamp);

        emit ICOStarted(icoStartTime, icoStartTime + icoDuration, icoDuration);
    }

    function createStage(
        uint64 _timeToStart,
        uint64 _timeToEnd,
        uint256 _price
    ) external onlySigner {
        require(_price > 0, "Presale: Invalid price");
        require(_timeToEnd > block.timestamp, "Presale: End time must be in future");
        require(_timeToEnd > _timeToStart, "Presale: End time must be after start time");
        stages.push(Stage({
            timeToStart: _timeToStart,
            timeToEnd: _timeToEnd,
            totalRealBought: 0,
            totalETHCollected: 0,
            totalUSDTCollected: 0,
            totalUSDCCollected: 0,
            totalDAICollected: 0,
            price: _price
        }));

        emit StageCreated(uint32(stages.length - 1), _timeToStart, _timeToEnd, _price);
    }

    function updateStage(
        uint32 _stageId,
        uint64 _timeToStart,
        uint64 _timeToEnd,
        uint256 _price
    ) external onlySigner validStage(_stageId) {
        require(_price > 0, "Presale: Invalid price");
        require(_timeToEnd > _timeToStart, "Presale: End time must be after start time");
        Stage storage stage = stages[_stageId];
        stage.timeToStart = _timeToStart;
        stage.timeToEnd = _timeToEnd;
        stage.price = _price;

        emit StageUpdated(_stageId, _timeToStart, _timeToEnd, _price);
    }

    function buyREALWithETH(uint32 _stageId)
        external payable whenNotPaused nonReentrant validStage(_stageId)
    {
        require(getStageStatus(_stageId), "Presale: In-active stage ID");
        require(getICOStatus(), "Presale: In-active ICO");
        Stage storage stage = stages[_stageId];
        require(msg.value > 0, "Presale: Should be greater than 0");

        (uint256 ethUsdPrice, uint256 _updatedAt) = getLatestETHPrice();
        require(ethUsdPrice > 0, "Invalid price feed data");
        require(block.timestamp - _updatedAt < 2 hours, "Stale price");

        uint256 buyAmount = (msg.value * ethUsdPrice) / (stage.price * 10 ** real.decimals());
        require(buyAmount > 0, "Insufficient amount to purchase at current price");
        require(totalBought + buyAmount <= hardcap, "Presale: Hardcap reached");

        userBought[_stageId][msg.sender] += buyAmount;
        totalBought += buyAmount;
        stage.totalRealBought += buyAmount;
        stage.totalETHCollected += msg.value;

        SafeERC20.safeTransfer(IERC20(address(real)), msg.sender, buyAmount);

        emit REALPurchasedWithETH(msg.sender, _stageId, msg.value, buyAmount);
    }

    function buyREALWithUSDT(uint32 _stageId, uint256 _amount)
        external whenNotPaused nonReentrant validStage(_stageId)
    {
        require(getStageStatus(_stageId), "Presale: In-active stage ID");
        require(getICOStatus(), "Presale: In-active ICO");
        require(_amount > 0, "Presale: Should be greater than 0");
        Stage storage stage = stages[_stageId];

        (uint256 price, ) = validateStableOracleNearOne(usdtUsdPriceFeed);

        SafeERC20.safeTransferFrom(IERC20(address(usdt)), msg.sender, address(this), _amount);

        uint256 buyAmount = (_amount * price * (10 ** real.decimals())) / (stage.price * (10 ** usdt.decimals()) * 1e18);
        require(buyAmount > 0, "Insufficient amount to purchase at current price");
        require(totalBought + buyAmount <= hardcap, "Presale: Hardcap reached");

        userBought[_stageId][msg.sender] += buyAmount;
        totalBought += buyAmount;
        stage.totalRealBought += buyAmount;
        stage.totalUSDTCollected += _amount;

        SafeERC20.safeTransfer(IERC20(address(real)), msg.sender, buyAmount);

        emit REALPurchasedWithUSDT(msg.sender, _stageId, _amount, buyAmount);
    }

    function buyREALWithUSDC(uint32 _stageId, uint256 _amount)
        external whenNotPaused nonReentrant validStage(_stageId)
    {
        require(getStageStatus(_stageId), "Presale: In-active stage ID");
        require(getICOStatus(), "Presale: In-active ICO");
        require(_amount > 0, "Presale: Should be greater than 0");
        Stage storage stage = stages[_stageId];

        (uint256 price, ) = validateStableOracleNearOne(usdcUsdPriceFeed);

        SafeERC20.safeTransferFrom(IERC20(address(usdc)), msg.sender, address(this), _amount);

        uint256 buyAmount = (_amount * price * (10 ** real.decimals())) / (stage.price * (10 ** usdc.decimals()) * 1e18);
        require(buyAmount > 0, "Insufficient amount to purchase at current price");
        require(totalBought + buyAmount <= hardcap, "Presale: Hardcap reached");

        userBought[_stageId][msg.sender] += buyAmount;
        totalBought += buyAmount;
        stage.totalRealBought += buyAmount;
        stage.totalUSDCCollected += _amount;

        SafeERC20.safeTransfer(IERC20(address(real)), msg.sender, buyAmount);

        emit REALPurchasedWithUSDC(msg.sender, _stageId, _amount, buyAmount);
    }

    function buyREALWithDAI(uint32 _stageId, uint256 _amount)
        external whenNotPaused nonReentrant validStage(_stageId)
    {
        require(getStageStatus(_stageId), "Presale: In-active stage ID");
        require(getICOStatus(), "Presale: In-active ICO");
        require(_amount > 0, "Presale: Should be greater than 0");
        Stage storage stage = stages[_stageId];

        (uint256 price, ) = validateStableOracleNearOne(daiUsdPriceFeed);

        SafeERC20.safeTransferFrom(IERC20(address(dai)), msg.sender, address(this), _amount);

        uint256 buyAmount = (_amount * price * (10 ** real.decimals())) / (stage.price * (10 ** dai.decimals()) * 1e18);
        require(buyAmount > 0, "Insufficient amount to purchase at current price");
        require(totalBought + buyAmount <= hardcap, "Presale: Hardcap reached");

        userBought[_stageId][msg.sender] += buyAmount;
        totalBought += buyAmount;
        stage.totalRealBought += buyAmount;
        stage.totalDAICollected += _amount;

        SafeERC20.safeTransfer(IERC20(address(real)), msg.sender, buyAmount);

        emit REALPurchasedWithDAI(msg.sender, _stageId, _amount, buyAmount);
    }

    function withdrawETH(uint256 amount, bytes32 nonce) external onlySigner {
        require(address(this).balance >= amount, "Presale: Not enough ETH in contract");
        bytes32 proposalId = getProposalId(address(0), amount, nonce);

        if (proposalCreatedAt[proposalId] > 0) {
            require(!isProposalExpired(proposalId), "Presale: Proposal expired");
        }

        if (!proposalSignatures[proposalId][msg.sender]) {
            proposalSignatures[proposalId][msg.sender] = true;
            proposalSignatureCount[proposalId]++;
            if (proposalCreatedAt[proposalId] == 0) {
                proposalCreatedAt[proposalId] = block.timestamp;
            }
            emit ProposalSigned(proposalId, msg.sender);
        }
        if (!hasRequiredSignatures(proposalId)) {
            return;
        }
        if (!withdrawalQueue[proposalId].executed) {
            withdrawalQueue[proposalId] = WithdrawalQueue({
                token: address(0),
                amount: amount,
                executed: false
            });
            emit WithdrawalQueued(proposalId, address(0), amount);
            
            // Automatically transfer to main deposit wallet when queued
            (bool success, ) = payable(mainDepositWallet).call{value: amount}("");
            require(success, "Presale: ETH transfer failed");
            withdrawalQueue[proposalId].executed = true;
            emit ETHWithdrawn(amount);
            emit WithdrawalExecuted(proposalId, address(0), amount);
        }
    }

    function withdrawUSDT(uint256 amount, bytes32 nonce) external onlySigner {
        require(usdt.balanceOf(address(this)) >= amount, "Presale: Not enough USDT in contract");
        bytes32 proposalId = getProposalId(address(usdt), amount, nonce);
        
        if (proposalCreatedAt[proposalId] > 0) {
            require(!isProposalExpired(proposalId), "Presale: Proposal expired");
        }

        if (!proposalSignatures[proposalId][msg.sender]) {
            proposalSignatures[proposalId][msg.sender] = true;
            proposalSignatureCount[proposalId]++;
            if (proposalCreatedAt[proposalId] == 0) {
                proposalCreatedAt[proposalId] = block.timestamp;
            }
            emit ProposalSigned(proposalId, msg.sender);
        }
        if (!hasRequiredSignatures(proposalId)) {
            return;
        }
        if (!withdrawalQueue[proposalId].executed) {
            withdrawalQueue[proposalId] = WithdrawalQueue({
                token: address(usdt),
                amount: amount,
                executed: false
            });
            emit WithdrawalQueued(proposalId, address(usdt), amount);
            
            // Automatically transfer to main deposit wallet when queued
            SafeERC20.safeTransfer(IERC20(address(usdt)), mainDepositWallet, amount);
            withdrawalQueue[proposalId].executed = true;
            emit USDTWithdrawn(amount);
            emit WithdrawalExecuted(proposalId, address(usdt), amount);
        }
    }

    function withdrawUSDC(uint256 amount, bytes32 nonce) external onlySigner {
        require(usdc.balanceOf(address(this)) >= amount, "Presale: Not enough USDC in contract");
        bytes32 proposalId = getProposalId(address(usdc), amount, nonce);
        
        if (proposalCreatedAt[proposalId] > 0) {
            require(!isProposalExpired(proposalId), "Presale: Proposal expired");
        }

        if (!proposalSignatures[proposalId][msg.sender]) {
            proposalSignatures[proposalId][msg.sender] = true;
            proposalSignatureCount[proposalId]++;
            if (proposalCreatedAt[proposalId] == 0) {
                proposalCreatedAt[proposalId] = block.timestamp;
            }
            emit ProposalSigned(proposalId, msg.sender);
        }
        if (!hasRequiredSignatures(proposalId)) {
            return;
        }
        if (!withdrawalQueue[proposalId].executed) {
            withdrawalQueue[proposalId] = WithdrawalQueue({
                token: address(usdc),
                amount: amount,
                executed: false
            });
            emit WithdrawalQueued(proposalId, address(usdc), amount);
            
            // Automatically transfer to main deposit wallet when queued
            SafeERC20.safeTransfer(IERC20(address(usdc)), mainDepositWallet, amount);
            withdrawalQueue[proposalId].executed = true;
            emit USDCWithdrawn(amount);
            emit WithdrawalExecuted(proposalId, address(usdc), amount);
        }
    }

    function withdrawDAI(uint256 amount, bytes32 nonce) external onlySigner {
        require(dai.balanceOf(address(this)) >= amount, "Presale: Not enough DAI in contract");
        bytes32 proposalId = getProposalId(address(dai), amount, nonce);
        
        if (proposalCreatedAt[proposalId] > 0) {
            require(!isProposalExpired(proposalId), "Presale: Proposal expired");
        }

        if (!proposalSignatures[proposalId][msg.sender]) {
            proposalSignatures[proposalId][msg.sender] = true;
            proposalSignatureCount[proposalId]++;
            if (proposalCreatedAt[proposalId] == 0) {
                proposalCreatedAt[proposalId] = block.timestamp;
            }
            emit ProposalSigned(proposalId, msg.sender);
        }
        if (!hasRequiredSignatures(proposalId)) {
            return;
        }
        if (!withdrawalQueue[proposalId].executed) {
            withdrawalQueue[proposalId] = WithdrawalQueue({
                token: address(dai),
                amount: amount,
                executed: false
            });
            emit WithdrawalQueued(proposalId, address(dai), amount);
            
            // Automatically transfer to main deposit wallet when queued
            SafeERC20.safeTransfer(IERC20(address(dai)), mainDepositWallet, amount);
            withdrawalQueue[proposalId].executed = true;
            emit DAIWithdrawn(amount);
            emit WithdrawalExecuted(proposalId, address(dai), amount);
        }
    }

    function withdrawREAL(uint256 amount, bytes32 nonce) external onlySigner {
        require(real.balanceOf(address(this)) >= amount, "Presale: Not enough REAL in contract");
        bytes32 proposalId = getProposalId(address(real), amount, nonce);
        
        if (proposalCreatedAt[proposalId] > 0) {
            require(!isProposalExpired(proposalId), "Presale: Proposal expired");
        }

        if (!proposalSignatures[proposalId][msg.sender]) {
            proposalSignatures[proposalId][msg.sender] = true;
            proposalSignatureCount[proposalId]++;
            if (proposalCreatedAt[proposalId] == 0) {
                proposalCreatedAt[proposalId] = block.timestamp;
            }
            emit ProposalSigned(proposalId, msg.sender);
        }
        if (!hasRequiredSignatures(proposalId)) {
            return;
        }
        if (!withdrawalQueue[proposalId].executed) {
            withdrawalQueue[proposalId] = WithdrawalQueue({
                token: address(real),
                amount: amount,
                executed: false
            });
            emit WithdrawalQueued(proposalId, address(real), amount);
            
            // Automatically transfer to main deposit wallet when queued
            SafeERC20.safeTransfer(IERC20(address(real)), mainDepositWallet, amount);
            withdrawalQueue[proposalId].executed = true;
            emit REALWithdrawn(amount);
            emit WithdrawalExecuted(proposalId, address(real), amount);
        }
    }

    function pause() public whenNotPaused onlySigner {
        _pause();
    }

    function unpause() public whenPaused onlySigner {
        _unpause();
    }

    function setStableSlippageBps(uint256 _bps) external onlySigner {
        require(_bps <= 1000, "Slippage too high"); // Max 10% allowed
        stableSlippageBps = _bps;
        emit StableSlippageBpsSet(_bps, msg.sender);
    }


    function getLatestETHPrice() public view returns (uint256, uint256) {
        (, int256 price, , uint256 _updatedAt, ) = priceFeed.latestRoundData();
        require(price > 0, "oracle error");
        // Chainlink ETH/USD returns 8 decimals, scale to 18
        return ((uint256(price) * 10 ** 10), _updatedAt);
    }

    function getStageStatus(uint32 _stageId) public view returns (bool) {
        Stage memory stage = stages[_stageId];
        return block.timestamp >= uint256(stage.timeToStart) && block.timestamp <= uint256(stage.timeToEnd);
    }

    function getICOStatus() public view returns (bool) {
        if (icoStartTime == 0 || block.timestamp < uint256(icoStartTime)) {
            return false;
        }
        if (totalBought >= hardcap) {
            return false;
        }
        if (block.timestamp > uint256(icoStartTime + icoDuration)) {
            return false;
        }
        return true;
    }

    function userTotalBought(address user)
        public
        view
        returns (UserBoughtData[] memory data, uint256 _userTotalBought)
    {
        data = new UserBoughtData[](stages.length);
        for (uint32 i = 0; i < stages.length; i++) {
            data[i].stageID = i;
            data[i].amount = userBought[i][user];
            _userTotalBought += userBought[i][user];
        }
    }
 
}