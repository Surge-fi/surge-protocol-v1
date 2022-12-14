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
    uint constant KINK_BPS = 8000;
    uint constant MAX_BASE_APR_BPS = 4000;
    uint constant MAX_JUMP_APR_BPS = 6000;
    uint constant MAX_UTIL_BPS = 8000;
    uint constant AUCTION_INTERVAL = 1 hours;
    IFactory public immutable factory;
    IERC20 public immutable collateralToken;
    IERC20 public immutable creditToken;
    uint public immutable collateralRatioBps;
    uint public immutable creditTokenDecimals;
    uint public immutable collateralTokenDecimals;

    uint public totalSupply;
    mapping (address => uint) public balanceOf;

    uint public totalDebt;
    uint public debtSharesSupply;
    mapping (address => uint) public debtSharesBalanceOf;
    uint public debtLastUpdated;

    uint public collateralSharesSupply;
    mapping (address => uint) public collateralSharesBalanceOf;

    uint public totalAuctionsReserves;
    mapping (uint => uint) public auctionSharesSupplies;
    mapping (uint => uint) public auctionSharesInitialSupplies;
    mapping (uint => uint) public auctionCreditReserves;
    // auctionId => user => shares
    mapping (uint => mapping(address => uint)) public auctionShares;

    constructor(IERC20 _collateralToken, IERC20 _creditToken, uint _collateralRatioBps){
        require(_collateralRatioBps > 0);
        factory = IFactory(msg.sender);
        collateralToken = _collateralToken;
        creditToken = _creditToken;
        collateralRatioBps = _collateralRatioBps;
        uint8 _creditTokenDecimals = creditToken.decimals();
        uint8 _collateralTokenDecimals = collateralToken.decimals();
        require(_creditTokenDecimals > 0 && _creditTokenDecimals <= 18);
        require(_collateralTokenDecimals > 0 && _collateralTokenDecimals <= 18);
        creditTokenDecimals = _creditTokenDecimals;
        collateralTokenDecimals = _collateralTokenDecimals;
    }

    modifier accrueInterest {
        if (totalDebt > 0) {
            // totalDebt = 1,000,000; getBorrowRateBps = 1000; seconds = 1 year; interest = 100,000
            uint interest = totalDebt * getBorrowRateBps() / 10000 * (block.timestamp - debtLastUpdated) / 365 days;
            (address feeRecipient, uint feeBps) = factory.getFee(address(this));
            totalDebt += interest;
            if(feeBps > 0) {
                uint fee = interest * feeBps / 10000;
                uint creditShares = creditToShares(fee);
                totalSupply += creditShares;
                balanceOf[feeRecipient] += creditShares;
                emit Transfer(address(0), feeRecipient, creditShares);
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
            uint creditShares = creditToShares(amount);
            totalSupply += creditShares;
            balanceOf[msg.sender] += creditShares;

            emit Transfer(address(0), msg.sender, creditShares);
        }
        
        creditToken.transferFrom(msg.sender, address(this), amount);
    }    

    function divest (uint amount) public accrueInterest {
        uint creditShares = creditToShares(amount);
        totalSupply -= creditShares;
        balanceOf[msg.sender] -= creditShares;

        creditToken.transfer(msg.sender, amount);
        emit Transfer(msg.sender, address(0), creditShares);      
    }

    // If returns auctionId as 0 then no auction
    function recall (uint amount) external returns (uint auctionId) {
        if(creditToken.balanceOf(address(this)) >= amount) {
            divest(amount);
        } else {
            uint creditShares = creditToShares(amount);
            balanceOf[msg.sender] -= creditShares;
            balanceOf[address(this)] += creditShares;

            emit Transfer(msg.sender, address(this), creditShares);

            auctionId = block.timestamp / AUCTION_INTERVAL + 1;
            uint auctionSharesSupply = auctionSharesSupplies[auctionId];
            if(auctionSharesSupply == 0) {
                auctionSharesInitialSupplies[auctionId] = creditShares;
                auctionSharesSupplies[auctionId] = creditShares;
                auctionShares[auctionId][msg.sender] = creditShares;
            } else {
                uint shares = creditShares * auctionSharesSupply / (creditShares + auctionSharesSupply);
                auctionSharesInitialSupplies[auctionId] += shares;
                auctionSharesSupplies[auctionId] += shares;
                auctionShares[auctionId][msg.sender] += shares;
            }
        }
    }

    function sell(uint creditTokenAmount, uint minCollateralAmount) external accrueInterest {
        uint auctionId = block.timestamp / AUCTION_INTERVAL;
        // TODO: TEST
        uint maxCollateralCost = creditTokenAmount * (10 ** (18 - creditTokenDecimals)) * 10000 / collateralRatioBps / (10 ** (18 - collateralTokenDecimals));
        uint auctionStartTimestamp = auctionId * AUCTION_INTERVAL;
        uint currentCollateralCost = (block.timestamp - auctionStartTimestamp) * 10000 / AUCTION_INTERVAL * maxCollateralCost / 10000;
        require(currentCollateralCost >= minCollateralAmount);
        uint creditShares = creditToShares(creditTokenAmount);
        // TODO: Test auction cannot oversell collateral for more creditTokens than auctioned
        auctionSharesSupplies[auctionId] -= creditShares;
        auctionCreditReserves[auctionId] += creditTokenAmount;
        totalAuctionsReserves += creditTokenAmount;
        totalDebt -= creditTokenAmount;
        totalSupply -= creditShares;
        balanceOf[address(this)] -= creditShares;
        emit Transfer(address(this), address(0), creditShares);
        creditToken.transferFrom(msg.sender, address(this), creditTokenAmount);
        collateralToken.transfer(msg.sender, currentCollateralCost);
    }

    function claimAuctionProceeds(uint auctionId) external {
        uint currentAuctionId = block.timestamp / AUCTION_INTERVAL;
        require(auctionId < currentAuctionId);
        uint auctionShareBalance = auctionShares[auctionId][msg.sender];
        uint proceeds = auctionShareBalance * auctionCreditReserves[auctionId] / auctionSharesInitialSupplies[auctionId];
        uint remainingSharesRefund = auctionShareBalance * auctionSharesSupplies[auctionId] / auctionSharesInitialSupplies[auctionId];
        auctionShares[auctionId][msg.sender] = 0;
        auctionSharesInitialSupplies[auctionId] -= auctionShareBalance;
        auctionCreditReserves[auctionId] -= proceeds;
        totalAuctionsReserves -= proceeds;
        if(proceeds > 0) {
            creditToken.transfer(msg.sender, proceeds);
        }
        if(remainingSharesRefund > 0) {
            balanceOf[address(this)] -= remainingSharesRefund;
            balanceOf[msg.sender] += remainingSharesRefund;
            emit Transfer(address(this), msg.sender, remainingSharesRefund);
        }
    }

    function creditToShares (uint creditTokenAmount) public view returns (uint) {
        return creditTokenAmount * totalSupply / getSuppliedCreditTokens();
    }

    function getSuppliedCreditTokens () public view returns (uint) {
        return totalDebt + creditToken.balanceOf(address(this)) - totalAuctionsReserves;
    }

    function getDebtOf(address user) public view returns (uint) {
        if (debtSharesSupply == 0) return 0;
        return debtSharesBalanceOf[user] * totalDebt / debtSharesSupply;
    }

    function getInvestmentOf(address user) public view returns (uint) {
        if (totalSupply == 0) return 0;
        return balanceOf[user] * getSuppliedCreditTokens() / totalSupply;
    }

    function getCollateralOf(address user) public view returns (uint) {
        if (debtSharesSupply == 0) return 0;
        return debtSharesBalanceOf[user] * collateralToken.balanceOf(address(this)) / debtSharesSupply;
    }

    function getUtilizationBps() public view returns (uint) {
        uint _totalDebt = totalDebt;
        return _totalDebt / getSuppliedCreditTokens() * 10000;
    }

    function getBorrowRateBps() public view returns (uint) {
        uint util = getUtilizationBps();
        if(util <= KINK_BPS) {
            return util * MAX_BASE_APR_BPS / KINK_BPS;
        } else {
            uint excessUtil = util - KINK_BPS;
            return (excessUtil * MAX_JUMP_APR_BPS / (10000 - KINK_BPS)) + MAX_BASE_APR_BPS;
        }
    }

    function getMaxCreditOf(address user) public view returns (uint) {
        if (collateralSharesSupply == 0) return 0;
        uint collateralAmount = collateralSharesBalanceOf[user] * collateralToken.balanceOf(address(this)) / collateralSharesSupply;
        return collateralAmount * (10 ** (18 - collateralTokenDecimals)) * collateralRatioBps / 10000 / (10 ** (18 - creditTokenDecimals));
    }

    function borrow (uint amount) external accrueInterest {
        require(totalDebt + amount / getSuppliedCreditTokens() * 10000 < MAX_UTIL_BPS, "EXCEEDED MAX UTILIZATION");
        
        // TODO: TEST
        uint collateralAmount = amount * (10 ** (18 - creditTokenDecimals)) * 10000 / collateralRatioBps / (10 ** (18 - collateralTokenDecimals));
 
        if(collateralSharesSupply == 0) {
            collateralSharesSupply = collateralAmount;
            collateralSharesBalanceOf[msg.sender] = collateralAmount;
        } else {
            uint collateralShares = collateralAmount * collateralSharesSupply / collateralToken.balanceOf(address(this));
            collateralSharesSupply += collateralShares;
            collateralSharesBalanceOf[msg.sender] += collateralShares;
        }

        if (debtSharesSupply == 0) {
            debtSharesSupply = amount;
            debtSharesBalanceOf[msg.sender] = amount;
        } else {
            // TODO: test interest accrual over time
            uint debtShares = amount * debtSharesSupply / totalDebt;
            debtSharesSupply += debtShares;
            debtSharesBalanceOf[msg.sender] += debtShares; 
        }
        totalDebt += amount;

        collateralToken.transferFrom(msg.sender, address(this), collateralAmount);
        creditToken.transfer(msg.sender, amount);        
    }

    function repay(address borrower, uint amount) external accrueInterest {
        uint debtShares = amount * debtSharesSupply / totalDebt;
        debtSharesBalanceOf[borrower] -= debtShares;
        // TODO: test interest accrual over time
        totalDebt -= amount;
        debtSharesSupply -= debtShares;

        creditToken.transferFrom(msg.sender, address(this), amount);
    }

    function withdrawCollateral(uint amount) external accrueInterest {
        uint collateralShares = amount * collateralSharesSupply / collateralToken.balanceOf(address(this));
        collateralSharesBalanceOf[msg.sender] -= collateralShares;
        collateralSharesSupply -= collateralShares;
        collateralToken.transfer(msg.sender, amount);
        require(getMaxCreditOf(msg.sender) >= getDebtOf(msg.sender));
    }


    event Transfer(address from, address to, uint value);
}
