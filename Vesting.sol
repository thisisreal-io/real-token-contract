// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract Vesting is ReentrancyGuard {
    using Strings for address;
    using Strings for uint;

    struct EventDetail {
        uint8 eventNumber;
        uint256 eventMaturityTime;
        bool unlockStatus;
    }

    uint8 public totalEvents; // @dev unlock event range 1-120
    uint8 public maturedEvents;
    uint256 public vestingDuration; // @dev unlock duration range 1-1200 months (max 100 years)
    uint256 public startTime;
    uint256 public eventSpan;
    uint16 public firstUnlockMonth; // @dev months before first unlock (0 = current behavior)
    uint256 public lockedFund;
    uint256 public unlockedFund;
    uint256 public amountPerEvent;
    string[] public memo;
    EventDetail[] public eventDetails;

    IERC20 public token;
    IERC721 public vestingReceiptNFT;
    address public factory;
    uint256 public nftTokenId;

    // Maximum memo length in bytes (256 bytes = ~256 ASCII characters)
    uint256 public constant MAX_MEMO_BYTES = 256;

    event VestingStarted(
        uint256 amount,
        uint8 totalEvents,
        uint256 vestingDuration,
        uint256 startTime
    );
    event UnlockedEvent(uint256 amount, uint8 eventCount, uint256 unlockedTime);
    event LockedFundAdjusted(uint256 previousLockedFund, uint256 newLockedFund);

    constructor(
        address _token,
        uint256 _vestingAmount,
        uint8 _totalEvents,
        uint16 _vestingDuration,
        uint16 _firstUnlockMonth,
        string memory _vestingMemo,
        address _vestingReceiptNFT
    ) {
        factory = msg.sender;
        require(
            _token != address(0),
            "Token address cannot be zero address"
        );
        require(
            _vestingReceiptNFT != address(0),
            "VestingReceiptNFT address cannot be zero"
        );
        token = IERC20(_token);
        vestingReceiptNFT = IERC721(_vestingReceiptNFT);
        require(_totalEvents > 0, "Invalid total events");

        // @dev - {_vestingDuration} must be in number of months. e.g. 1 ~ 1 month , 120 ~ 120 months

        require(
            _vestingDuration <= 1200 && _vestingDuration >= 1,
            "Invalid vesting duration"
        );

        if (_firstUnlockMonth == 0) {
            require(
                _totalEvents <= _vestingDuration,
                "Total events exceeds vesting duration"
            );
        } else if (_totalEvents == 1) {
            require(
                _firstUnlockMonth <= _vestingDuration,
                "First unlock month must not exceed vesting duration"
            );
        } else {
            require(
                _totalEvents <= (_vestingDuration - _firstUnlockMonth),
                "Total events exceeds disbursement window"
            );
        }

        lockedFund = _vestingAmount;
        totalEvents = _totalEvents;
        firstUnlockMonth = _firstUnlockMonth;
        vestingDuration = _vestingDuration * uint256(30 days);
        startTime = block.timestamp;
        amountPerEvent = lockedFund / totalEvents;

        if (_firstUnlockMonth == 0) {
            eventSpan = vestingDuration / totalEvents;

            for (uint8 i = 1; i <= totalEvents; ) {
                eventDetails.push(
                    EventDetail({
                        eventNumber: (i),
                        eventMaturityTime: (eventSpan * uint256(i)) +
                            block.timestamp,
                        unlockStatus: false
                    })
                );

                unchecked {
                    i++;
                }
            }
        } else {
            uint256 _firstUnlockTime = block.timestamp + (uint256(_firstUnlockMonth) * 30 days);
            uint256 vestingEnd = block.timestamp + vestingDuration;

            if (_totalEvents == 1) {
                eventSpan = 0;
                eventDetails.push(
                    EventDetail({
                        eventNumber: 1,
                        eventMaturityTime: _firstUnlockTime,
                        unlockStatus: false
                    })
                );
            } else {
                eventSpan = (vestingEnd - _firstUnlockTime) / (uint256(_totalEvents) - 1);

                for (uint8 i = 0; i < _totalEvents; ) {
                    uint256 maturityTime;
                    if (i == _totalEvents - 1) {
                        maturityTime = vestingEnd;
                    } else {
                        maturityTime = _firstUnlockTime + (eventSpan * uint256(i));
                    }

                    eventDetails.push(
                        EventDetail({
                            eventNumber: i + 1,
                            eventMaturityTime: maturityTime,
                            unlockStatus: false
                        })
                    );

                    unchecked {
                        i++;
                    }
                }
            }
        }

        bytes memory __vestingMemo = abi.encodePacked(
            "Memo:- Vesting started: ",
            " locked amount: ",
            (lockedFund).toString(),
            ", Start time: ",
            (block.timestamp).toString(),
            ", ",
            _vestingMemo
        );
        memo.push(string(__vestingMemo));

        emit VestingStarted(
            lockedFund,
            totalEvents,
            vestingDuration,
            block.timestamp
        );
    }

    /**
     * @dev Adjust locked fund to match the actual amount received (fee-on-transfer / deflationary tokens).
     * Callable only by the factory, intended to be called immediately after token transfer in the same tx.
     *
     * This updates `lockedFund` and recalculates `amountPerEvent` so future unlocks match real balance.
     */
    function adjustLockedFund(uint256 _actualLockedFund) external {
        require(msg.sender == factory, "Only factory can adjust locked fund");
        require(unlockedFund == 0 && maturedEvents == 0, "Vesting already started");
        require(_actualLockedFund > 0, "Actual locked fund must be > 0");

        uint256 previous = lockedFund;
        lockedFund = _actualLockedFund;
        amountPerEvent = lockedFund / totalEvents;

        emit LockedFundAdjusted(previous, _actualLockedFund);
    }

    function unlockFund(
        string memory _unlockingMemo
    )
        external
        nonReentrant
        returns (uint256 amountToSent, string memory evString)
    {
        require(nftTokenId != 0, "NFT token ID not set");
        require(
            vestingReceiptNFT.ownerOf(nftTokenId) == msg.sender,
            "Not NFT holder"
        );
        require(totalEvents > maturedEvents, "Vesting completed");
        require(lockedFund > unlockedFund, "unable to lock");
        require(
            bytes(_unlockingMemo).length <= MAX_MEMO_BYTES,
            "Unlocking memo exceeds maximum length"
        );

        uint8 _maturedEvents;
        uint arrayLen = eventDetails.length;
        bytes memory evBytes = new bytes(0);

        for (uint i; i < arrayLen; i++) {
            if (eventDetails[i].eventMaturityTime <= block.timestamp) {
                if (!eventDetails[i].unlockStatus) {
                    eventDetails[i].unlockStatus = true;
                    _maturedEvents++;

                    bytes memory __eventsBytes = bytes(
                        uint(eventDetails[i].eventNumber).toString()
                    );
                    
                    // Add comma only if we've already added at least one event
                    // This ensures no trailing comma regardless of array position
                    if (evBytes.length > 0) {
                        evBytes = bytes.concat(evBytes, ", ", __eventsBytes);
                    } else {
                        evBytes = bytes.concat(evBytes, __eventsBytes);
                    }
                }
            }
        }

        require(_maturedEvents > 0, "No amount to unlock");

        // Calculate amount to send, handling remainder from division
        uint256 baseAmount = amountPerEvent * uint256(_maturedEvents);
        
        // If this is the last unlock event, include any remainder tokens
        if (maturedEvents + _maturedEvents == totalEvents) {
            uint256 remainder = lockedFund - (amountPerEvent * uint256(totalEvents));
            amountToSent = baseAmount + remainder;
        } else {
            amountToSent = baseAmount;
        }
        
        maturedEvents += _maturedEvents;
        unlockedFund += amountToSent;

        bytes memory __unlockingMemo = abi.encodePacked(
            "Memo:- Events: ",
            string(evBytes),
            ", Unlocked amount: ",
            (amountToSent).toString(),
            ", Unlock time: ",
            (block.timestamp).toString(),
            ", ",
            _unlockingMemo
        );

        evString = string(__unlockingMemo);
        memo.push(evString);

        SafeERC20.safeTransfer(token, msg.sender, amountToSent);

        emit UnlockedEvent(amountToSent, maturedEvents, block.timestamp);
        return (amountToSent, evString);
    }

    /**
     * @dev Set NFT token ID (only callable by factory)
     */
    function setNFTTokenId(uint256 _nftTokenId) external {
        require(msg.sender == factory, "Only factory can set NFT token ID");
        require(nftTokenId == 0, "NFT token ID already set");
        nftTokenId = _nftTokenId;
    }

    /**
     * @dev Get current vesting balance (locked tokens remaining)
     */
    function getCurrentVestingBalance() public view returns (uint256) {
        return lockedFund - unlockedFund;
    }

    /**
     * @dev Get claimable amount (matured events that haven't been unlocked yet)
     * Accounts for remainder tokens that are added to the final vesting event
     */
    function getClaimableAmount() public view returns (uint256) {
        uint8 _maturedEvents = 0;
        bool includesFinalEvent = false;
        uint arrayLen = eventDetails.length;

        for (uint i; i < arrayLen; i++) {
            if (eventDetails[i].eventMaturityTime <= block.timestamp) {
                if (!eventDetails[i].unlockStatus) {
                    _maturedEvents++;
                    // Check if this is the final event (eventNumber == totalEvents)
                    if (eventDetails[i].eventNumber == totalEvents) {
                        includesFinalEvent = true;
                    }
                }
            }
        }

        uint256 baseAmount = amountPerEvent * uint256(_maturedEvents);
        
        // If final event is included, add remainder tokens
        if (includesFinalEvent) {
            uint256 remainder = lockedFund - (amountPerEvent * uint256(totalEvents));
            return baseAmount + remainder;
        }
        
        return baseAmount;
    }

    /**
     * @dev Get next release date and amount
     * Accounts for remainder tokens that are added to the final vesting event
     */
    function getNextReleaseInfo() public view returns (uint256 nextReleaseDate, uint256 nextReleaseAmount) {
        uint arrayLen = eventDetails.length;

        for (uint i; i < arrayLen; i++) {
            if (eventDetails[i].eventMaturityTime > block.timestamp && !eventDetails[i].unlockStatus) {
                nextReleaseDate = eventDetails[i].eventMaturityTime;
                nextReleaseAmount = amountPerEvent;
                
                // If this is the final event, add remainder tokens
                if (eventDetails[i].eventNumber == totalEvents) {
                    uint256 remainder = lockedFund - (amountPerEvent * uint256(totalEvents));
                    nextReleaseAmount = amountPerEvent + remainder;
                }
                
                break;
            }
        }
    }

    /**
     * @dev Get vesting end date
     */
    function getVestingEndDate() public view returns (uint256) {
        return startTime + vestingDuration;
    }

    /**
     * @dev Get release ratio string (e.g., "3/10")
     */
    function getReleaseRatio() public view returns (string memory) {
        return string(abi.encodePacked(uint256(maturedEvents).toString(), "/", uint256(totalEvents).toString()));
    }

    /**
     * @dev Get all event details
     * @return Array of EventDetail structs
     */
    function getAllEventDetails() public view returns (EventDetail[] memory) {
        return eventDetails;
    }

    /**
     * @dev Get all memos
     * @return Array of memo strings
     */
    function getAllMemos() public view returns (string[] memory) {
        return memo;
    }

    /**
     * @dev Get remainder tokens (if any) that will be unlocked in final event
     * @return Remainder amount
     */
    function getRemainderAmount() public view returns (uint256) {
        return lockedFund - (amountPerEvent * uint256(totalEvents));
    }
}
