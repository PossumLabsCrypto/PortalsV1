// SPDX-License-Identifier: MIT
pragma solidity =0.8.19;

interface IWater {
    function deposit(
        uint256 _assets,
        address _receiver
    ) external returns (uint256);

    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner
    ) external returns (uint256);

    function withdrawETH(uint256 _assets) external returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function lockTime() external view returns (uint256);

    function withdrawalFees() external view returns (uint256);

    function DENOMINATOR() external view returns (uint256);
}
