// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IERC20 {
    function balanceOf(address) external view returns(uint);
    function transferFrom(address sender, address recipient, uint256 amount) external returns(bool);
    function decimals() external view returns (uint8);
    function transfer(address, uint) external returns (bool);
}

interface IFactory {
    function getFee(address pool) external view returns (address to, uint feeBps);
}

contract Pool {
    uint constant MAX_UTIL_BPS = 8000;
    IFactory public immutable factory;
    IERC20 public immutable collateralToken;
    IERC20 public immutable creditToken;
    uint public immutable collateralRatioBps;
    uint public immutable interestRateBps;
    uint public immutable creditTokenDecimals;
    uint public immutable collateralTokenDecimals;

    uint public totalSupply;
    mapping (address => uint) public balanceOf;

    uint public collateralSharesSupply;
    mapping (address => uint) public collateralSharesBalanceOf;

    uint public totalDebt;
    uint public debtSharesSupply;
    mapping (address => uint) public debtSharesBalanceOf;
    uint public debtLastUpdated;

    constructor(IERC20 _collateralToken, IERC20 _creditToken, uint _collateralRatioBps, uint _interestRateBps){
        require(_collateralRatioBps > 0);
        factory = IFactory(msg.sender);
        collateralToken = _collateralToken;
        creditToken = _creditToken;
        collateralRatioBps = _collateralRatioBps;
        interestRateBps = _interestRateBps;
        uint8 _creditTokenDecimals = creditToken.decimals();
        uint8 _collateralTokenDecimals = collateralToken.decimals();
        require(_creditTokenDecimals > 0 && _creditTokenDecimals <= 18);
        require(_collateralTokenDecimals > 0 && _collateralTokenDecimals <= 18);
        creditTokenDecimals = _creditTokenDecimals;
        collateralTokenDecimals = _collateralTokenDecimals;
    }

    modifier accrueInterest {
        if (totalDebt > 0) {
            uint interest = (block.timestamp - debtLastUpdated) * interestRateBps / 10000 / 365 days;
            (address feeRecipient, uint feeBps) = factory.getFee(address(this));
            if(feeBps > 0) {
                uint fee = interest * feeBps / 10000;
                uint creditShares = fee * totalSupply / (totalDebt + creditToken.balanceOf(address(this)));
                totalDebt += interest - fee;
                totalSupply += creditShares;
                balanceOf[feeRecipient] += creditShares;
                emit Transfer(address(0), feeRecipient, creditShares);
            } else {
                totalDebt += interest;
            }
        }
        debtLastUpdated = block.timestamp;
        _;
    }

    function invest(uint amount) external accrueInterest {
        if (totalSupply == 0) {
            totalSupply = amount;
            balanceOf[msg.sender] = amount;

            emit Transfer(address(0), msg.sender, amount);
        } else {
            uint creditShares = amount * totalSupply / (totalDebt + creditToken.balanceOf(address(this)));
            totalSupply += creditShares;
            balanceOf[msg.sender] += creditShares;

            emit Transfer(address(0), msg.sender, creditShares);
        }
        
        creditToken.transferFrom(msg.sender, address(this), amount);
    }    

    function divest (uint amount) external accrueInterest {
        uint creditShares = amount * totalSupply / (totalDebt + creditToken.balanceOf(address(this)));
        totalSupply -= creditShares;
        balanceOf[msg.sender] -= creditShares;

        creditToken.transfer(msg.sender, amount);
        emit Transfer(msg.sender, address(0), creditShares);      
    }

    function recall (uint amount) external accrueInterest {

    }

    function secure (uint amount) external {
        if (collateralSharesSupply == 0) {
            collateralSharesSupply = amount;
            collateralSharesBalanceOf[msg.sender] = amount;
        } else {
            uint collateralShares = amount * collateralSharesSupply / collateralToken.balanceOf(address(this));
            collateralSharesSupply += collateralShares;
            collateralSharesBalanceOf[msg.sender] += collateralShares; 
        }
        collateralToken.transferFrom(msg.sender, address(this), amount);
    }
    
    function unsecure(uint amount) external accrueInterest {
        //require(getCollateralOf(msg.sender) >= amount);
        uint collateralShares = amount * collateralSharesSupply / collateralToken.balanceOf(address(this));
        collateralSharesBalanceOf[msg.sender] -= collateralShares;
        collateralSharesSupply -= collateralShares;
        collateralToken.transfer(msg.sender, amount);
        require(getMaxCreditOf(msg.sender) >= getDebtOf(msg.sender));
    }

    function getMaxCreditOf(address user) public view returns (uint) {
        if (collateralSharesSupply == 0) return 0;
        uint collateralAmount = collateralSharesBalanceOf[user] * collateralToken.balanceOf(address(this)) / collateralSharesSupply;
        return collateralAmount * (10 ** (18 - collateralTokenDecimals)) * collateralRatioBps / 10000 / (10 ** (18 - creditTokenDecimals));
    }

    function getDebtOf(address user) public view returns (uint) {
        if (debtSharesSupply == 0) return 0;
        return debtSharesBalanceOf[user] * totalDebt / debtSharesSupply;
    }

    function getInvestmentOf(address user) public view returns (uint) {
        if (totalSupply == 0) return 0;
        return balanceOf[user] * (totalDebt + creditToken.balanceOf(address(this))) / totalSupply;
    }

    function getCollateralOf(address user) public view returns (uint) {
        if (collateralSharesSupply == 0) return 0;
        return collateralSharesBalanceOf[user] * collateralToken.balanceOf(address(this)) / collateralSharesSupply;
    }

    function borrow (uint amount) external accrueInterest {
        uint _totalDebt = totalDebt;
        require(_totalDebt + amount / (_totalDebt + creditToken.balanceOf(address(this))) * 10000 < MAX_UTIL_BPS, "EXCEEDED MAX UTILIZATION");
        require(getMaxCreditOf(msg.sender) >= getDebtOf(msg.sender) + amount);

        if (debtSharesSupply == 0) {
            debtSharesSupply = amount;
            debtSharesBalanceOf[msg.sender] = amount;
        } else {
            uint debtShares = amount * debtSharesSupply / totalDebt;
            debtSharesSupply += debtShares;
            debtSharesBalanceOf[msg.sender] += debtShares; 
        }
        totalDebt += amount;
        creditToken.transfer(msg.sender, amount);        
    }

    function repay(address borrower, uint amount) external accrueInterest {
        uint debtShares = amount * debtSharesSupply / totalDebt;
        debtSharesBalanceOf[borrower] -= debtShares;
        totalDebt -= amount;
        debtSharesSupply -= debtShares;
        creditToken.transferFrom(msg.sender, address(this), amount);
    }



    event Transfer(address from, address to, uint value);
}
