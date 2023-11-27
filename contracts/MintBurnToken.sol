// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MintBurnToken is ERC20, ERC20Burnable, Ownable(msg.sender), ERC20Permit {
    constructor() ERC20("PrincipalToken", "PRINCIPAL") ERC20Permit("PrincipalToken"){}

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}