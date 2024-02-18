// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

error NotOwner();

contract MintBurnToken is ERC20, ERC20Burnable, ERC20Permit {
    address public immutable OWNER;

    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) ERC20Permit(name) {
        OWNER = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != OWNER) {
            revert NotOwner();
        }
        _;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
