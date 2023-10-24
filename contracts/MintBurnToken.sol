// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MintBurnToken is ERC20, ERC20Burnable, Ownable, ERC20Permit {
    constructor(
        address initialOwner
    )
        ERC20("PortalEnergy", "PE")
        Ownable(initialOwner)
        ERC20Permit("PortalEnergy")
    {}

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}
