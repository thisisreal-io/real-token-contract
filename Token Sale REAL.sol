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
    uint256 public HARDCAP;
    uint256 public totalBought;
    uint64 public icoDuration; // in seconds
    uint64 public icoStartTime;

    AggregatorV3Interface internal priceFeed;

    // Multi-signature system (5 signers, 3 of 5 required)
    address[5] public signers;
    uint256 public constant REQUIRED_SIGNATURES = 3;
    uint256 public constant TIMELOCK_DURATION = 7 days; // 7 days timelock for withdrawals
    address public mainDepositWallet;

    // Multi-sig proposal tracking
    mapping(bytes32 => mapping(address => bool)) public proposalSignatures;
    mapping(bytes32 => uint256) public proposalSignatureCount;
    mapping(bytes32 => uint256) public proposalCreatedAt;

    // Timelock queue for withdrawals
    struct WithdrawalQueue {
        address token; // address(0) for ETH
        uint256 amount;
        uint256 queuedAt;
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
    event WithdrawalQueued(
        bytes32 indexed proposalId,
        address indexed token,
        uint256 amount,
        uint256 executeAfter
    );
    event WithdrawalExecuted(
        bytes32 indexed proposalId,
        address indexed token,
        uint256 amount
    );
    event ProposalSigned(
        bytes32 indexed proposalId,
        address indexed signer
    );

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

    function getProposalId(
        address _token,
        uint256 _amount,
        bytes32 _nonce
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_token, _amount, _nonce));
    }

    function signProposal(bytes32 _proposalId) external onlySigner {
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

    constructor(
        address _real,
        address _usdt,
        address _usdc,
        address _dai,
        uint256 _hardCAP,
        address _mainDepositWallet
    ) {
        priceFeed = AggregatorV3Interface(
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
        );
        //priceFeed = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306);

        real = IERC20Metadata(_real);
        usdt = IERC20Metadata(_usdt);
        usdc = IERC20Metadata(_usdc);
        dai = IERC20Metadata(_dai);
        HARDCAP = _hardCAP;
        mainDepositWallet = _mainDepositWallet;

        // Initialize multi-signature signers
        signers[0] = 0x4106E21F155383DfB947b44e2A846405Cd7837A6; // Creator Wallet
        signers[1] = 0x2438d494751cFeB9551342be64D3F7C645975067; // Aquisitions Wallet
        signers[2] = 0xeCCb924aFec718a2cB0a4546D6569c9E4F825177; // Org Operations Wallet
        signers[3] = 0xBc3B0Bdead411d8034b6DAC49e2e666dA8779D16; // Org Developement Wallet
        signers[4] = 0xa39Be9812b96A198C92B7723dBb6E1D561Eb94F4; // Founder Wallet
    }

    function startICO(uint64 _icoDuration) external onlySigner {
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
    ) external onlySigner {
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
    ) external onlySigner validStage(_stageId) {
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

    function withdrawETH(uint256 amount, bytes32 nonce) external onlySigner {
        require(
            address(this).balance >= amount,
            "Presale: Not enough ETH in contract"
        );
        
        bytes32 proposalId = getProposalId(address(0), amount, nonce);
        
        // Auto-sign if not already signed by this signer
        if (!proposalSignatures[proposalId][msg.sender]) {
            proposalSignatures[proposalId][msg.sender] = true;
            proposalSignatureCount[proposalId]++;
            if (proposalCreatedAt[proposalId] == 0) {
                proposalCreatedAt[proposalId] = block.timestamp;
            }
            emit ProposalSigned(proposalId, msg.sender);
        }
        
        // If not enough signatures yet, return (waiting for more signatures)
        if (!hasRequiredSignatures(proposalId)) {
            return;
        }
        
        // If enough signatures but not queued yet, queue it
        if (withdrawalQueue[proposalId].queuedAt == 0) {
            withdrawalQueue[proposalId] = WithdrawalQueue({
                token: address(0),
                amount: amount,
                queuedAt: block.timestamp,
                executed: false
            });
            emit WithdrawalQueued(proposalId, address(0), amount, block.timestamp + TIMELOCK_DURATION);
            return;
        }
        
        // Execute withdrawal if timelock has passed
        WithdrawalQueue storage queue = withdrawalQueue[proposalId];
        require(block.timestamp >= queue.queuedAt + TIMELOCK_DURATION, "Presale: Timelock not expired");
        require(!queue.executed, "Presale: Already executed");
        
        queue.executed = true;
        (bool success, ) = payable(mainDepositWallet).call{value: amount}("");
        require(success, "Presale: ETH transfer failed");
        
        emit ETHWithdrawn(amount);
        emit WithdrawalExecuted(proposalId, address(0), amount);
    }

    function withdrawUSDT(uint256 amount, bytes32 nonce) external onlySigner {
        require(
            usdt.balanceOf(address(this)) >= amount,
            "Presale: Not enough USDT in contract"
        );
        
        bytes32 proposalId = getProposalId(address(usdt), amount, nonce);
        
        // Auto-sign if not already signed by this signer
        if (!proposalSignatures[proposalId][msg.sender]) {
            proposalSignatures[proposalId][msg.sender] = true;
            proposalSignatureCount[proposalId]++;
            if (proposalCreatedAt[proposalId] == 0) {
                proposalCreatedAt[proposalId] = block.timestamp;
            }
            emit ProposalSigned(proposalId, msg.sender);
        }
        
        // If not enough signatures yet, return (waiting for more signatures)
        if (!hasRequiredSignatures(proposalId)) {
            return;
        }
        
        // If enough signatures but not queued yet, queue it
        if (withdrawalQueue[proposalId].queuedAt == 0) {
            withdrawalQueue[proposalId] = WithdrawalQueue({
                token: address(usdt),
                amount: amount,
                queuedAt: block.timestamp,
                executed: false
            });
            emit WithdrawalQueued(proposalId, address(usdt), amount, block.timestamp + TIMELOCK_DURATION);
            return;
        }
        
        // Execute withdrawal if timelock has passed
        WithdrawalQueue storage queue = withdrawalQueue[proposalId];
        require(block.timestamp >= queue.queuedAt + TIMELOCK_DURATION, "Presale: Timelock not expired");
        require(!queue.executed, "Presale: Already executed");
        
        queue.executed = true;
        SafeERC20.safeTransfer(IERC20(address(usdt)), mainDepositWallet, amount);

        emit USDTWithdrawn(amount);
        emit WithdrawalExecuted(proposalId, address(usdt), amount);
    }

    function withdrawUSDC(uint256 amount, bytes32 nonce) external onlySigner {
        require(
            usdc.balanceOf(address(this)) >= amount,
            "Presale: Not enough USDC in contract"
        );
        
        bytes32 proposalId = getProposalId(address(usdc), amount, nonce);
        
        // Auto-sign if not already signed by this signer
        if (!proposalSignatures[proposalId][msg.sender]) {
            proposalSignatures[proposalId][msg.sender] = true;
            proposalSignatureCount[proposalId]++;
            if (proposalCreatedAt[proposalId] == 0) {
                proposalCreatedAt[proposalId] = block.timestamp;
            }
            emit ProposalSigned(proposalId, msg.sender);
        }
        
        // If not enough signatures yet, return (waiting for more signatures)
        if (!hasRequiredSignatures(proposalId)) {
            return;
        }
        
        // If enough signatures but not queued yet, queue it
        if (withdrawalQueue[proposalId].queuedAt == 0) {
            withdrawalQueue[proposalId] = WithdrawalQueue({
                token: address(usdc),
                amount: amount,
                queuedAt: block.timestamp,
                executed: false
            });
            emit WithdrawalQueued(proposalId, address(usdc), amount, block.timestamp + TIMELOCK_DURATION);
            return;
        }
        
        // Execute withdrawal if timelock has passed
        WithdrawalQueue storage queue = withdrawalQueue[proposalId];
        require(block.timestamp >= queue.queuedAt + TIMELOCK_DURATION, "Presale: Timelock not expired");
        require(!queue.executed, "Presale: Already executed");
        
        queue.executed = true;
        SafeERC20.safeTransfer(IERC20(address(usdc)), mainDepositWallet, amount);

        emit USDCWithdrawn(amount);
        emit WithdrawalExecuted(proposalId, address(usdc), amount);
    }

    function withdrawREAL(uint256 amount, bytes32 nonce) external onlySigner {
        require(
            real.balanceOf(address(this)) >= amount,
            "Presale: Not enough REAL in contract"
        );
        
        bytes32 proposalId = getProposalId(address(real), amount, nonce);
        
        // Auto-sign if not already signed by this signer
        if (!proposalSignatures[proposalId][msg.sender]) {
            proposalSignatures[proposalId][msg.sender] = true;
            proposalSignatureCount[proposalId]++;
            if (proposalCreatedAt[proposalId] == 0) {
                proposalCreatedAt[proposalId] = block.timestamp;
            }
            emit ProposalSigned(proposalId, msg.sender);
        }
        
        // If not enough signatures yet, return (waiting for more signatures)
        if (!hasRequiredSignatures(proposalId)) {
            return;
        }
        
        // If enough signatures but not queued yet, queue it
        if (withdrawalQueue[proposalId].queuedAt == 0) {
            withdrawalQueue[proposalId] = WithdrawalQueue({
                token: address(real),
                amount: amount,
                queuedAt: block.timestamp,
                executed: false
            });
            emit WithdrawalQueued(proposalId, address(real), amount, block.timestamp + TIMELOCK_DURATION);
            return;
        }
        
        // Execute withdrawal if timelock has passed
        WithdrawalQueue storage queue = withdrawalQueue[proposalId];
        require(block.timestamp >= queue.queuedAt + TIMELOCK_DURATION, "Presale: Timelock not expired");
        require(!queue.executed, "Presale: Already executed");
        
        queue.executed = true;
        SafeERC20.safeTransfer(IERC20(address(real)), mainDepositWallet, amount);

        emit REALWithdrawn(amount);
        emit WithdrawalExecuted(proposalId, address(real), amount);
    }

    function pause() public whenNotPaused onlySigner {
        _pause();
    }

    function unpause() public whenPaused onlySigner {
        _unpause();
    }

    // method `setHARDCAP`
    // @dev - for testing purpose only
    function setHARDCAP(uint256 hardcap) public onlySigner {
        HARDCAP = hardcap;
    }

    // method `setICODuration`
    // @dev - for testing purpose only
    function setICODuration(uint64 _icoDuration) public onlySigner {
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
