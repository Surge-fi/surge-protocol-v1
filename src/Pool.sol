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
    uint public constant RATE_CEILING = 100e18; // 10,000% borrow APR
    uint public immutable MIN_RATE;
    uint public immutable SURGE_RATE;
    uint public immutable MAX_RATE;
    uint public immutable MAX_COLLATERAL_RATIO_MANTISSA;
    uint public immutable SURGE_MANTISSA;
    uint public immutable COLLATERAL_RATIO_FALL_DURATION;
    uint public immutable COLLATERAL_RATIO_RECOVERY_DURATION;
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
        require(_maxCollateralRatioMantissa > 0, "Pool: _maxCollateralRatioMantissa too low");
        require(_surgeMantissa <= 1e18, "Pool: _surgeMantissa too high");
        require(_minRateMantissa <= _surgeRateMantissa, "Pool: _minRateMantissa too high");
        require(_surgeRateMantissa <= _maxRateMantissa, "Pool: _surgeRateMantissa too high");
        require(_maxRateMantissa <= RATE_CEILING, "Pool: _maxRateMantissa too high");
        require(_collateralRatioFallDuration > 0, "Pool: _collateralRatioFallDuration too low");
        require(_collateralRatioRecoveryDuration > 0, "Pool: _collateralRatioRecoveryDuration too low");
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

    function getCurrentState(
        uint _totalSupply,
        uint _lastAccrueInterestTime,
        uint _now,
        uint _totalDebt,
        uint _loanTokenBalance,
        uint _surgeMantissa,
        uint _feeMantissa,
        uint _lastCollateralRatioMantissa,
        uint _collateralRatioFallDuration,
        uint _collateralRatioRecoveryDuration,
        uint _maxCollateralRatioMantissa,
        uint _minRateMantissa,
        uint _surgeRateMantissa,
        uint _maxRateMantissa
        ) internal pure returns (
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) {
        
        _currentTotalSupply = _totalSupply;
        _currentTotalDebt = _totalDebt;
        _currentCollateralRatioMantissa = _lastCollateralRatioMantissa;
        // _accruedFeeShares = 0;

        uint _timeDelta = _now - _lastAccrueInterestTime;
        if(_timeDelta == 0) return (_currentTotalSupply, _accruedFeeShares, _currentCollateralRatioMantissa, _currentTotalDebt);
        
        uint _supplied = _totalDebt + _loanTokenBalance;
        uint _util = getUtilizationMantissa(_totalDebt, _supplied);

        _currentCollateralRatioMantissa = getCollateralRatioMantissa(
            _util,
            _lastAccrueInterestTime,
            _now,
            _lastCollateralRatioMantissa,
            _collateralRatioFallDuration,
            _collateralRatioRecoveryDuration,
            _maxCollateralRatioMantissa,
            _surgeMantissa
        );

        if(_totalDebt == 0) return (_currentTotalSupply, _accruedFeeShares, _currentCollateralRatioMantissa, _currentTotalDebt);

        uint _borrowRate = getBorrowRateMantissa(_util, _surgeMantissa, _minRateMantissa, _surgeRateMantissa, _maxRateMantissa);
        uint _interest = _totalDebt * _borrowRate / 1e18 * _timeDelta / 365 days;
        _currentTotalDebt += _interest;
        
        if(_feeMantissa == 0) return (_currentTotalSupply, _accruedFeeShares, _currentCollateralRatioMantissa, _currentTotalDebt);
        uint fee = _interest * _feeMantissa / 1e18;
        _accruedFeeShares = fee * _totalSupply / _supplied;
        _currentTotalSupply += _accruedFeeShares;
    }

    function getBorrowRateMantissa(uint _util, uint _surgeMantissa, uint _minRateMantissa, uint _surgeRateMantissa, uint _maxRateMantissa) internal pure returns (uint) {
        if(_util <= _surgeMantissa) {
            uint ratePerUnit = (_surgeRateMantissa - _minRateMantissa) * 1e18 / _surgeMantissa;
            return ratePerUnit * _util / 1e18 + _minRateMantissa;
        } else {
            uint excessUtil = (_util - _surgeMantissa);
            uint ratePerExcessUnit = (_maxRateMantissa - _surgeRateMantissa) * 1e18 / (1e18 - _surgeMantissa);
            return ratePerExcessUnit * excessUtil / 1e18 + _surgeRateMantissa;
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
        if(_lastAccrueInterestTime == _now) return _lastCollateralRatioMantissa;

        if(_util <= _surgeMantissa) {
            if(_lastCollateralRatioMantissa == _maxCollateralRatioMantissa) return _lastCollateralRatioMantissa;
            uint timeDelta = _now - _lastAccrueInterestTime;
            uint speed = _maxCollateralRatioMantissa / _collateralRatioRecoveryDuration;
            uint change = timeDelta * speed;
            if(_lastCollateralRatioMantissa + change > _maxCollateralRatioMantissa) {
                return _maxCollateralRatioMantissa;
            } else {
                return _lastCollateralRatioMantissa + change;
            }
        } else {
            if(_lastCollateralRatioMantissa == 0) return 0;
            uint timeDelta = _now - _lastAccrueInterestTime;
            uint speed = _maxCollateralRatioMantissa / _collateralRatioFallDuration;
            uint change = timeDelta * speed;
            if(_lastCollateralRatioMantissa < change) {
                return 0;
            } else {
                return _lastCollateralRatioMantissa - change;
            }
        }
    }

    function transfer(address to, uint amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
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
            totalSupply,
            lastAccrueInterestTime,
            block.timestamp,
            lastTotalDebt,
            _loanTokenBalance,
            SURGE_MANTISSA,
            _feeMantissa,
            lastCollateralRatioMantissa,
            COLLATERAL_RATIO_FALL_DURATION,
            COLLATERAL_RATIO_RECOVERY_DURATION,
            MAX_COLLATERAL_RATIO_MANTISSA,
            MIN_RATE,
            SURGE_RATE,
            MAX_RATE
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
        LOAN_TOKEN.transferFrom(msg.sender, address(this), amount);
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
            totalSupply,
            lastAccrueInterestTime,
            block.timestamp,
            lastTotalDebt,
            _loanTokenBalance,
            SURGE_MANTISSA,
            _feeMantissa,
            lastCollateralRatioMantissa,
            COLLATERAL_RATIO_FALL_DURATION,
            COLLATERAL_RATIO_RECOVERY_DURATION,
            MAX_COLLATERAL_RATIO_MANTISSA,
            MIN_RATE,
            SURGE_RATE,
            MAX_RATE
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
        LOAN_TOKEN.transfer(msg.sender, amount);
    }

    function secure (address to, uint amount) external {
        require(amount > 0, "Pool: amount too low");
        collateralBalanceOf[to] += amount;
        COLLATERAL_TOKEN.transferFrom(msg.sender, address(this), amount);
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
            totalSupply,
            lastAccrueInterestTime,
            block.timestamp,
            lastTotalDebt,
            _loanTokenBalance,
            SURGE_MANTISSA,
            _feeMantissa,
            lastCollateralRatioMantissa,
            COLLATERAL_RATIO_FALL_DURATION,
            COLLATERAL_RATIO_RECOVERY_DURATION,
            MAX_COLLATERAL_RATIO_MANTISSA,
            MIN_RATE,
            SURGE_RATE,
            MAX_RATE
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
        COLLATERAL_TOKEN.transfer(msg.sender, amount);
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
            totalSupply,
            lastAccrueInterestTime,
            block.timestamp,
            lastTotalDebt,
            _loanTokenBalance,
            SURGE_MANTISSA,
            _feeMantissa,
            lastCollateralRatioMantissa,
            COLLATERAL_RATIO_FALL_DURATION,
            COLLATERAL_RATIO_RECOVERY_DURATION,
            MAX_COLLATERAL_RATIO_MANTISSA,
            MIN_RATE,
            SURGE_RATE,
            MAX_RATE
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
        LOAN_TOKEN.transfer(msg.sender, amount);
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
            totalSupply,
            lastAccrueInterestTime,
            block.timestamp,
            lastTotalDebt,
            _loanTokenBalance,
            SURGE_MANTISSA,
            _feeMantissa,
            lastCollateralRatioMantissa,
            COLLATERAL_RATIO_FALL_DURATION,
            COLLATERAL_RATIO_RECOVERY_DURATION,
            MAX_COLLATERAL_RATIO_MANTISSA,
            MIN_RATE,
            SURGE_RATE,
            MAX_RATE
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
        LOAN_TOKEN.transferFrom(msg.sender, address(this), amount);
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
            totalSupply,
            lastAccrueInterestTime,
            block.timestamp,
            lastTotalDebt,
            _loanTokenBalance,
            SURGE_MANTISSA,
            _feeMantissa,
            lastCollateralRatioMantissa,
            COLLATERAL_RATIO_FALL_DURATION,
            COLLATERAL_RATIO_RECOVERY_DURATION,
            MAX_COLLATERAL_RATIO_MANTISSA,
            MIN_RATE,
            SURGE_RATE,
            MAX_RATE
        );

        uint collateralBalance = collateralBalanceOf[borrower];
        uint _debtSharesSupply = debtSharesSupply;
        uint userDebt = getDebtOf(debtSharesBalanceOf[borrower], _debtSharesSupply, _currentTotalDebt);
        uint userCollateralRatioMantissa = userDebt * 1e18 / collateralBalance;
        require(userCollateralRatioMantissa > _currentCollateralRatioMantissa, "Pool: borrower not liquidatable");

        uint _shares;
        uint collateralReward;
        if(amount == type(uint).max || amount == userDebt) {
            collateralReward = collateralBalance;
            _shares = debtSharesBalanceOf[borrower];
        } else {
            uint userInvertedCollateralRatioMantissa = collateralBalance * 1e18 / userDebt;
            collateralReward = amount * userInvertedCollateralRatioMantissa / 1e18;
            _shares = tokenToShares(amount, _currentTotalDebt, _debtSharesSupply);
        }
        _currentTotalDebt -= amount;

        // commit current state
        debtSharesBalanceOf[borrower] -= _shares;
        debtSharesSupply = _debtSharesSupply - _shares;
        collateralBalanceOf[borrower] = collateralBalance - collateralReward;
        totalSupply = _currentTotalSupply;
        lastTotalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        emit Liquidate(borrower, amount, collateralReward);
        if(_accruedFeeShares > 0) {
            balanceOf[_feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), _feeRecipient, _accruedFeeShares);
        }

        // interactions
        LOAN_TOKEN.transferFrom(msg.sender, address(this), amount);
        COLLATERAL_TOKEN.transfer(msg.sender, collateralReward);
    }

    event Transfer(address from, address to, uint value);
    event Approval(address owner, address spender, uint value);
    event Invest(address indexed user, uint amount);
    event Divest(address indexed user, uint amount);
    event Borrow(address indexed user, uint amount);
    event Repay(address indexed user, address indexed caller, uint amount);
    event Liquidate(address indexed user, uint amount, uint collateralReward);
    event Secure(address indexed user, address indexed caller, uint amount);
    event Unsecure(address indexed user, uint amount);
}