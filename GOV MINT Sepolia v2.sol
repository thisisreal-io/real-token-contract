// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {GOVMINTv2} from "./GOV MINT v2.sol";

/// TEST CANDIDATE ONLY. Eligibility manifest is independently reconstructed by
/// scripts/gov-mint/build-electorate.mjs and attested by three current signers.
/// The history itself is not cryptographically verified on-chain. Do not fund
/// with real assets or deploy through any proxy with a separate upgrade admin.
contract GOVMINTSepoliaV2 is GOVMINTv2 {
    constructor() {
        require(block.chainid == 11155111 || block.chainid == 31337, "Sepolia/local only");
    }
    function _holdingPeriod() internal pure override returns (uint256) { return 30 hours; }
    function _votingPeriod() internal pure override returns (uint256) { return 30 hours; }
    function _timelockDuration() internal pure override returns (uint256) { return 30 hours; }
    function _cooldownDuration() internal pure override returns (uint256) { return 90 hours; }
    function _minimumVoters() internal pure override returns (uint256) { return 5; }
}
