// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract Vesting is Ownable, ReentrancyGuard {
    using Strings for address;
    using Strings for uint;

    struct EventDetail {
        uint8 eventNumber;
        uint256 eventMaturityTime;
        bool unlockStatus;
    }

    uint8 public totalEvents; // @dev unlock event range 1-10
    uint8 public maturedEvents;
    uint256 public vestingDuration; // @dev unlock duration range 1-120 months
    uint256 public startTime;
    uint256 public eventSpan;
    uint256 public lockedFund;
    uint256 public unlockedFund;
    uint256 public amountPerEvent;
    string[] public memo;
    EventDetail[] public eventDetails;

    IERC20 public token;
    address public factory;
    uint256 public nftTokenId;

    event VestingStarted(
        uint256 amount,
        uint8 totalEvents,
        uint256 vestingDuration,
        uint256 startTime
    );
    event UnlockedEvent(uint256 amount, uint8 eventCount, uint256 unlockedTime);

    constructor(
        address _initialOwner,
        address _token,
        uint256 _vestingAmount,
        uint8 _totalEvents,
        uint8 _vestingDuration,
        string memory _vestingMemo
    ) Ownable(_initialOwner) {
        factory = msg.sender;
        require(
            _token != address(0),
            "Token address cannot be zero address"
        );
        token = IERC20(_token);
        require(_totalEvents <= 10 && _totalEvents > 0, "Invalid total events");

        // @dev - {_vestingDuration} must be in number of months. e.g. 1 ~ 1 month , 120 ~ 120 months

        require(
            _vestingDuration <= 120 && _vestingDuration >= 1,
            "Invalid vesting duration"
        );

        lockedFund = _vestingAmount;
        totalEvents = _totalEvents;
        vestingDuration = _vestingDuration * uint256(30 days);
        eventSpan = vestingDuration / totalEvents;
        startTime = block.timestamp;
        // Calculate amount per event, remainder will be added to last event
        amountPerEvent = lockedFund / totalEvents;

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

    function unlockFund(
        string memory _unlockingMemo
    )
        external
        onlyOwner
        nonReentrant
        returns (uint256 amountToSent, string memory evString)
    {
        require(totalEvents > maturedEvents, "Vesting completed");
        require(lockedFund > unlockedFund, "unable to lock");

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
                    bytes memory eventsBytesEn;
                    if (i < arrayLen - 1) {
                        eventsBytesEn = abi.encodePacked(__eventsBytes, ", ");
                    } else {
                        eventsBytesEn = abi.encodePacked(__eventsBytes);
                    }

                    evBytes = bytes.concat(evBytes, eventsBytesEn);
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
     */
    function getClaimableAmount() public view returns (uint256) {
        uint8 _maturedEvents = 0;
        uint arrayLen = eventDetails.length;

        for (uint i; i < arrayLen; i++) {
            if (eventDetails[i].eventMaturityTime <= block.timestamp) {
                if (!eventDetails[i].unlockStatus) {
                    _maturedEvents++;
                }
            }
        }

        return amountPerEvent * uint256(_maturedEvents);
    }

    /**
     * @dev Get next release date and amount
     */
    function getNextReleaseInfo() public view returns (uint256 nextReleaseDate, uint256 nextReleaseAmount) {
        uint arrayLen = eventDetails.length;

        for (uint i; i < arrayLen; i++) {
            if (eventDetails[i].eventMaturityTime > block.timestamp && !eventDetails[i].unlockStatus) {
                nextReleaseDate = eventDetails[i].eventMaturityTime;
                nextReleaseAmount = amountPerEvent;
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
