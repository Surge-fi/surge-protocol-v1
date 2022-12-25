// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../../src/Pool.sol";
import "../../src/Factory.sol";
import "../../src/PoolLens.sol";
import "../mocks/ERC20.sol";

contract PoolTest is Test, Pool(IERC20(address(0)), IERC20(address(1)), 1, 0, 0, 0, 0, 0) {

    Factory factory;
    PoolLens lens;

    function setUp() public {
        factory = new Factory(address(this));
        lens = new PoolLens();
    }

    function testInvestDivest() external {
        // create tokens
        MockERC20 collateralToken = new MockERC20(0, 18);
        MockERC20 loanToken = new MockERC20(1000e18, 18);
        // create pool
        Pool pool = factory.deployPool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15, 0.1e18, 0.4e18, 0.6e18);
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
        MockERC20 collateralToken = new MockERC20(1000e18, 18);
        MockERC20 loanToken = new MockERC20(1000e18, 18);
        Pool pool = factory.deployPool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), 1000e18);
        collateralToken.approve(address(pool), 1000e18);
        pool.invest(125e18);
        pool.secure(address(this), 100e18);
        pool.borrow(100e18);
        vm.warp(block.timestamp + 365 days);
        pool.repay(address(this), 140e18);
        pool.divest(140e18);
        pool.unsecure(100e18);
    }

    function testInterestAccrual20Util() external {
        MockERC20 collateralToken = new MockERC20(1000e18, 18);
        MockERC20 loanToken = new MockERC20(1000e18, 18);
        Pool pool = factory.deployPool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), 1000e18);
        collateralToken.approve(address(pool), 1000e18);
        pool.invest(100e18);
        pool.secure(address(this), 20e18);
        pool.borrow(20e18);
        vm.warp(block.timestamp + 365 days);
        pool.repay(address(this), 23.5e18);
        assertEq(pool.lastTotalDebt(), 0);
        pool.divest(103.5e18);
        pool.unsecure(20e18);
    }

    function testInterestAccrual90Util() external {
        MockERC20 collateralToken = new MockERC20(1000e18, 18);
        MockERC20 loanToken = new MockERC20(1000e18, 18);
        Pool pool = factory.deployPool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), 1000e18);
        collateralToken.approve(address(pool), 1000e18);
        pool.invest(125e18);
        pool.secure(address(this), 90e18);
        pool.borrow(90e18);
        pool.divest(25e18);
        vm.warp(block.timestamp + 365 days);
        pool.repay(address(this), 135e18);
        assertEq(pool.lastTotalDebt(), 0);
        pool.divest(135e18);
        pool.unsecure(90e18);
    }

    function testInterestAccrual100Util() external {
        MockERC20 collateralToken = new MockERC20(1000e18, 18);
        MockERC20 loanToken = new MockERC20(1000e18, 18);
        Pool pool = factory.deployPool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), 1000e18);
        collateralToken.approve(address(pool), 1000e18);
        pool.invest(125e18);
        pool.secure(address(this), 100e18);
        pool.borrow(100e18);
        pool.divest(25e18);
        vm.warp(block.timestamp + 365 days);
        pool.repay(address(this), 160e18);
        assertEq(pool.lastTotalDebt(), 0);
        pool.divest(160e18);
        pool.unsecure(100e18);
    }

}
