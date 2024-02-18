// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

error PortalNotRegistered();
error NotOwner();
error InvalidAddress();
error OwnerNotExpired();

/// @title Portal V2 Virtual LP
/// @author Possum Labs
/** @notice This contract serves as the collective, virtual LP for multiple Portals
 * Each Portal registers with an individual constantProduct K
 * The full amount of PSM inside the LP is available for each Portal
 * The LP is refilled by convert() calls of all registered Portals
 * The contract is owned for a predetermined time to enable registering more Portals
 * Registering more Portals must be permissioned because it can be malicious
 * Portals cannot be removed from the registry to guarantee Portal integrity
 */
/// @dev Deployment Process:
/// @dev 1. Deploy VirtualLP, 2. Deploy Portals, 3. Register Portals in VirtualLP
contract VirtualLP is ReentrancyGuard {
    constructor(address _owner) {
        if (_owner == address(0)) {
            revert InvalidAddress();
        }
        owner = _owner;
        OWNER_EXPIRY_TIME = OWNER_DURATION + block.timestamp;
    }

    using SafeERC20 for IERC20;

    address public owner;
    address public constant PSM_ADDRESS =
        0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5;
    uint256 public immutable OWNER_EXPIRY_TIME;
    uint256 private constant OWNER_DURATION = 31536000; // 1 Year

    mapping(address portal => bool isRegistered) public registeredPortals;

    /// ======== FUNCTIONS & MODIFIER ===============

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    /// @notice This function transfers PSM to a recipient address
    /// @dev Can only be called by a registered address (Portal)
    /// @dev All critical logic is handled by the Portal, hence no additional checks
    function PSM_sendToPortalUser(
        address _recipient,
        uint256 _amount
    ) public nonReentrant {
        /// @dev Check that the caller is a registered address (Portal)
        if (!registeredPortals[msg.sender]) {
            revert PortalNotRegistered();
        }
        /// @dev Transfer PSM to the recipient
        IERC20(PSM_ADDRESS).transfer(_recipient, _amount);
    }

    /// @notice Function to add new Portals to the registry
    /// @dev Portals can only be added, never removed
    /// @dev Only callable by Owner to prevent malicious Portals
    function registerPortal(address _portal) public onlyOwner {
        registeredPortals[_portal] = true;
    }

    /// @notice This function disables the ownership access
    /// @dev Set the zero address as owner
    /// @dev Callable by anyone after duration passed
    function removeOwner() public {
        if (block.timestamp < OWNER_EXPIRY_TIME) {
            revert OwnerNotExpired();
        }
        owner = address(0);
    }

    /// @notice This function shows the amount of PSM inside the contract
    function getLiqudityPSM() external view returns (uint256 amountPSM) {
        amountPSM = IERC20(PSM_ADDRESS).balanceOf(address(this));
    }
}
