// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IRewarder {
    // Call a specific reward contract to get the claimable reward for a specific staker
    function pendingReward(address _claimer) external view returns(uint256);
}