// SPDX-License-Identifier: MIT
pragma solidity =0.8.19;

interface ISingleStaking {
    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function claimAll() external;

    function getPoolTokenAddress(uint256 _pid) external view returns (address);

    function poolLength() external view returns (uint256);
}
