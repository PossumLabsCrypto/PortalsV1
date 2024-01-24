// SPDX-License-Identifier: MIT
pragma solidity =0.8.19;

interface IDualStaking {
    // enter address of esVKA or VKA
    function stake(uint256 amount, address token) external;

    /// @notice function to claim protocol fee and re stake the esVKA rewards
    function compound() external;

    function pendingRewardsUSDC(address account) external view returns (uint);
}
