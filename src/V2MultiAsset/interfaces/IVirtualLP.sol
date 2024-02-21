// SPDX-License-Identifier: MIT
pragma solidity =0.8.19;

interface IVirtualLP {
    function PSM_sendToPortalUser(address _recipient, uint256 _amount) external;

    function depositToYieldSource(address _asset, uint256 _amount) external;

    function withdrawFromYieldSource(
        address _asset,
        address _user,
        uint256 _amount
    ) external;
}
