// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

interface IERC20 {
    function balanceOf(address) external view returns(uint);
    function transferFrom(address sender, address recipient, uint256 amount) external returns(bool);
    function transfer(address, uint) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IFactory {
    function getFee() external view returns (address to, uint feeMantissa);
}

contract Pool {

    IFactory public immutable FACTORY;
    IERC20 public immutable COLLATERAL_TOKEN;
    IERC20 public immutable LOAN_TOKEN;
    uint8 public constant decimals = 18;
    uint private constant RATE_CEILING = 100e18; // 10,000% borrow APR
    uint public immutable MIN_RATE;
    uint public immutable SURGE_RATE;
    uint public immutable MAX_RATE;
    uint public immutable MAX_COLLATERAL_RATIO_MANTISSA;
    uint public immutable SURGE_MANTISSA;
    uint public immutable COLLATERAL_RATIO_FALL_DURATION;
    uint public immutable COLLATERAL_RATIO_RECOVERY_DURATION;
    bytes4 private constant TRANSFER_SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));
    bytes4 private constant TRANSFER_FROM_SELECTOR = bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
    uint public lastCollateralRatioMantissa;
    uint public debtSharesSupply;
    mapping (address => uint) public debtSharesBalanceOf;
    uint public lastTotalDebt;
    uint public lastAccrueInterestTime;
    uint public totalSupply;
    mapping (address => mapping (address => uint)) public allowance;
    mapping (address => uint) public balanceOf;
    mapping (address => uint) public collateralBalanceOf;

    constructor (
        IERC20 _collateralToken,
        IERC20 _loanToken,
        uint _maxCollateralRatioMantissa,
        uint _surgeMantissa,
        uint _collateralRatioFallDuration,
        uint _collateralRatioRecoveryDuration,
        uint _minRateMantissa,
        uint _surgeRateMantissa,
        uint _maxRateMantissa
    ) {
        require(_collateralToken != _loanToken, "Pool: collateral and loan tokens are the same");
        require(_collateralRatioFallDuration > 0, "Pool: _collateralRatioFallDuration too low");
        require(_collateralRatioRecoveryDuration > 0, "Pool: _collateralRatioRecoveryDuration too low");
        require(_maxCollateralRatioMantissa > 0, "Pool: _maxCollateralRatioMantissa too low");
        require(_surgeMantissa <= 1e18, "Pool: _surgeMantissa too high");
        require(_minRateMantissa <= _surgeRateMantissa, "Pool: _minRateMantissa too high");
        require(_surgeRateMantissa <= _maxRateMantissa, "Pool: _surgeRateMantissa too high");
        require(_maxRateMantissa <= RATE_CEILING, "Pool: _maxRateMantissa too high");
        FACTORY = IFactory(msg.sender);
        COLLATERAL_TOKEN = _collateralToken;
        LOAN_TOKEN = _loanToken;
        MAX_COLLATERAL_RATIO_MANTISSA = _maxCollateralRatioMantissa;
        SURGE_MANTISSA = _surgeMantissa;
        COLLATERAL_RATIO_FALL_DURATION = _collateralRatioFallDuration;
        COLLATERAL_RATIO_RECOVERY_DURATION = _collateralRatioRecoveryDuration;
        lastCollateralRatioMantissa = _maxCollateralRatioMantissa;
        MIN_RATE = _minRateMantissa;
        SURGE_RATE = _surgeRateMantissa;
        MAX_RATE = _maxRateMantissa;
    }

    function safeTransfer(IERC20 token, address to, uint value) internal {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(TRANSFER_SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'Pool: TRANSFER_FAILED');
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint value) internal {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(TRANSFER_FROM_SELECTOR, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'Pool: TRANSFER_FROM_FAILED');
    }

    function getCurrentState(
        uint _loanTokenBalance,
        uint _feeMantissa,
        uint _lastCollateralRatioMantissa,
        uint _totalSupply,
        uint _lastAccrueInterestTime,
        uint _totalDebt
        ) internal view returns (
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) {
        
        // 1. Set default return values
        _currentTotalSupply = _totalSupply;
        _currentTotalDebt = _totalDebt;
        _currentCollateralRatioMantissa = _lastCollateralRatioMantissa;
        // _accruedFeeShares = 0;

        // 2. Get the time passed since the last interest accrual
        uint _timeDelta = block.timestamp - _lastAccrueInterestTime;
        
        // 3. If the time passed is 0, return the current values
        if(_timeDelta == 0) return (_currentTotalSupply, _accruedFeeShares, _currentCollateralRatioMantissa, _currentTotalDebt);
        
        // 4. Calculate the supplied value
        uint _supplied = _totalDebt + _loanTokenBalance;
        // 5. Calculate the utilization
        uint _util = getUtilizationMantissa(_totalDebt, _supplied);

        // 6. Calculate the collateral ratio
        _currentCollateralRatioMantissa = getCollateralRatioMantissa(
            _util,
            _lastAccrueInterestTime,
            block.timestamp,
            _lastCollateralRatioMantissa,
            COLLATERAL_RATIO_FALL_DURATION,
            COLLATERAL_RATIO_RECOVERY_DURATION,
            MAX_COLLATERAL_RATIO_MANTISSA,
            SURGE_MANTISSA
        );

        // 7. If there is no debt, return the current values
        if(_totalDebt == 0) return (_currentTotalSupply, _accruedFeeShares, _currentCollateralRatioMantissa, _currentTotalDebt);

        // 8. Calculate the borrow rate
        uint _borrowRate = getBorrowRateMantissa(_util, SURGE_MANTISSA, MIN_RATE, SURGE_RATE, MAX_RATE);
        // 9. Calculate the interest
        uint _interest = _totalDebt * _borrowRate * _timeDelta / (365 days * 1e18);
        // 10. Update the total debt
        _currentTotalDebt += _interest;
        
        // 11. If there is no fee, return the current values
        if(_feeMantissa == 0) return (_currentTotalSupply, _accruedFeeShares, _currentCollateralRatioMantissa, _currentTotalDebt);
        // 12. Calculate the fee
        uint fee = _interest * _feeMantissa / 1e18;
        // 13. Calculate the accrued fee shares
        _accruedFeeShares = fee * _totalSupply / _supplied;
        // 14. Update the total supply
        _currentTotalSupply += _accruedFeeShares;
    }

    function getBorrowRateMantissa(uint _util, uint _surgeMantissa, uint _minRateMantissa, uint _surgeRateMantissa, uint _maxRateMantissa) internal pure returns (uint) {
        if(_util <= _surgeMantissa) {
            return (_surgeRateMantissa - _minRateMantissa) * 1e18 * _util / _surgeMantissa / 1e18 + _minRateMantissa;
        } else {
            uint excessUtil = (_util - _surgeMantissa);
            return (_maxRateMantissa - _surgeRateMantissa) * 1e18 * excessUtil / (1e18 - _surgeMantissa) / 1e18 + _surgeRateMantissa;
        }
    }

    function getUtilizationMantissa(uint _totalDebt, uint _supplied) internal pure returns (uint) {
        if(_supplied == 0) return 0;
        return _totalDebt * 1e18 / _supplied;
    }

    function tokenToShares (uint _tokenAmount, uint _supplied, uint _sharesTotalSupply) internal pure returns (uint) {
        if(_supplied == 0) return _tokenAmount;
        return _tokenAmount * _sharesTotalSupply / _supplied;
    }

    function getCollateralRatioMantissa(
        uint _util,
        uint _lastAccrueInterestTime,
        uint _now,
        uint _lastCollateralRatioMantissa,
        uint _collateralRatioFallDuration,
        uint _collateralRatioRecoveryDuration,
        uint _maxCollateralRatioMantissa,
        uint _surgeMantissa
        ) internal pure returns (uint) {
        unchecked {
            if(_lastAccrueInterestTime == _now) return _lastCollateralRatioMantissa;
            
            // If utilization is less than or equal to surge, we are increasing collateral ratio
            if(_util <= _surgeMantissa) {
                // The collateral ratio can only increase if it is less than the max collateral ratio
                if(_lastCollateralRatioMantissa == _maxCollateralRatioMantissa) return _lastCollateralRatioMantissa;

                // If the collateral ratio can increase, we calculate the increase
                uint timeDelta = _now - _lastAccrueInterestTime;
                uint change = timeDelta * _maxCollateralRatioMantissa / _collateralRatioRecoveryDuration;

                // If the change in collateral ratio is greater than the max collateral ratio, we set the collateral ratio to the max collateral ratio
                if(_lastCollateralRatioMantissa + change >= _maxCollateralRatioMantissa) {
                    return _maxCollateralRatioMantissa;
                } else {
                    // Otherwise we increase the collateral ratio by the change
                    return _lastCollateralRatioMantissa + change;
                }
            } else {
                // If utilization is greater than the surge, we are decreasing collateral ratio
                // The collateral ratio can only decrease if it is greater than 0
                if(_lastCollateralRatioMantissa == 0) return 0;

                // If the collateral ratio can decrease, we calculate the decrease
                uint timeDelta = _now - _lastAccrueInterestTime;
                uint change = timeDelta * _maxCollateralRatioMantissa / _collateralRatioFallDuration;

                // If the change in collateral ratio is greater than the collateral ratio, we set the collateral ratio to 0
                if(_lastCollateralRatioMantissa <= change) {
                    return 0;
                } else {
                    // Otherwise we decrease the collateral ratio by the change
                    return _lastCollateralRatioMantissa - change;
                }
            }
        }
    }

    function transfer(address to, uint amount) external returns (bool) {
        require(to != address(0), "Pool: to cannot be address 0");
        balanceOf[msg.sender] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint amount) external returns (bool) {
        require(to != address(0), "Pool: to cannot be address 0");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function invest(uint amount) external {
        uint _loanTokenBalance = LOAN_TOKEN.balanceOf(address(this));
        (address _feeRecipient, uint _feeMantissa) = FACTORY.getFee();
        (  
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) = getCurrentState(
            _loanTokenBalance,
            _feeMantissa,
            lastCollateralRatioMantissa,
            totalSupply,
            lastAccrueInterestTime,
            lastTotalDebt
        );

        uint _shares = tokenToShares(amount, (_currentTotalDebt + _loanTokenBalance), _currentTotalSupply);
        _currentTotalSupply += _shares;

        // commit current state
        balanceOf[msg.sender] += _shares;
        totalSupply = _currentTotalSupply;
        lastTotalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        emit Invest(msg.sender, amount);
        emit Transfer(address(0), msg.sender, _shares);
        if(_accruedFeeShares > 0) {
            balanceOf[_feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), _feeRecipient, _accruedFeeShares);
        }

        // interactions
        safeTransferFrom(LOAN_TOKEN, msg.sender, address(this), amount);
    }

    function divest(uint amount) external {
        uint _loanTokenBalance = LOAN_TOKEN.balanceOf(address(this));
        (address _feeRecipient, uint _feeMantissa) = FACTORY.getFee();
        (  
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) = getCurrentState(
            _loanTokenBalance,
            _feeMantissa,
            lastCollateralRatioMantissa,
            totalSupply,
            lastAccrueInterestTime,
            lastTotalDebt
        );


        if (amount == type(uint).max) {
            amount = balanceOf[msg.sender] * (_currentTotalDebt + _loanTokenBalance) / _currentTotalSupply;       
        }
        
        uint _shares = tokenToShares(amount, (_currentTotalDebt + _loanTokenBalance), _currentTotalSupply);
        _currentTotalSupply -= _shares;

        // commit current state
        balanceOf[msg.sender] -= _shares;
        totalSupply = _currentTotalSupply;
        lastTotalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        emit Divest(msg.sender, amount);
        emit Transfer(msg.sender, address(0), _shares);
        if(_accruedFeeShares > 0) {
            balanceOf[_feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), _feeRecipient, _accruedFeeShares);
        }

        // interactions
        safeTransfer(LOAN_TOKEN, msg.sender, amount);
    }

    function secure (address to, uint amount) external {
        collateralBalanceOf[to] += amount;
        safeTransferFrom(COLLATERAL_TOKEN, msg.sender, address(this), amount);
        emit Secure(to, msg.sender, amount);
    }

    function getDebtOf(uint _userDebtShares, uint _debtSharesSupply, uint _totalDebt) internal pure returns (uint) {
        if (_debtSharesSupply == 0) return 0;
        return _userDebtShares * _totalDebt / _debtSharesSupply;
    }
    
    function unsecure(uint amount) external {
        uint _loanTokenBalance = LOAN_TOKEN.balanceOf(address(this));
        (address _feeRecipient, uint _feeMantissa) = FACTORY.getFee();
        (  
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) = getCurrentState(
            _loanTokenBalance,
            _feeMantissa,
            lastCollateralRatioMantissa,
            totalSupply,
            lastAccrueInterestTime,
            lastTotalDebt
        );

        uint userDebt = getDebtOf(debtSharesBalanceOf[msg.sender], debtSharesSupply, _currentTotalDebt);
        if(userDebt > 0) {
            uint userCollateralRatioMantissa = userDebt * 1e18 / (collateralBalanceOf[msg.sender] - amount);
            require(userCollateralRatioMantissa <= _currentCollateralRatioMantissa, "Pool: user collateral ratio too high");
        }

        // commit current state
        totalSupply = _currentTotalSupply;
        lastTotalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        collateralBalanceOf[msg.sender] -= amount;
        emit Unsecure(msg.sender, amount);
        if(_accruedFeeShares > 0) {
            balanceOf[_feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), _feeRecipient, _accruedFeeShares);
        }

        // interactions
        safeTransfer(COLLATERAL_TOKEN, msg.sender, amount);
    }

    function borrow(uint amount) external {
        uint _loanTokenBalance = LOAN_TOKEN.balanceOf(address(this));
        (address _feeRecipient, uint _feeMantissa) = FACTORY.getFee();
        (  
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) = getCurrentState(
            _loanTokenBalance,
            _feeMantissa,
            lastCollateralRatioMantissa,
            totalSupply,
            lastAccrueInterestTime,
            lastTotalDebt
        );

        uint _debtSharesSupply = debtSharesSupply;
        uint userDebt = getDebtOf(debtSharesBalanceOf[msg.sender], _debtSharesSupply, _currentTotalDebt) + amount;
        uint userCollateralRatioMantissa = userDebt * 1e18 / collateralBalanceOf[msg.sender];
        require(userCollateralRatioMantissa <= _currentCollateralRatioMantissa, "Pool: user collateral ratio too high");

        uint _newUtil = getUtilizationMantissa(_currentTotalDebt + amount, (_currentTotalDebt + _loanTokenBalance));
        require(_newUtil <= SURGE_MANTISSA, "Pool: utilization too high");

        uint _shares = tokenToShares(amount, _currentTotalDebt, _debtSharesSupply);
        _currentTotalDebt += amount;

        // commit current state
        debtSharesBalanceOf[msg.sender] += _shares;
        debtSharesSupply = _debtSharesSupply + _shares;
        totalSupply = _currentTotalSupply;
        lastTotalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        emit Borrow(msg.sender, amount);
        if(_accruedFeeShares > 0) {
            balanceOf[_feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), _feeRecipient, _accruedFeeShares);
        }

        // interactions
        safeTransfer(LOAN_TOKEN, msg.sender, amount);
    }

    //TODO: Add a way to repay all debt including accrued interest
    function repay(address borrower, uint amount) external {
        uint _loanTokenBalance = LOAN_TOKEN.balanceOf(address(this));
        (address _feeRecipient, uint _feeMantissa) = FACTORY.getFee();
        (  
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) = getCurrentState(
            _loanTokenBalance,
            _feeMantissa,
            lastCollateralRatioMantissa,
            totalSupply,
            lastAccrueInterestTime,
            lastTotalDebt
        );

        uint _debtSharesSupply = debtSharesSupply;

        if(amount == type(uint).max) {
            amount = getDebtOf(debtSharesBalanceOf[borrower], _debtSharesSupply, _currentTotalDebt);
        }

        uint _shares = tokenToShares(amount, _currentTotalDebt, _debtSharesSupply);
        _currentTotalDebt -= amount;

        // commit current state
        debtSharesBalanceOf[borrower] -= _shares;
        debtSharesSupply = _debtSharesSupply - _shares;
        totalSupply = _currentTotalSupply;
        lastTotalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        emit Repay(borrower, msg.sender, amount);
        if(_accruedFeeShares > 0) {
            balanceOf[_feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), _feeRecipient, _accruedFeeShares);
        }

        // interactions
        safeTransferFrom(LOAN_TOKEN, msg.sender, address(this), amount);
    }

    function liquidate(address borrower, uint amount) external {
        uint _loanTokenBalance = LOAN_TOKEN.balanceOf(address(this));
        (address _feeRecipient, uint _feeMantissa) = FACTORY.getFee();
        (  
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) = getCurrentState(
            _loanTokenBalance,
            _feeMantissa,
            lastCollateralRatioMantissa,
            totalSupply,
            lastAccrueInterestTime,
            lastTotalDebt
        );

        uint collateralBalance = collateralBalanceOf[borrower];
        uint _debtSharesSupply = debtSharesSupply;
        uint userDebt = getDebtOf(debtSharesBalanceOf[borrower], _debtSharesSupply, _currentTotalDebt);
        uint userCollateralRatioMantissa = userDebt * 1e18 / collateralBalance;
        require(userCollateralRatioMantissa > _currentCollateralRatioMantissa, "Pool: borrower not liquidatable");

        address _borrower = borrower; // avoid stack too deep
        uint _amount = amount;
        uint _shares;
        uint collateralReward;
        if(_amount == type(uint).max || _amount == userDebt) {
            collateralReward = collateralBalance;
            _shares = debtSharesBalanceOf[_borrower];
        } else {
            uint userInvertedCollateralRatioMantissa = collateralBalance * 1e18 / userDebt;
            collateralReward = _amount * userInvertedCollateralRatioMantissa / 1e18;
            _shares = tokenToShares(_amount, _currentTotalDebt, _debtSharesSupply);
        }
        _currentTotalDebt -= amount;

        // commit current state
        debtSharesBalanceOf[_borrower] -= _shares;
        debtSharesSupply = _debtSharesSupply - _shares;
        collateralBalanceOf[_borrower] = collateralBalance - collateralReward;
        totalSupply = _currentTotalSupply;
        lastTotalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        emit Liquidate(_borrower, _amount, collateralReward);
        if(_accruedFeeShares > 0) {
            address __feeRecipient = _feeRecipient; // avoid stack too deep
            balanceOf[__feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), __feeRecipient, _accruedFeeShares);
        }

        // interactions
        safeTransferFrom(LOAN_TOKEN, msg.sender, address(this), _amount);
        safeTransfer(COLLATERAL_TOKEN, msg.sender, collateralReward);
    }

    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);
    event Invest(address indexed user, uint amount);
    event Divest(address indexed user, uint amount);
    event Borrow(address indexed user, uint amount);
    event Repay(address indexed user, address indexed caller, uint amount);
    event Liquidate(address indexed user, uint amount, uint collateralReward);
    event Secure(address indexed user, address indexed caller, uint amount);
    event Unsecure(address indexed user, uint amount);
}