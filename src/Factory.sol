// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./Pool.sol";

contract Factory {

    address public operator;
    address public feeRecipient;
    uint public feeMantissa;
    uint public constant MAX_FEE_MANTISSA = 0.2e18;
    mapping (Pool => bool) public isPool;
    Pool[] public pools;

    constructor (address _operator) {
        operator = _operator;
    }

    function setFeeRecipient(address _feeRecipient) external {
        require(msg.sender == operator, "Factory: not operator");
        feeRecipient = _feeRecipient;
    }

    function setFeeMantissa(uint _feeMantissa) external {
        require(msg.sender == operator, "Factory: not operator");
        require(_feeMantissa <= MAX_FEE_MANTISSA, "Factory: fee too high");
        if(_feeMantissa > 0) require(feeRecipient != address(0), "Factory: fee recipient is zero address");
        feeMantissa = _feeMantissa;
    }

    function getFee() external view returns (address, uint) {
        return (feeRecipient, feeMantissa);
    }

    function deployPool(IERC20 _collateralToken, IERC20 _loanToken, uint _maxCollateralRatioMantissa, uint _kinkMantissa, uint _collateralRatioSpeedMantissa) external returns (Pool) {
        Pool pool = new Pool(_collateralToken, _loanToken, _maxCollateralRatioMantissa, _kinkMantissa, _collateralRatioSpeedMantissa);
        isPool[pool] = true;
        pools.push(pool);
        return pool;
    }

    event PoolDeployed(address pool, address indexed collateralToken, address indexed loanToken, uint indexed maxCollateralRatioMantissa, uint kinkMantissa, uint collateralRatioSpeedMantissa);
}