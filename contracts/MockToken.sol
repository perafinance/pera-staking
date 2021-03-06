// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockToken is ERC20, ERC20Burnable, Ownable {
    constructor() ERC20("Pera Finance", "PERA") {
        _mint(msg.sender, 7000000000 * 10 ** decimals()); //3144960000
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}