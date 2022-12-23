// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

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

    modifier accrueInterest {
        if (totalDebt > 0) {
            // totalDebt = 1,000,000; getBorrowRateMantissa = 0.1e18; seconds = 1 year; interest = 100,000
            uint interest = totalDebt * getBorrowRateMantissa() / 1e18 * (block.timestamp - lastAccrueInterestTime) / 365 days;
            (address feeRecipient, uint feeMantissa) = factory.getFee();
            totalDebt += interest;
            if(feeMantissa > 0) {
                uint fee = interest * feeMantissa / 1e18;
                uint loanTokenShares = loanTokenToShares(fee);
                totalSupply += loanTokenShares;
                balanceOf[feeRecipient] += loanTokenShares;
                emit Transfer(address(0), feeRecipient, loanTokenShares);
            }
        }
        lastCollateralRatioMantissa = getCollateralRatioMantissa();
        lastAccrueInterestTime = block.timestamp;
        _;
    }

    function getBorrowRateMantissa() public view returns (uint) {
        uint util = getUtilizationMantissa();
        if(util <= kinkMantissa) {
            return util * MAX_BASE_APR_MANTISSA / 1e18;
        } else {
            uint normalRate = kinkMantissa * MAX_BASE_APR_MANTISSA / 1e18;
            uint excessUtil = util - kinkMantissa;
            return (excessUtil * MAX_JUMP_APR_MANTISSA / 1e18) + normalRate;
        }
    }

    function getSupplyRateMantissa() public view returns (uint) {
        (, uint feeMantissa) = factory.getFee();
        uint oneMinusFee = 1e18 - feeMantissa;
        uint borrowRate = getBorrowRateMantissa();
        uint rateToPool = borrowRate * oneMinusFee / 1e18;
        return getUtilizationMantissa() * rateToPool / 1e18;
    }

    function getUtilizationMantissa() public view returns (uint) {
        uint supplied = getSuppliedLoanTokens();
        if(supplied == 0) return 0;
        return totalDebt * 1e18 / getSuppliedLoanTokens();
    }

    function loanTokenToShares (uint loanTokenAmount) public view returns (uint) {
        uint supplied = getSuppliedLoanTokens();
        if(supplied == 0) return loanTokenAmount;
        return loanTokenAmount * totalSupply / getSuppliedLoanTokens();
    }

    function getSuppliedLoanTokens () public view returns (uint) {
        return totalDebt + loanToken.balanceOf(address(this));
    }

    function getInvestmentOf (address account) public view returns (uint) {
        if(totalSupply == 0) return 0;
        return balanceOf[account] * getSuppliedLoanTokens() / totalSupply;
    }

    function getCollateralRatioMantissa() public view returns (uint) {
        uint util = getUtilizationMantissa();
        uint _lastAccrueInterestTime = lastAccrueInterestTime;
        uint _lastCollateralRatioMantissa = lastCollateralRatioMantissa;
        if(_lastAccrueInterestTime == block.timestamp) return _lastCollateralRatioMantissa;

        if(util <= kinkMantissa) {
            if(_lastCollateralRatioMantissa == maxCollateralRatioMantissa) return _lastCollateralRatioMantissa;
            uint timeDelta = block.timestamp - _lastAccrueInterestTime;
            uint change = timeDelta * collateralRatioSpeedMantissa;
            if(_lastCollateralRatioMantissa + change > maxCollateralRatioMantissa) {
                return maxCollateralRatioMantissa;
            } else {
                return _lastCollateralRatioMantissa + change;
            }
        } else {
            if(_lastCollateralRatioMantissa == 0) return 0;
            uint timeDelta = block.timestamp - _lastAccrueInterestTime;
            uint change = timeDelta * collateralRatioSpeedMantissa;
            if(_lastCollateralRatioMantissa < change) {
                return 0;
            } else {
                return _lastCollateralRatioMantissa - change;
            }
        }
    }
   
    function getDebtOf(address user) public view returns (uint) {
        if (debtSharesSupply == 0) return 0;
        return debtSharesBalanceOf[user] * totalDebt / debtSharesSupply;
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

    function invest(uint amount) external accrueInterest {
        if (totalSupply == 0) {
            totalSupply = amount;
            balanceOf[msg.sender] = amount;

            emit Transfer(address(0), msg.sender, amount);
        } else {
            uint loanTokenShares = loanTokenToShares(amount);
            totalSupply += loanTokenShares;
            balanceOf[msg.sender] += loanTokenShares;

            emit Transfer(address(0), msg.sender, loanTokenShares);
        }

        loanToken.transferFrom(msg.sender, address(this), amount);
        emit Invest(msg.sender, amount);
    }

    function divest(uint amount) external accrueInterest {
        uint loanTokenShares = loanTokenToShares(amount);
        totalSupply -= loanTokenShares;
        balanceOf[msg.sender] -= loanTokenShares;

        loanToken.transfer(msg.sender, amount);
        emit Transfer(msg.sender, address(0), loanTokenShares);
        emit Divest(msg.sender, amount);
    }

    function secure (address to, uint amount) external {
        require(amount > 0, "Pool: amount too low");
        collateralBalanceOf[to] += amount;
        collateralToken.transferFrom(msg.sender, address(this), amount);
        emit Secure(to, msg.sender, amount);
    }

    function assertCollateralRatio(address user) internal view {
        if(getDebtOf(user) > 0) {
            uint userCollateralRatioMantissa = getDebtOf(user) * 1e18 / collateralBalanceOf[user];
            require(userCollateralRatioMantissa <= lastCollateralRatioMantissa, "Pool: user collateral ratio too high");
        }
    }

    function isLiquidatable(address user) public view returns (bool) {
        if(getDebtOf(user) == 0) return false;
        uint userCollateralRatioMantissa = getDebtOf(user) * 1e18 / collateralBalanceOf[user];
        if (userCollateralRatioMantissa > getCollateralRatioMantissa()) return true;
        return false;
    }

    function unsecure(uint amount) external accrueInterest {
        require(amount > 0, "Pool: amount too low");
        collateralBalanceOf[msg.sender] -= amount;
        collateralToken.transfer(msg.sender, amount);
        emit Unsecure(msg.sender, amount);
        assertCollateralRatio(msg.sender);
    }

    function borrow(uint amount) external accrueInterest {
        require(amount > 0, "Pool: amount too low");
        if (debtSharesSupply == 0) {
            debtSharesSupply = amount;
            debtSharesBalanceOf[msg.sender] = amount;
        } else {
            uint debtShares = amount * debtSharesSupply / totalDebt;
            debtSharesSupply += debtShares;
            debtSharesBalanceOf[msg.sender] += debtShares; 
        }
        totalDebt += amount;
        loanToken.transfer(msg.sender, amount);
        emit Borrow(msg.sender, amount);
        assertCollateralRatio(msg.sender);
        require(getUtilizationMantissa() <= kinkMantissa, "Pool: utilization too high");
    }

    function repay(address borrower, uint amount) external accrueInterest {
        //TODO: Add a way to repay all debt including accrued interest
        require(amount > 0, "Pool: amount too low");
        uint debtShares = amount * debtSharesSupply / totalDebt;
        debtSharesSupply -= debtShares;
        debtSharesBalanceOf[borrower] -= debtShares;
        totalDebt -= amount;
        loanToken.transferFrom(msg.sender, address(this), amount);
        emit Repay(borrower, msg.sender, amount);
    }

    function liquidate(address borrower, uint amount) external accrueInterest {
        require(isLiquidatable(borrower), "Pool: borrower not liquidatable");
        require(amount > 0, "Pool: amount too low");
        uint userInvertedCollateralRatioMantissa = collateralBalanceOf[borrower] * 1e18 / getDebtOf(borrower);
        uint debtShares = amount * debtSharesSupply / totalDebt;
        debtSharesSupply -= debtShares;
        debtSharesBalanceOf[borrower] -= debtShares;
        totalDebt -= amount;
        uint collateralReward = amount * userInvertedCollateralRatioMantissa / 1e18;
        collateralBalanceOf[borrower] -= collateralReward;
        emit Liquidate(borrower, amount, collateralReward);
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