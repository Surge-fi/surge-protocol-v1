// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/Pool.sol";
import "../src/Factory.sol";
import "../src/PoolLens.sol";
import "./mocks/ERC20.sol";

contract PoolTest is Test {

    Factory factory;
    PoolLens lens;

    function setUp() public {
        factory = new Factory(address(this), "G");
        lens = new PoolLens();
    }

    function testDepositWithdraw() external {
        uint amount = 1e36;
        MockERC20 collateralToken = new MockERC20(0, 18);
        MockERC20 loanToken = new MockERC20(amount, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), amount);
        pool.deposit(amount);
        assertEq(loanToken.balanceOf(address(pool)), amount);
        assertEq(loanToken.balanceOf(address(this)), 0);
        assertEq(pool.balanceOf(address(this)), amount);
        assertEq(pool.totalSupply(), amount);
        pool.withdraw(amount);
        assertEq(loanToken.balanceOf(address(pool)), 0);
        assertEq(loanToken.balanceOf(address(this)), amount);
        assertEq(pool.balanceOf(address(this)), 0);
        assertEq(pool.totalSupply(), 0);
    }

    function testDepositWithdrawAll() public {
        uint amount = 1000;
        MockERC20 collateralToken = new MockERC20(0, 18);
        MockERC20 loanToken = new MockERC20(1004, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), amount);
        loanToken.transfer(address(1), 3);
        vm.prank(address(1));
        loanToken.approve(address(pool), 3);
        vm.prank(address(1));
        pool.deposit(3);
        pool.deposit(amount);
        assertEq(pool.balanceOf(address(this)), amount);
        loanToken.transfer(address(pool), 1); // to trigger x * y % denom > 0
        pool.withdraw(type(uint).max);
        assertEq(pool.balanceOf(address(this)), 0);
        assertEq(loanToken.balanceOf(address(this)), amount);
    }

    function testInterestAccrual() external {
        uint amount = 1e36;
        uint borrowAmount = amount / 2;
        MockERC20 collateralToken = new MockERC20(amount, 18);
        MockERC20 loanToken = new MockERC20(amount * 2, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.5e18, 1e15, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), type(uint).max);
        collateralToken.approve(address(pool), type(uint).max);
        pool.deposit(amount);
        pool.addCollateral(address(this), borrowAmount);
        pool.borrow(borrowAmount / 2);
        if(borrowAmount == 0) return;
        assertApproxEqAbs(pool.lastTotalDebt(), borrowAmount / 2, 1, "a");
        assertEq(pool.debtSharesBalanceOf(address(this)), pool.lastTotalDebt(), "b");
        pool.borrow(borrowAmount / 2);
        assertApproxEqAbs(pool.lastTotalDebt(), borrowAmount, 1, "c");
        assertEq(pool.debtSharesBalanceOf(address(this)), pool.lastTotalDebt(), "d");
        vm.warp(block.timestamp + 365 days);
        pool.withdraw(0); // accrues interest
        uint debt = pool.lastTotalDebt();
        uint expectedDebt = borrowAmount + (borrowAmount * 0.4e18 * 365 days / (365 days * 1e18));
        assertApproxEqAbs(debt, expectedDebt, 5, "e");
        pool.repay(address(this), debt);
        pool.withdraw(debt);
        pool.removeCollateral(borrowAmount);
    }

    function testInterestAccrual20Util() external {
        MockERC20 collateralToken = new MockERC20(1000e18, 18);
        MockERC20 loanToken = new MockERC20(1000e18, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), 1000e18);
        collateralToken.approve(address(pool), 1000e18);
        pool.deposit(100e18);
        pool.addCollateral(address(this), 20e18);
        pool.borrow(20e18);
        vm.warp(block.timestamp + 365 days);
        pool.repay(address(this), 23.5e18);
        assertEq(pool.lastTotalDebt(), 0);
        pool.withdraw(103.5e18);
        pool.removeCollateral(20e18);
    }

    function testInterestAccrual90Util() external {
        MockERC20 collateralToken = new MockERC20(1000e18, 18);
        MockERC20 loanToken = new MockERC20(1000e18, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), 1000e18);
        collateralToken.approve(address(pool), 1000e18);
        pool.deposit(125e18);
        pool.addCollateral(address(this), 90e18);
        pool.borrow(90e18);
        pool.withdraw(25e18);
        vm.warp(block.timestamp + 365 days);
        pool.repay(address(this), 135e18);
        assertEq(pool.lastTotalDebt(), 0);
        pool.withdraw(135e18);
        pool.removeCollateral(90e18);
    }

    function testInterestAccrual100Util() external {
        MockERC20 collateralToken = new MockERC20(1000e18, 18);
        MockERC20 loanToken = new MockERC20(1000e18, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), 1000e18);
        collateralToken.approve(address(pool), 1000e18);
        pool.deposit(125e18);
        pool.addCollateral(address(this), 100e18);
        pool.borrow(100e18);
        pool.withdraw(25e18);
        vm.warp(block.timestamp + 365 days);
        pool.repay(address(this), 160e18);
        assertEq(pool.lastTotalDebt(), 0);
        pool.withdraw(160e18);
        pool.removeCollateral(100e18);
    }

    function testInterestAccrualFee() external {
        uint fee = 0.1e18;
        MockERC20 collateralToken = new MockERC20(1000e18, 18);
        MockERC20 loanToken = new MockERC20(1000e18, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.8e18, 1e15, 1e15, 1e18, 1e18, 1e18);
        loanToken.approve(address(pool), 1000e18);
        collateralToken.approve(address(pool), 1000e18);
        factory.setFeeRecipient(address(1));
        factory.setFeeMantissa(fee);
        pool.deposit(100e18);
        pool.addCollateral(address(this), 20e18);
        pool.borrow(20e18);
        vm.warp(block.timestamp + 365 days);
        pool.withdraw(0);
        assertEq(pool.lastTotalDebt(), 40e18);
        assertEq(pool.balanceOf(address(1)), 2e18);
        assertEq(pool.balanceOf(address(this)), 100e18);
    }

    function testBorrow() external {
        uint amount = 1e36;
        uint borrowAmount = amount / 2;
        MockERC20 collateralToken = new MockERC20(amount, 18);
        MockERC20 loanToken = new MockERC20(amount, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.5e18, 1e15, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), type(uint).max);
        collateralToken.approve(address(pool), type(uint).max);
        pool.deposit(amount);
        pool.addCollateral(address(this), borrowAmount);
        pool.borrow(borrowAmount);
        assertEq(pool.debtSharesBalanceOf(address(this)), borrowAmount);
        assertEq(pool.lastTotalDebt(), borrowAmount);
        pool.repay(address(this), borrowAmount);
        assertEq(pool.debtSharesBalanceOf(address(this)), 0);
        assertEq(pool.lastTotalDebt(), 0);
        pool.withdraw(borrowAmount);
        pool.removeCollateral(borrowAmount);
    }

    function testRepayAll() external {
        uint amount = 1e36;
        uint borrowAmount = amount / 2;
        MockERC20 collateralToken = new MockERC20(amount, 18);
        MockERC20 loanToken = new MockERC20(amount, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.5e18, 1e15, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), type(uint).max);
        collateralToken.approve(address(pool), type(uint).max);
        pool.deposit(amount);
        pool.addCollateral(address(this), borrowAmount);
        pool.borrow(borrowAmount);
        assertEq(pool.debtSharesBalanceOf(address(this)), borrowAmount);
        assertEq(pool.lastTotalDebt(), borrowAmount);
        pool.repay(address(this), type(uint).max);
        assertEq(pool.debtSharesBalanceOf(address(this)), 0);
        assertEq(pool.lastTotalDebt(), 0);
        pool.withdraw(borrowAmount);
        pool.removeCollateral(borrowAmount);
    }

    function testAddAndRemoveCollateral() external {
        uint amount = 1e18;
        uint borrowAmount = amount / 2;
        MockERC20 collateralToken = new MockERC20(amount, 18);
        MockERC20 loanToken = new MockERC20(amount, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.5e18, 1e15, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), type(uint).max);
        collateralToken.approve(address(pool), type(uint).max);
        pool.deposit(amount);
        pool.addCollateral(address(this), borrowAmount);
        pool.borrow(borrowAmount);
        vm.expectRevert();
        pool.removeCollateral(borrowAmount);
        pool.repay(address(this), borrowAmount / 2);
        vm.expectRevert();
        pool.removeCollateral((borrowAmount / 2) + 1);
        pool.removeCollateral(borrowAmount / 2);
        assertEq(pool.collateralBalanceOf(address(this)), borrowAmount / 2);
        vm.expectRevert();
        pool.removeCollateral(1);
    }

    function testLiquidate() external {
        uint amount = 1e18;
        uint borrowAmount = amount / 2;
        MockERC20 collateralToken = new MockERC20(amount, 18);
        MockERC20 loanToken = new MockERC20(amount * 2, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.5e18, 1e15, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), type(uint).max);
        collateralToken.approve(address(pool), type(uint).max);
        pool.deposit(amount);
        pool.addCollateral(address(this), borrowAmount);
        pool.borrow(borrowAmount);
        vm.warp(block.timestamp + 365 days);
        pool.withdraw(0);
        uint debtAmount = pool.lastTotalDebt();
        pool.liquidate(address(this), debtAmount);
        assertEq(pool.lastTotalDebt(), 0);
        assertEq(pool.collateralBalanceOf(address(this)), 0);
    }

    function testLiquidateAll() external {
        uint amount = 1e18;
        uint borrowAmount = amount / 2;
        MockERC20 collateralToken = new MockERC20(amount, 18);
        MockERC20 loanToken = new MockERC20(amount * 2, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.5e18, 1e15, 1e15, 0.1e18, 0.4e18, 0.6e18);
        loanToken.approve(address(pool), type(uint).max);
        collateralToken.approve(address(pool), type(uint).max);
        pool.deposit(amount);
        pool.addCollateral(address(this), borrowAmount);
        pool.borrow(borrowAmount);
        vm.warp(block.timestamp + 365 days);
        pool.withdraw(0);
        pool.liquidate(address(this), type(uint).max);
        assertEq(pool.lastTotalDebt(), 0);
        assertEq(pool.collateralBalanceOf(address(this)), 0);
    }

    function testSurgeRecovery() external {
        uint amount = 1e18;
        uint borrowAmount = amount / 2;
        MockERC20 collateralToken = new MockERC20(amount, 18);
        MockERC20 loanToken = new MockERC20(amount * 2, 18);
        Pool pool = factory.deploySurgePool(IERC20(address(collateralToken)), IERC20(address(loanToken)), 1e18, 0.5e18, 1e15, 1e15, 1000, 1000, 1000);
        loanToken.approve(address(pool), type(uint).max);
        collateralToken.approve(address(pool), type(uint).max);
        pool.deposit(amount);
        pool.addCollateral(address(this), borrowAmount);
        pool.borrow(borrowAmount);
        vm.warp(block.timestamp + 365 days);
        pool.withdraw(0);
        vm.warp(block.timestamp + (1e15 / 2));
        pool.withdraw(0);
        assertEq(pool.lastCollateralRatioMantissa(), 0.5e18);
        vm.warp(block.timestamp + (1e15 / 2));
        pool.withdraw(0);
        assertEq(pool.lastCollateralRatioMantissa(), 0);
        pool.repay(address(this), borrowAmount);
        vm.warp(block.timestamp + (1e15 / 2));
        pool.withdraw(0);
        assertEq(pool.lastCollateralRatioMantissa(), 0.5e18);
        vm.warp(block.timestamp + (1e15 / 2));
        pool.withdraw(0);
        assertEq(pool.lastCollateralRatioMantissa(), 1e18);
    }
}
