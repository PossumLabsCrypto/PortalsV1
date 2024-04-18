// SPDX-License-Identifier: MIT
pragma solidity =0.8.19;

interface ICompounder {
    function compound(
        address[] memory pools,
        address[][] memory rewarders,
        uint256 startEpochTimestamp,
        uint256 noOfEpochs,
        uint256[] calldata tokenIds
    ) external;
}
