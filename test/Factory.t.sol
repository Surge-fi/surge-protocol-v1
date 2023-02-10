// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/Factory.sol";
import "./mocks/ERC20.sol";
import "../src/Pool.sol";

contract FactoryTest is Test {

    Factory factory;

    function setUp() public {
        factory = new Factory(address(this), "G");
    }

    function testInitialValues() external {
        assertEq(factory.operator(), address(this));
        assertEq(factory.MAX_FEE_MANTISSA(), 0.2e18);
    }

    function testDeployPool() external {
        Pool pool = factory.deploySurgePool(IERC20(address(0)), IERC20(address(1)), 1, 1, 1, 1, 1, 1, 1);    
        assertEq(factory.getPoolsLength(), 1);
        assertEq(address(factory.pools(0)), address(pool));
        assertEq(factory.isPool(pool), true);
        assertEq(address(pool.COLLATERAL_TOKEN()), address(0));
        assertEq(address(pool.LOAN_TOKEN()), address(1));
        assertEq(pool.MAX_COLLATERAL_RATIO_MANTISSA(), 1);
        assertEq(pool.SURGE_MANTISSA(), 1);
        assertEq(pool.COLLATERAL_RATIO_FALL_DURATION(), 1);
        assertEq(pool.COLLATERAL_RATIO_RECOVERY_DURATION(), 1);
        assertEq(pool.MIN_RATE(), 1);
        assertEq(pool.SURGE_RATE(), 1);
        assertEq(pool.MAX_RATE(), 1);
        assertEq(pool.symbol(), "G0");
        assertEq(pool.name(), "Surge G0 Pool");
        
        for (uint i = 1; i <= 100; i++) {
            factory.deploySurgePool(IERC20(address(0)), IERC20(address(1)), 1, 1, 1, 1, 1, 1, 1);
        }

        assertEq(factory.getPoolsLength(), 101);
        Pool latestPool = factory.pools(100);
        assertEq(latestPool.symbol(), "G100");
        assertEq(latestPool.name(), "Surge G100 Pool");
    }

    function testFee() external {
        assertEq(factory.feeMantissa(), 0);
        factory.setFeeRecipient(address(1));
        assertEq(factory.feeRecipient(), address(1));
        factory.setFeeMantissa(1);
        assertEq(factory.feeMantissa(), 1);
        (address feeRecipient, uint fee) = factory.getFee();
        assertEq(feeRecipient, address(1));
        assertEq(fee, 1);
    }

    function testChangeOperator() external {
        assertEq(factory.operator(), address(this));
        factory.setPendingOperator(address(1));
        assertEq(factory.pendingOperator(), address(1));
        vm.prank(address(1));
        factory.acceptOperator();
        assertEq(factory.operator(), address(1));
    }
}

