// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IStaking {
    function deposit(address _to, uint256 _amount) external;

    function withdraw(uint256 _amount) external;
}