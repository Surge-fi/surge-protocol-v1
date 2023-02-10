// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "../src/PoolLens.sol";
import "forge-std/Test.sol";
import "../src/Pool.sol";
import "./mocks/ERC20.sol";

contract PoolLensTest is Test, Pool("", "",IERC20(address(new MockERC20(1000, 18))), IERC20(address(new MockERC20(1000, 18))), 1e18, 0.8e18, 1e15, 1e15, 0.1e18, 0.4e18, 0.6e18) {

    PoolLens lens;

    function setUp() public {
        lens = new PoolLens();
    }

    function testGetDebtOf() external {
        // we define these variables for the lens contract to access
        lastTotalDebt = 1e18;
        lastAccrueInterestTime = block.timestamp;
        debtSharesSupply = 1e18 + 1;
        debtSharesBalanceOf[address(1)] = 1e18;

        assertEq(lens.getDebtOf(address(this), address(1)), getDebtOf(debtSharesBalanceOf[address(1)], debtSharesSupply, lastTotalDebt));
    }

}