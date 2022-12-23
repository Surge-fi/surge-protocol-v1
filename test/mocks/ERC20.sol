// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

contract MockERC20 {

    uint8 public immutable decimals;
    uint public immutable totalSupply;
    mapping (address => uint) public balanceOf;
    mapping (address => mapping (address => uint)) public allowance;

    constructor (uint supply, uint8 _decimals) {
        decimals = _decimals;
        balanceOf[msg.sender] = totalSupply = supply;
    }

    function transfer(address to, uint amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint amount) public returns (bool) {
        allowance[from][msg.sender] -= amount;

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

}