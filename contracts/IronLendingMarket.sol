// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IronToken.sol";

/**
 * @title IronLendingMarket
 * @notice Variable-rate lending market with a kinked interest rate curve.
 *         Lenders deposit tokens to earn interest; borrowers post collateral
 *         (in a separate token) and draw funds at market-driven variable rates.
 * @dev Interest accrues per block using a two-slope (kinked) rate model.
 *      Below the utilisation kink the rate scales gently with {SLOPE_1}; above
 *      it the rate rises steeply with {SLOPE_2} to incentivise repayments and
 *      attract fresh liquidity.
 *      Collateral is valued at a fixed LTV defined by {COLLATERAL_FACTOR}.
 */
contract IronLendingMarket {
    IronToken public immutable lendingToken;
    IronToken public immutable collateralToken;

    address public owner;

    // ─── Interest rate parameters (kinked curve) ───
    uint256 public constant BASE_RATE = 200; // 2% base APR (in bps)
    uint256 public constant SLOPE_1 = 375; // 3.75% slope below kink (bps)
    uint256 public constant SLOPE_2 = 150000; // 1500% slope above kink (bps) — AGGRESSIVE
    uint256 public constant KINK = 8000; // 80% utilization kink (in bps)
    uint256 public constant BPS = 10000;

    // ─── Lending ───
    uint256 public totalDeposits;
    uint256 public totalBorrowed;
    mapping(address => uint256) public lenderDeposits;

    // ─── Borrowing ───
    struct BorrowPosition {
        uint256 collateral;
        uint256 borrowed;
        uint256 lastAccrueBlock;
    }
    mapping(address => BorrowPosition) public positions;

    uint256 public constant COLLATERAL_FACTOR = 7500; // 75% LTV
    uint256 public constant BLOCKS_PER_YEAR = 2_628_000; // ~12s blocks

    // ─── Accumulated interest ───
    uint256 public totalInterestAccumulated;
    uint256 public lastAccrueBlock;

    event Deposited(address indexed lender, uint256 amount);
    event Withdrawn(address indexed lender, uint256 amount);
    event Borrowed(address indexed borrower, uint256 amount, uint256 collateral);
    event Repaid(address indexed borrower, uint256 amount);
    event InterestAccrued(uint256 interest, uint256 utilization, uint256 rate);

    constructor(address _lendingToken, address _collateralToken) {
        lendingToken = IronToken(_lendingToken);
        collateralToken = IronToken(_collateralToken);
        owner = msg.sender;
        lastAccrueBlock = block.number;
    }

    // ═══════════════════════════════════════════════════════════════
    // INTEREST RATE MODEL
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Calculate current utilization rate (in bps).
     */
    function utilizationRate() public view returns (uint256) {
        if (totalDeposits == 0) return 0;
        return (totalBorrowed * BPS) / totalDeposits;
    }

    /**
     * @notice Returns the current annualised interest rate in basis points.
     * @dev Two-slope kinked model. Below {KINK} utilisation the rate increases
     *      gradually via {SLOPE_1}. Above the kink it rises steeply via {SLOPE_2}
     *      to create strong repayment incentives and protect lender liquidity.
     *      Representative values at current parameters:
     *        util 50% → ~388 bps  (~3.9% APR)
     *        util 79% → ~496 bps  (~5.0% APR)
     *        util 81% → ~7,800 bps (~78% APR)
     *        util 95% → ~113,000 bps (~1,130% APR)
     */
    function getInterestRate() public view returns (uint256) {
        uint256 util = utilizationRate();

        if (util <= KINK) {
            // Below kink: gentle slope
            return BASE_RATE + (SLOPE_1 * util) / BPS;
        } else {
            // Above kink: extreme slope
            uint256 baseAtKink = BASE_RATE + (SLOPE_1 * KINK) / BPS;
            uint256 excessUtil = util - KINK;
            uint256 maxExcess = BPS - KINK; // 2000 bps (20%)
            return baseAtKink + (SLOPE_2 * excessUtil) / maxExcess;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // LENDING
    // ═══════════════════════════════════════════════════════════════

    function deposit(uint256 amount) external {
        accrueInterest();
        lendingToken.transferFrom(msg.sender, address(this), amount);
        lenderDeposits[msg.sender] += amount;
        totalDeposits += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        accrueInterest();
        require(lenderDeposits[msg.sender] >= amount, "Market: insufficient deposit");

        uint256 available = lendingToken.balanceOf(address(this));
        require(available >= amount, "Market: insufficient liquidity");

        lenderDeposits[msg.sender] -= amount;
        totalDeposits -= amount;
        lendingToken.transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    // BORROWING
    // ═══════════════════════════════════════════════════════════════

    function borrow(uint256 amount, uint256 collateralAmount) external {
        accrueInterest();

        // Post collateral
        if (collateralAmount > 0) {
            collateralToken.transferFrom(msg.sender, address(this), collateralAmount);
            positions[msg.sender].collateral += collateralAmount;
        }

        // Check capacity
        uint256 maxBorrow = (positions[msg.sender].collateral * COLLATERAL_FACTOR) / BPS;
        require(positions[msg.sender].borrowed + amount <= maxBorrow, "Market: exceeds borrowing capacity");

        uint256 available = lendingToken.balanceOf(address(this));
        require(available >= amount, "Market: insufficient liquidity");

        positions[msg.sender].borrowed += amount;
        positions[msg.sender].lastAccrueBlock = block.number;
        totalBorrowed += amount;

        lendingToken.transfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount, collateralAmount);
    }

    function repay(uint256 amount) external {
        accrueInterest();

        BorrowPosition storage pos = positions[msg.sender];
        uint256 repayAmount = amount > pos.borrowed ? pos.borrowed : amount;

        lendingToken.transferFrom(msg.sender, address(this), repayAmount);
        pos.borrowed -= repayAmount;
        totalBorrowed -= repayAmount;

        emit Repaid(msg.sender, repayAmount);
    }

    // ═══════════════════════════════════════════════════════════════
    // INTEREST ACCRUAL
    // ═══════════════════════════════════════════════════════════════

    function accrueInterest() public {
        uint256 blockDelta = block.number - lastAccrueBlock;
        if (blockDelta == 0 || totalBorrowed == 0) {
            lastAccrueBlock = block.number;
            return;
        }

        uint256 rate = getInterestRate();
        uint256 interest = (totalBorrowed * rate * blockDelta) / (BLOCKS_PER_YEAR * BPS);

        totalBorrowed += interest;
        totalInterestAccumulated += interest;
        lastAccrueBlock = block.number;

        emit InterestAccrued(interest, utilizationRate(), rate);
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════

    function getPosition(address user) external view returns (uint256 collateral, uint256 borrowed, uint256 maxBorrow) {
        BorrowPosition storage pos = positions[user];
        collateral = pos.collateral;
        borrowed = pos.borrowed;
        maxBorrow = (collateral * COLLATERAL_FACTOR) / BPS;
    }

    function getLenderEarnings(address lender) external view returns (uint256) {
        if (totalDeposits == 0) return 0;
        return (totalInterestAccumulated * lenderDeposits[lender]) / totalDeposits;
    }
}
