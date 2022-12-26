// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

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

    function getPoolsLength () external view returns (uint) {
        return pools.length;
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
        uint _feeMantissa = feeMantissa;
        if(_feeMantissa == 0) return (address(0), 0);
        return (feeRecipient, _feeMantissa);
    }

    function deployPool(
        IERC20 _collateralToken,
        IERC20 _loanToken,
        uint _maxCollateralRatioMantissa,
        uint _surgeMantissa,
        uint _collateralRatioFallDuration,
        uint _collateralRatioRecoveryDuration,
        uint _minRateMantissa,
        uint _surgeRateMantissa,
        uint _maxRateMantissa
    ) external returns (Pool) {
        Pool pool = new Pool(_collateralToken, _loanToken, _maxCollateralRatioMantissa, _surgeMantissa, _collateralRatioFallDuration, _collateralRatioRecoveryDuration, _minRateMantissa, _surgeRateMantissa, _maxRateMantissa);
        isPool[pool] = true;
        emit PoolDeployed(pools.length, address(pool), address(_collateralToken), address(_loanToken), _maxCollateralRatioMantissa, _surgeMantissa, _collateralRatioFallDuration, _collateralRatioRecoveryDuration, _minRateMantissa, _surgeRateMantissa, _maxRateMantissa);
        pools.push(pool);
        return pool;
    }
    event PoolDeployed(uint poolId, address pool, address indexed collateralToken, address indexed loanToken, uint indexed maxCollateralRatioMantissa, uint surgeMantissa, uint collateralRatioFallDuration, uint collateralRatioRecoveryDuration, uint minRateMantissa, uint surgeRateMantissa, uint maxRateMantissa);
}