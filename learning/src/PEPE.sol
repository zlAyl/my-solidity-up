// SPDX-License-Identifier: MIT 
pragma solidity ^0.8;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PEPE is ERC20,Ownable {
    bool public limited;
    uint256 public maxHoldingAmount;
    uint256 public minHoldingAmount;
    address public uniswapV2Pair; //DEX 交易池的地址
    mapping(address => bool) blackLists;

    constructor(uint256 _totalSupply) ERC20("Pepe", "PEPE") Ownable(msg.sender){
        _mint(msg.sender,_totalSupply);
    }

    function blacklist(address _address,bool _isBlacklisting) external onlyOwner {
        blackLists[_address] = _isBlacklisting;
    }

    function setRule(bool _limited, address _uniswapV2Pair, uint256 _maxHoldingAmount, uint256 _minHoldingAmount) external onlyOwner {
        limited = _limited;
        uniswapV2Pair = _uniswapV2Pair;
        maxHoldingAmount = _maxHoldingAmount;
        minHoldingAmount = _minHoldingAmount;
    }

    // OpenZeppelin v5.x 版本
    function _update(address from, address to, uint256 value) internal virtual override  {
        require(!blackLists[to] && !blackLists[from], "Blacklisted");
        if (uniswapV2Pair == address(0)) { //表示交易还没开始，还没给交易池的地址 防预售机器人 / 防前置交易
            require(from == owner() || to == owner(), "trading is not started");
            return;
        }
        if (limited && from == uniswapV2Pair) {
            require(super.balanceOf(to) + value <= maxHoldingAmount && super.balanceOf(to) + value >= minHoldingAmount, "Forbid");
        }

        super._update(from,to,value);
    }

    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }
 
}