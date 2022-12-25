// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "./Pool.sol";

contract PoolLens {

    function getUtilizationMantissa(address pool) public view returns (uint) {
        uint _totalDebt = Pool(pool).lastTotalDebt();
        IERC20 _loanToken = IERC20(Pool(pool).LOAN_TOKEN());
        uint _loanTokenBalance = IERC20(_loanToken).balanceOf(pool);
        uint _supplied = _loanTokenBalance + _totalDebt;
        if(_supplied == 0) return 0;
        return _totalDebt * 1e18 / _supplied;
    }

    function getBorrowRateMantissa(address pool) public view returns (uint) {
        uint _util = getUtilizationMantissa(pool);
        uint _surgeMantissa = Pool(pool).SURGE_MANTISSA();
        uint MIN_RATE = Pool(pool).MIN_RATE();
        uint SURGE_RATE = Pool(pool).SURGE_RATE();
        uint MAX_RATE = Pool(pool).MAX_RATE();
        if(_util <= _surgeMantissa) {
            uint ratePerUnit = (SURGE_RATE - MIN_RATE) * 1e18 / _surgeMantissa;
            return ratePerUnit * _util / 1e18 + MIN_RATE;
        } else {
            uint excessUtil = (_util - _surgeMantissa);
            uint ratePerExcessUnit = (MAX_RATE - SURGE_RATE) * 1e18 / (1e18 - _surgeMantissa);
            return (ratePerExcessUnit * excessUtil / 1e18) + SURGE_RATE;
        }
    }

    function getCurrentTotalDebt(address pool) public view returns (uint256) {
        uint _totalDebt = Pool(pool).lastTotalDebt();
        if(_totalDebt == 0) return 0;
        uint _lastAccrueInterestTime = Pool(pool).lastAccrueInterestTime();
        if(_lastAccrueInterestTime == block.timestamp) return _totalDebt;
        uint _borrowRate = getBorrowRateMantissa(pool);
        uint _timeDelta = block.timestamp - _lastAccrueInterestTime;
        uint _interest = _totalDebt * _borrowRate / 1e18 * _timeDelta / 365 days;
        return _totalDebt + _interest;
    }
    
    function getInvestmentOf(address pool, address user) external view returns (uint256) {
        uint _totalDebt = getCurrentTotalDebt(pool);
        IERC20 _loanToken = IERC20(Pool(pool).LOAN_TOKEN());
        uint _loanTokenBalance = IERC20(_loanToken).balanceOf(pool);
        uint _totalSupply = Pool(pool).totalSupply();
        if(_totalSupply == 0) return 0;
        return Pool(pool).balanceOf(user) * (_totalDebt + _loanTokenBalance) / _totalSupply;
    }

}