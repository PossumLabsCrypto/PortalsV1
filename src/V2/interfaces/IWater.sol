// SPDX-License-Identifier: MIT
pragma solidity =0.8.19;

interface IWater {
    function deposit(
        uint256 _assets,
        address _receiver
    ) external returns (uint256);

    function depositETH() external payable returns (uint256);

    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner
    ) external returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function convertToAssets(uint256 assets) external view returns (uint256);
}
