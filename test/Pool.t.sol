// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Pool.sol";
import "./mocks/ERC20.sol";

contract PoolTest is Test {

    MockERC20 collateralToken;
    MockERC20 creditToken;
    Pool public pool;

    function setUp() public {
        collateralToken = new MockERC20(1000e6, 6); // e.g. USDC/USDT
        creditToken = new MockERC20(1000e18, 18); // e.g. Ether
        pool = new Pool(
            IERC20(address(collateralToken)),
            IERC20(address(creditToken)),
            10000000 // 10 million bps ratio = 1000x
        );
    }

    function testGetMaxCreditOf() public {
    }

}
