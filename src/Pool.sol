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

    uint8 public constant decimals = 18;
    uint public constant MAX_BASE_APR_MANTISSA = 0.4e18;
    uint public constant MAX_JUMP_APR_MANTISSA = 0.6e18;
    IFactory public immutable factory;
    IERC20 public immutable collateralToken;
    IERC20 public immutable loanToken;
    uint public immutable maxCollateralRatioMantissa;
    uint public immutable kinkMantissa;
    uint public immutable collateralRatioSpeedMantissa; //change in collateral ratio per second
    uint public lastCollateralRatioMantissa;
    uint public debtSharesSupply;
    mapping (address => uint) public debtSharesBalanceOf;
    uint public totalDebt;
    uint public lastAccrueInterestTime;
    uint public totalSupply;
    mapping (address => mapping (address => uint)) public allowance;
    mapping (address => uint) public balanceOf;
    mapping (address => uint) public collateralBalanceOf;

    constructor (IERC20 _collateralToken, IERC20 _loanToken, uint _maxCollateralRatioMantissa, uint _kinkMantissa, uint _collateralRatioSpeedMantissa) {
        require(_collateralToken != _loanToken, "Pool: collateral and loan tokens are the same");
        require(_maxCollateralRatioMantissa > 0, "Pool: _maxCollateralRatioMantissa too low");
        factory = IFactory(msg.sender);
        collateralToken = _collateralToken;
        loanToken = _loanToken;
        maxCollateralRatioMantissa = _maxCollateralRatioMantissa;
        kinkMantissa = _kinkMantissa;
        collateralRatioSpeedMantissa = _collateralRatioSpeedMantissa;
        lastCollateralRatioMantissa = _maxCollateralRatioMantissa;
    }

    function getCurrentState(
        uint _totalSupply,
        uint _lastAccrueInterestTime,
        uint _now,
        uint _totalDebt,
        uint _loanTokenBalance,
        uint _kinkMantissa,
        uint _feeMantissa,
        uint _lastCollateralRatioMantissa,
        uint _collateralRatioSpeedMantissa,
        uint _maxCollateralRatioMantissa
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
            _collateralRatioSpeedMantissa,
            _maxCollateralRatioMantissa,
            _kinkMantissa
        );

        if(_totalDebt == 0) return (_currentTotalSupply, _accruedFeeShares, _currentCollateralRatioMantissa, _currentTotalDebt);

        uint _borrowRate = getBorrowRateMantissa(_util, _kinkMantissa);
        uint _interest = _totalDebt * _borrowRate / 1e18 * _timeDelta / 365 days;
        _currentTotalDebt += _interest;
        
        if(_feeMantissa == 0) return (_currentTotalSupply, _accruedFeeShares, _currentCollateralRatioMantissa, _currentTotalDebt);
        uint fee = _interest * _feeMantissa / 1e18;
        _accruedFeeShares = fee * _totalSupply / _supplied;
        _currentTotalSupply += _accruedFeeShares;
    }

    function getBorrowRateMantissa(uint _util, uint _kinkMantissa) internal pure returns (uint) {
        if(_util <= _kinkMantissa) {
            return _util * MAX_BASE_APR_MANTISSA / 1e18;
        } else {
            uint normalRate = _kinkMantissa * MAX_BASE_APR_MANTISSA / 1e18;
            uint excessUtil = _util - _kinkMantissa;
            return (excessUtil * MAX_JUMP_APR_MANTISSA / 1e18) + normalRate;
        }
    }

    function getSupplyRateMantissa(uint _borrowRate, uint _fee, uint _util) internal pure returns (uint) {
        uint oneMinusFee = 1e18 - _fee;
        uint rateToPool = _borrowRate * oneMinusFee / 1e18;
        return _util * rateToPool / 1e18;
    }

    function getUtilizationMantissa(uint _totalDebt, uint _supplied) internal pure returns (uint) {
        if(_supplied == 0) return 0;
        return _totalDebt * 1e18 / _supplied;
    }

    function tokenToShares (uint _tokenAmount, uint _supplied, uint _sharesTotalSupply) internal pure returns (uint) {
        if(_supplied == 0) return _tokenAmount;
        return _tokenAmount * _sharesTotalSupply / _supplied;
    }

    // function getInvestmentOf (address account) public view returns (uint) {
    //     if(totalSupply == 0) return 0;
    //     return balanceOf[account] * getSuppliedLoanTokens() / totalSupply;
    // }

    function getCollateralRatioMantissa(
        uint _util,
        uint _lastAccrueInterestTime,
        uint _now,
        uint _lastCollateralRatioMantissa,
        uint _collateralRatioSpeedMantissa,
        uint _maxCollateralRatioMantissa,
        uint _kinkMantissa
        ) internal pure returns (uint) {
        if(_lastAccrueInterestTime == _now) return _lastCollateralRatioMantissa;

        if(_util <= _kinkMantissa) {
            if(_lastCollateralRatioMantissa == _maxCollateralRatioMantissa) return _lastCollateralRatioMantissa;
            uint timeDelta = _now - _lastAccrueInterestTime;
            uint change = timeDelta * _collateralRatioSpeedMantissa;
            if(_lastCollateralRatioMantissa + change > _maxCollateralRatioMantissa) {
                return _maxCollateralRatioMantissa;
            } else {
                return _lastCollateralRatioMantissa + change;
            }
        } else {
            if(_lastCollateralRatioMantissa == 0) return 0;
            uint timeDelta = _now - _lastAccrueInterestTime;
            uint change = timeDelta * _collateralRatioSpeedMantissa;
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
        uint _loanTokenBalance = loanToken.balanceOf(address(this));
        (address _feeRecipient, uint _feeMantissa) = factory.getFee();
        (  
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) = getCurrentState(
            totalSupply,
            lastAccrueInterestTime,
            block.timestamp,
            totalDebt,
            _loanTokenBalance,
            kinkMantissa,
            _feeMantissa,
            lastCollateralRatioMantissa,
            collateralRatioSpeedMantissa,
            maxCollateralRatioMantissa
        );

        uint _shares = tokenToShares(amount, (_currentTotalDebt + _loanTokenBalance), _currentTotalSupply);
        _currentTotalSupply += _shares;

        // commit current state
        balanceOf[msg.sender] += _shares;
        totalSupply = _currentTotalSupply;
        totalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        emit Invest(msg.sender, amount);
        emit Transfer(address(0), msg.sender, _shares);
        if(_accruedFeeShares > 0) {
            balanceOf[_feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), _feeRecipient, _accruedFeeShares);
        }

        // interactions
        loanToken.transferFrom(msg.sender, address(this), amount);
    }

    function divest(uint amount) external {
        uint _loanTokenBalance = loanToken.balanceOf(address(this));
        (address _feeRecipient, uint _feeMantissa) = factory.getFee();
        (  
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) = getCurrentState(
            totalSupply,
            lastAccrueInterestTime,
            block.timestamp,
            totalDebt,
            _loanTokenBalance,
            kinkMantissa,
            _feeMantissa,
            lastCollateralRatioMantissa,
            collateralRatioSpeedMantissa,
            maxCollateralRatioMantissa
        );

        uint _shares = tokenToShares(amount, (_currentTotalDebt + _loanTokenBalance), _currentTotalSupply);
        _currentTotalSupply -= _shares;

        // commit current state
        balanceOf[msg.sender] -= _shares;
        totalSupply = _currentTotalSupply;
        totalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        emit Divest(msg.sender, amount);
        emit Transfer(msg.sender, address(0), _shares);
        if(_accruedFeeShares > 0) {
            balanceOf[_feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), _feeRecipient, _accruedFeeShares);
        }

        // interactions
        loanToken.transfer(msg.sender, amount);
    }

    function secure (address to, uint amount) external {
        require(amount > 0, "Pool: amount too low");
        collateralBalanceOf[to] += amount;
        collateralToken.transferFrom(msg.sender, address(this), amount);
        emit Secure(to, msg.sender, amount);
    }

    function getDebtOf(uint _userDebtShares, uint _debtSharesSupply, uint _totalDebt) internal pure returns (uint) {
        if (_debtSharesSupply == 0) return 0;
        return _userDebtShares * _totalDebt / _debtSharesSupply;
    }
    
    function unsecure(uint amount) external {
        uint _loanTokenBalance = loanToken.balanceOf(address(this));
        (address _feeRecipient, uint _feeMantissa) = factory.getFee();
        (  
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) = getCurrentState(
            totalSupply,
            lastAccrueInterestTime,
            block.timestamp,
            totalDebt,
            _loanTokenBalance,
            kinkMantissa,
            _feeMantissa,
            lastCollateralRatioMantissa,
            collateralRatioSpeedMantissa,
            maxCollateralRatioMantissa
        );

        uint userDebt = getDebtOf(balanceOf[msg.sender], debtSharesSupply, _currentTotalDebt);
        uint userCollateralRatioMantissa = userDebt * 1e18 / (collateralBalanceOf[msg.sender] - amount);
        require(userCollateralRatioMantissa <= _currentCollateralRatioMantissa, "Pool: user collateral ratio too high");

        // commit current state
        totalSupply = _currentTotalSupply;
        totalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        collateralBalanceOf[msg.sender] -= amount;
        emit Unsecure(msg.sender, amount);
        if(_accruedFeeShares > 0) {
            balanceOf[_feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), _feeRecipient, _accruedFeeShares);
        }

        // interactions
        collateralToken.transfer(msg.sender, amount);
    }

    function borrow(uint amount) external {
        uint _loanTokenBalance = loanToken.balanceOf(address(this));
        (address _feeRecipient, uint _feeMantissa) = factory.getFee();
        (  
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) = getCurrentState(
            totalSupply,
            lastAccrueInterestTime,
            block.timestamp,
            totalDebt,
            _loanTokenBalance,
            kinkMantissa,
            _feeMantissa,
            lastCollateralRatioMantissa,
            collateralRatioSpeedMantissa,
            maxCollateralRatioMantissa
        );

        uint _debtSharesSupply = debtSharesSupply;
        uint userDebt = getDebtOf(balanceOf[msg.sender], _debtSharesSupply, _currentTotalDebt) + amount;
        uint userCollateralRatioMantissa = userDebt * 1e18 / collateralBalanceOf[msg.sender];
        require(userCollateralRatioMantissa <= _currentCollateralRatioMantissa, "Pool: user collateral ratio too high");

        uint _newUtil = getUtilizationMantissa(_currentTotalDebt + amount, (_currentTotalDebt + _loanTokenBalance));
        require(_newUtil <= kinkMantissa, "Pool: utilization too high");

        uint _shares = tokenToShares(amount, _currentTotalDebt, _debtSharesSupply);
        _currentTotalDebt += amount;

        // commit current state
        debtSharesBalanceOf[msg.sender] += _shares;
        debtSharesSupply = _debtSharesSupply + _shares;
        totalSupply = _currentTotalSupply;
        totalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        emit Borrow(msg.sender, amount);
        if(_accruedFeeShares > 0) {
            balanceOf[_feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), _feeRecipient, _accruedFeeShares);
        }

        // interactions
        loanToken.transfer(msg.sender, amount);
    }

    //TODO: Add a way to repay all debt including accrued interest
    function repay(address borrower, uint amount) external {
        uint _loanTokenBalance = loanToken.balanceOf(address(this));
        (address _feeRecipient, uint _feeMantissa) = factory.getFee();
        (  
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) = getCurrentState(
            totalSupply,
            lastAccrueInterestTime,
            block.timestamp,
            totalDebt,
            _loanTokenBalance,
            kinkMantissa,
            _feeMantissa,
            lastCollateralRatioMantissa,
            collateralRatioSpeedMantissa,
            maxCollateralRatioMantissa
        );

        uint _debtSharesSupply = debtSharesSupply;
        uint _shares = tokenToShares(amount, _currentTotalDebt, _debtSharesSupply);
        _currentTotalDebt -= amount;

        // commit current state
        debtSharesBalanceOf[borrower] -= _shares;
        debtSharesSupply = _debtSharesSupply - _shares;
        totalSupply = _currentTotalSupply;
        totalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        emit Repay(borrower, msg.sender, amount);
        if(_accruedFeeShares > 0) {
            balanceOf[_feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), _feeRecipient, _accruedFeeShares);
        }

        // interactions
        loanToken.transferFrom(msg.sender, address(this), amount);
    }

    function liquidate(address borrower, uint amount) external {
        uint _loanTokenBalance = loanToken.balanceOf(address(this));
        (address _feeRecipient, uint _feeMantissa) = factory.getFee();
        (  
            uint _currentTotalSupply,
            uint _accruedFeeShares,
            uint _currentCollateralRatioMantissa,
            uint _currentTotalDebt
        ) = getCurrentState(
            totalSupply,
            lastAccrueInterestTime,
            block.timestamp,
            totalDebt,
            _loanTokenBalance,
            kinkMantissa,
            _feeMantissa,
            lastCollateralRatioMantissa,
            collateralRatioSpeedMantissa,
            maxCollateralRatioMantissa
        );

        uint collateralBalance = collateralBalanceOf[borrower];
        uint _debtSharesSupply = debtSharesSupply;
        uint userDebt = getDebtOf(balanceOf[borrower], _debtSharesSupply, _currentTotalDebt);
        uint userCollateralRatioMantissa = userDebt * 1e18 / collateralBalance;
        require(userCollateralRatioMantissa > _currentCollateralRatioMantissa, "Pool: borrower not liquidatable");

        uint _shares = tokenToShares(amount, _currentTotalDebt, _debtSharesSupply);
        _currentTotalDebt -= amount;

        uint userInvertedCollateralRatioMantissa = collateralBalance * 1e18 / userDebt;
        uint collateralReward = amount * userInvertedCollateralRatioMantissa / 1e18;

        // commit current state
        debtSharesBalanceOf[borrower] -= _shares;
        debtSharesSupply = _debtSharesSupply - _shares;
        collateralBalanceOf[borrower] = collateralBalance - collateralReward;
        totalSupply = _currentTotalSupply;
        totalDebt = _currentTotalDebt;
        lastAccrueInterestTime = block.timestamp;
        lastCollateralRatioMantissa = _currentCollateralRatioMantissa;
        emit Liquidate(borrower, amount, collateralReward);
        if(_accruedFeeShares > 0) {
            balanceOf[_feeRecipient] += _accruedFeeShares;
            emit Transfer(address(0), _feeRecipient, _accruedFeeShares);
        }

        // interactions
        loanToken.transferFrom(msg.sender, address(this), amount);
        collateralToken.transfer(msg.sender, collateralReward);
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