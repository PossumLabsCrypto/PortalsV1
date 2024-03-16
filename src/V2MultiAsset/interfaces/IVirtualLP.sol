// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

interface IVirtualLP {
    function PSM_sendToPortalUser(address _recipient, uint256 _amount) external;

    function depositToYieldSource(address _asset, uint256 _amount) external;

    function withdrawFromYieldSource(
        address _asset,
        address _user,
        uint256 _amount
    ) external;

    function isActiveLP() external view returns (bool);

    function fundingRewardPool() external view returns (uint256);
}
