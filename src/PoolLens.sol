// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "./Pool.sol";
import "./Factory.sol";

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

    function getDebtOf(address pool, address user) external view returns (uint) {
        uint _debtSharesSupply = Pool(pool).debtSharesSupply();
        if (_debtSharesSupply == 0) return 0;
        uint _totalDebt = getCurrentTotalDebt(pool);
        uint _userDebtShares = Pool(pool).debtSharesBalanceOf(user);
        uint debt = _userDebtShares * _totalDebt / _debtSharesSupply;
        if(debt * _debtSharesSupply < _userDebtShares * _totalDebt) debt++;
        return debt;
    }

    function getCollateralRatioMantissa(address pool) external view returns (uint) {
        uint _lastAccrueInterestTime = Pool(pool).lastAccrueInterestTime();
        uint _lastCollateralRatioMantissa = Pool(pool).lastCollateralRatioMantissa();

        if(_lastAccrueInterestTime == block.timestamp) return _lastCollateralRatioMantissa;
        
        uint _util = getUtilizationMantissa(pool);
        uint _surgeMantissa = Pool(pool).SURGE_MANTISSA();
        uint _maxCollateralRatioMantissa = Pool(pool).MAX_COLLATERAL_RATIO_MANTISSA();
        uint _collateralRatioFallDuration = Pool(pool).COLLATERAL_RATIO_FALL_DURATION();
        uint _collateralRatioRecoveryDuration = Pool(pool).COLLATERAL_RATIO_RECOVERY_DURATION();

        if(_util <= _surgeMantissa) {
            if(_lastCollateralRatioMantissa == _maxCollateralRatioMantissa) return _lastCollateralRatioMantissa;
            uint timeDelta = block.timestamp - _lastAccrueInterestTime;
            uint speed = _maxCollateralRatioMantissa / _collateralRatioRecoveryDuration;
            uint change = timeDelta * speed;
            if(_lastCollateralRatioMantissa + change > _maxCollateralRatioMantissa) {
                return _maxCollateralRatioMantissa;
            } else {
                return _lastCollateralRatioMantissa + change;
            }
        } else {
            if(_lastCollateralRatioMantissa == 0) return 0;
            uint timeDelta = block.timestamp - _lastAccrueInterestTime;
            uint speed = _maxCollateralRatioMantissa / _collateralRatioFallDuration;
            uint change = timeDelta * speed;
            if(_lastCollateralRatioMantissa < change) {
                return 0;
            } else {
                return _lastCollateralRatioMantissa - change;
            }
        }
    }

    function getSuppliedLoanTokens(address pool) external view returns (uint) {
        return getCurrentTotalDebt(pool) + IERC20(Pool(pool).LOAN_TOKEN()).balanceOf(pool);
    }

    function getSupplyRateMantissa(address pool) external view returns (uint) {
        uint _fee = Factory(address(Pool(pool).FACTORY())).feeMantissa();
        uint _borrowRate = getBorrowRateMantissa(pool);
        uint _util = getUtilizationMantissa(pool);
        uint oneMinusFee = 1e18 - _fee;
        uint rateToPool = _borrowRate * oneMinusFee / 1e18;
        return _util * rateToPool / 1e18;
    }

}