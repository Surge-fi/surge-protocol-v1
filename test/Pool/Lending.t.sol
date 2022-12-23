// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../../src/Pool.sol";
import "../../src/Factory.sol";
import "../mocks/ERC20.sol";

contract PoolTest is Test {

    Factory factory;

    function setUp() public {
        factory = new Factory(address(this));
    }

    function testInvestDivest() external {
        // create tokens
        MockERC20 collateralToken = new MockERC20(0, 18);
        MockERC20 loanToken = new MockERC20(1000e18, 18);
        // create pool
        Pool pool = factory.deployPool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15);
        loanToken.approve(address(pool), 1000e18);
        // invest 100
        pool.invest(100e18);
        // assert balances
        assertEq(loanToken.balanceOf(address(pool)), 100e18);
        assertEq(loanToken.balanceOf(address(this)), 900e18);
        assertEq(pool.balanceOf(address(this)), 100e18);
        assertEq(pool.totalSupply(), 100e18);
        // invest 900
        pool.invest(900e18);
        // assert balances
        assertEq(loanToken.balanceOf(address(pool)), 1000e18);
        assertEq(loanToken.balanceOf(address(this)), 0e18);
        assertEq(pool.balanceOf(address(this)), 1000e18);
        assertEq(pool.totalSupply(), 1000e18);
        // divest 1000
        pool.divest(1000e18);
        // assert balances
        assertEq(loanToken.balanceOf(address(pool)), 0e18);
        assertEq(loanToken.balanceOf(address(this)), 1000e18);
        assertEq(pool.balanceOf(address(this)), 0e18);
        assertEq(pool.totalSupply(), 0e18);
    }

    function testInterestAccrual() external {
        // create tokens
        MockERC20 collateralToken = new MockERC20(1000e18, 18);
        MockERC20 loanToken = new MockERC20(100e18, 18);
        // create pool
        Pool pool = factory.deployPool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15);
        loanToken.approve(address(pool), 1000e18);
        // invest 100
        pool.invest(100e18);
        // add collateral using secure()
        collateralToken.approve(address(pool), 100e18);
        pool.secure(address(this), 100e18);
        pool.borrow(80e18);
        // move time forward 1 day
        vm.warp(block.timestamp + 365 days);
        // assert interest accrued
        pool.divest(20);
        vm.warp(block.timestamp + 365 days);
        pool.invest(20);
    }

}
