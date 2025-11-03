
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
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract TokenSaleREAL is Ownable, ReentrancyGuard, Pausable {
    uint256 public HARDCAP;
    uint256 public totalBought;
    uint64 public icoDuration; // in seconds
    uint64 public icoStartTime;

    AggregatorV3Interface internal priceFeed;

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

    event ICOStarted(
        uint64 _icoStartTime,
        uint64 _icoEndTime,
        uint64 _icoDuration
    );
    event StageCreated(
        uint32 indexed _stageId,
        uint64 _timeToStart,
        uint64 _timeToEnd,
        uint256 _price
    );
    event StageUpdated(
        uint32 indexed _stageId,
        uint64 _timeToStart,
        uint64 _timeToEnd,
        uint256 _price
    );
    event REALPurchasedWithETH(
        address indexed _user,
        uint32 indexed _stage,
        uint256 _baseAmount,
        uint256 _quoteAmount
    );
    event REALPurchasedWithUSDT(
        address indexed _user,
        uint32 indexed _stage,
        uint256 _baseAmount,
        uint256 _quoteAmount
    );
    event REALPurchasedWithUSDC(
        address indexed _user,
        uint32 indexed _stage,
        uint256 _baseAmount,
        uint256 _quoteAmount
    );
    event REALPurchasedWithDAI(
        address indexed _user,
        uint32 indexed _stage,
        uint256 _baseAmount,
        uint256 _quoteAmount
    );
    event ETHWithdrawn(uint256 _amount);
    event USDTWithdrawn(uint256 _amount);
    event USDCWithdrawn(uint256 _amount);
    event REALWithdrawn(uint256 _amount);
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

    constructor(
        address _real,
        address _usdt,
        address _usdc,
        address _dai,
        uint256 _hardCAP
    ) Ownable(msg.sender) {
        priceFeed = AggregatorV3Interface(
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
            );
        //priceFeed = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306);

        real = IERC20Metadata(_real);
        usdt = IERC20Metadata(_usdt);
        usdc = IERC20Metadata(_usdc);
        dai = IERC20Metadata(_dai);
        HARDCAP = _hardCAP;
    }

    function startICO(uint64 _icoDuration) external onlyOwner {
        icoDuration = _icoDuration;
        icoStartTime = uint64(block.timestamp);

        emit ICOStarted(
            icoStartTime,
            (icoStartTime + icoDuration),
            icoDuration
        );
    }

    function createStage(
        uint64 _timeToStart,
        uint64 _timeToEnd,
        uint256 _price
    ) external onlyOwner {
        stages.push(
            Stage({
                timeToStart: _timeToStart,
                timeToEnd: _timeToEnd,
                totalRealBought: 0,
                totalETHCollected: 0,
                totalUSDTCollected: 0,
                totalUSDCCollected: 0,
                totalDAICollected: 0,
                price: _price
            })
        );

        emit StageCreated(
            uint32(stages.length - 1),
            _timeToStart,
            _timeToEnd,
            _price
        );
    }

    function updateStage(
        uint32 _stageId,
        uint64 _timeToStart,
        uint64 _timeToEnd,
        uint256 _price
    ) external onlyOwner validStage(_stageId) {
        Stage storage stage = stages[_stageId];
        stage.timeToStart = _timeToStart;
        stage.timeToEnd = _timeToEnd;
        stage.price = _price;

        emit StageUpdated(_stageId, _timeToStart, _timeToEnd, _price);
    }

    function buyREALWithETH(
        uint32 _stageId
    ) external payable whenNotPaused nonReentrant validStage(_stageId) {
        require(getStageStatus(_stageId), "Presale: In-active stage ID");
        require(getICOStatus(), "Presale: In-active ICO");

        Stage storage stage = stages[_stageId];

        require(msg.value > 0, "Presale: Should be greater than 0");

        (uint256 price, uint256 updatedAt) = getLatestETHPrice();
        require(price > 0, "Invalid price feed data");
        require(block.timestamp - updatedAt < 1 hours, "Stale price");

        uint256 buyAmount = (msg.value * price) /
            (stage.price * 10 ** real.decimals());

        userBought[_stageId][msg.sender] += buyAmount;
        totalBought += buyAmount;
        stage.totalRealBought += buyAmount;
        stage.totalETHCollected += msg.value;

        require(totalBought <= HARDCAP, "Presale: Hardcap reached");

        SafeERC20.safeTransfer(IERC20(address(real)), msg.sender, buyAmount);

        emit REALPurchasedWithETH(msg.sender, _stageId, msg.value, buyAmount);
    }

    function buyREALWithUSDT(
        uint32 _stageId,
        uint256 _amount
    ) external whenNotPaused nonReentrant validStage(_stageId) {
        require(getStageStatus(_stageId), "Presale: In-active stage ID");
        require(getICOStatus(), "Presale: In-active ICO");

        Stage storage stage = stages[_stageId];

        require(_amount > 0, "Presale: Should be greater than 0");

        SafeERC20.safeTransferFrom(
            IERC20(address(usdt)),
            msg.sender,
            address(this),
            _amount
        );

        uint256 buyAmount = (_amount * (10 ** real.decimals())) /
            (stage.price * (10 ** usdt.decimals()));

        userBought[_stageId][msg.sender] += buyAmount;
        totalBought += buyAmount;
        stage.totalRealBought += buyAmount;
        stage.totalUSDTCollected += _amount;

        require(totalBought <= HARDCAP, "Presale: Hardcap reached");

        SafeERC20.safeTransfer(IERC20(address(real)), msg.sender, buyAmount);

        emit REALPurchasedWithUSDT(msg.sender, _stageId, _amount, buyAmount);
    }

    function buyREALWithUSDC(
        uint32 _stageId,
        uint256 _amount
    ) external whenNotPaused nonReentrant validStage(_stageId) {
        require(getStageStatus(_stageId), "Presale: In-active stage ID");
        require(getICOStatus(), "Presale: In-active ICO");

        Stage storage stage = stages[_stageId];

        require(_amount > 0, "Presale: Should be greater than 0");

        SafeERC20.safeTransferFrom(
            IERC20(address(usdc)),
            msg.sender,
            address(this),
            _amount
        );

        uint256 buyAmount = (_amount * (10 ** real.decimals())) /
            (stage.price * (10 ** usdc.decimals()));

        userBought[_stageId][msg.sender] += buyAmount;
        totalBought += buyAmount;
        stage.totalRealBought += buyAmount;
        stage.totalUSDCCollected += _amount;

        require(totalBought <= HARDCAP, "Presale: Hardcap reached");

        SafeERC20.safeTransfer(IERC20(address(real)), msg.sender, buyAmount);

        emit REALPurchasedWithUSDC(msg.sender, _stageId, _amount, buyAmount);
    }

    function buyREALWithDAI(
        uint32 _stageId,
        uint256 _amount
    ) external whenNotPaused nonReentrant validStage(_stageId) {
        require(getStageStatus(_stageId), "Presale: In-active stage ID");
        require(getICOStatus(), "Presale: In-active ICO");

        Stage storage stage = stages[_stageId];

        require(_amount > 0, "Presale: Should be greater than 0");

        SafeERC20.safeTransferFrom(
            IERC20(address(dai)),
            msg.sender,
            address(this),
            _amount
        );

        uint256 buyAmount = (_amount * (10 ** real.decimals())) /
            (stage.price * (10 ** dai.decimals()));

        userBought[_stageId][msg.sender] += buyAmount;
        totalBought += buyAmount;
        stage.totalRealBought += buyAmount;
        stage.totalDAICollected += _amount;

        require(totalBought <= HARDCAP, "Presale: Hardcap reached");

        SafeERC20.safeTransfer(IERC20(address(real)), msg.sender, buyAmount);

        emit REALPurchasedWithDAI(msg.sender, _stageId, _amount, buyAmount);
    }

    function withdrawETH(uint256 amount) external onlyOwner {
        require(
            address(this).balance >= amount,
            "Presale: Not enough ETH in contract"
        );
        payable(msg.sender).transfer(amount);

        emit ETHWithdrawn(amount);
    }

    function withdrawUSDT(uint256 amount) external onlyOwner {
        require(
            usdt.balanceOf(address(this)) >= amount,
            "Presale: Not enough USDT in contract"
        );
        SafeERC20.safeTransfer(IERC20(address(usdt)), msg.sender, amount);

        emit USDTWithdrawn(amount);
    }

    function withdrawUSDC(uint256 amount) external onlyOwner {
        require(
            usdc.balanceOf(address(this)) >= amount,
            "Presale: Not enough USDC in contract"
        );
        SafeERC20.safeTransfer(IERC20(address(usdc)), msg.sender, amount);

        emit USDCWithdrawn(amount);
    }

    function withdrawREAL(uint256 amount) external onlyOwner {
        require(
            real.balanceOf(address(this)) >= amount,
            "Presale: Not enough REAL in contract"
        );
        SafeERC20.safeTransfer(IERC20(address(real)), msg.sender, amount);

        emit REALWithdrawn(amount);
    }

    function pause() public whenNotPaused onlyOwner{
        _pause();
    }

    function unpause() public whenPaused onlyOwner{
        _unpause();
    }

    // method `setHARDCAP`
    // @dev - for testing purpose only
    function setHARDCAP(uint256 hardcap) public onlyOwner {
        HARDCAP = hardcap;
    }

    // method `setICODuration`
    // @dev - for testing purpose only
    function setICODuration(uint64 _icoDuration) public onlyOwner {
        icoDuration = _icoDuration;
    }

    function getLatestETHPrice() public view returns (uint256, uint256) {
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        return ((uint256(price) * 10 ** 10), updatedAt); // Convert to 18 decimals
    }

    function getStageStatus(
        uint32 _stageId
    ) public view returns (bool _status) {
        if (
            block.timestamp >= uint256(stages[_stageId].timeToStart) &&
            block.timestamp <= uint256(stages[_stageId].timeToEnd)
        ) {
            return true;
        } else {
            return false;
        }
    }

    function getICOStatus() public view returns (bool _status) {
        if (icoStartTime == 0 || block.timestamp < uint256(icoStartTime)) {
            return false;
        }

        if (totalBought >= HARDCAP) {
            return false;
        }
            if (block.timestamp > uint256(icoStartTime + icoDuration)) {
            return false;
        }
        return true;
    }

    function userTotalBought(
        address user
    )
        public
        view
        returns (UserBoughtData[] memory data, uint256 _userTotalBought)
    {
        data = new UserBoughtData[](stages.length);
        for (uint32 i = 0; i < stages.length; i++) {
            data[uint(i)].stageID = i;
            data[uint(i)].amount = userBought[i][user];
            _userTotalBought += userBought[i][user];
        }
    }
}
