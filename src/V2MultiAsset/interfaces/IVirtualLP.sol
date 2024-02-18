// SPDX-License-Identifier: MIT
pragma solidity =0.8.19;

interface IVirtualLP {
    function PSM_sendToPortalUser(address _recipient, uint256 _amount) external;
}
