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
        uint32 eventMaturityTime;
        bool unlockStatus;
    }

    uint8 public totalEvents; // @dev unlock event range 1-10
    uint8 public maturedEvents;
    uint32 public vestingDuration; // @dev unlock duration range 1-120 months
    uint32 public startTime;
    uint32 public eventSpan;
    uint256 public lockedFund;
    uint256 public unlockedFund;
    uint256 public amountPerEvent;
    string[] public memo;
    EventDetail[] public eventDetails;

    IERC20 public token;

    event VestingStarted(
        uint256 amount,
        uint8 totalEvents,
        uint32 vestingDuration,
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
        require(
            _token != address(0),
            "Token address cannot be zero address"
        );
        token = IERC20(_token);
        require(_totalEvents <= 10 && _totalEvents > 0, "Invalid total events");

        // @dev - {_vestingDuration} must be in number of months. e.g. 1 ~ 1 month , 10 ~ 10 months

        require(
            _vestingDuration <= 120 && _vestingDuration > 0,
            "Invalid vesting duration"
        );

        lockedFund = _vestingAmount;
        totalEvents = _totalEvents;
        vestingDuration = _vestingDuration * uint32(30 days);
        eventSpan = vestingDuration / totalEvents;
        startTime = uint32(block.timestamp);
        amountPerEvent = lockedFund / totalEvents;

        for (uint8 i = 1; i <= totalEvents; ) {
            eventDetails.push(
                EventDetail({
                    eventNumber: (i),
                    eventMaturityTime: (eventSpan * uint32(i)) +
                        uint32(block.timestamp),
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

        amountToSent = amountPerEvent * uint256(_maturedEvents);
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
}
